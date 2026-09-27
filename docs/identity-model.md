# Identity Model
---
Status: draft
---
## Identity Categories:
### Human Identity:
- One human identity used for repo admininstration, deployment approval, and the initial bootstrap operation.
### Terraform plan identity:
- Used by CI/CD to read infrastructure config and generate tf plan
### Terraform apply identity
- Used to execute the plan. Creates, updates, and destroys resources
### Runtime identities:
- dedicated managed identities will be assigned to runtime components like telemetry processors, automation workflows, and the AI investigator agent.
## Identity Principles
- No stored client secrets
- Seperate deployment and runtime identities
- Seperate plan and apply identities
- Least privileged role assignments
- Resource scoped permissions whenever possible/practical
