# OIDC subject claims, immutable IDs, and repojacking

**Date:** 2026-10-20
**Related:** [ADR 0002](../docs/adr/0002-pipeline-identities-oidc.md), [`bootstrap.ps1`](../infra/bootstrap/bootstrap.ps1)

## What happened

I opened my first pull request against this repo to test the two pipeline identities (`mi-tf-plan` and `mi-tf-apply`). The PR triggered a small smoke-test workflow whose plan job logs in to Azure with GitHub OIDC and checks that the plan identity can read Terraform state but not write it.

The plan job failed after 54 seconds. It never got to the permission checks. It failed at login.

## Finding the cause

The log had the answer. GitHub's login step prints the details of the token it presents to Azure, and Entra ID's error named the problem:

```
subject claim - repo:cooke-labs@333205863/azure-detection-engineering-lab@1387044859:pull_request

Error: AADSTS700213: No matching federated identity record found for presented
assertion subject 'repo:cooke-labs@333205863/azure-detection-engineering-lab@1387044859:pull_request'.
```

`AADSTS700213` means Entra ID received a token from a trusted issuer, but none of the identity's federated credentials matched its subject. I compared what GitHub sent with what I had configured:

| | Subject |
|---|---|
| GitHub sent | `repo:cooke-labs@333205863/azure-detection-engineering-lab@1387044859:pull_request` |
| I configured | `repo:cooke-labs/azure-detection-engineering-lab:pull_request` |

GitHub had added a number after the organization name and after the repository name. My credential used the format every tutorial I'd read showed, and the subject has to match exactly, character for character. So Azure correctly refused the login.

That's the federation boundary working as designed. A near-miss subject is a rejected subject.

## Why GitHub adds those numbers

The numbers are **immutable IDs**. GitHub assigns every account, organization, and repository a numeric ID that never changes, even when the name does. The new subject format is:

```
repo:<owner>@<owner-id>/<repo>@<repo-id>:<context>
```

GitHub [announced the change](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens) in April 2026. Repositories created after July 15, 2026 use the new format automatically, and older repositories can opt in. I created this repo in September 2026, so it got the new format by default. Most documentation and examples still show the old one, which is how I configured mine wrong.

### The attack it mitigates: repojacking

The old subject trusted a **name**. Names on GitHub can be freed up: an organization renames itself, or a repository or account is deleted, and someone else can register the same name.

That's **repojacking** (repository hijacking). Anything that trusted the old name now trusts whoever claimed it. The classic example is software dependencies: a build pulls code from `some-org/some-library`, the org renames, an attacker registers the old name, and the next build pulls the attacker's code.

For OIDC, the stakes are cloud access. With an old-format credential like mine, the chain would have been:

1. I delete or rename `cooke-labs`.
2. An attacker registers `cooke-labs` and creates `azure-detection-engineering-lab`.
3. They open a pull request in their own repo. GitHub issues a token with the subject `repo:cooke-labs/azure-detection-engineering-lab:pull_request`.
4. That subject matches my federated credential, so Entra ID lets them log in to Azure as `mi-tf-plan`.

With immutable IDs in the subject, step 4 fails. The attacker's org and repo get new IDs, so their token's subject can't match mine, even though the names are identical.

The general lesson: **trust identifiers that can't be reassigned, not names that can.** It's the same reason Azure role assignments use object IDs rather than display names.

## The fix

1. **Updated both federated credentials** with `Update-AzFederatedIdentityCredential`, using the exact subject from the error for the plan identity and the same format for the apply identity (`...:environment:lab`).
2. **Changed `bootstrap.ps1` to look up the IDs** instead of hard-coding names. It queries GitHub's API for the repository and builds the subject prefix from `owner.id` and `id`. If someone forks this project, their credentials get their own IDs automatically.
3. **Re-ran the failed job.** No code change was needed, since the workflow was fine; only the trust rule in Azure was wrong.

## What I took away

- **Read the error before guessing.** The log printed both the subject GitHub sent and the reason Azure rejected it. The answer was on screen.
- **Tutorials lag platform changes.** The format in most guides was correct when they were written and wrong for a repo created this year.
- **Exact-match boundaries fail closed.** That's annoying while setting things up, and it's the property you want from a security control.
- **Bind trust to immutable identifiers.** Names are labels; IDs are identity.
- **Check the subject format on older repos.** Any existing repository still on the old format is still trusting names. GitHub lets you opt in, and federated credentials need to be updated at the same moment, or logins break.
