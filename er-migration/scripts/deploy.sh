#!/usr/bin/env bash
#
# Full end-to-end deployment of the ExpressRoute migration lab (Linux / Bash).
#
# Mirrors scripts/deploy.ps1:
#   1. Checks prerequisites (az, terraform, and gcloud when deploying GCP) and prints install help.
#   2. Collects inputs (Azure subscription, VM admin password, GCP project/region/zone).
#   3. Authenticates Azure CLI and (for GCP) gcloud + Application Default Credentials.
#   4. Writes terraform.tfvars and runs init/plan/apply for the Azure hub-spoke, ExpressRoute
#      circuit + gateway, and (optionally) the GCP simulated on-prem side.
#   5. Prints the ExpressRoute service key and GCP pairing key for manual Megaport VXC creation.
#   6. Polls the circuit until Megaport provisions it (serviceProviderProvisioningState = Provisioned).
#   7. Self-heals any ExpressRoute connection stuck in a Failed state, then enables and applies the
#      gateway-to-circuit connection and polls it to Succeeded.
#   8. Validates route exchange between Azure (10.0.0.0/24) and GCP (192.168.100.0/24).
#
# Review every prompt before confirming apply. Creates real, billable Azure/GCP/Megaport resources.

set -euo pipefail

# --- Lab constants (must match the Terraform configuration) ---
RG="lab-er-migration"
CIRCUIT="az-hub-er-circuit"
GATEWAY="az-hub-ergw"
CONN_NAME="${GATEWAY}-to-${CIRCUIT}"
AZURE_HUB_CIDR="10.0.0.0/24"
GCP_ONPREM_CIDR="192.168.100.0/24"

# --- Defaults / args ---
AZURE_REGION="westus3"
AZURE_REGION_SET=""  # set to "yes" if --azure-region was passed
GCP_PROJECT=""
GCP_REGION="us-east1"
GCP_REGION_SET=""    # set to "yes" if --gcp-region was passed
GCP_ZONE="us-east1-b"
USE_GCP=""          # "yes"/"no"; empty = prompt
POLL_SECONDS=60

usage() {
  cat <<EOF
Usage: $0 [options]
  --azure-region REGION Azure region        (default: westus3)
  --gcp-project ID     GCP project ID (enables the GCP side)
  --gcp-region  REGION GCP region (default: us-east1)
  --gcp-zone    ZONE   GCP zone   (default: us-east1-b)
  --deploy-gcp         Deploy the GCP side without prompting
  --skip-gcp           Azure-only deployment
  --poll-seconds N     Circuit poll interval (default: 60)
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --azure-region) AZURE_REGION="$2"; AZURE_REGION_SET="yes"; shift 2 ;;
    --gcp-project) GCP_PROJECT="$2"; USE_GCP="yes"; shift 2 ;;
    --gcp-region)  GCP_REGION="$2"; GCP_REGION_SET="yes"; shift 2 ;;
    --gcp-zone)    GCP_ZONE="$2"; shift 2 ;;
    --deploy-gcp)  USE_GCP="yes"; shift ;;
    --skip-gcp)    USE_GCP="no"; shift ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
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

show_install_help() {
  case "$1" in
    gcloud)
      warn "Debian/Ubuntu:"
      warn "  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg"
      warn "  echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list"
      warn "  sudo apt-get update && sudo apt-get install -y google-cloud-cli"
      warn "  (or: curl https://sdk.cloud.google.com | bash)"
      ;;
    az)
      warn "Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
      ;;
    terraform)
      warn "Debian/Ubuntu:"
      warn "  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
      warn "  echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list"
      warn "  sudo apt-get update && sudo apt-get install -y terraform"
      ;;
  esac
}

ensure_tool() {
  local tool="$1" optional="${2:-}"
  if has_cmd "$tool"; then return 0; fi
  if [[ "$optional" == "optional" ]]; then return 1; fi
  warn "$tool is NOT installed or not on PATH. Install options:"
  show_install_help "$tool"
  err "'$tool' is required. Install it with the command(s) above, then re-run this script."
  exit 1
}

# wait_for_state <wanted> <label> <interval> <timeout_min> <command...>
wait_for_state() {
  local wanted="$1" label="$2" interval="$3" timeout_min="$4"; shift 4
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  local attempt=0 state=""
  while true; do
    attempt=$((attempt+1))
    state="$("$@" 2>/dev/null || true)"
    if [[ "$state" == "$wanted" ]]; then
      ok "[check $attempt] $label = '$wanted'."
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      err "[check $attempt] Timed out after ${timeout_min} min waiting for $label = '$wanted' (last: '$state')."
      return 1
    fi
    warn "[check $attempt] $label = '${state:-<unreadable>}' (waiting for '$wanted'). Re-checking in ${interval}s... (Ctrl+C to stop)"
    sleep "$interval"
  done
}

probe_circuit_state() { az network express-route show -g "$RG" -n "$CIRCUIT" --query serviceProviderProvisioningState -o tsv; }
probe_conn_state()    { az network vpn-connection show -g "$RG" -n "$CONN_NAME" --query provisioningState -o tsv; }

# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../terraform" && pwd)"
TFVARS_PATH="${TERRAFORM_DIR}/terraform.tfvars"

printf "${c_mag}ExpressRoute migration lab - full deployment${c_reset}\n"
echo "    Terraform dir : ${TERRAFORM_DIR}"

# --- Decide GCP scope ---
if [[ -z "$USE_GCP" ]]; then
  read -r -p "Deploy the GCP simulated on-prem side too? (Y/n) " ans
  if [[ "$ans" =~ ^([nN]|no)$ ]]; then USE_GCP="no"; else USE_GCP="yes"; fi
fi
if [[ "$USE_GCP" == "yes" ]]; then ok "GCP side: ENABLED"; else ok "GCP side: skipped (Azure only)"; fi

# --- Azure region ---
step "Azure region (press Enter to accept the [default])"
if [[ -z "$AZURE_REGION_SET" ]]; then
  read -r -p "Azure region [$AZURE_REGION]: " in_az_region
  AZURE_REGION="${in_az_region:-$AZURE_REGION}"
fi
ok "Azure region : $AZURE_REGION"

# --- Prerequisites ---
step "Checking prerequisites"
ensure_tool az
ensure_tool terraform
[[ "$USE_GCP" == "yes" ]] && ensure_tool gcloud
ok "All required tools present."

# --- GCP inputs ---
if [[ "$USE_GCP" == "yes" ]]; then
  step "GCP inputs (press Enter to accept the [default])"
  if [[ -z "$GCP_PROJECT" ]]; then
    def_proj="$(gcloud config get-value project 2>/dev/null || true)"
    [[ "$def_proj" == "(unset)" ]] && def_proj=""
    if [[ -n "$def_proj" ]]; then
      read -r -p "GCP project ID [$def_proj]: " GCP_PROJECT; GCP_PROJECT="${GCP_PROJECT:-$def_proj}"
    else
      read -r -p "GCP project ID (required): " GCP_PROJECT
    fi
  fi
  [[ -z "$GCP_PROJECT" ]] && { err "A GCP project ID is required to deploy the GCP side."; exit 1; }
  if [[ -z "$GCP_REGION_SET" ]]; then
    read -r -p "GCP region [$GCP_REGION]: " in_region; GCP_REGION="${in_region:-$GCP_REGION}"
  fi
  read -r -p "GCP zone [$GCP_ZONE]: " in_zone; GCP_ZONE="${in_zone:-$GCP_ZONE}"
  ok "project = $GCP_PROJECT | region = $GCP_REGION | zone = $GCP_ZONE"
fi

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

# --- VM admin password (with confirmation) ---
step "Azure VM admin password"
warn "Used as the login password for the lab Ubuntu VMs (12+ chars). Reuse the same value on re-runs."
ADMIN_PASSWORD=""
while true; do
  read -r -s -p "admin_password: " p1; echo
  read -r -s -p "Confirm admin_password: " p2; echo
  if [[ "$p1" != "$p2" ]]; then warn "Passwords do not match. Try again.";
  elif [[ ${#p1} -lt 12 ]]; then warn "admin_password must be at least 12 characters. Try again.";
  else ADMIN_PASSWORD="$p1"; break; fi
done
export TF_VAR_admin_password="$ADMIN_PASSWORD"

# --- gcloud auth (GCP only) ---
if [[ "$USE_GCP" == "yes" ]]; then
  unset GOOGLE_OAUTH_ACCESS_TOKEN || true
  step "Authenticating gcloud (a browser/URL prompt may appear)"
  active_acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [[ -z "$active_acct" ]]; then gcloud auth login; else ok "gcloud account: $active_acct"; fi

  step "Ensuring Application Default Credentials (Terraform google provider uses ADC)"
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    gcloud auth application-default login
  else
    ok "ADC present"
  fi
  gcloud config set project "$GCP_PROJECT" >/dev/null 2>&1
  step "Enabling Compute Engine API"
  gcloud services enable compute.googleapis.com --project "$GCP_PROJECT"
  ok "Compute API enabled"
fi

# --- Write terraform.tfvars (connection disabled for the first apply) ---
step "Writing $TFVARS_PATH"
if [[ "$USE_GCP" == "yes" ]]; then
  TF_GCP_PROJECT="$GCP_PROJECT"; TF_GCP_REGION="$GCP_REGION"; TF_GCP_ZONE="$GCP_ZONE"; TF_DEPLOY_GCP="true"
else
  TF_GCP_PROJECT="er-migration-lab-unused"; TF_GCP_REGION="us-east1"; TF_GCP_ZONE="us-east1-b"; TF_DEPLOY_GCP="false"
fi
cat > "$TFVARS_PATH" <<EOF
# Generated by scripts/deploy.sh on $(date -Iseconds).
# admin_password is supplied via the TF_VAR_admin_password environment variable.

location    = "$AZURE_REGION"

gcp_project = "$TF_GCP_PROJECT"
gcp_region  = "$TF_GCP_REGION"
gcp_zone    = "$TF_GCP_ZONE"

gcp_onprem = {
  deploy_gcp       = $TF_DEPLOY_GCP
  network_name     = "gcp-on-prem-vpc"
  network_cidr     = "192.168.100.0/24"
  subnet_cidr      = "192.168.100.0/24"
  vm_private_ip    = "192.168.100.2"
  cloud_router_asn = 16550
}

# Connection is enabled later, after Megaport provisions the circuit.
er_circuit = {
  name = "$CIRCUIT"
  private_peering = {
    enabled        = false
    create_peering = false
    peer_asn       = 65001
  }
}
EOF
ok "terraform.tfvars written"

cd "$TERRAFORM_DIR"

# --- Phase 1: deploy infrastructure (no connection yet) ---
step "terraform init"
terraform init -input=false

step "terraform plan"
terraform plan -input=false -out=lab.tfplan

read -r -p $'\nReview the plan above. Type '\''yes'\'' to apply: ' answer
if [[ "$answer" != "yes" ]]; then warn "Apply skipped. Saved plan: ${TERRAFORM_DIR}/lab.tfplan"; exit 0; fi

step "terraform apply (this can take 30-45 minutes for the ExpressRoute gateway)"
terraform apply -input=false lab.tfplan
ok "Infrastructure apply complete."

# --- Phase 2: keys for Megaport ---
SERVICE_KEY="$(terraform output -raw expressroute_circuit_service_key 2>/dev/null || true)"
[[ -z "$SERVICE_KEY" ]] && SERVICE_KEY="$(az network express-route show -g "$RG" -n "$CIRCUIT" --query serviceKey -o tsv 2>/dev/null || true)"
PAIRING_KEY=""
if [[ "$USE_GCP" == "yes" ]]; then
  PAIRING_KEY="$(gcloud compute interconnects attachments describe gcp-on-prem-vpc-partner-attachment \
    --region "$GCP_REGION" --project "$GCP_PROJECT" --format='value(pairingKey)' 2>/dev/null || true)"
fi

printf "\n${c_mag}========================= MEGAPORT PROVISIONING =========================${c_reset}\n"
printf "${c_mag} Create the cross-connect(s) (VXCs) in the Megaport portal:${c_reset}\n\n"
echo "  1) Azure ExpressRoute VXC  ->  service key:"
if [[ -n "$SERVICE_KEY" ]]; then ok "     $SERVICE_KEY"; else warn "     az network express-route show -g $RG -n $CIRCUIT --query serviceKey -o tsv"; fi
if [[ "$USE_GCP" == "yes" ]]; then
  echo
  echo "  2) Google Interconnect VXC ->  GCP pairing key:"
  if [[ -n "$PAIRING_KEY" ]]; then ok "     $PAIRING_KEY"; else warn "     gcloud compute interconnects attachments describe gcp-on-prem-vpc-partner-attachment --region $GCP_REGION --project $GCP_PROJECT --format='value(pairingKey)'"; fi
fi
printf "${c_mag}=========================================================================${c_reset}\n"
read -r -p $'\nProvision the VXC(s) in Megaport, then press Enter to continue... ' _

# --- Phase 3: wait for the circuit to be provisioned ---
step "Waiting for the ExpressRoute circuit to be provisioned by Megaport"
if ! wait_for_state "Provisioned" "serviceProviderProvisioningState" "$POLL_SECONDS" 120 probe_circuit_state; then
  err "Circuit was not provisioned in time. Re-run the script once Megaport completes."; exit 1
fi

# --- Phase 4: ensure AzurePrivatePeering exists ---
step "Verifying AzurePrivatePeering on the circuit"
PEERING="$(az network express-route peering list -g "$RG" --circuit-name "$CIRCUIT" \
  --query "[?peeringType=='AzurePrivatePeering'].provisioningState | [0]" -o tsv 2>/dev/null || true)"
if [[ "$PEERING" != "Succeeded" ]]; then
  warn "AzurePrivatePeering state = '${PEERING:-none}'. Megaport normally creates it automatically."
  warn "If your provider does NOT manage peering, set create_peering = true plus vlan_id and the two /30 prefixes in terraform.tfvars."
else
  ok "AzurePrivatePeering = Succeeded"
fi

# --- Phase 5: self-heal a Failed connection ---
CONN_STATE="$(az network vpn-connection show -g "$RG" -n "$CONN_NAME" --query provisioningState -o tsv 2>/dev/null || true)"
if [[ "$CONN_STATE" == "Failed" ]]; then
  warn "Existing connection '$CONN_NAME' is in a Failed state (created before the circuit was provisioned)."
  read -r -p "Delete the Failed connection so it can be recreated cleanly? (Y/n) " del
  if [[ ! "$del" =~ ^([nN]|no)$ ]]; then
    az network vpn-connection delete -g "$RG" -n "$CONN_NAME" >/dev/null 2>&1 || true
    ok "Removed the Failed connection."
  else
    warn "Leaving the Failed connection in place may block a clean apply."
  fi
elif [[ -n "$CONN_STATE" ]]; then
  ok "Existing connection '$CONN_NAME' state = $CONN_STATE"
fi

# --- Phase 6: enable the connection and re-apply ---
step "Enabling the gateway-to-circuit connection (create_peering = false)"
sed -i 's/enabled        = false/enabled        = true/' "$TFVARS_PATH"
terraform plan -input=false -out=conn.tfplan
terraform apply -input=false conn.tfplan
ok "Connection apply complete."

# --- Phase 7: poll the connection to Succeeded ---
step "Waiting for the ExpressRoute connection to succeed"
if ! wait_for_state "Succeeded" "connection provisioningState" 30 20 probe_conn_state; then
  warn "Connection did not reach 'Succeeded'. Check the portal and BGP status."
fi

# --- Phase 8: validate route exchange ---
step "Validating route exchange across ExpressRoute"
OK_PATH="yes"
if [[ "$USE_GCP" == "yes" ]]; then
  ROUTER="$(gcloud compute routers list --project "$GCP_PROJECT" --filter="region:( $GCP_REGION )" --format='value(name)' 2>/dev/null | head -n1 || true)"
  if [[ -n "$ROUTER" ]]; then
    LEARNED="$(gcloud compute routers get-status "$ROUTER" --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --format='value(result.bestRoutesForRouter[].destRange)' 2>/dev/null || true)"
    if grep -q "$AZURE_HUB_CIDR" <<<"$LEARNED"; then
      ok "GCP Cloud Router has learned the Azure hub prefix $AZURE_HUB_CIDR."
    else
      warn "GCP has NOT yet learned $AZURE_HUB_CIDR. BGP may still be converging - re-check in a minute."
      warn "  gcloud compute routers get-status $ROUTER --region $GCP_REGION --project $GCP_PROJECT"
      OK_PATH="no"
    fi
  fi
fi

step "Done"
if [[ "$OK_PATH" == "yes" ]]; then
  ok "Lab deployed and the ExpressRoute data path is up (Azure $AZURE_HUB_CIDR <-> GCP $GCP_ONPREM_CIDR)."
else
  warn "Lab deployed; route convergence still pending. Use scripts/validate-lab.sh to re-check."
fi
printf "\n${c_cyan}Next: try the Azure managed gateway migration (portal/PowerShell) - see README.${c_reset}\n"

# Scrub the password from the environment of this shell.
unset TF_VAR_admin_password || true
