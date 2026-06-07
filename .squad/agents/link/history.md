# Link — History

## Project Context
- **Project:** azure-hub-spoke — Hub-and-Spoke networking labs on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario; README indexes all labs.
- **Stack:** Azure CLI, ExpressRoute, VPN Gateway, Azure Route Server, OPNSense NVA, GCP/Megaport.
- **Created:** 2026-06-04

## Learnings
- 2026-06-04: Exported er-migration Excalidraw to SVG with a jsdom-backed Node one-liner using @excalidraw/utils exportToSvg and skipInliningFonts.
- 2026-06-04: Authored er-migration README from Terraform source, address plan, Megaport handoff, SVG topology, and archive notes.
- 2026-06-06: Added "Measuring migration interruption" section to er-migration README — documents data-path interruption measurement during managed gateway migration using ping-monitor.sh script (GCP 192.168.100.2 pings Azure hub 10.0.0.4), with copy-paste-ready heredoc block for GCP VM deployment.
