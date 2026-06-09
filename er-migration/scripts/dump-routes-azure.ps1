<#
.SYNOPSIS
    Dumps ExpressRoute routing tables on the AZURE side of the ER migration lab.

.DESCRIPTION
    Read-only. Collects and prints (and optionally saves) the routing information for:

      ExpressRoute CIRCUIT (per peering, primary + secondary paths):
        * az network express-route list-route-tables-summary  (BGP neighbour summary)
        * az network express-route list-route-tables           (routes in the MSEE table)
        * az network express-route list-arp-tables             (L2 ARP, optional)

      ExpressRoute GATEWAY(s) in the resource group:
        * az network vnet-gateway list-bgp-peer-status         (BGP peers)
        * az network vnet-gateway list-learned-routes          (routes learned via BGP)
        * az network vnet-gateway list-advertised-routes --peer (routes advertised to each peer)

    Circuit route tables are only available once the circuit's
    serviceProviderProvisioningState is 'Provisioned' and BGP is up (i.e. after the
    Megaport VXC + private peering are in place). When it is not provisioned, the script
    says so and skips the circuit calls; the gateway calls still run (and return empty
    until BGP converges).

    Command syntax validated against Microsoft Learn:
      https://learn.microsoft.com/cli/azure/network/express-route
      https://learn.microsoft.com/cli/azure/network/vnet-gateway

.EXAMPLE
    ./dump-routes-azure.ps1
    ./dump-routes-azure.ps1 -ResourceGroup lab-er-migration -OutputDir .\route-dumps
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "lab-er-migration",
    [string]$Circuit       = "az-hub-er-circuit",
    [string[]]$Gateway,
    [string]$PeeringName   = "AzurePrivatePeering",
    [string]$Subscription,
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    $msg" -ForegroundColor Red }
function Test-Cmd($name)   { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

if (-not (Test-Cmd "az")) { throw "Azure CLI ('az') is required. Install it and re-run." }

# Saves raw JSON for a section when -OutputDir is set.
function Save-Json($label, $json) {
    if (-not $OutputDir -or -not $json) { return }
    $safe = ($label -replace '[^A-Za-z0-9_-]', '-')
    $path = Join-Path $OutputDir "$safe.json"
    Set-Content -Path $path -Value $json -Encoding UTF8
    Write-Ok "saved -> $path"
}

# Runs an az command (passed as an argument array) ONCE as JSON, renders it as a local
# table, and returns the raw JSON. Single call avoids re-running the slow MSEE route-table
# queries. Never throws on az failure - reports and returns $null instead.
function Invoke-AzDump {
    param([string]$Label, [string[]]$AzArgs)
    Write-Step $Label
    $json = & az @AzArgs -o json 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not $json) {
        Write-Warn2 "No data returned (az exit $code). The resource may not be provisioned yet or BGP is not up."
        return $null
    }
    $raw = ($json -join "`n")
    Save-Json $Label $raw
    try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null }
    $rows = if ($obj -and ($obj.PSObject.Properties.Name -contains 'value')) { $obj.value } else { $obj }
    if (-not $rows -or (@($rows).Count -eq 0)) {
        Write-Ok "(no entries)"
    } else {
        @($rows) | Format-Table -AutoSize | Out-String | Write-Host
    }
    return $raw
}

# --- Subscription ---
if ($Subscription) {
    az account set --subscription $Subscription | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not switch to subscription '$Subscription'." }
}
$azSub = (az account show --query id -o tsv 2>$null)
if (-not $azSub) { throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." }
Write-Ok "Subscription : $azSub"
Write-Ok "Resource group: $ResourceGroup"

if ($OutputDir -and -not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# ============================ ExpressRoute CIRCUIT ============================
Write-Host "`n##################### ExpressRoute CIRCUIT: $Circuit #####################" -ForegroundColor Magenta
$circuitState = (az network express-route show -g $ResourceGroup -n $Circuit `
    --query serviceProviderProvisioningState -o tsv 2>$null)
if (-not $circuitState) {
    Write-Warn2 "Circuit '$Circuit' not found in '$ResourceGroup' (or not accessible). Skipping circuit route tables."
} else {
    Write-Ok "serviceProviderProvisioningState = $circuitState"
    if ($circuitState -ne "Provisioned") {
        Write-Warn2 "Circuit is not 'Provisioned' (needs the Megaport VXC). Route tables are unavailable until then; skipping."
    } else {
        foreach ($path in @("primary", "secondary")) {
            Invoke-AzDump "Circuit BGP summary [$PeeringName / $path]" `
                @("network","express-route","list-route-tables-summary","-g",$ResourceGroup,"-n",$Circuit,"--peering-name",$PeeringName,"--path",$path) | Out-Null
            Invoke-AzDump "Circuit route table [$PeeringName / $path]" `
                @("network","express-route","list-route-tables","-g",$ResourceGroup,"-n",$Circuit,"--peering-name",$PeeringName,"--path",$path) | Out-Null
            Invoke-AzDump "Circuit ARP table [$PeeringName / $path]" `
                @("network","express-route","list-arp-tables","-g",$ResourceGroup,"-n",$Circuit,"--peering-name",$PeeringName,"--path",$path) | Out-Null
        }
    }
}

# ============================ ExpressRoute GATEWAY(s) ============================
if (-not $Gateway -or $Gateway.Count -eq 0) {
    Write-Step "Discovering ExpressRoute gateways in '$ResourceGroup'"
    $Gateway = @(az network vnet-gateway list -g $ResourceGroup `
        --query "[?gatewayType=='ExpressRoute'].name" -o tsv 2>$null)
    if (-not $Gateway -or $Gateway.Count -eq 0) {
        Write-Warn2 "No ExpressRoute gateways found in '$ResourceGroup'. Nothing to dump on the gateway side."
        return
    }
    Write-Ok ("Found gateway(s): " + ($Gateway -join ", "))
}

foreach ($gw in $Gateway) {
    Write-Host "`n##################### ExpressRoute GATEWAY: $gw #####################" -ForegroundColor Magenta

    $peerJson = Invoke-AzDump "Gateway BGP peer status [$gw]" `
        @("network","vnet-gateway","list-bgp-peer-status","-g",$ResourceGroup,"-n",$gw)

    Invoke-AzDump "Gateway learned routes [$gw]" `
        @("network","vnet-gateway","list-learned-routes","-g",$ResourceGroup,"-n",$gw) | Out-Null

    # Advertised routes require a specific peer IP; pull peers from the BGP peer status.
    if ($peerJson) {
        $peers = @()
        try { $peers = @(($peerJson | ConvertFrom-Json).value | Select-Object -ExpandProperty neighbor) } catch { $peers = @() }
        $peers = $peers | Where-Object { $_ } | Sort-Object -Unique
        if ($peers.Count -eq 0) {
            Write-Warn2 "No BGP peers reported yet for '$gw' (BGP may not be up); skipping advertised routes."
        }
        foreach ($peer in $peers) {
            Invoke-AzDump "Gateway advertised routes [$gw -> peer $peer]" `
                @("network","vnet-gateway","list-advertised-routes","-g",$ResourceGroup,"-n",$gw,"--peer",$peer) | Out-Null
        }
    }
}

Write-Host "`n==> Done." -ForegroundColor Cyan
if ($OutputDir) { Write-Ok "JSON dumps saved under: $OutputDir" }
