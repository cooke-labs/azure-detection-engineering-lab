# ADR 0001: Bootstrap the Terraform state backend manually

**Status:** Accepted
**Date:** 2026-10-02

## Context

All infrastructure in this lab is meant to be managed by Terraform, run from a CI/CD pipeline. Terraform records what it has built in a state file. For a pipeline, that file needs to live in shared, durable storage rather than on a laptop.

Terraform can't create that storage for itself, because it needs the storage to exist before it can run. Something outside Terraform has to create it once. This is a real "something from nothing" creation-of-the-universe-type predicament. 

The state file is also one of the most sensitive assets in the project. It maps every managed resource and can contain secrets in plain text. Anyone who can write to it can steer what Terraform changes or destroys. The backend therefore needs to be hardened, recoverable, and cheap.

## Decision

A human operator with Owner on the subscription creates the state backend once, by hand, using Azure PowerShell. The exact commands are recorded in [`infra/bootstrap/bootstrap.ps1`](../../infra/bootstrap/bootstrap.ps1).

The backend consists of:

| Resource | Name | Purpose |
|---|---|---|
| Resource group | `rg-bootstrap` | Holds bootstrap resources only, separate from anything Terraform manages |
| Storage account | `stlabbootstraptfstate` | Terraform remote state |
| Blob container | `tfstate` | Holds the state file(s) |

**SKU: Standard, LRS, StorageV2, Hot tier.** This is the cheapest viable configuration. A state file is a small text file, so Premium (SSD) performance adds cost with no benefit. LRS keeps three copies in a single datacenter; cross-region replication (GRS) guards against regional outages, which aren't a realistic risk for a lab. Hot tier is used because state is read on every Terraform run, and the Cool and Cold tiers charge more per read and impose minimum storage periods.

**Hardening:**

| Setting | Value | Why |
|---|---|---|
| `AllowSharedKeyAccess` | `false` | Disables the account keys (master passwords). All access goes through Entra ID identities, which are auditable and revocable. |
| `AllowBlobPublicAccess` | `false` | No container can ever be made anonymously readable. |
| `MinimumTlsVersion` | `TLS1_2` | Rejects older, weaker protocol versions. |
| `EnableHttpsTrafficOnly` | `true` | Rejects unencrypted connections. |
| `AllowCrossTenantReplication` | `false` | Prevents the data from being replicated into another tenant. |

**Recovery:**

| Feature | Setting | Protects against |
|---|---|---|
| Blob versioning | Enabled | A bad run corrupting the state file; prior versions can be restored |
| Blob soft delete | 30 days | Accidental deletion of the state file |
| Container soft delete | 30 days | Accidental deletion of the container |

Replication is not the recovery mechanism here. The realistic failure modes for a state file are overwrite and deletion, and versioning and soft delete address those directly.

## Verification

After the bootstrap, the following were confirmed (commands are at the end of `bootstrap.ps1`):

- `AllowSharedKeyAccess` returns `False`.
- The `tfstate` container exists with public access `Off`.
- `Get-AzStorageBlobServiceProperty` shows versioning enabled and both delete retention policies enabled at 30 days.

## Consequences

**Positive**

- The state backend exists before Terraform's first run, and with no stored keys or secrets.
- Recovery from the most likely failures (corruption, deletion) is built in from day one.
- Cost is negligible: pennies per month.
- The manual steps are recorded in a script, so the bootstrap is documented and repeatable rather than ad hoc.

**Negative / trade-offs**

- These resources sit outside Terraform's state. Terraform won't detect if someone changes their settings by hand ("drift"). Changes to the backend must be made deliberately and recorded in `bootstrap.ps1`.
- The bootstrap requires a privileged human identity. That access should not remain standing afterward; how it is reduced is out of scope for this ADR.
- LRS means a full datacenter loss could lose the state file. This is accepted for a lab environment.
- The storage account uses a public network endpoint. Protection relies on identity (Entra ID only, no keys) rather than network restriction. Private networking is a possible future hardening step.

## Alternatives considered

- **Bootstrap with Terraform using local state, then migrate it into the new backend.** This keeps everything in code but adds a state migration step and a second state file to manage. Rejected as more complexity than a one-time setup needs.
- **Keep storage account keys enabled.** This is simpler to start with, since many tools default to key auth. Rejected because keys are long-lived shared secrets that grant full access to the account.
- **GRS or ZRS replication.** Higher resilience at higher cost. Rejected as unnecessary for a lab; versioning and soft delete cover the realistic risks.

## Not covered by this ADR

The pipeline identities, their GitHub OIDC federation, and their role assignments will be recorded in a separate ADR.
