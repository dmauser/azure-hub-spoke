# Tank — History

## Project Context
- **Project:** azure-hub-spoke — Hub-and-Spoke networking labs on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario with its own deploy/validate/cleanup scripts.
- **Stack:** Azure CLI (`.azcli`, `.sh`), ExpressRoute, VPN Gateway, Azure Route Server, OPNSense NVA, GCP/Megaport.
- **Created:** 2026-06-04

## Learnings
- 2026-06-04: er-migration lab scripts currently expose hygiene risks: plaintext VM password in 1-hub-spk.sh, unpinned remote ARM template URL, hardcoded GCP project/regions, no shared vars file, missing shebang/strict mode, and scratch validation commands in 4-validation.sh.
- 2026-06-04: For er-migration, recommend a shared lab.env plus validation-first wrappers, Key Vault/secret parameters for VM credentials, pinned template/image versions, robust wait helpers, tags/labels, and explicit dry-run cleanup guidance.
- 2026-06-04: Archived 6 original imperative shell/gcloud scripts (1-hub-spk.sh, 2-gcp-er.sh, 3-add-subnetprefix.sh, 4-validation.sh, 5-clean-up.sh, gw-prepare.png) to archive/ with README; Terraform rebuild now primary source.
- 2026-06-04: Scaffolded er-migration Terraform root files from the authoritative address-plan contract; modules remain owned by other agents.
- 2026-06-04: Built er-migration Terraform modules for Azure hub, spokes, and Route Server using exact corrected CIDRs and Azure-required subnet names.
