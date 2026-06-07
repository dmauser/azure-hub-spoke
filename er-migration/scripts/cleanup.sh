#!/usr/bin/env bash
#
# Full teardown of the ExpressRoute migration lab (Linux / Bash).
#
# Mirrors scripts/cleanup.ps1:
#   1. Confirmation + prerequisites check.
#   2. Pre-destroy: delete the orphan ER gateway connection via az if it still exists
#      (the connection 'az-hub-ergw-to-az-hub-er-circuit' may have been created/recreated
#      via 'az' during incident remediation and therefore NOT tracked in Terraform state;
#      'terraform destroy' will not remove it).
#   3. terraform destroy (removes Azure hub/spokes/ERGW/circuit and, when deploy_gcp=true,
#      the GCP VPC/VM/Cloud Router/Partner Interconnect attachment).
#   4. Post-destroy verification: confirm the resource group is gone or empty; warn if
#      any leftovers remain.
#   5. Final reminder: Megaport VXCs must be deleted manually in the Megaport portal —
#      Terraform cannot destroy portal-created VXCs.
#
# DESTRUCTIVE: this script permanently deletes Azure and GCP lab resources.
# Review every prompt before confirming.

set -euo pipefail

# --- Lab constants (must match the Terraform configuration) ---
RG="lab-er-migration"
CIRCUIT="az-hub-er-circuit"
GATEWAY="az-hub-ergw"
CONN_NAME="${GATEWAY}-to-${CIRCUIT}"

# --- Defaults / args ---
AZURE_REGION="westus3"
GCP_PROJECT=""
GCP_REGION="us-east1"
USE_GCP=""       # "yes"/"no"; empty = prompt
FORCE=""         # set to "yes" if --force/--yes was passed

usage() {
  cat <<EOF
Usage: $0 [options]

  --azure-region REGION  Azure region         (default: westus3)
  --gcp-project  ID      GCP project ID       (enables GCP-side destruction)
  --gcp-region   REGION  GCP region           (default: us-east1)
  --skip-gcp             Azure-only teardown
  --force, --yes         Skip confirmation prompt (for automation)
  -h, --help             Show this help

DESTRUCTIVE: destroys all Terraform-managed lab resources.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --azure-region) AZURE_REGION="$2"; shift 2 ;;
    --gcp-project)  GCP_PROJECT="$2"; USE_GCP="yes"; shift 2 ;;
    --gcp-region)   GCP_REGION="$2"; shift 2 ;;
    --skip-gcp)     USE_GCP="no"; shift ;;
    --force|--yes)  FORCE="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --- Colored logging ---
c_cyan='\033[36m'; c_green='\033[32m'; c_yellow='\033[33m'; c_red='\033[31m'; c_mag='\033[35m'; c_reset='\033[0m'
step() { printf "\n${c_cyan}==> %s${c_reset}\n" "$1"; }
ok()   { printf "    ${c_green}%s${c_reset}\n" "$1"; }
warn() { printf "    ${c_yellow}%s${c_reset}\n" "$1"; }
err()  { printf "    ${c_red}%s${c_reset}\n" "$1"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_tool() {
  local tool="$1"
  if has_cmd "$tool"; then return 0; fi
  err "'$tool' is required but was not found on PATH."
  case "$tool" in
    az)        warn "Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash" ;;
    terraform) warn "Debian/Ubuntu: https://developer.hashicorp.com/terraform/install" ;;
    gcloud)    warn "curl https://sdk.cloud.google.com | bash" ;;
  esac
  exit 1
}

# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../terraform" && pwd)"

printf "\n${c_red}╔══════════════════════════════════════════════════════════════════════╗${c_reset}\n"
printf "${c_red}║   DESTRUCTIVE — ExpressRoute migration lab teardown / cleanup        ║${c_reset}\n"
printf "${c_red}║   Resource group : %-50s║${c_reset}\n" "$RG"
printf "${c_red}╚══════════════════════════════════════════════════════════════════════╝${c_reset}\n"
echo "    Terraform dir : ${TERRAFORM_DIR}"

# --- Decide GCP scope ---
if [[ "$USE_GCP" == "no" ]]; then
  : # skip-gcp set
elif [[ -n "$GCP_PROJECT" ]]; then
  USE_GCP="yes"
elif [[ -z "$USE_GCP" ]]; then
  read -r -p $'\nDestroy the GCP side too? (Y/n) ' ans
  if [[ "$ans" =~ ^([nN]|no)$ ]]; then USE_GCP="no"; else USE_GCP="yes"; fi
fi
if [[ "$USE_GCP" == "yes" ]]; then
  ok "GCP side: ENABLED (will be destroyed)"
else
  USE_GCP="no"
  ok "GCP side: skipped (Azure only)"
fi

# --- GCP project (required when GCP in scope) ---
if [[ "$USE_GCP" == "yes" && -z "$GCP_PROJECT" ]]; then
  def_proj="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "$def_proj" == "(unset)" ]] && def_proj=""
  if [[ -n "$def_proj" ]]; then
    read -r -p "GCP project ID [$def_proj]: " GCP_PROJECT; GCP_PROJECT="${GCP_PROJECT:-$def_proj}"
  else
    read -r -p "GCP project ID (required): " GCP_PROJECT
  fi
  [[ -z "$GCP_PROJECT" ]] && { err "A GCP project ID is required to destroy the GCP side."; exit 1; }
fi

# --- Confirmation (unless --force/--yes) ---
step "Confirmation"
if [[ "$FORCE" != "yes" ]]; then
  echo ""
  printf "  ${c_red}This will PERMANENTLY DELETE all resources in resource group '${RG}'${c_reset}\n"
  printf "  ${c_red}and run 'terraform destroy' in: ${TERRAFORM_DIR}${c_reset}\n"
  if [[ "$USE_GCP" == "yes" ]]; then
    printf "  ${c_red}GCP project '${GCP_PROJECT}' resources will also be destroyed.${c_reset}\n"
  fi
  echo ""
  read -r -p "  Type the resource group name '${RG}' to confirm, or Ctrl+C to abort: " confirm
  if [[ "$confirm" != "$RG" ]]; then
    warn "Confirmation did not match. Aborting."
    exit 0
  fi
  ok "Confirmed."
else
  warn "--force specified — skipping interactive confirmation."
fi

# --- Prerequisites ---
step "Checking prerequisites"
ensure_tool az
ensure_tool terraform
[[ "$USE_GCP" == "yes" ]] && ensure_tool gcloud
ok "All required tools present."

# --- Azure subscription ---
step "Resolving Azure subscription"
AZ_SUB="$(az account show --query id -o tsv 2>/dev/null || true)"
if [[ -z "$AZ_SUB" ]]; then
  warn "Not logged in to Azure. Launching 'az login'..."
  az login >/dev/null
  AZ_SUB="$(az account show --query id -o tsv 2>/dev/null || true)"
fi
[[ -z "$AZ_SUB" ]] && { err "No active Azure subscription. Run 'az login' and 'az account set --subscription <id>'."; exit 1; }
export ARM_SUBSCRIPTION_ID="$AZ_SUB"
ok "ARM_SUBSCRIPTION_ID = $AZ_SUB"

# --- VM admin password (terraform destroy still requires the variable) ---
step "Azure VM admin password (required by Terraform even for destroy)"
warn "Terraform will prompt if omitted. Enter the same password used during deploy."
if [[ -n "${TF_VAR_admin_password:-}" ]]; then
  ok "TF_VAR_admin_password already set in environment — reusing."
else
  read -r -s -p "admin_password: " ADMIN_PASSWORD; echo
  [[ -z "$ADMIN_PASSWORD" ]] && { err "Password cannot be empty."; exit 1; }
  export TF_VAR_admin_password="$ADMIN_PASSWORD"
fi

# --- gcloud auth (GCP only) ---
if [[ "$USE_GCP" == "yes" ]]; then
  unset GOOGLE_OAUTH_ACCESS_TOKEN || true
  step "Verifying gcloud authentication"
  active_acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [[ -z "$active_acct" ]]; then
    warn "No active gcloud account. Launching 'gcloud auth login'..."
    gcloud auth login
  else
    ok "gcloud account: $active_acct"
  fi
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    warn "No Application Default Credentials. Launching 'gcloud auth application-default login'..."
    gcloud auth application-default login
  else
    ok "ADC present"
  fi
  gcloud config set project "$GCP_PROJECT" >/dev/null 2>&1
fi

# ============================================================================
# Phase 1: Pre-destroy — delete orphan ER connection (may be outside TF state)
# ============================================================================
step "Phase 1 — Pre-destroy: checking for orphan ER connection '${CONN_NAME}'"
warn "This connection may have been created/recreated via 'az' during incident remediation"
warn "and therefore may NOT exist in Terraform state. Deleting it directly via az."

CONN_STATE="$(az network vpn-connection show -g "$RG" -n "$CONN_NAME" --query provisioningState -o tsv 2>/dev/null || true)"

if [[ -n "$CONN_STATE" ]]; then
  warn "Found connection '${CONN_NAME}' (state: ${CONN_STATE}). Deleting..."
  az network vpn-connection delete -g "$RG" -n "$CONN_NAME" --yes 2>/dev/null || true
  ok "Connection '${CONN_NAME}' deleted (or was already gone)."
else
  ok "Connection '${CONN_NAME}' not found (already deleted or never existed). Continuing."
fi

# ============================================================================
# Phase 2: terraform destroy
# ============================================================================
step "Phase 2 — terraform destroy"

if [[ "$USE_GCP" == "yes" ]]; then
  TF_GCP_PROJECT="$GCP_PROJECT"
  TF_GCP_REGION="$GCP_REGION"
  TF_DEPLOY_GCP="true"
else
  TF_GCP_PROJECT="er-migration-lab-unused"
  TF_GCP_REGION="us-east1"
  TF_DEPLOY_GCP="false"
fi

cd "$TERRAFORM_DIR"

step "terraform init (refresh providers)"
terraform init -input=false

step "terraform destroy (this may take 15-30 minutes)"
terraform destroy -input=false -auto-approve \
  -var="location=${AZURE_REGION}" \
  -var="gcp_project=${TF_GCP_PROJECT}" \
  -var="gcp_region=${TF_GCP_REGION}" \
  -var="gcp_onprem={deploy_gcp=${TF_DEPLOY_GCP},network_name=\"gcp-on-prem-vpc\",network_cidr=\"192.168.100.0/24\",subnet_cidr=\"192.168.100.0/24\",vm_private_ip=\"192.168.100.2\",cloud_router_asn=16550}" \
  || warn "terraform destroy returned non-zero. Proceeding to post-destroy verification."

ok "terraform destroy phase complete."

# ============================================================================
# Phase 3: Post-destroy verification
# ============================================================================
step "Phase 3 — Post-destroy verification"

RG_EXISTS="$(az group show -n "$RG" --query name -o tsv 2>/dev/null || true)"

if [[ -z "$RG_EXISTS" ]]; then
  ok "Resource group '${RG}' no longer exists. Azure cleanup confirmed."
else
  warn "Resource group '${RG}' still exists. Checking for remaining resources..."
  LEFTOVERS="$(az resource list -g "$RG" --query "[].{name:name,type:type}" -o table 2>/dev/null || true)"
  if [[ -n "$LEFTOVERS" && "$LEFTOVERS" != *"Name"* ]] || [[ $(echo "$LEFTOVERS" | wc -l) -gt 2 ]]; then
    warn "Resources still present in '${RG}':"
    echo "$LEFTOVERS"
    warn "You may need to manually delete them or re-run 'terraform destroy'."
    warn "  az group delete -n ${RG} --yes --no-wait"
  else
    ok "Resource group '${RG}' is empty. It will be removed shortly by Azure."
  fi
fi

if [[ "$USE_GCP" == "yes" ]]; then
  ok "GCP resources (VPC, VM, Cloud Router, Partner Interconnect attachment) were targeted by terraform destroy."
  warn "Verify in the GCP console: https://console.cloud.google.com/compute/instances?project=${GCP_PROJECT}"
fi

# ============================================================================
# Phase 4: Final reminder — Megaport VXCs require manual deletion
# ============================================================================
printf "\n${c_mag}╔══════════════════════════════════════════════════════════════════════╗${c_reset}\n"
printf "${c_mag}║   ⚠  MANUAL ACTION REQUIRED — Megaport VXCs                         ║${c_reset}\n"
printf "${c_mag}╠══════════════════════════════════════════════════════════════════════╣${c_reset}\n"
printf "${c_mag}║                                                                      ║${c_reset}\n"
printf "${c_mag}║  Terraform CANNOT delete Megaport VXCs (created in the portal).     ║${c_reset}\n"
printf "${c_mag}║  You MUST delete them manually in the Megaport portal:              ║${c_reset}\n"
printf "${c_mag}║                                                                      ║${c_reset}\n"
printf "${c_mag}║    https://portal.megaport.com                                       ║${c_reset}\n"
printf "${c_mag}║                                                                      ║${c_reset}\n"
printf "${c_mag}║  Delete both VXCs to stop Megaport charges:                         ║${c_reset}\n"
printf "${c_mag}║    1. Azure ExpressRoute VXC  (linked to circuit az-hub-er-circuit)  ║${c_reset}\n"
if [[ "$USE_GCP" == "yes" ]]; then
  printf "${c_mag}║    2. Google Interconnect VXC (linked to GCP pairing key)            ║${c_reset}\n"
fi
printf "${c_mag}║                                                                      ║${c_reset}\n"
printf "${c_mag}║  Reference: terraform/docs/megaport-cross-connect.md                ║${c_reset}\n"
printf "${c_mag}╚══════════════════════════════════════════════════════════════════════╝${c_reset}\n"
echo ""

# Scrub the password from the environment of this shell.
unset TF_VAR_admin_password || true
ok "Cleanup script complete."
