# Apoc — History

## Project Context
- **Project:** azure-hub-spoke — Hub-and-Spoke networking labs on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario; many ship a dedicated validation script.
- **Stack:** Azure CLI, ExpressRoute, VPN Gateway, Azure Route Server, OPNSense NVA, GCP/Megaport.
- **Created:** 2026-06-04

## Learnings

- 2026-06-04: Static Terraform validation passed for er-migration after fixing ER service-key output reference, AzureRM BGP attribute, and sensitive GCP pairing-key output.
- 2026-06-04: Reviewed and fixed `er-migration/scripts/ping-monitor.sh` — migration-interruption monitor. Target topology: GCP on-prem VM `192.168.100.2` → Azure hub VM `10.0.0.4` over ExpressRoute. Script pings 10.0.0.4 from the GCP VM at 1 s intervals, timestamps every probe (ms precision), detects outage windows (start time / duration / recovery), logs to file, and prints a final summary on Ctrl+C. Two bugs fixed: (1) summary displayed `max_outage` probe-count directly as seconds — corrected to `max_outage × INTERVAL`; (2) on_exit labeled an active outage as "recovered" — corrected to `[STILL-DOWN] … NOT recovered`. CRLF→LF pass applied. Portability note: `date +%3N` milliseconds require GNU coreutils (standard on Debian/Ubuntu GCP VMs); not available on Busybox/Alpine — replace `%3N` with `%S` if needed.
- 2026-06-06: Live ER connection fix verified healthy (connection Succeeded; ERGW learned 192.168.100.0/24; GCP Cloud Router BGP UP; data-path healthy). Self-heal and cleanup scripts added to deploy automation. Commit 6c507ff.
