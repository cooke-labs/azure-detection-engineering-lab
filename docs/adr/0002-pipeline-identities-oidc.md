# ADR 0002: Pipeline identities: user-assigned managed identities with GitHub OIDC

**Status:** Accepted
**Date:** 2026-10-04

## Context

Changes to this lab's infrastructure are made by Terraform running in GitHub Actions. To do that, the pipeline needs a non-human identity in Entra ID that Azure will accept a login from.

Three questions had to be answered:

1. **What kind of identity?** Azure offers two kinds of workload identity that GitHub Actions can log in as: an app registration (with its service principal) or a user-assigned managed identity.
2. **How does GitHub prove it is allowed to use that identity?** Options are a stored secret, a certificate, or federation using OpenID Connect (OIDC).
3. **How much access does it get?** `terraform plan` and `terraform apply` carry  different risk. Plan runs on every PR, often on unreviewed code. It generally only needs to read. A plan identity could use write permission to put a lease on the Blob and deconflict new writes while performing the plan function, but there a number of mitigating factors that make this unnecessary, especially for a single-maintainer lab. Apply changes infrastructure and should only run after review and approval.

The bootstrap that created the Terraform state backend is recorded in [ADR 0001](0001-manual-terraform-state-bootstrap.md).

## Decision

### Two identities, split by risk

| Identity | Used by | Purpose |
|---|---|---|
| `mi-tf-plan` | Pull request workflows | Read the environment and produce a plan |
| `mi-tf-apply` | Approved deployments only | Change the environment |

Splitting them means anything that can trigger a plan, including a malicious or buggy pull request, can at most read. Write access sits behind an approval gate.

### User-assigned managed identities

Both identities are user-assigned managed identities, created in `rg-bootstrap` alongside the state backend. Terraform does not manage them.

### OIDC federation, no stored secrets

Each identity has a federated identity credential that trusts tokens issued by GitHub Actions, but only for this repository in a specific situation:

| Identity | Issuer | Audience | Subject |
|---|---|---|---|
| `id-tf-plan` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` | `repo:cooke-labs/azure-detection-engineering-lab:pull_request` |
| `id-tf-apply` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` | `repo:cooke-labs/azure-detection-engineering-lab:environment:lab` |

On each run, GitHub issues a short-lived token describing the workflow. Entra ID checks it against these rules and, if it matches, issues a short-lived Azure token. No password, secret, or cert is stored anywhere.

The **subject** is the security boundary. The apply identity trusts only jobs running in the `lab` GitHub environment, which requires manual approval from a designated reviewer. It is deliberately not trusted for pull requests or plain branch pushes.

### Least-privilege role assignments

| Identity | Role | Scope | Why |
|---|---|---|---|
| `mi-tf-plan` | Reader | Subscription | See all resources; change nothing |
| `mi-tf-plan` | Storage Blob Data Reader | `tfstate` container | Read state. Cannot write the state lock that prevents concurrent runs. Must be initiated with "terraform plan -lock=false. This eliminates the risk of tampering and lock-out attacks associated with write perms on untrusted PRs. |
| `mif-apply` | Contributor | Subscription | Create, change, and delete resources; cannot grant access or remove locks |
| `mif-apply` | Storage Blob Data Contributor | `tfstate` container | Read and write state |

The storage data roles are scoped to the single container, not the storage account. Reader and Contributor don't include data-plane access to blob contents, which is why the storage roles are assigned separately.

Not granted at this time:

- **Any role-assignment-capable role** (such as User Access Administrator or Role Based Access Control Administrator). If Terraform later needs to create role assignments, a constrained role will be added and recorded in a new ADR.
- **Any data-plane role for the human operator.** Terraform never runs locally; only the pipeline identities read or write state.

### GitHub configuration

- A `lab` environment with a required reviewer serves as the approval gate. 
- The `lab` environment's deployment branches are restricted to `main`, so only reviewed, merged code can deploy. Even an approved run can't deploy from an unreviewed branch.
- `lab` is the only environment. The lab has no users to protect and its compute is routinely torn down to control cost, so separate dev/test/prod environments would roughly double cost without reducing meaningful risk. Resource names and the state key include the environment name, so another environment can be added later without renaming anything. 
- The tenant ID, subscription ID, and the two client IDs are stored as GitHub Actions secrets. They are identifiers, not credentials, but storing them as secrets masks them in workflow logs, which are publicly visible on this repo.

## Alternatives considered

**App registration with a client secret.** This was the standard pattern before OIDC federation was available, and it is still common in older tutorials. Rejected: it requires a long-lived secret stored in GitHub that must be rotated and can leak.

**App registration with OIDC federation.** Viable and widely used; much of the existing GitHub-to-Azure documentation is written around it. GitHub workflows can't tell the difference between this and the chosen option. Rejected because:

- A secret or certificate can be added to an app registration later, intentionally or by mistake, reintroducing a long-lived credential. A managed identity cannot hold one at all.
- An app registration lives at the tenant level, separate from the bootstrap resources. A managed identity is an Azure resource, governed by the same RBAC, tags, and resource group as the state backend.
- Creating an app registration requires Entra ID permissions in addition to Azure permissions.

**A single identity for both plan and apply.** Simpler, but anything able to trigger a plan would hold write access to the environment. Rejected.

## Consequences

**Positive**

- No stored credentials anywhere in the pipeline.
- Pull requests, the least-trusted entry point, get read-only access to Azure.
- Every apply requires explicit human approval.
- Identities and their trust rules live alongside the state backend and are governed by Azure RBAC.

**Negative / trade-offs**

- **Subject strings must match exactly.** GitHub only includes `pull_request` in the subject when the job does not reference an environment, and includes the environment name when it does. The plan job must not declare an environment; the apply job must declare `production`. A mismatch causes login to fail.
- - **The approval gate depends on GitHub settings outside Azure.** Branch protection on `main`, and the `lab` environment's required reviewer and deployment branch restriction, must stay in place; if any are removed, the boundary weakens without any change in Azure.
- **Reader at subscription scope** lets the plan identity see every resource in the subscription. Acceptable for a single-purpose lab subscription; narrower scopes would be needed in a shared subscription.
- **Contributor at subscription scope** is broader than strictly necessary. Enterprises often scope apply identities to specific resource groups. Accepted for a lab; revisit if the subscription hosts other workloads.
- **Managing Entra ID objects is harder.** If Terraform needs to manage Entra objects (groups, app registrations) through Microsoft Graph, Graph permissions must be granted to the managed identity through PowerShell or the Graph API, since the portal offers no UI for it. This is the main trigger to revisit this decision.
- Each identity supports a maximum of 20 federated credentials, which limits how many repositories, branches, or environments it can trust.

## References

- [Workload identity federation overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a user-assigned managed identity to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [Use the Azure Login action with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)
- [GitHub OpenID Connect reference (subject claim formats)](https://docs.github.com/en/actions/reference/security/oidc)
