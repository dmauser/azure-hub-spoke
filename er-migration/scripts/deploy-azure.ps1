<#
.SYNOPSIS
    Deploys ONLY the Azure side of the ExpressRoute migration lab (no GCP, no Megaport).

.DESCRIPTION
    A trimmed-down companion to deploy.ps1 for standing up just the Azure hub-spoke
    infrastructure (resource group, hub + spoke VNets, NSG/VM, Azure Bastion, the
    ExpressRoute gateway and an unprovisioned ExpressRoute circuit) in a SEPARATE
    resource group, without:
      * the GCP simulated on-prem side (gcp_onprem.deploy_gcp = false), and
      * the Megaport cross-connect / gateway-to-circuit connection
        (er_circuit.private_peering.enabled = false).

    State isolation: this script runs Terraform in a dedicated workspace named after the
    target resource group, so it never touches the state of the main deploy.ps1 lab.
    The original workspace is restored when the script finishes.

    The ExpressRoute circuit is created but left in serviceProviderProvisioningState
    'NotProvisioned' (that step requires Megaport). No gateway-to-circuit connection is
    created. Run the full deploy.ps1 if you later want the end-to-end ER data path.

.EXAMPLE
    ./deploy-azure.ps1 -ResourceGroup lab-er-azure-only -AzureRegion westus3
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "lab-er-migration-azure",
    [string]$AzureRegion   = "westus3",
    [string]$Subscription,
    [int]$PollSeconds = 60
)

$ErrorActionPreference = "Stop"

# Lab constants (must match the Terraform configuration).
$Circuit = "az-hub-er-circuit"
$Gateway = "az-hub-ergw"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    $msg" -ForegroundColor Red }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

$onWindows = ($PSVersionTable.Platform -ne 'Unix')

function Ensure-Tool($tool) {
    if (Test-Cmd $tool) { return }
    Write-Err2 "$tool is NOT installed or not on PATH."
    switch ($tool) {
        "az"        {
            Write-Warn2 "Windows : winget install --id Microsoft.AzureCLI -e"
            Write-Warn2 "Docs    : https://learn.microsoft.com/cli/azure/install-azure-cli"
        }
        "terraform" {
            Write-Warn2 "Windows : winget install --id Hashicorp.Terraform -e"
            Write-Warn2 "Docs    : https://developer.hashicorp.com/terraform/install"
        }
    }
    throw "'$tool' is required. Install it and re-run this script."
}

# Runs 'terraform apply' with retries on transient Azure control-plane errors
# (context deadline exceeded / connection reset) that can occur during the long
# ExpressRoute gateway provisioning. The first attempt uses the reviewed saved plan;
# retries re-plan against current state (the saved plan is stale after a partial apply).
# Must be called from within the Terraform directory.
function Invoke-TfApplyWithRetry {
    param(
        [string]$PlanFile,
        [int]$MaxAttempts = 3,
        [string]$Label = "terraform apply"
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -eq 1 -and $PlanFile -and (Test-Path $PlanFile)) {
            terraform apply -input=false $PlanFile
        } else {
            Write-Warn2 "[$Label] Attempt $attempt/$MaxAttempts - re-planning and applying against current state (auto-approve)..."
            terraform apply -input=false -auto-approve
        }
        if ($LASTEXITCODE -eq 0) {
            if ($attempt -gt 1) { Write-Ok "[$Label] succeeded on attempt $attempt." }
            return
        }
        if ($attempt -lt $MaxAttempts) {
            $wait = 30 * $attempt
            Write-Warn2 "[$Label] failed (exit $LASTEXITCODE). This is usually a transient Azure control-plane error (context deadline exceeded / connection reset). Retrying in ${wait}s..."
            Start-Sleep -Seconds $wait
        }
    }
    throw "$Label failed after $MaxAttempts attempts. Re-run this script to resume - Terraform apply is idempotent and will pick up where it left off."
}

# ----------------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TerraformDir = Resolve-Path (Join-Path $ScriptDir "..\terraform")
$TfvarsPath   = Join-Path $TerraformDir "terraform.tfvars"

Write-Host "ExpressRoute migration lab - AZURE-ONLY deployment (no GCP, no Megaport)" -ForegroundColor Magenta
Write-Host "    Terraform dir : $TerraformDir"

# --- Azure region ---
Write-Step "Azure region (press Enter to accept the [default])"
if (-not $PSBoundParameters.ContainsKey('AzureRegion')) {
    $inRegion = Read-Host "Azure region [$AzureRegion]"
    if ($inRegion) { $AzureRegion = $inRegion }
}
Write-Ok "Azure region : $AzureRegion"

# --- Azure resource group ---
Write-Step "Azure resource group (press Enter to accept the [default])"
if (-not $PSBoundParameters.ContainsKey('ResourceGroup')) {
    $inRg = Read-Host "Azure resource group [$ResourceGroup]"
    if ($inRg) { $ResourceGroup = $inRg }
}
$Rg = $ResourceGroup
Write-Ok "Azure resource group : $Rg"

# --- Prerequisites ---
Write-Step "Checking prerequisites"
Ensure-Tool "az"
Ensure-Tool "terraform"
Write-Ok "All required tools present."

# --- Azure authentication ---
Write-Step "Checking Azure authentication"
$azSub = (az account show --query id -o tsv 2>$null)
if (-not $azSub) {
    Write-Warn2 "Not logged in to Azure. Launching 'az login'..."
    az login | Out-Null
    $azSub = (az account show --query id -o tsv 2>$null)
}
if (-not $azSub) { throw "Azure login failed. Run 'az login' manually, then re-run this script." }
$azUser = (az account show --query user.name -o tsv 2>$null)
Write-Ok "Authenticated to Azure as $azUser"

# --- Azure subscription selection ---
Write-Step "Selecting Azure subscription"
$curName = (az account show --query name -o tsv 2>$null)
Write-Ok "Current subscription: $curName ($azSub)"
$subs = @(az account list --query "sort_by([?state=='Enabled'].{name:name, id:id}, &name)" -o json 2>$null | ConvertFrom-Json)
if ($PSBoundParameters.ContainsKey('Subscription') -and $Subscription) {
    az account set --subscription $Subscription | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not switch to subscription '$Subscription'. Check the name/ID and try again." }
    $azSub   = (az account show --query id -o tsv 2>$null)
    $curName = (az account show --query name -o tsv 2>$null)
    Write-Ok "Using subscription: $curName ($azSub)"
} elseif ($subs.Count -gt 1) {
    Write-Host "    Available subscriptions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $subs.Count; $i++) {
        Write-Host ("      [{0}] {1}  ({2})" -f $i, $subs[$i].name, $subs[$i].id)
    }
    $pick = Read-Host "Subscription number to use [press Enter to keep current]"
    if ($pick -match '^\d+$' -and [int]$pick -lt $subs.Count) {
        $azSub = $subs[[int]$pick].id
        az account set --subscription $azSub | Out-Null
        $curName = $subs[[int]$pick].name
        Write-Ok "Switched to subscription: $curName ($azSub)"
    } else {
        Write-Ok "Keeping current subscription: $curName ($azSub)"
    }
}
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
    if ($p1 -ne $p2)            { Write-Warn2 "Passwords do not match. Try again." }
    elseif ($p1.Length -lt 12)  { Write-Warn2 "admin_password must be at least 12 characters. Try again." }
    else { $plain = $p1 }
}
$env:TF_VAR_admin_password = $plain

# --- Write terraform.tfvars (Azure only: GCP off, ER connection off) ---
Write-Step "Writing $TfvarsPath"
$tfvars = @"
# Generated by scripts/deploy-azure.ps1 on $(Get-Date -Format o).
# Azure-only deployment: GCP disabled and the Megaport ER connection disabled.
# admin_password is supplied via the TF_VAR_admin_password environment variable.

rg_name     = "$Rg"
location    = "$AzureRegion"

# GCP simulated on-prem side is intentionally disabled.
gcp_project = "er-migration-lab-unused"
gcp_region  = "us-east1"
gcp_zone    = "us-east1-b"

gcp_onprem = {
  deploy_gcp       = false
  network_name     = "gcp-on-prem-vpc"
  network_cidr     = "192.168.100.0/24"
  subnet_cidr      = "192.168.100.0/24"
  vm_private_ip    = "192.168.100.2"
  cloud_router_asn = 16550
}

# The ExpressRoute circuit is created but left unprovisioned; no gateway-to-circuit
# connection is created (that requires the Megaport cross-connect).
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

# --- Terraform workspace (isolates state from the main deploy.ps1 lab) ---
$Workspace = ($Rg -replace '[^A-Za-z0-9_-]', '-')

Push-Location $TerraformDir
$priorWorkspace = $null
try {
    Write-Step "terraform init"
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

    $priorWorkspace = (terraform workspace show 2>$null)
    Write-Step "Selecting isolated Terraform workspace '$Workspace'"
    terraform workspace select -or-create $Workspace
    if ($LASTEXITCODE -ne 0) { throw "Could not select/create Terraform workspace '$Workspace'." }
    Write-Ok "Workspace: $Workspace (state isolated from the main lab)"

    Write-Step "terraform plan"
    terraform plan -input=false "-out=azure-only.tfplan"
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed." }

    $answer = Read-Host "`nReview the plan above. Type 'yes' to apply"
    if ($answer -ne "yes") {
        Write-Warn2 "Apply skipped. Saved plan: $TerraformDir\azure-only.tfplan"
        return
    }

    Write-Step "terraform apply (this can take 30-45 minutes for the ExpressRoute gateway)"
    Invoke-TfApplyWithRetry -PlanFile "azure-only.tfplan" -Label "azure-only apply"
    Write-Ok "Azure-only infrastructure apply complete."

    # --- Summary ---
    $rgOut      = (terraform output -raw resource_group_name 2>$null)
    $serviceKey = (terraform output -raw expressroute_circuit_service_key 2>$null)
    Write-Host "`n========================= AZURE-ONLY DEPLOYMENT DONE =========================" -ForegroundColor Magenta
    Write-Ok "Resource group        : $rgOut"
    Write-Ok "ExpressRoute gateway  : $Gateway"
    Write-Ok "ExpressRoute circuit  : $Circuit (NOT provisioned - needs Megaport)"
    if ($serviceKey) { Write-Ok "Circuit service key   : $serviceKey" }
    Write-Warn2 "No gateway-to-circuit connection was created. To complete the ER data path,"
    Write-Warn2 "run scripts/deploy.ps1 (which drives the Megaport provisioning + connection)."
    Write-Host "==============================================================================" -ForegroundColor Magenta
}
finally {
    # Restore the original workspace so a later deploy.ps1 run is unaffected.
    if ($priorWorkspace -and $priorWorkspace -ne $Workspace) {
        terraform workspace select $priorWorkspace 2>$null | Out-Null
    }
    Pop-Location
}
