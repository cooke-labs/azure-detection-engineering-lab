\# Azure Detection Engineering Lab

In this repo I will emulate a production-ready enterprise-grade security engineering environment for developing, validating, and automating detection and response actions.

## Objectives

Version 1.0 of this project will demonstrate:

* IaC using Terraform
* Secret-less CI/CD pipelines with authentication performed using workload identity federation
* Policy as Code using Azure Policy
* Centralized telemetry transport using Event Hubs
* Detection engineering with Sentinel
* Detection validation and tuning using Atomic Red Team
* Security response automation and alert enrichment
* AI-assisted investigation
* AI/Identity governance using constrained identity and permissions

## Vision

I had intended to create a lab in which I could demonstrate the ability write and tune detections against a simulated attack, but along the way I decided that I could also demonstrate some security engineering skill by designing a cloud environment that emulates controls consistent with an enterprise's most secure workloads. In order to make this possible I will aggressively manage costs using IaC to build and tear down resources as needed.

## Project Status

This project is currently in \*\*Phase 1: Architecture and Terraform Bootstrap\*\*. I have planned the repo structure and created some placeholder files that I think I will need. Ultimately, all deployments will flow through federated identities in a CI/CD pipeline, but in order to accomplish this, a one time bootstrap by a highly-privileged human account will be required to establish the root of trust for the deployment platform.

## Phases:

1. Architecture and Terraform Bootstrap
2. Secure Azure foundations
3. Telemetry pipeline
4. Detection engineering

5\. Atomic Red Team validation
6. Security automation/alert enrichment
7. AI event investigator

## Documentation
- docs/architecture.md
- docs/identity-model.md
- docs/threat-model.md

## Future Ambitions

After building and securing the platform I intend to test my detections and the AI investigator against real attackers by exposing a honeypot to public internet.
## License
This project is licensed under the MIT License.

