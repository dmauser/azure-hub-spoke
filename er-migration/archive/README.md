# Original ExpressRoute Migration Scripts - Archived

These are the original imperative shell/gcloud scripts for the ExpressRoute migration lab, archived on 2026-06-04 and superseded by the Terraform rebuild in `er-migration/terraform/`.

## Archived Files

- **1-hub-spk.sh** — Deployed Azure hub-spoke network topology with VNets, subnets, and routing.
- **2-gcp-er.sh** — Deployed GCP VPC and configured Google Cloud Interconnect for hybrid connectivity.
- **3-add-subnetprefix.sh** — Added GatewaySubnet prefix to support ExpressRoute gateway deployment.
- **4-validation.sh** — Validated connectivity, BGP routes, and performed migration cutover verification.
- **5-clean-up.sh** — Cleanup script to remove resources and reset test environment.
- **gw-prepare.png** — Diagram image illustrating gateway preparation and network design.
