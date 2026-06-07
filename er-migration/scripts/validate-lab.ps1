<#
.SYNOPSIS
  Read-only validation of the ExpressRoute migration lab data path (Windows / PowerShell).

.DESCRIPTION
  Checks, without changing anything:
    - ExpressRoute circuit provisioning + service-provider state
    - AzurePrivatePeering state
    - Gateway-to-circuit connection provisioning state
    - GCP Cloud Router BGP session + whether it learned the Azure hub prefix
  Exits 0 when the data path looks healthy, 1 otherwise.

.NOTES
  Requires az (and gcloud for the GCP checks) authenticated to the lab subscription/project.
#>

[CmdletBinding()]
param(
    [string]$GcpProject,
    [string]$GcpRegion = "us-east1",
    [switch]$SkipGcp
)

$Rg            = "lab-er-migration"
$Circuit       = "az-hub-er-circuit"
$Gateway       = "az-hub-ergw"
$ConnName      = "$Gateway-to-$Circuit"
$AzureHubCidr  = "10.0.0.0/24"
$GcpOnpremCidr = "192.168.100.0/24"

function Write-Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }

$failures = 0

Write-Info "Validating ExpressRoute migration lab in resource group '$Rg'"

# --- Circuit ---
$circuitState = az network express-route show -g $Rg -n $Circuit `
    --query "{prov:provisioningState, provider:serviceProviderProvisioningState}" -o json 2>$null | ConvertFrom-Json
if ($circuitState.prov -eq "Succeeded" -and $circuitState.provider -eq "Provisioned") {
    Write-Pass "Circuit '$Circuit' is Succeeded / Provisioned."
} else {
    Write-Fail "Circuit state prov='$($circuitState.prov)' provider='$($circuitState.provider)' (want Succeeded/Provisioned)."
    $failures++
}

# --- Private peering ---
$peering = az network express-route peering list -g $Rg --circuit-name $Circuit `
    --query "[?peeringType=='AzurePrivatePeering'].provisioningState | [0]" -o tsv 2>$null
if ($peering -eq "Succeeded") { Write-Pass "AzurePrivatePeering is Succeeded." }
else { Write-Fail "AzurePrivatePeering state = '$peering' (want Succeeded)."; $failures++ }

# --- Connection ---
$conn = az network vpn-connection show -g $Rg -n $ConnName --query provisioningState -o tsv 2>$null
if ($conn -eq "Succeeded") { Write-Pass "Connection '$ConnName' is Succeeded." }
else { Write-Fail "Connection '$ConnName' state = '$conn' (want Succeeded)."; $failures++ }

# --- GCP BGP / learned routes ---
if (-not $SkipGcp) {
    if (-not $GcpProject) {
        $GcpProject = (gcloud config get-value project 2>$null)
    }
    if ($GcpProject -and $GcpProject -ne "(unset)") {
        $router = gcloud compute routers list --project $GcpProject --filter="region:( $GcpRegion )" --format="value(name)" 2>$null | Select-Object -First 1
        if ($router) {
            $bgpUp = gcloud compute routers get-status $router --region $GcpRegion --project $GcpProject `
                --format="value(result.bgpPeerStatus[].status)" 2>$null
            if ($bgpUp -match "UP") { Write-Pass "GCP Cloud Router '$router' BGP session is UP." }
            else { Write-Fail "GCP Cloud Router BGP status = '$bgpUp' (want UP)."; $failures++ }

            $learned = gcloud compute routers get-status $router --region $GcpRegion --project $GcpProject `
                --format="value(result.bestRoutesForRouter[].destRange)" 2>$null
            if ($learned -match [regex]::Escape($AzureHubCidr)) {
                Write-Pass "GCP has learned the Azure hub prefix $AzureHubCidr."
            } else {
                Write-Fail "GCP has NOT learned $AzureHubCidr."
                $failures++
            }
        } else {
            Write-Info "No GCP Cloud Router found in $GcpRegion - skipping GCP route checks."
        }
    } else {
        Write-Info "No GCP project set - skipping GCP checks (use -GcpProject or -SkipGcp)."
    }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Pass "Lab data path looks healthy (Azure $AzureHubCidr <-> GCP $GcpOnpremCidr)."
    exit 0
} else {
    Write-Fail "$failures check(s) failed. BGP may still be converging, or the connection needs attention."
    exit 1
}
