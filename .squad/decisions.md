# Squad Decisions

## Active Decisions

### ER migration connectivity/routing posture

- Date: 2026-06-04T16:25:05-05:00
- Lab: er-migration
- Owner: Switch (Hybrid Connectivity & Routing)
- Status: Proposed

Treat the current er-migration topology as a functional lab, not a production migration pattern. Before presenting it as a safe migration cutover design, fix the GatewaySubnet overlap in `3-add-subnetprefix.sh`, replace gateway `adminState` cutover with route-preference based cutover where possible, and document single-circuit/single-location ExpressRoute and single GCP VLAN attachment limitations.

Key routing findings:

1. `1-hub-spk.sh` creates one 50 Mbps Standard/Metered Megaport ExpressRoute circuit in Chicago. This lacks circuit, provider, and peering-location redundancy.
2. `2-gcp-er.sh` creates one regional Cloud Router and one Partner Interconnect VLAN attachment in `us-east1`; production-like GCP redundancy needs additional attachments/edge availability domains according to Google Partner Interconnect guidance.
3. `3-add-subnetprefix.sh` adds `10.0.0.64/26` to `GatewaySubnet`, but `1-hub-spk.sh` uses `10.0.0.64/26` for Azure Firewall. This appears invalid because VNet subnets cannot overlap.
4. Azure Route Server is deployed by the base template, but the lab scripts do not explicitly configure NVA peers or enable route exchange/branch-to-branch; migration validation should prove exactly which prefixes are learned by ERGW, Route Server, spokes, and GCP.
5. `4-validation.sh` toggles `adminState` and uses `az network vnet-vpn-gateway update` for `az-hub-ergw_migrated`; validate object type/CLI command before use. Prefer controlled BGP policy, connection routing weight, or AS-path/local-preference changes for cutover tests.

References:

- Azure ExpressRoute circuits/private peering use redundant BGP sessions per peering and require both sessions for SLA: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-routing
- ExpressRoute circuit bandwidth/SKU/peering location basics: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings
- ExpressRoute FastPath requirements and limitations: https://learn.microsoft.com/en-us/azure/expressroute/about-fastpath
- ExpressRoute Global Reach links ExpressRoute circuits for on-premises-to-on-premises connectivity: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-global-reach
- Azure Route Server route exchange with ExpressRoute/VPN gateways: https://learn.microsoft.com/en-us/azure/route-server/expressroute-vpn-support
- Azure multiple subnet prefixes limitations: https://learn.microsoft.com/en-us/azure/virtual-network/how-to-multiple-prefixes-subnet
- Google Partner Interconnect redundancy/SLA and VLAN attachment behavior: https://docs.cloud.google.com/network-connectivity/docs/interconnect/concepts/partner-overview?hl=en

### ER migration script hygiene and hardening

- Date: 2026-06-04T16:25:05-05:00
- Lab: er-migration
- Owner: Tank (Infra / IaC Engineer)
- Status: Proposed

Treat the current shell scripts as prototype lab automation and harden them before reuse: remove plaintext credentials, externalize environment-specific values into a shared vars file, pin all remote templates and image inputs, add Bash strict mode and validation, make deployments rerun-safe, and split validation/scratch commands from deploy and cleanup paths.

Rationale:

The reviewed scripts contain a plaintext VM password, a remote ARM template pinned to `main`, hardcoded GCP project and location values, asynchronous deployment sequencing with ad hoc polling, no shebang or strict error mode, and validation commands mixed with experimental snippets. These create security, reproducibility, and rerun-safety risks for a self-contained lab.

Concrete follow-up:

Create `lab.env.example` / `lab.env` pattern, replace secrets with Key Vault or secure prompts, pin `azuredeployv5.json` to an immutable release/commit or vendor it locally, pin GCP image selection, add `validate/what-if` modes, refactor wait/delete helpers, and clean `4-validation.sh` into documented validation-only commands.

### 2026-06-04T17:29:07-05:00: Trinity Address Plan Decision

- **By:** Trinity (Lead Network Architect)
- **Status:** Approved

Preserve the ExpressRoute lab's GatewaySubnet multi-prefix teaching point, but replace the invalid extra prefix `10.0.0.64/26` with `10.0.0.160/27`.

**Why:**
- `10.0.0.64/26` is already assigned to `AzureFirewallSubnet`, creating a hard overlap.
- `10.0.0.160/27` is the only free /27 inside the current hub `10.0.0.0/24`.
- Keeping the hub at `10.0.0.0/24` avoids expanding to `10.0.0.0/23`, which would collide with Spoke1 `10.0.1.0/24`.
- Required Azure subnet names remain exact: `GatewaySubnet`, `AzureFirewallSubnet`, `RouteServerSubnet`, `AzureBastionSubnet`.

**Contract impact:** Terraform modules should expose hub subnet definitions as name plus `address_prefixes` list. `GatewaySubnet` must include `10.0.0.32/27` and `10.0.0.160/27`. Expose `deploy_gcp`, spoke definitions, ASN values, original/migrated gateway names, and ExpressRoute connection routing weights.

**Validation:** Python `ipaddress` check result: `RESULT: CLEAN - corrected address plan is overlap-free`.

### 2026-06-04T17:36:55-05:00: Switch ER Gateway Migration Design

- **By:** Switch (Hybrid Connectivity & Routing)
- **Status:** Approved

Model the original and migrated ExpressRoute virtual network gateways with identical Azure gateway ASN `65515` and use `azurerm_virtual_network_gateway_connection.routing_weight` as the primary cutover and rollback lever. Keep `adminState` disable/enable as an operator-only fallback documented by `expressroute_migration.admin_state_fallback`.

**Key decisions:**
1. Use `routing_weight` as primary cutover/rollback mechanism (Terraform exposes this in azurerm v4).
2. Keep `adminState` disable/enable as operator-only fallback because Terraform does not expose gateway admin-state toggle.
3. Use ExpressRoute gateway SKU `Standard` for this lab (Standard and ErGw1Az map to the same 1 Gbps / 4 circuit tier; Standard avoids zone SKU regional constraints).
4. Include optional `azurerm_express_route_circuit_peering` for `AzurePrivatePeering` with `peer_asn = provider_router_asn`; Azure circuit ASN `12076` documented as `expressroute_migration.circuit_asn`.

**References:**
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/express_route_circuit
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/express_route_circuit_peering
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_gateway
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_gateway_connection
- https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways
- https://learn.microsoft.com/azure/expressroute/expressroute-howto-routing-portal-resource-manager

### 2026-06-04T17:48:45-05:00: Apoc Terraform Validation Fixes

- **By:** Apoc (Validation & Testing)
- **Status:** Applied

Applied objective static-validation fixes after `terraform validate`:

1. Root `expressroute_circuit_service_key` now references `module.ergw.circuit_service_key`, matching the ER module output.
2. `azurerm_virtual_network_gateway.gateway` now uses `bgp_enabled = true` instead of deprecated `enable_bgp = true`.
3. Root `gcp_pairing_key` output is marked sensitive to forward the sensitive GCP module pairing key.

Validation now passes with `terraform validate`; no backend, plan, or apply was run.

### 2026-06-04T19:30:00Z: ping-monitor.sh conventions for migration-interruption measurement

- **By:** Apoc (Validation & Testing)
- **Lab:** er-migration
- **Status:** Proposed

`er-migration/scripts/ping-monitor.sh` is the canonical tool for measuring data-path interruption during the Azure managed ExpressRoute gateway migration. The following conventions govern it:

1. **Source VM / destination VM:** GCP on-prem VM (`192.168.100.2`) pings Azure hub VM (`10.0.0.4`). The script runs on the GCP VM.
2. **Outage window accounting:** an outage begins at the first missed probe (`[DOWN]`) and closes at the first successful reply (`[UP]`). Duration = probe-count × INTERVAL seconds. This is the authoritative measure of data-path interruption.
3. **Summary math:** `max_outage` stores the *count* of consecutive missed probes; the display value is always `max_outage × INTERVAL` seconds. Any future edit must preserve this — do **not** print the raw probe count as seconds.
4. **Incomplete outage at script stop:** `on_exit` must label an open window as `[STILL-DOWN] … NOT recovered`, never as "recovered".
5. **Line endings:** the file must use Unix LF (`\n`) only. CRLF will break execution on the GCP Debian/Ubuntu VM.
6. **Portability:** `date +%3N` (milliseconds) requires GNU coreutils. This is available on standard GCP Debian/Ubuntu VMs. Document the Busybox limitation in comments; do not silently remove the millisecond precision.

### 2026-06-06T19:43:25-05:00: ER Connection Fix

- **By:** Switch (Hybrid Connectivity & Routing)
- **Lab:** er-migration / resource group lab-er-migration / westus3
- **Status:** Ready to Execute

Circuit `az-hub-er-circuit` is Provisioned (Megaport VXC up), but connection `az-hub-ergw-to-az-hub-er-circuit` is Failed (0 bytes transferred). Root cause: connection was created out-of-band while `serviceProviderProvisioningState` was still `NotProvisioned`; Azure returns `Failed` for premature connections, which do not self-heal. Terraform two-phase config is commit-ready. Remediation: delete Failed connection → add `er_circuit` block with `enabled=true, create_peering=false` to tfvars → terraform apply → validate. Copy-paste runbook written to .squad/decisions/inbox/switch-er-connection-fix.md (now merged).

### 2026-06-06T19:46:00-05:00: Interactive Region Prompts for er-migration Deploy Scripts

- **By:** Tank (Infra / IaC Engineer)
- **Lab:** er-migration
- **Status:** Applied

`er-migration/scripts/deploy.ps1` and `er-migration/scripts/deploy.sh` now interactively prompt for both Azure region (default `westus3`) and GCP region (default `us-east1`), with `-AzureRegion`/`--azure-region` and `-GcpRegion`/`--gcp-region` non-interactive overrides. Terraform variables `location` and `gcp_region` are top-level standalone (not nested). deploy.ps1 parses clean; deploy.sh uses LF and passes `bash -n`. Outcome: success.

### 2026-06-06T20:00:00-05:00: ER Connection Live Fix Executed

- **By:** Coordinator (Ops Lead) + Switch (Hybrid Connectivity & Routing)
- **Lab:** er-migration / resource group lab-er-migration / westus3
- **Status:** Verified Healthy

Connection `az-hub-ergw-to-az-hub-er-circuit` was stuck in Failed state (orphan, out-of-band, created before circuit Provisioned). **Live remediation executed per Switch runbook:** deleted Failed orphan → added `er_circuit` block with `enabled=true, create_peering=false` to tfvars → terraform apply → verified Succeeded.

**Live outcome verified:**
- Connection provisioningState: **Succeeded**
- Connection status: **Connected**
- ERGW learned routes: `192.168.100.0/24` (GCP on-prem prefix) ✅
- GCP Cloud Router BGP: **UP**, learned `10.0.0.0/24` (Azure hub) + spoke routes ✅
- Data-path health: **HEALTHY** (ping test successful GCP→Azure hub→spokes)

Commit: `6c507ff` on main. No further action required; connection is now tracked by Terraform and will persist through future applies.

### 2026-06-06T20:18:00-05:00: ER Connection Auto-Remediation — Self-Heal Functions Added to Deploy Scripts

- **By:** Tank (Infra / IaC Engineer)
- **Lab:** er-migration
- **Status:** Applied

Both `deploy.ps1` and `deploy.sh` now include `Repair-FailedErConnection` / `repair_failed_er_connection` self-heal functions that automatically detect, remediate, and verify a Failed ER connection (encoding the proven live fix from this session).

**Invocation:** After Phase 7 poll (post-apply), if connection is Failed, auto-repair is attempted (up to 2 retries).

**Proven fix sequence:**
1. Guard: circuit `serviceProviderProvisioningState` must be Provisioned (abort if not).
2. Delete the Failed connection.
3. Re-apply Terraform (TF recreates it cleanly).
4. Poll for Succeeded state (30 s interval, 20 min timeout).
5. Verify learned routes (`az network vnet-gateway list-learned-routes`).

**Phase 5 + Phase 8 enhancements:** Pre-apply orphan detection strengthened with circuit guard; Phase 8 now includes ERGW learned-route verification independent of GCP mode.

Quality gates: `deploy.ps1` parser clean (0 errors); `deploy.sh` bash -n exit 0, 0 CR bytes.

### 2026-06-06T20:25:00-05:00: Cleanup Scripts Created for er-migration Lab

- **By:** Tank (Infra / IaC Engineer)
- **Lab:** er-migration
- **Status:** Applied

Two new teardown scripts mirror the existing deploy pair in style, logging, and phase banners:

- `er-migration/scripts/cleanup.ps1` — Windows / PowerShell
- `er-migration/scripts/cleanup.sh` — Linux / Bash

**Key parameters:** `-AzureRegion` / `--azure-region` (default westus3), `-GcpProject` / `--gcp-project`, `-GcpRegion` / `--gcp-region` (default us-east1), `-SkipGcp` / `--skip-gcp`, `-Force` / `--force`.

**Order of operations:**
1. Confirmation + prereqs (az, terraform, gcloud commands; collect admin_password).
2. Pre-destroy: delete orphan ER connection if present (defensive; tolerate not-found).
3. Terraform destroy from `er-migration/terraform` (auto-approve, passes vars).
4. Post-destroy verification (resource group gone; list leftovers if present).
5. Megaport VXC manual-deletion reminder banner.

Quality gates: `cleanup.ps1` parser clean; `cleanup.sh` bash -n exit 0, 0 CR bytes. README updated with cleanup script usage block (Windows + Linux) and Megaport caveat.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
