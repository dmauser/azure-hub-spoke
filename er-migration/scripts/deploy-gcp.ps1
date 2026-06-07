<#
.SYNOPSIS
  Interactive helper to deploy the GCP simulated on-prem side of the ER-migration lab.

.DESCRIPTION
  Prompts for the GCP inputs (project, region, zone), authenticates gcloud (user + ADC),
  enables the Compute Engine API, writes terraform.tfvars with deploy_gcp = true, then runs
  terraform init/plan and (after you confirm) apply. Finally prints the GCP Partner
  interconnect-attachment pairing key used to create the Megaport VXC on the GCP side.

  Run this from a machine that has the Google Cloud SDK (gcloud), Azure CLI (az), and
  Terraform installed. The Azure side of the lab must already be deployed.

.NOTES
  Analysis/automation helper only. Review every prompt before confirming apply.
#>

[CmdletBinding()]
param(
    [string]$GcpProject,
    [string]$GcpRegion = "us-east1",
    [string]$GcpZone   = "us-east1-b"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Show-InstallHelp($tool) {
    switch ($tool) {
        "gcloud" {
            Write-Warn2 "Windows : winget install --id Google.CloudSDK -e"
            Write-Warn2 "          (portable: download the bundled zip, unzip, add google-cloud-sdk\bin to PATH)"
            Write-Warn2 "Linux   : (Debian/Ubuntu) sudo apt-get install -y apt-transport-https ca-certificates gnupg curl"
            Write-Warn2 "          echo 'deb https://packages.cloud.google.com/apt cloud-sdk main' | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list"
            Write-Warn2 "          curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg"
            Write-Warn2 "          sudo apt-get update && sudo apt-get install -y google-cloud-cli   (or: curl https://sdk.cloud.google.com | bash)"
            Write-Warn2 "Docs    : https://cloud.google.com/sdk/docs/install"
        }
        "az" {
            Write-Warn2 "Windows : winget install --id Microsoft.AzureCLI -e"
            Write-Warn2 "Linux   : curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
            Write-Warn2 "Docs    : https://learn.microsoft.com/cli/azure/install-azure-cli"
        }
        "terraform" {
            Write-Warn2 "Windows : winget install --id Hashicorp.Terraform -e"
            Write-Warn2 "Linux   : sudo apt-get update && sudo apt-get install -y gnupg software-properties-common"
            Write-Warn2 "          wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
            Write-Warn2 "          echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com `$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list"
            Write-Warn2 "          sudo apt-get update && sudo apt-get install -y terraform"
            Write-Warn2 "Docs    : https://developer.hashicorp.com/terraform/install"
        }
    }
}

function Install-GcloudPortable {
    $dir = Join-Path $env:LOCALAPPDATA 'google-cloud-sdk-portable'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir 'gcloud.zip'
    $url = 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-windows-x86_64-bundled-python.zip'
    Write-Step "Downloading Google Cloud SDK (~100 MB)"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Write-Step "Extracting Google Cloud SDK"
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $bin = Join-Path $dir 'google-cloud-sdk\bin'
    $env:PATH = "$bin;$env:PATH"
    Write-Ok "gcloud installed to $bin (added to PATH for this session)"
}

function Install-ViaWinget($id) {
    if (-not (Test-Cmd winget)) { throw "winget is not available. Install $id manually using the command(s) above." }
    winget install --id $id -e --accept-package-agreements --accept-source-agreements
    # Refresh PATH from machine + user scopes so the freshly installed tool is found in this session.
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# --- Resolve paths (script lives in er-migration/scripts, terraform is ../terraform) ---
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TerraformDir = Resolve-Path (Join-Path $ScriptDir "..\terraform")
$TfvarsPath   = Join-Path $TerraformDir "terraform.tfvars"

Write-Step "ER-migration GCP on-prem deployment"
Write-Host "    Terraform dir : $TerraformDir"

# --- Prerequisite checks (offer to install if missing) ---
Write-Step "Checking prerequisites"
$onWindows = ($env:OS -eq 'Windows_NT')
foreach ($tool in @("gcloud", "az", "terraform")) {
    if (Test-Cmd $tool) { Write-Ok "$tool found"; continue }

    Write-Warn2 "$tool is NOT installed or not on PATH. Install options:"
    Show-InstallHelp $tool

    if (-not $onWindows) {
        throw "'$tool' is required. Install it with the Linux command above, then re-run this script."
    }

    $ans = Read-Host "Install $tool now? (y/N)"
    if ($ans -notmatch '^(y|yes)$') { throw "'$tool' is required. Install it and re-run this script." }

    switch ($tool) {
        "gcloud"    { Install-GcloudPortable }
        "az"        { Install-ViaWinget "Microsoft.AzureCLI" }
        "terraform" { Install-ViaWinget "Hashicorp.Terraform" }
    }

    if (-not (Test-Cmd $tool)) {
        throw "'$tool' still not found after install. Open a NEW terminal (so PATH refreshes) and re-run this script."
    }
    Write-Ok "$tool installed."
}

# --- Collect inputs ---
Write-Step "GCP inputs (press Enter to accept the [default])"
if (-not $GcpProject) {
    $detected = (gcloud config get-value project 2>$null)
    if ($detected -and $detected -ne "(unset)") { $defProj = $detected } else { $defProj = "" }
    $prompt = if ($defProj) { "GCP project ID [$defProj]" } else { "GCP project ID (required)" }
    $GcpProject = Read-Host $prompt
    if (-not $GcpProject -and $defProj) { $GcpProject = $defProj }
}
if (-not $GcpProject) { throw "A GCP project ID is required." }

$inRegion = Read-Host "GCP region [$GcpRegion]"
if ($inRegion) { $GcpRegion = $inRegion }
$inZone = Read-Host "GCP zone [$GcpZone]"
if ($inZone) { $GcpZone = $inZone }

Write-Ok "project = $GcpProject | region = $GcpRegion | zone = $GcpZone"

# --- Azure subscription (needed because azurerm v4 requires a subscription id) ---
Write-Step "Resolving Azure subscription (the apply re-plans the whole lab)"
$azSub = (az account show --query id -o tsv 2>$null)
if (-not $azSub) { throw "No active Azure subscription. Run 'az login' and 'az account set --subscription <id>' first." }
$env:ARM_SUBSCRIPTION_ID = $azSub
Write-Ok "ARM_SUBSCRIPTION_ID = $azSub"

# --- VM admin password (must match the value used for the existing Azure VMs) ---
Write-Step "Azure VM admin password"
Write-Warn2 "Enter the SAME admin_password used when the Azure side was deployed (12+ chars)."
$plain = $null
while (-not $plain) {
    $secure1 = Read-Host "admin_password" -AsSecureString
    $secure2 = Read-Host "Confirm admin_password" -AsSecureString

    $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
    $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)

    if ($p1 -ne $p2) {
        Write-Warn2 "Passwords do not match. Try again."
    } elseif ($p1.Length -lt 12) {
        Write-Warn2 "admin_password must be at least 12 characters. Try again."
    } else {
        $plain = $p1
    }
}
$env:TF_VAR_admin_password = $plain

# Make sure no leftover dummy Google token shadows real ADC auth.
Remove-Item Env:\GOOGLE_OAUTH_ACCESS_TOKEN -ErrorAction SilentlyContinue

# --- gcloud auth ---
Write-Step "Authenticating gcloud (a browser window may open)"
$activeAcct = (gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null)
if (-not $activeAcct) { gcloud auth login } else { Write-Ok "gcloud account: $activeAcct" }

Write-Step "Ensuring Application Default Credentials (Terraform google provider uses ADC)"
$adcOk = $false
try { gcloud auth application-default print-access-token 1>$null 2>$null; $adcOk = ($LASTEXITCODE -eq 0) } catch { $adcOk = $false }
if (-not $adcOk) { gcloud auth application-default login } else { Write-Ok "ADC present" }

gcloud config set project $GcpProject 1>$null 2>$null

Write-Step "Enabling Compute Engine API (compute.googleapis.com)"
gcloud services enable compute.googleapis.com --project $GcpProject
Write-Ok "Compute API enabled"

# --- Write terraform.tfvars ---
Write-Step "Writing $TfvarsPath (deploy_gcp = true)"
$tfvars = @"
# Generated by scripts/deploy-gcp.ps1 on $(Get-Date -Format o).
# admin_password is supplied via the TF_VAR_admin_password environment variable.

gcp_project = "$GcpProject"
gcp_region  = "$GcpRegion"
gcp_zone    = "$GcpZone"

gcp_onprem = {
  deploy_gcp       = true
  network_name     = "gcp-on-prem-vpc"
  network_cidr     = "192.168.100.0/24"
  subnet_cidr      = "192.168.100.0/24"
  vm_private_ip    = "192.168.100.2"
  cloud_router_asn = 16550
}
"@
Set-Content -Path $TfvarsPath -Value $tfvars -Encoding UTF8
Write-Ok "terraform.tfvars updated"

# --- Terraform init + plan ---
Push-Location $TerraformDir
try {
    Write-Step "terraform init"
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

    Write-Step "terraform plan"
    # Quote -out so PowerShell's native arg parser doesn't split the value (causes
    # terraform "Too many command line arguments").
    terraform plan -input=false "-out=gcp.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed." }

    Write-Step "Review the plan above"
    $answer = Read-Host "Type 'yes' to apply and create the GCP on-prem resources"
    if ($answer -ne "yes") {
        Write-Warn2 "Apply skipped. The saved plan is at $TerraformDir\gcp.tfplan (run 'terraform apply gcp.tfplan' later)."
        return
    }

    Write-Step "terraform apply (this can take a few minutes)"
    terraform apply -input=false "gcp.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed." }
    Write-Ok "Apply complete."

    # --- Pairing key for the Megaport GCP-side VXC ---
    Write-Step "Fetching the GCP Partner interconnect-attachment pairing key (for Megaport)"
    $attachment = "gcp-on-prem-vpc-partner-attachment"
    $pairingKey = (gcloud compute interconnects attachments describe $attachment `
        --region $GcpRegion --project $GcpProject --format="value(pairingKey)" 2>$null)
    if (-not $pairingKey) {
        Write-Warn2 "Could not read the GCP pairing key automatically. Retrieve it with:"
        Write-Warn2 "  gcloud compute interconnects attachments describe $attachment --region $GcpRegion --project $GcpProject --format=`"value(pairingKey)`""
    }

    # --- ExpressRoute service key for the Megaport Azure-side VXC ---
    Write-Step "Fetching the Azure ExpressRoute circuit service key (for Megaport)"
    $serviceKey = (terraform output -raw expressroute_circuit_service_key 2>$null)
    if (-not $serviceKey) {
        Write-Warn2 "Could not read the ExpressRoute service key automatically. Retrieve it with:"
        Write-Warn2 "  az network express-route show -g lab-er-migration -n az-hub-er-circuit --query serviceKey -o tsv"
    }

    # --- Show both keys and ask the user to provision the Megaport VXCs ---
    Write-Host "`n========================= MEGAPORT PROVISIONING =========================" -ForegroundColor Magenta
    Write-Host " Create BOTH cross-connects (VXCs) in the Megaport portal:" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  1) Azure ExpressRoute VXC  ->  service key:" -ForegroundColor White
    if ($serviceKey) { Write-Host "     $serviceKey" -ForegroundColor Green } else { Write-Host "     <see command above>" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  2) Google Interconnect VXC ->  GCP pairing key:" -ForegroundColor White
    if ($pairingKey) { Write-Host "     $pairingKey" -ForegroundColor Green } else { Write-Host "     <see command above>" -ForegroundColor Yellow }
    Write-Host "=========================================================================" -ForegroundColor Magenta

    Read-Host "`nGo create both VXCs in Megaport, then press Enter to check the Azure circuit status"

    # --- Poll the Azure circuit provider state until it is Provisioned ---
    # If it is already 'Provisioned', the loop breaks on the first check (skips waiting).
    Write-Step "Waiting for the Azure ExpressRoute circuit to be provisioned by Megaport"
    $rg          = "lab-er-migration"
    $circuit     = "az-hub-er-circuit"
    $pollSeconds = 60
    $attempt     = 0
    $state       = ""
    while ($true) {
        $attempt++
        $state = (az network express-route show -g $rg -n $circuit `
            --query serviceProviderProvisioningState -o tsv 2>$null)
        if ($state -eq "Provisioned") {
            Write-Ok "[check $attempt] serviceProviderProvisioningState = 'Provisioned'."
            break
        }
        if ($state) {
            Write-Warn2 "[check $attempt] serviceProviderProvisioningState = '$state' (not yet 'Provisioned'). Re-checking in ${pollSeconds}s... (Ctrl+C to stop)"
        } else {
            Write-Warn2 "[check $attempt] Could not read circuit state (verify 'az login' and the circuit name '$circuit'). Re-checking in ${pollSeconds}s... (Ctrl+C to stop)"
        }
        Start-Sleep -Seconds $pollSeconds
    }

    # --- Provisioned: move forward to bring up private peering ---
    Write-Step "Circuit is Provisioned - enable private peering and re-apply"
    Write-Host "       Set er_circuit.private_peering.enabled = true (+ vlan_id and two /30 peer prefixes)," -ForegroundColor Green
    Write-Host "       then run 'terraform apply' to create the gateway-to-circuit connection." -ForegroundColor Green
}
finally {
    Pop-Location
    # Scrub the password from the environment of this session.
    Remove-Item Env:\TF_VAR_admin_password -ErrorAction SilentlyContinue
    $plain = $null
}
