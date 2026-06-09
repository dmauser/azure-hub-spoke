<#
.SYNOPSIS
    Dumps routing tables on the GCP "on-prem" side of the ER migration lab.

.DESCRIPTION
    Read-only. Collects and prints (and optionally saves) the routing information for the
    simulated on-prem GCP VPC that attaches to Azure over the Megaport / Partner
    Interconnect:

        * gcloud compute routers get-status   - BGP peer state + DYNAMIC routes learned
                                                 via BGP (e.g. the Azure hub 10.0.0.0/24)
        * gcloud compute routers describe      - Cloud Router config (ASN, BGP peers)
        * gcloud compute routes list           - static / subnet / peering routes
                                                 (does NOT include dynamic BGP routes)
        * gcloud compute interconnects attachments describe
                                               - VLAN attachment + Cloud/customer router
                                                 IPs and pairing key

    Per Google's docs, 'routes list' shows custom static/subnet/peering routes only;
    BGP-learned (dynamic) routes are viewed via 'routers get-status'.

    Command syntax validated against Google Cloud docs:
      https://cloud.google.com/sdk/gcloud/reference/compute/routers/get-status
      https://cloud.google.com/sdk/gcloud/reference/compute/routes/list
      https://cloud.google.com/network-connectivity/docs/interconnect/how-to/partner/viewing-vlans

.EXAMPLE
    ./dump-routes-gcp.ps1 -Project my-gcp-project
    ./dump-routes-gcp.ps1 -Project my-gcp-project -Region us-east1 -OutputDir .\route-dumps
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region     = "us-central1",
    [string]$Router     = "gcp-on-prem-vpc-router",
    [string]$Attachment = "vlan-to-megaport",
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Test-Cmd($name)   { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

if (-not (Test-Cmd "gcloud")) { throw "Google Cloud SDK ('gcloud') is required. Install it and re-run." }

# --- Project + auth ---
$activeAcct = (gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null)
if (-not $activeAcct) { throw "No active gcloud account. Run 'gcloud auth login' first." }
Write-Ok "gcloud account: $activeAcct"

if (-not $Project) {
    $Project = (gcloud config get-value project 2>$null)
    if (-not $Project -or $Project -eq "(unset)") {
        throw "No GCP project specified. Pass -Project <id> or run 'gcloud config set project <id>'."
    }
}
Write-Ok "Project : $Project"
Write-Ok "Region  : $Region"
Write-Ok "Router  : $Router"

if ($OutputDir -and -not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

function Save-Json($label, $json) {
    if (-not $OutputDir -or -not $json) { return }
    $safe = ($label -replace '[^A-Za-z0-9_-]', '-')
    $path = Join-Path $OutputDir "$safe.json"
    Set-Content -Path $path -Value $json -Encoding UTF8
    Write-Ok "saved -> $path"
}

# Runs a gcloud command (argument array) and prints a readable table view. Only makes a
# second JSON call when -OutputDir is set (to save the raw dump). Never throws on gcloud
# failure - reports instead.
function Invoke-GcDump {
    param([string]$Label, [string[]]$GcArgs, [string]$TableFormat)
    Write-Step $Label
    $fmt = if ($TableFormat) { $TableFormat } else { "json" }
    $out = & gcloud @GcArgs --format=$fmt 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Warn2 "No data returned (gcloud exit $code). The resource may not exist yet or BGP is not up."
        return
    }
    if ($out) { $out | Out-Host } else { Write-Ok "(no entries)" }
    if ($OutputDir) {
        $json = & gcloud @GcArgs --format=json 2>$null
        Save-Json $Label ($json -join "`n")
    }
}

Write-Host "`n##################### GCP Cloud Router: $Router #####################" -ForegroundColor Magenta

# Dynamic (BGP-learned) routes + BGP peer state.
Invoke-GcDump "Cloud Router status: BGP peers" `
    @("compute","routers","get-status",$Router,"--region",$Region,"--project",$Project) `
    "table(result.bgpPeerStatus[].name, result.bgpPeerStatus[].ipAddress, result.bgpPeerStatus[].peerIpAddress, result.bgpPeerStatus[].state, result.bgpPeerStatus[].status, result.bgpPeerStatus[].numLearnedRoutes)" | Out-Null

Invoke-GcDump "Cloud Router status: learned (dynamic) routes" `
    @("compute","routers","get-status",$Router,"--region",$Region,"--project",$Project) `
    "table(result.bestRoutesForRouter[].destRange, result.bestRoutesForRouter[].nextHopIp, result.bestRoutesForRouter[].priority)" | Out-Null

Invoke-GcDump "Cloud Router config (ASN + BGP peers)" `
    @("compute","routers","describe",$Router,"--region",$Region,"--project",$Project) `
    "yaml(bgp, bgpPeers, interfaces)" | Out-Null

Write-Host "`n##################### GCP VPC routes (static/subnet/peering) #####################" -ForegroundColor Magenta
Invoke-GcDump "Static / subnet / peering routes" `
    @("compute","routes","list","--project",$Project) `
    "table(name, network, destRange, nextHopGateway.scope(), nextHopIp, priority)" | Out-Null

Write-Host "`n##################### Partner Interconnect VLAN attachment #####################" -ForegroundColor Magenta
Invoke-GcDump "Interconnect attachment: $Attachment" `
    @("compute","interconnects","attachments","describe",$Attachment,"--region",$Region,"--project",$Project) `
    "yaml(name, state, type, cloudRouterIpAddress, customerRouterIpAddress, pairingKey, vlanTag8021q, router)" | Out-Null

Write-Host "`n==> Done." -ForegroundColor Cyan
if ($OutputDir) { Write-Ok "JSON dumps saved under: $OutputDir" }
