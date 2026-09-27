# Architecture
---
Status: Draft
---
## Purpose:
This doc will provide a description of components, trust boundaries, telemetry flow, security controls, workflows, and architectural decisions for the lab. More granular design reasoning for each individual architectural decision will be recorded under `docs/architecture/adr`.
## High level components:
- Github Actions
- Entra workload identity federation
- Terraform
- Azure Policy
- Azure Key Vault
- Azure Event Hub
- Log Analytics Workspace
- Sentinel
- Atomic Red Team
- AI-incident investigator agent
