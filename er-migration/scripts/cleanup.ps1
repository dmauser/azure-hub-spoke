<#
.SYNOPSIS
  Full teardown of the ExpressRoute migration lab (Windows / PowerShell).

.DESCRIPTION
  Destroys all Terraform-managed resources for the er-migration lab and handles the
  known orphan ER connection that may exist outside Terraform state.

  Order of operations:
    1. Confirmation + prerequisites check.
    2. Pre-destroy: delete the orphan ER gateway connection via az if it still exists
       (the connection 'az-hub-ergw-to-az-hub-er-circuit' may have been created/recreated
       via 'az' during incident remediation and therefore NOT tracked in Terraform state;
       'terraform destroy' will not remove it).
    3. terraform destroy (removes Azure hub/spokes/ERGW/circuit and, when deploy_gcp=true,
       the GCP VPC/VM/Cloud Router/Partner Interconnect attachment).
    4. Post-destroy verification: confirm the resource group is gone or empty; warn if
       any leftovers remain.
    5. Final reminder: Megaport VXCs must be deleted manually in the Megaport portal —
       Terraform cannot destroy portal-created VXCs.

  Re-runnable: already-deleted resources are tolerated gracefully.

.PARAMETER AzureRegion
  Azure region (default: westus3). Passed to Terraform as var 'location'.

.PARAMETER GcpProject
  GCP project ID. Required when not using -SkipGcp.

.PARAMETER GcpRegion
  GCP region (default: us-east1). Passed to Terraform as var 'gcp_region'.

.PARAMETER SkipGcp
  Skip GCP-side destruction (Azure resources only).

.PARAMETER Force
  Skip the interactive confirmation prompt. Use in automated pipelines.

.NOTES
  DESTRUCTIVE: this script permanently deletes Azure and GCP lab resources.
  Review every prompt before confirming.
#>

[CmdletBinding()]
param(
    [string]$AzureRegion = "westus3",
    [string]$GcpProject,
    [string]$GcpRegion  = "us-east1",
    [switch]$SkipGcp,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Lab constants (must match the Terraform configuration).
$Rg       = "lab-er-migration"
$Circuit  = "az-hub-er-circuit"
$Gateway  = "az-hub-ergw"
$ConnName = "$Gateway-to-$Circuit"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    $msg" -ForegroundColor Red }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Ensure-Tool($tool) {
    if (Test-Cmd $tool) { return }
    Write-Err2 "'$tool' is required but was not found on PATH."
    switch ($tool) {
        "az"        { Write-Warn2 "Windows: winget install --id Microsoft.AzureCLI -e" }
        "terraform" { Write-Warn2 "Windows: winget install --id Hashicorp.Terraform -e" }
        "gcloud"    { Write-Warn2 "Windows: winget install --id Google.CloudSDK -e" }
    }
    throw "'$tool' is required. Install it and re-run this script."
}

# ----------------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TerraformDir = Resolve-Path (Join-Path $ScriptDir "..\terraform")

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║   DESTRUCTIVE — ExpressRoute migration lab teardown / cleanup        ║" -ForegroundColor Red
Write-Host "║   Resource group : $Rg" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host "    Terraform dir : $TerraformDir"

# --- Decide GCP scope ---
if ($SkipGcp) {
    $useGcp = $false
} elseif ($GcpProject) {
    $useGcp = $true
} else {
    $ans    = Read-Host "`nDestroy the GCP side too? (Y/n)"
    $useGcp = ($ans -notmatch '^(n|no)$')
}
Write-Ok ("GCP side: " + ($(if ($useGcp) { "ENABLED (will be destroyed)" } else { "skipped (Azure only)" })))

# --- GCP project (required when GCP in scope) ---
if ($useGcp -and -not $GcpProject) {
    $detected = $null
    try { $detected = (gcloud config get-value project 2>$null) } catch {}
    if ($detected -and $detected -ne "(unset)") { $defProj = $detected } else { $defProj = "" }
    $prompt     = if ($defProj) { "GCP project ID [$defProj]" } else { "GCP project ID (required)" }
    $GcpProject = Read-Host $prompt
    if (-not $GcpProject -and $defProj) { $GcpProject = $defProj }
    if (-not $GcpProject) { throw "A GCP project ID is required to destroy the GCP side." }
}

# --- Confirmation (unless -Force) ---
Write-Step "Confirmation"
if (-not $Force) {
    Write-Host ""
    Write-Host "  This will PERMANENTLY DELETE all resources in resource group '$Rg'" -ForegroundColor Red
    Write-Host "  and run 'terraform destroy' in: $TerraformDir" -ForegroundColor Red
    if ($useGcp) {
        Write-Host "  GCP project '$GcpProject' resources will also be destroyed." -ForegroundColor Red
    }
    Write-Host ""
    $confirm = Read-Host "  Type the resource group name '$Rg' to confirm, or Ctrl+C to abort"
    if ($confirm -ne $Rg) { Write-Warn2 "Confirmation did not match. Aborting."; exit 0 }
    Write-Ok "Confirmed."
} else {
    Write-Warn2 "-Force specified — skipping interactive confirmation."
}

# --- Prerequisites ---
Write-Step "Checking prerequisites"
Ensure-Tool "az"
Ensure-Tool "terraform"
if ($useGcp) { Ensure-Tool "gcloud" }
Write-Ok "All required tools present."

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

# --- VM admin password (terraform destroy still requires the variable) ---
Write-Step "Azure VM admin password (required by Terraform even for destroy)"
Write-Warn2 "Terraform will prompt if omitted. Enter the same password used during deploy."
$plain = $null
if ($env:TF_VAR_admin_password) {
    Write-Ok "TF_VAR_admin_password already set in environment — reusing."
    $plain = $env:TF_VAR_admin_password
} else {
    while (-not $plain) {
        $s1 = Read-Host "admin_password" -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        if ($p1.Length -lt 1) { Write-Warn2 "Password cannot be empty. Try again." }
        else { $plain = $p1 }
    }
}
$env:TF_VAR_admin_password = $plain

# --- gcloud auth (GCP only) ---
if ($useGcp) {
    Remove-Item Env:\GOOGLE_OAUTH_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Write-Step "Verifying gcloud authentication"
    $activeAcct = (gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null)
    if (-not $activeAcct) {
        Write-Warn2 "No active gcloud account. Launching 'gcloud auth login'..."
        gcloud auth login
    } else {
        Write-Ok "gcloud account: $activeAcct"
    }
    $adcOk = $false
    try { gcloud auth application-default print-access-token 1>$null 2>$null; $adcOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $adcOk) {
        Write-Warn2 "No Application Default Credentials. Launching 'gcloud auth application-default login'..."
        gcloud auth application-default login
    } else {
        Write-Ok "ADC present"
    }
    gcloud config set project $GcpProject 1>$null 2>$null
}

# ============================================================================
# Phase 1: Pre-destroy — delete orphan ER connection (may be outside TF state)
# ============================================================================
Write-Step "Phase 1 — Pre-destroy: checking for orphan ER connection '$ConnName'"
Write-Warn2 "This connection may have been created/recreated via 'az' during incident remediation"
Write-Warn2 "and therefore may NOT exist in Terraform state. Deleting it directly via az."

$connState = $null
try { $connState = (az network vpn-connection show -g $Rg -n $ConnName --query provisioningState -o tsv 2>$null) } catch {}

if ($connState) {
    Write-Warn2 "Found connection '$ConnName' (state: $connState). Deleting..."
    az network vpn-connection delete -g $Rg -n $ConnName --yes 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Connection '$ConnName' deleted."
    } else {
        Write-Warn2 "Delete command returned non-zero; connection may already be gone."
    }
} else {
    Write-Ok "Connection '$ConnName' not found (already deleted or never existed). Continuing."
}

# ============================================================================
# Phase 2: terraform destroy
# ============================================================================
Write-Step "Phase 2 — terraform destroy"

$gcpProjLine = if ($useGcp) { $GcpProject } else { "er-migration-lab-unused" }
$gcpRegLine  = if ($useGcp) { $GcpRegion }  else { "us-east1" }
$deployGcp   = if ($useGcp) { "true" }       else { "false" }

Push-Location $TerraformDir
try {
    Write-Step "terraform init (refresh providers)"
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

    Write-Step "terraform destroy (this may take 15-30 minutes)"
    terraform destroy -input=false -auto-approve `
        "-var=location=$AzureRegion" `
        "-var=gcp_project=$gcpProjLine" `
        "-var=gcp_region=$gcpRegLine" `
        "-var=gcp_onprem={deploy_gcp=$deployGcp,network_name=`"gcp-on-prem-vpc`",network_cidr=`"192.168.100.0/24`",subnet_cidr=`"192.168.100.0/24`",vm_private_ip=`"192.168.100.2`",cloud_router_asn=16550}"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "terraform destroy returned non-zero. Proceeding to post-destroy verification."
    } else {
        Write-Ok "terraform destroy completed."
    }
} finally {
    Pop-Location
}

# ============================================================================
# Phase 3: Post-destroy verification
# ============================================================================
Write-Step "Phase 3 — Post-destroy verification"

$rgExists = $null
try { $rgExists = (az group show -n $Rg --query name -o tsv 2>$null) } catch {}

if (-not $rgExists) {
    Write-Ok "Resource group '$Rg' no longer exists. Azure cleanup confirmed."
} else {
    Write-Warn2 "Resource group '$Rg' still exists. Checking for remaining resources..."
    $leftovers = $null
    try { $leftovers = (az resource list -g $Rg --query "[].{name:name,type:type}" -o table 2>$null) } catch {}
    if ($leftovers -and $leftovers -notmatch '^\s*$') {
        Write-Warn2 "Resources still present in '$Rg':"
        Write-Host $leftovers -ForegroundColor Yellow
        Write-Warn2 "You may need to manually delete them or re-run 'terraform destroy'."
        Write-Warn2 "  az group delete -n $Rg --yes --no-wait"
    } else {
        Write-Ok "Resource group '$Rg' is empty. It will be removed shortly by Azure."
    }
}

if ($useGcp) {
    Write-Ok "GCP resources (VPC, VM, Cloud Router, Partner Interconnect attachment) were targeted by terraform destroy."
    Write-Warn2 "Verify in the GCP console: https://console.cloud.google.com/compute/instances?project=$GcpProject"
}

# ============================================================================
# Phase 4: Final reminder — Megaport VXCs require manual deletion
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   ⚠  MANUAL ACTION REQUIRED — Megaport VXCs                         ║" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║                                                                      ║" -ForegroundColor Magenta
Write-Host "║  Terraform CANNOT delete Megaport VXCs (created in the portal).     ║" -ForegroundColor Magenta
Write-Host "║  You MUST delete them manually in the Megaport portal:              ║" -ForegroundColor Magenta
Write-Host "║                                                                      ║" -ForegroundColor Magenta
Write-Host "║    https://portal.megaport.com                                       ║" -ForegroundColor Magenta
Write-Host "║                                                                      ║" -ForegroundColor Magenta
Write-Host "║  Delete both VXCs to stop Megaport charges:                         ║" -ForegroundColor Magenta
Write-Host "║    1. Azure ExpressRoute VXC  (linked to circuit az-hub-er-circuit)  ║" -ForegroundColor Magenta
if ($useGcp) {
    Write-Host "║    2. Google Interconnect VXC (linked to GCP pairing key)            ║" -ForegroundColor Magenta
}
Write-Host "║                                                                      ║" -ForegroundColor Magenta
Write-Host "║  Reference: terraform/docs/megaport-cross-connect.md                ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# Scrub the password from the environment.
Remove-Item Env:\TF_VAR_admin_password -ErrorAction SilentlyContinue
Write-Ok "Cleanup script complete."
