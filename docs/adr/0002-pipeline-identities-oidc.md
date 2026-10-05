# ADR 0002: Pipeline identities: user-assigned managed identities with GitHub OIDC

**Status:** Proposed
**Date:** 2026-10-04

## Context

All changes to this lab's infrastructure are made by Terraform running in GitHub Actions. To do that, the pipeline needs a non-human identity in Microsoft Entra ID that Azure will accept a login from.

Three questions had to be answered:

1. **What kind of identity?** Azure offers two kinds of workload identity that GitHub Actions can log in as: an app registration (with its service principal) or a user-assigned managed identity.
2. **How does GitHub prove it is allowed to use that identity?** Options are a stored secret, a certificate, or federation using OpenID Connect (OIDC).
3. **How much access does it get?** `terraform plan` and `terraform apply` carry very different risk. Plan runs on every pull request, often on unreviewed code, and only needs to read. Apply changes infrastructure and should only run after review and approval.

The bootstrap that created the Terraform state backend is recorded in [ADR 0001](0001-manual-terraform-state-bootstrap.md).

## Decision

### Two identities, split by risk

| Identity | Used by | Purpose |
|---|---|---|
| `mi-tf-plan` | Pull request workflows | Read the environment and produce a plan |
| `mi-tf-apply` | Approved deployments only | Change the environment |

Splitting them means anything that can trigger a plan, including a malicious or buggy pull request, can only read. Write access sits behind an approval gate.

### User-assigned managed identities

Both identities are user-assigned managed identities, created in `rg-bootstrap` alongside the state backend. Terraform does not manage them.

### OIDC federation, no stored secrets

Each identity has a federated identity credential that trusts tokens issued by GitHub Actions, but only for this repository in a specific situation:

| Identity | Issuer | Audience | Subject |
|---|---|---|---|
| `mi-tf-plan` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` | `repo:cooke-labs/azure-detection-engineering-lab:pull_request` |
| `mi-tf-apply` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` | `repo:cooke-labs/azure-detection-engineering-lab:environment:lab` |

On each run, GitHub issues a short-lived token describing the workflow. Entra ID checks it against these rules and, if it matches, issues a short-lived Azure token. No password, secret, or certificate is stored anywhere.

The **subject** is the security boundary. The apply identity trusts only jobs running in the `lab` GitHub environment, which requires manual approval from a designated reviewer. It is deliberately not trusted for pull requests or plain branch pushes.

### Least-privilege role assignments

| Identity | Role | Scope | Why |
|---|---|---|---|
| `mi-tf-plan` | Reader | Subscription | See resources to compute a plan; change nothing |
| `mi-tf-plan` | Storage Blob Data Reader | `tfstate` container | Read state; cannot modify, delete, or lease it |
| `mi-tf-apply` | Contributor | Workload resource group(s), e.g. `rg-lab-core` | Create, change, and delete resources inside the workload boundary only |
| `mi-tf-apply` | Storage Blob Data Contributor | `tfstate` container | Read, write, and lock state |

Reader and Contributor don't include access to the *contents* of storage (the data plane), which is why the storage roles are assigned separately. Both are scoped to the single `tfstate` container, not the storage account.

**The plan identity is read-only end to end.** Plan runs with `terraform plan -lock=false`. Terraform's state lock is a lease on the state blob, and taking a lease is a write operation; skipping it lets the plan identity hold only Storage Blob Data Reader. This is safe because plan never writes state. Apply still takes the lock, so two applies can never run against state at the same time.

**The apply identity is scoped to workload resource groups, never the subscription.** Workload resource groups are created during bootstrap, and Terraform references them as data sources rather than creating them. The apply identity has no access to `rg-bootstrap`.

Not granted at this time:

- **Any role-assignment-capable role** (such as User Access Administrator or Role Based Access Control Administrator). If Terraform later needs to create role assignments, a constrained role will be added and recorded in a new ADR.
- **Any subscription-scope write role.** Some resources this lab will need live at subscription scope, such as sending the Activity Log to Log Analytics, Azure Policy assignments, and Defender for Cloud settings. Each will get the narrowest role that covers it (for example, Monitoring Contributor for diagnostic settings), recorded when added.
- **Any data-plane role for the human operator.** Terraform never runs locally; only the pipeline identities read or write state.

### GitHub configuration

- A `lab` environment with a required reviewer serves as the approval gate.
- The tenant ID, subscription ID, and the two client IDs are stored as GitHub Actions secrets. They are identifiers, not credentials, but secrets are masked in workflow logs, which are publicly visible on this repository. Variables are not.
- Workflows triggered by pull requests from outside contributors require approval before running.

## Alternatives considered

**App registration with a client secret.** This was the standard pattern before OIDC federation was available, and it is still common in older tutorials. Rejected: it requires a long-lived secret stored in GitHub that must be rotated and can leak.

**App registration with OIDC federation.** Viable and widely used; much of the existing GitHub-to-Azure documentation is written around it. GitHub workflows can't tell the difference between this and the chosen option. Rejected because:

- A secret or certificate can be added to an app registration later, intentionally or by mistake, reintroducing a long-lived credential. A managed identity cannot hold one at all.
- An app registration lives at the tenant level, separate from the bootstrap resources. A managed identity is an Azure resource, governed by the same RBAC, tags, and resource group as the state backend.
- Creating an app registration requires Entra ID permissions in addition to Azure permissions.

**A single identity for both plan and apply.** Simpler, but anything able to trigger a plan would hold write access to the environment. Rejected.

**Contributor for the apply identity at subscription scope.** Simplest, since Terraform could create resource groups itself. Rejected because subscription scope includes `rg-bootstrap`, which would let the apply identity:

- Add a federated credential to *itself* trusting pull requests, bypassing the approval gate.
- Re-enable shared key access on the state storage account and read its keys, bypassing Entra ID.
- Modify or delete the plan identity or its trust rules.

In short, the pipeline could be turned against the controls that constrain it.

**Storage Blob Data Contributor for the plan identity, so plan can take the state lock.** This is Terraform's default behavior. Rejected because write access would let a pull request tamper with or delete the state file, or hold an indefinite lease that blocks every future apply. Plan gains nothing from locking, since it never writes state.

## Consequences

**Positive**

- No stored credentials anywhere in the pipeline.
- Pull requests, the least-trusted entry point, cannot change Azure resources or Terraform state.
- Every apply requires explicit human approval.
- The pipeline cannot modify its own identities, its trust rules, or the state backend's configuration.

**Negative / trade-offs**

- **Subject strings must match exactly.** GitHub includes `pull_request` in the token's subject only when the job does not reference an environment, and includes the environment name when it does. The plan job must not declare an environment; the apply job must declare `lab`. A mismatch causes login to fail.
- **New resource groups require a manual bootstrap step.** Terraform cannot create them; each one must be pre-created and given an apply role assignment by a human operator.
- **Resource provider registration must be handled outside Terraform.** By default, the `azurerm` provider tries to register Azure resource providers at subscription scope, which neither identity is permitted to do. Provider registration is disabled in Terraform's configuration, and required providers are registered manually during bootstrap.
- **Plans may occasionally be stale.** Because plan doesn't lock, it can read state while an apply is running. Saved plan files mitigate this: Terraform refuses to apply a plan built from outdated state.
- **Read access to state remains a risk.** Anyone who can trigger an authenticated plan can read the state file, which may contain sensitive values. Workflows from forked repositories don't receive OIDC tokens by default, so only people with push access to this repository can trigger an authenticated plan. Secrets are kept out of Terraform state where possible.
- **The approval gate depends on GitHub settings outside Azure.** Branch protection on `main` and the `lab` environment's required reviewer must stay in place; if they are removed, the boundary weakens without any change in Azure.
- **Reader at subscription scope** lets the plan identity see every resource in the subscription, including the bootstrap resources' configuration. Acceptable for a single-purpose lab subscription.
- **Managing Entra ID objects is harder.** If Terraform needs to manage Entra objects (groups, app registrations) through Microsoft Graph, Graph permissions must be granted to the managed identity through PowerShell or the Graph API, since the portal offers no UI for it. This is the main trigger to revisit this decision.
- Each identity supports a maximum of 20 federated credentials, which limits how many repositories, branches, or environments it can trust.

## References

- [Workload identity federation overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a user-assigned managed identity to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [Use the Azure Login action with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)
- [GitHub OpenID Connect reference (subject claim formats)](https://docs.github.com/en/actions/reference/security/oidc)
