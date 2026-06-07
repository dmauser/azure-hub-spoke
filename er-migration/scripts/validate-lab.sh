#!/usr/bin/env bash
#
# Read-only validation of the ExpressRoute migration lab data path (Linux / Bash).
#
# Checks, without changing anything:
#   - ExpressRoute circuit provisioning + service-provider state
#   - AzurePrivatePeering state
#   - Gateway-to-circuit connection provisioning state
#   - GCP Cloud Router BGP session + whether it learned the Azure hub prefix
# Exits 0 when the data path looks healthy, 1 otherwise.

set -uo pipefail

RG="lab-er-migration"
CIRCUIT="az-hub-er-circuit"
GATEWAY="az-hub-ergw"
CONN_NAME="${GATEWAY}-to-${CIRCUIT}"
AZURE_HUB_CIDR="10.0.0.0/24"
GCP_ONPREM_CIDR="192.168.100.0/24"

GCP_PROJECT=""
GCP_REGION="us-east1"
SKIP_GCP="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gcp-project) GCP_PROJECT="$2"; shift 2 ;;
    --gcp-region)  GCP_REGION="$2"; shift 2 ;;
    --skip-gcp)    SKIP_GCP="yes"; shift ;;
    -h|--help) echo "Usage: $0 [--gcp-project ID] [--gcp-region REGION] [--skip-gcp]"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_green='\033[32m'; c_red='\033[31m'; c_cyan='\033[36m'; c_reset='\033[0m'
pass() { printf "${c_green}[PASS]${c_reset} %s\n" "$1"; }
fail() { printf "${c_red}[FAIL]${c_reset} %s\n" "$1"; }
info() { printf "${c_cyan}[INFO]${c_reset} %s\n" "$1"; }

failures=0

info "Validating ExpressRoute migration lab in resource group '$RG'"

# --- Circuit ---
prov="$(az network express-route show -g "$RG" -n "$CIRCUIT" --query provisioningState -o tsv 2>/dev/null || true)"
provider="$(az network express-route show -g "$RG" -n "$CIRCUIT" --query serviceProviderProvisioningState -o tsv 2>/dev/null || true)"
if [[ "$prov" == "Succeeded" && "$provider" == "Provisioned" ]]; then
  pass "Circuit '$CIRCUIT' is Succeeded / Provisioned."
else
  fail "Circuit prov='$prov' provider='$provider' (want Succeeded/Provisioned)."; failures=$((failures+1))
fi

# --- Private peering ---
peering="$(az network express-route peering list -g "$RG" --circuit-name "$CIRCUIT" \
  --query "[?peeringType=='AzurePrivatePeering'].provisioningState | [0]" -o tsv 2>/dev/null || true)"
if [[ "$peering" == "Succeeded" ]]; then pass "AzurePrivatePeering is Succeeded."
else fail "AzurePrivatePeering state = '${peering:-none}' (want Succeeded)."; failures=$((failures+1)); fi

# --- Connection ---
conn="$(az network vpn-connection show -g "$RG" -n "$CONN_NAME" --query provisioningState -o tsv 2>/dev/null || true)"
if [[ "$conn" == "Succeeded" ]]; then pass "Connection '$CONN_NAME' is Succeeded."
else fail "Connection '$CONN_NAME' state = '${conn:-none}' (want Succeeded)."; failures=$((failures+1)); fi

# --- GCP BGP / learned routes ---
if [[ "$SKIP_GCP" != "yes" ]]; then
  [[ -z "$GCP_PROJECT" ]] && GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -n "$GCP_PROJECT" && "$GCP_PROJECT" != "(unset)" ]]; then
    router="$(gcloud compute routers list --project "$GCP_PROJECT" --filter="region:( $GCP_REGION )" --format='value(name)' 2>/dev/null | head -n1 || true)"
    if [[ -n "$router" ]]; then
      bgp="$(gcloud compute routers get-status "$router" --region "$GCP_REGION" --project "$GCP_PROJECT" --format='value(result.bgpPeerStatus[].status)' 2>/dev/null || true)"
      if grep -q "UP" <<<"$bgp"; then pass "GCP Cloud Router '$router' BGP session is UP."
      else fail "GCP Cloud Router BGP status = '${bgp:-none}' (want UP)."; failures=$((failures+1)); fi

      learned="$(gcloud compute routers get-status "$router" --region "$GCP_REGION" --project "$GCP_PROJECT" --format='value(result.bestRoutesForRouter[].destRange)' 2>/dev/null || true)"
      if grep -q "$AZURE_HUB_CIDR" <<<"$learned"; then pass "GCP has learned the Azure hub prefix $AZURE_HUB_CIDR."
      else fail "GCP has NOT learned $AZURE_HUB_CIDR."; failures=$((failures+1)); fi
    else
      info "No GCP Cloud Router found in $GCP_REGION - skipping GCP route checks."
    fi
  else
    info "No GCP project set - skipping GCP checks (use --gcp-project or --skip-gcp)."
  fi
fi

echo
if [[ "$failures" -eq 0 ]]; then
  pass "Lab data path looks healthy (Azure $AZURE_HUB_CIDR <-> GCP $GCP_ONPREM_CIDR)."
  exit 0
else
  fail "$failures check(s) failed. BGP may still be converging, or the connection needs attention."
  exit 1
fi
