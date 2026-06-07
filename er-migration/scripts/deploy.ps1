<#
.SYNOPSIS
  Full end-to-end deployment of the ExpressRoute migration lab (Windows / PowerShell).

.DESCRIPTION
  Drives the complete lab lifecycle:
    1. Checks prerequisites (az, terraform, and gcloud when deploying GCP) and offers to install missing ones.
    2. Collects inputs (Azure subscription, VM admin password, GCP project/region/zone).
    3. Authenticates Azure CLI and (for GCP) gcloud + Application Default Credentials.
    4. Writes terraform.tfvars and runs init/plan/apply for the Azure hub-spoke, ExpressRoute
       circuit + gateway, and (optionally) the GCP simulated on-prem side.
    5. Prints the ExpressRoute service key and GCP pairing key for manual Megaport VXC creation.
    6. Polls the circuit until Megaport provisions it (serviceProviderProvisioningState = Provisioned).
    7. Self-heals any ExpressRoute connection stuck in a Failed state, then enables and applies the
       gateway-to-circuit connection and polls it to Succeeded.
    8. Validates route exchange between Azure (10.0.0.0/24) and GCP (192.168.100.0/24).

  Re-runnable: existing resources are skipped by Terraform, and the circuit/connection steps detect
  state and only act when needed.

.NOTES
  Review every prompt before confirming apply. Creates real, billable Azure/GCP/Megaport resources.
#>

[CmdletBinding()]
param(
    [string]$AzureRegion = "westus3",
    [string]$GcpProject,
    [string]$GcpRegion = "us-east1",
    [string]$GcpZone   = "us-east1-b",
    [switch]$DeployGcp,
    [switch]$SkipGcp,
    [int]$PollSeconds = 60
)

$ErrorActionPreference = "Stop"

# Lab constants (must match the Terraform configuration).
$Rg            = "lab-er-migration"
$Circuit       = "az-hub-er-circuit"
$Gateway       = "az-hub-ergw"
$ConnName      = "$Gateway-to-$Circuit"
$AzureHubCidr  = "10.0.0.0/24"
$GcpOnpremCidr = "192.168.100.0/24"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    $msg" -ForegroundColor Red }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

$onWindows = ($PSVersionTable.Platform -ne 'Unix')

function Show-InstallHelp($tool) {
    switch ($tool) {
        "gcloud" {
            Write-Warn2 "Windows : winget install --id Google.CloudSDK -e"
            Write-Warn2 "Linux   : use scripts/deploy.sh, or https://cloud.google.com/sdk/docs/install"
            Write-Warn2 "Docs    : https://cloud.google.com/sdk/docs/install"
        }
        "az" {
            Write-Warn2 "Windows : winget install --id Microsoft.AzureCLI -e"
            Write-Warn2 "Linux   : curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
            Write-Warn2 "Docs    : https://learn.microsoft.com/cli/azure/install-azure-cli"
        }
        "terraform" {
            Write-Warn2 "Windows : winget install --id Hashicorp.Terraform -e"
            Write-Warn2 "Linux   : https://developer.hashicorp.com/terraform/install"
            Write-Warn2 "Docs    : https://developer.hashicorp.com/terraform/install"
        }
    }
}

function Install-GcloudPortable {
    $dest = Join-Path $env:USERPROFILE "gcloud-sdk"
    $bin  = Join-Path $dest "google-cloud-sdk\bin"
    if (Test-Path (Join-Path $bin "gcloud.cmd")) {
        $env:PATH = "$bin;" + $env:PATH
        Write-Ok "Found existing portable gcloud at $bin"
        return
    }
    $zipUrl = "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-windows-x86_64-bundled-python.zip"
    $zip    = Join-Path $env:TEMP "google-cloud-cli.zip"
    Write-Warn2 "Downloading Google Cloud SDK (portable, ~100 MB)..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    Write-Warn2 "Extracting to $dest ..."
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
    $env:PATH = "$bin;" + $env:PATH
}

function Install-ViaWinget($id) {
    if (-not (Test-Cmd "winget")) { throw "winget is not available. Install '$id' manually, then re-run." }
    winget install --id $id -e --accept-source-agreements --accept-package-agreements
}

function Ensure-Tool($tool, [switch]$Optional) {
    if (Test-Cmd $tool) { return $true }
    if ($Optional) { return $false }

    Write-Warn2 "$tool is NOT installed or not on PATH. Install options:"
    Show-InstallHelp $tool
    if (-not $onWindows) { throw "'$tool' is required. Install it with the command above, then re-run." }

    $ans = Read-Host "Install $tool now? (y/N)"
    if ($ans -notmatch '^(y|yes)$') { throw "'$tool' is required. Install it and re-run this script." }

    switch ($tool) {
        "gcloud"    { Install-GcloudPortable }
        "az"        { Install-ViaWinget "Microsoft.AzureCLI" }
        "terraform" { Install-ViaWinget "Hashicorp.Terraform" }
    }
    if (-not (Test-Cmd $tool)) {
        throw "'$tool' still not found. Open a NEW terminal (so PATH refreshes) and re-run this script."
    }
    Write-Ok "$tool installed."
    return $true
}

# Polls a script block until it returns the wanted value or the timeout elapses.
function Wait-ForState {
    param(
        [scriptblock]$Probe,
        [string]$Wanted,
        [string]$Label,
        [int]$IntervalSeconds = 60,
        [int]$TimeoutMinutes = 60
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $attempt  = 0
    while ($true) {
        $attempt++
        $state = (& $Probe)
        if ($state -eq $Wanted) {
            Write-Ok "[check $attempt] $Label = '$Wanted'."
            return $true
        }
        if ((Get-Date) -ge $deadline) {
            Write-Err2 "[check $attempt] Timed out after $TimeoutMinutes min waiting for $Label = '$Wanted' (last: '$state')."
            return $false
        }
        $shown = if ($state) { "'$state'" } else { "<unreadable>" }
        Write-Warn2 "[check $attempt] $Label = $shown (waiting for '$Wanted'). Re-checking in ${IntervalSeconds}s... (Ctrl+C to stop)"
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# ----------------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TerraformDir = Resolve-Path (Join-Path $ScriptDir "..\terraform")
$TfvarsPath   = Join-Path $TerraformDir "terraform.tfvars"

Write-Host "ExpressRoute migration lab - full deployment" -ForegroundColor Magenta
Write-Host "    Terraform dir : $TerraformDir"

# --- Decide GCP scope ---
if ($SkipGcp) {
    $useGcp = $false
} elseif ($DeployGcp) {
    $useGcp = $true
} else {
    $ans   = Read-Host "Deploy the GCP simulated on-prem side too? (Y/n)"
    $useGcp = ($ans -notmatch '^(n|no)$')
}
Write-Ok ("GCP side: " + ($(if ($useGcp) { "ENABLED" } else { "skipped (Azure only)" })))

# --- Azure region ---
Write-Step "Azure region (press Enter to accept the [default])"
if (-not $PSBoundParameters.ContainsKey('AzureRegion')) {
    $inRegion = Read-Host "Azure region [$AzureRegion]"
    if ($inRegion) { $AzureRegion = $inRegion }
}
Write-Ok "Azure region : $AzureRegion"

# --- Prerequisites ---
Write-Step "Checking prerequisites"
Ensure-Tool "az"        | Out-Null
Ensure-Tool "terraform" | Out-Null
if ($useGcp) { Ensure-Tool "gcloud" | Out-Null }
Write-Ok "All required tools present."

# --- GCP inputs ---
if ($useGcp) {
    Write-Step "GCP inputs (press Enter to accept the [default])"
    if (-not $GcpProject) {
        $detected = (gcloud config get-value project 2>$null)
        if ($detected -and $detected -ne "(unset)") { $defProj = $detected } else { $defProj = "" }
        $prompt = if ($defProj) { "GCP project ID [$defProj]" } else { "GCP project ID (required)" }
        $GcpProject = Read-Host $prompt
        if (-not $GcpProject -and $defProj) { $GcpProject = $defProj }
    }
    if (-not $GcpProject) { throw "A GCP project ID is required to deploy the GCP side." }
    if (-not $PSBoundParameters.ContainsKey('GcpRegion')) {
        $inRegion = Read-Host "GCP region [$GcpRegion]"; if ($inRegion) { $GcpRegion = $inRegion }
    }
    $inZone   = Read-Host "GCP zone [$GcpZone]";     if ($inZone)   { $GcpZone   = $inZone }
    Write-Ok "project = $GcpProject | region = $GcpRegion | zone = $GcpZone"
}

# --- Azure subscription ---
Write-Step "Resolving Azure subscription"
$azSub = (az account show --query id -o tsv 2>$null)
if (-not $azSub) {
    Write-Warn2 "Not logged in to Azure. Launching 'az login'..."
    az login | Out-Null
    $azSub = (az account show --query id -o tsv 2>$null)
}
if (-not $azSub) { throw "No active Azure subscription. Run 'az login' and 'az account set --subscription <id>'." }
$env:ARM_SUBSCRIPTION_ID = $azSub
Write-Ok "ARM_SUBSCRIPTION_ID = $azSub"

# --- VM admin password (with confirmation) ---
Write-Step "Azure VM admin password"
Write-Warn2 "Used as the login password for the lab Ubuntu VMs (12+ chars). Reuse the same value on re-runs."
$plain = $null
while (-not $plain) {
    $s1 = Read-Host "admin_password" -AsSecureString
    $s2 = Read-Host "Confirm admin_password" -AsSecureString
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    if ($p1 -ne $p2)        { Write-Warn2 "Passwords do not match. Try again." }
    elseif ($p1.Length -lt 12) { Write-Warn2 "admin_password must be at least 12 characters. Try again." }
    else { $plain = $p1 }
}
$env:TF_VAR_admin_password = $plain

# --- gcloud auth (GCP only) ---
if ($useGcp) {
    Remove-Item Env:\GOOGLE_OAUTH_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Write-Step "Authenticating gcloud (a browser window may open)"
    $activeAcct = (gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null)
    if (-not $activeAcct) { gcloud auth login } else { Write-Ok "gcloud account: $activeAcct" }

    Write-Step "Ensuring Application Default Credentials (Terraform google provider uses ADC)"
    $adcOk = $false
    try { gcloud auth application-default print-access-token 1>$null 2>$null; $adcOk = ($LASTEXITCODE -eq 0) } catch { $adcOk = $false }
    if (-not $adcOk) { gcloud auth application-default login } else { Write-Ok "ADC present" }

    gcloud config set project $GcpProject 1>$null 2>$null
    Write-Step "Enabling Compute Engine API"
    gcloud services enable compute.googleapis.com --project $GcpProject
    Write-Ok "Compute API enabled"
}

# --- Write terraform.tfvars (connection disabled for the first apply) ---
Write-Step "Writing $TfvarsPath"
$gcpProjLine = if ($useGcp) { $GcpProject } else { "er-migration-lab-unused" }
$gcpRegLine  = if ($useGcp) { $GcpRegion } else { "us-east1" }
$gcpZoneLine = if ($useGcp) { $GcpZone }   else { "us-east1-b" }
$deployGcp   = if ($useGcp) { "true" } else { "false" }
$tfvars = @"
# Generated by scripts/deploy.ps1 on $(Get-Date -Format o).
# admin_password is supplied via the TF_VAR_admin_password environment variable.

location    = "$AzureRegion"

gcp_project = "$gcpProjLine"
gcp_region  = "$gcpRegLine"
gcp_zone    = "$gcpZoneLine"

gcp_onprem = {
  deploy_gcp       = $deployGcp
  network_name     = "gcp-on-prem-vpc"
  network_cidr     = "192.168.100.0/24"
  subnet_cidr      = "192.168.100.0/24"
  vm_private_ip    = "192.168.100.2"
  cloud_router_asn = 16550
}

# Connection is enabled later, after Megaport provisions the circuit.
er_circuit = {
  name = "$Circuit"
  private_peering = {
    enabled        = false
    create_peering = false
    peer_asn       = 65001
  }
}
"@
Set-Content -Path $TfvarsPath -Value $tfvars -Encoding UTF8
Write-Ok "terraform.tfvars written"

Push-Location $TerraformDir
try {
    # --- Phase 1: deploy infrastructure (no connection yet) ---
    Write-Step "terraform init"
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

    Write-Step "terraform plan"
    terraform plan -input=false "-out=lab.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed." }

    $answer = Read-Host "`nReview the plan above. Type 'yes' to apply"
    if ($answer -ne "yes") { Write-Warn2 "Apply skipped. Saved plan: $TerraformDir\lab.tfplan"; return }

    Write-Step "terraform apply (this can take 30-45 minutes for the ExpressRoute gateway)"
    terraform apply -input=false "lab.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed." }
    Write-Ok "Infrastructure apply complete."

    # --- Phase 2: keys for Megaport ---
    $serviceKey = (terraform output -raw expressroute_circuit_service_key 2>$null)
    if (-not $serviceKey) {
        $serviceKey = (az network express-route show -g $Rg -n $Circuit --query serviceKey -o tsv 2>$null)
    }
    $pairingKey = $null
    if ($useGcp) {
        $attachment = "gcp-on-prem-vpc-partner-attachment"
        $pairingKey = (gcloud compute interconnects attachments describe $attachment `
            --region $GcpRegion --project $GcpProject --format="value(pairingKey)" 2>$null)
    }

    Write-Host "`n========================= MEGAPORT PROVISIONING =========================" -ForegroundColor Magenta
    Write-Host " Create the cross-connect(s) (VXCs) in the Megaport portal:" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  1) Azure ExpressRoute VXC  ->  service key:" -ForegroundColor White
    if ($serviceKey) { Write-Host "     $serviceKey" -ForegroundColor Green } else { Write-Warn2 "     az network express-route show -g $Rg -n $Circuit --query serviceKey -o tsv" }
    if ($useGcp) {
        Write-Host ""
        Write-Host "  2) Google Interconnect VXC ->  GCP pairing key:" -ForegroundColor White
        if ($pairingKey) { Write-Host "     $pairingKey" -ForegroundColor Green } else { Write-Warn2 "     gcloud compute interconnects attachments describe gcp-on-prem-vpc-partner-attachment --region $GcpRegion --project $GcpProject --format=`"value(pairingKey)`"" }
    }
    Write-Host "=========================================================================" -ForegroundColor Magenta
    Read-Host "`nProvision the VXC(s) in Megaport, then press Enter to continue"

    # --- Phase 3: wait for the circuit to be provisioned ---
    Write-Step "Waiting for the ExpressRoute circuit to be provisioned by Megaport"
    $provisioned = Wait-ForState `
        -Probe { az network express-route show -g $Rg -n $Circuit --query serviceProviderProvisioningState -o tsv 2>$null } `
        -Wanted "Provisioned" -Label "serviceProviderProvisioningState" `
        -IntervalSeconds $PollSeconds -TimeoutMinutes 120
    if (-not $provisioned) { throw "Circuit was not provisioned in time. Re-run the script once Megaport completes." }

    # --- Phase 4: ensure AzurePrivatePeering exists ---
    Write-Step "Verifying AzurePrivatePeering on the circuit"
    $peering = (az network express-route peering list -g $Rg --circuit-name $Circuit `
        --query "[?peeringType=='AzurePrivatePeering'].provisioningState | [0]" -o tsv 2>$null)
    if ($peering -ne "Succeeded") {
        Write-Warn2 "AzurePrivatePeering state = '$peering'. Megaport normally creates it automatically."
        Write-Warn2 "If your provider does NOT manage peering, set create_peering = true plus vlan_id and the two /30 prefixes in terraform.tfvars."
    } else {
        Write-Ok "AzurePrivatePeering = Succeeded"
    }

    # --- Phase 5: self-heal a Failed connection ---
    $connState = (az network vpn-connection show -g $Rg -n $ConnName --query provisioningState -o tsv 2>$null)
    if ($connState -eq "Failed") {
        Write-Warn2 "Existing connection '$ConnName' is in a Failed state (created before the circuit was provisioned)."
        $del = Read-Host "Delete the Failed connection so it can be recreated cleanly? (Y/n)"
        if ($del -notmatch '^(n|no)$') {
            az network vpn-connection delete -g $Rg -n $ConnName 2>$null | Out-Null
            Write-Ok "Removed the Failed connection."
        } else {
            Write-Warn2 "Leaving the Failed connection in place may block a clean apply."
        }
    } elseif ($connState) {
        Write-Ok "Existing connection '$ConnName' state = $connState"
    }

    # --- Phase 6: enable the connection and re-apply ---
    Write-Step "Enabling the gateway-to-circuit connection (create_peering = false)"
    (Get-Content $TfvarsPath -Raw) -replace 'enabled        = false', 'enabled        = true' | Set-Content -Path $TfvarsPath -Encoding UTF8

    terraform plan -input=false "-out=conn.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform plan (connection) failed." }
    terraform apply -input=false "conn.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform apply (connection) failed." }
    Write-Ok "Connection apply complete."

    # --- Phase 7: poll the connection to Succeeded ---
    Write-Step "Waiting for the ExpressRoute connection to succeed"
    $connOk = Wait-ForState `
        -Probe { az network vpn-connection show -g $Rg -n $ConnName --query provisioningState -o tsv 2>$null } `
        -Wanted "Succeeded" -Label "connection provisioningState" `
        -IntervalSeconds 30 -TimeoutMinutes 20
    if (-not $connOk) { Write-Warn2 "Connection did not reach 'Succeeded'. Check the portal and BGP status." }

    # --- Phase 8: validate route exchange ---
    Write-Step "Validating route exchange across ExpressRoute"
    $ok = $true
    if ($useGcp) {
        $router = (gcloud compute routers list --project $GcpProject --filter="region:( $GcpRegion )" --format="value(name)" 2>$null | Select-Object -First 1)
        if ($router) {
            $learned = (gcloud compute routers get-status $router --region $GcpRegion --project $GcpProject `
                --format="value(result.bestRoutesForRouter[].destRange)" 2>$null)
            if ($learned -match [regex]::Escape($AzureHubCidr)) {
                Write-Ok "GCP Cloud Router has learned the Azure hub prefix $AzureHubCidr."
            } else {
                Write-Warn2 "GCP has NOT yet learned $AzureHubCidr. BGP may still be converging - re-check in a minute."
                Write-Warn2 "  gcloud compute routers get-status $router --region $GcpRegion --project $GcpProject"
                $ok = $false
            }
        }
    }
    Write-Step "Done"
    if ($ok) {
        Write-Ok "Lab deployed and the ExpressRoute data path is up (Azure $AzureHubCidr <-> GCP $GcpOnpremCidr)."
    } else {
        Write-Warn2 "Lab deployed; route convergence still pending. Use scripts/validate-lab.ps1 to re-check."
    }
    Write-Host "`nNext: try the Azure managed gateway migration (portal/PowerShell) - see README." -ForegroundColor Cyan
}
finally {
    Pop-Location
    Remove-Item Env:\TF_VAR_admin_password -ErrorAction SilentlyContinue
    $plain = $null
}
