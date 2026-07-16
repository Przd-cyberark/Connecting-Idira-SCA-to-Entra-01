#Requires -Version 7.0
<#
.SYNOPSIS
    Removes all Azure resources created by Stream B and optionally deregisters
    the tenant from CyberArk ISP (Stream A).

.DESCRIPTION
    Deletes in the correct reverse order to avoid dependency conflicts:
      1. Role assignments (SCA Entra, SCA Resources, CCE)
      2. Custom role definitions (SCA Entra role, SCA Resources role)
      3. App registrations and their service principals + federated credentials
      4. CyberArk ISP — deregisters the tenant via DELETE /api/azure/tenants/{onboardingId}
         (only runs when -Subdomain, -BearerToken, and -OnboardingId are all provided)

    Safe to run after a successful or failed Stream B execution.
    Step 4 is skipped if any of the three CyberArk parameters are omitted.

    NOTE: The CyberArk delete endpoint used in Step 4 is
          DELETE /api/azure/tenants/{onboardingId}
    This follows the standard CCE API pattern. Verify against your tenant's
    API documentation if the call returns 404.

.PARAMETER EntraId
    The GUID of the Azure AD (Entra) tenant that was onboarded.

.PARAMETER Platform
    The platform name used when running Stream B (e.g. "Idira" or "CyberArk").

.PARAMETER Subdomain
    (Optional) CyberArk ISP tenant subdomain.
    Required together with -ClientId, -ClientSecret, and -OnboardingId to run Step 4.

.PARAMETER ClientId
    (Optional) Client ID of the service account used to authenticate to CyberArk ISP.
    Required together with -Subdomain, -ClientSecret, and -OnboardingId to run Step 4.

.PARAMETER ClientSecret
    (Optional) Client secret corresponding to -ClientId.
    Required together with -Subdomain, -ClientId, and -OnboardingId to run Step 4.

.PARAMETER OnboardingId
    (Optional) The onboarding ID returned by Stream A Phase 2.
    Required together with -Subdomain, -ClientId, and -ClientSecret to run Step 4.

.PARAMETER Force
    Skip the confirmation prompt and delete immediately.

.EXAMPLE
    # Azure cleanup only
    .\Test - Cleanup-AzureResources.ps1 `
        -EntraId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Platform "Idira"

.EXAMPLE
    # Full cleanup — Azure + CyberArk ISP
    .\Test - Cleanup-AzureResources.ps1 `
        -EntraId       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Platform      "Idira" `
        -Subdomain     "acme" `
        -ClientId      "svc-account@acme" `
        -ClientSecret  "s3cr3t" `
        -OnboardingId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    # Full cleanup without confirmation prompt
    .\Test - Cleanup-AzureResources.ps1 `
        -EntraId       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Platform      "Idira" `
        -Subdomain     "acme" `
        -ClientId      "svc-account@acme" `
        -ClientSecret  "s3cr3t" `
        -OnboardingId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Force
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)][string] $EntraId,
    [Parameter(Mandatory)][string] $Platform,
    [string] $Subdomain,
    [string] $ClientId,
    [string] $ClientSecret,
    [string] $OnboardingId,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Done  { param([string]$m); Write-Host "    OK: $m" -ForegroundColor Green }
function Write-Skip  { param([string]$m); Write-Host "    SKIP: $m (not found — already deleted or never created)" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$m); Write-Host "    WARN: $m" -ForegroundColor Yellow }

function Invoke-Az {
    param([string[]]$Arguments)
    $output = az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $output" }
    return $output
}

function Remove-AppIfExists {
    param([string]$AppId, [string]$DisplayName)
    if (-not $AppId) { Write-Skip "$DisplayName (ID not resolved)"; return }
    try {
        Invoke-Az @('ad','app','delete','--id',$AppId) | Out-Null
        Write-Done "Deleted app registration '$DisplayName' ($AppId)"
    } catch {
        Write-Warn "Could not delete '$DisplayName': $_"
    }
}

function Remove-RoleDefinitionIfExists {
    param([string]$RoleName)
    try {
        $role = Invoke-Az @('role','definition','list','--name',$RoleName,'--output','json') | ConvertFrom-Json
        if (-not $role -or $role.Count -eq 0) { Write-Skip "Custom role '$RoleName'"; return }
        Invoke-Az @('role','definition','delete','--name',$RoleName) | Out-Null
        Write-Done "Deleted custom role '$RoleName'"
    } catch {
        Write-Warn "Could not delete role '$RoleName': $_"
    }
}

function Remove-RoleAssignmentIfExists {
    param([string]$AppId, [string]$AppName, [string]$RoleName, [string]$Scope)
    if (-not $AppId) { Write-Skip "Role assignment for '$AppName' (ID not resolved)"; return }
    try {
        $assignments = Invoke-Az @('role','assignment','list','--assignee',$AppId,'--scope',$Scope,'--output','json') | ConvertFrom-Json
        $match = $assignments | Where-Object { $_.roleDefinitionName -eq $RoleName }
        if (-not $match) { Write-Skip "Role assignment '$RoleName' for '$AppName'"; return }
        Invoke-Az @('role','assignment','delete','--assignee',$AppId,'--role',$RoleName,'--scope',$Scope) | Out-Null
        Write-Done "Removed role assignment '$RoleName' from '$AppName'"
    } catch {
        Write-Warn "Could not remove role assignment for '$AppName': $_"
    }
}

# ---------------------------------------------------------------------------
# Derived names (must match Stream B exactly)
# ---------------------------------------------------------------------------

$ScaEntraAppName      = "$Platform-SCA-app-entra"
$ScaResourcesAppName  = "$Platform-SCA-app-resource"
$CceAppName           = "$Platform-CCE-app"
$ScaEntraRoleName     = "$Platform-SCA-entra-role"
$ScaResourcesRoleName = "$Platform-SCA-resources-role"
$RoleScope            = "/providers/Microsoft.Management/managementGroups/$EntraId"

# ---------------------------------------------------------------------------
# Resolve app IDs
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  Cleanup: removing Stream B resources for tenant $EntraId" -ForegroundColor Yellow
Write-Host "  Platform prefix: $Platform" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

Write-Step "Resolving app IDs"

$ScaEntraAppId     = (az ad app list --display-name $ScaEntraAppName     --query '[0].appId' --output tsv 2>$null).Trim()
$ScaResourcesAppId = (az ad app list --display-name $ScaResourcesAppName --query '[0].appId' --output tsv 2>$null).Trim()
$CceAppId          = (az ad app list --display-name $CceAppName          --query '[0].appId' --output tsv 2>$null).Trim()

Write-Host "  SCA Entra App ID    : $(if ($ScaEntraAppId)     { $ScaEntraAppId }     else { '(not found)' })"
Write-Host "  SCA Resources App ID: $(if ($ScaResourcesAppId) { $ScaResourcesAppId } else { '(not found)' })"
Write-Host "  CCE App ID          : $(if ($CceAppId)          { $CceAppId }          else { '(not found)' })"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

$CyberArkCleanup = $Subdomain -and $ClientId -and $ClientSecret -and $OnboardingId

if (-not $Force) {
    Write-Host ""
    Write-Host "  The following will be permanently deleted:" -ForegroundColor Yellow
    Write-Host "    - App registrations: $ScaEntraAppName, $ScaResourcesAppName, $CceAppName"
    Write-Host "    - Custom roles:      $ScaEntraRoleName, $ScaResourcesRoleName"
    Write-Host "    - All associated service principals, federated credentials, and role assignments"
    if ($CyberArkCleanup) {
        Write-Host "    - CyberArk ISP tenant registration (onboarding ID: $OnboardingId)"
    } else {
        Write-Host "    - CyberArk ISP: SKIPPED (no -Subdomain / -ClientId / -ClientSecret / -OnboardingId provided)" -ForegroundColor DarkGray
    }
    Write-Host ""
    $confirm = Read-Host "  Type 'yes' to proceed"
    if ($confirm -ne 'yes') {
        Write-Host "  Aborted." -ForegroundColor DarkGray
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Step 1 — Remove role assignments (before deleting the apps)
# ---------------------------------------------------------------------------

Write-Step "Step 1 — Removing role assignments"

Remove-RoleAssignmentIfExists $ScaEntraAppId     $ScaEntraAppName     $ScaEntraRoleName          $RoleScope
Remove-RoleAssignmentIfExists $ScaResourcesAppId $ScaResourcesAppName $ScaResourcesRoleName      $RoleScope
Remove-RoleAssignmentIfExists $CceAppId          $CceAppName          'Management Group Reader'  $RoleScope

# ---------------------------------------------------------------------------
# Step 2 — Delete custom role definitions
# ---------------------------------------------------------------------------

Write-Step "Step 2 — Deleting custom role definitions"

Remove-RoleDefinitionIfExists $ScaEntraRoleName
Remove-RoleDefinitionIfExists $ScaResourcesRoleName

# ---------------------------------------------------------------------------
# Step 3 — Delete app registrations
# (deleting an app registration also removes its service principal and
#  all federated credentials automatically)
# ---------------------------------------------------------------------------

Write-Step "Step 3 — Deleting app registrations (and their service principals + federated credentials)"

Remove-AppIfExists $ScaEntraAppId     $ScaEntraAppName
Remove-AppIfExists $ScaResourcesAppId $ScaResourcesAppName
Remove-AppIfExists $CceAppId          $CceAppName

# ---------------------------------------------------------------------------
# Step 4 — Deregister tenant from CyberArk ISP (Stream A cleanup)
# ---------------------------------------------------------------------------

Write-Step "Step 4 — Deregistering tenant from CyberArk ISP"

if (-not $CyberArkCleanup) {
    Write-Skip "CyberArk ISP cleanup (-Subdomain, -ClientId, -ClientSecret, and -OnboardingId not all provided)"
} else {
    try {
        $BaseUrl = "https://$Subdomain.cloudonboarding.cyberark.cloud"

        Write-Host "    Obtaining bearer token from CyberArk ISP ..." -ForegroundColor DarkGray
        $tokenResponse = Invoke-RestMethod `
            -Method Post `
            -Uri    "https://$Subdomain.id.cyberark.cloud/oauth2/platformtoken" `
            -Body   @{
                grant_type    = 'client_credentials'
                client_id     = $ClientId
                client_secret = $ClientSecret
            }
        $Headers = @{
            Authorization  = "Bearer $($tokenResponse.access_token)"
            'Content-Type' = 'application/json'
        }
        Write-Host "    Bearer token retrieved" -ForegroundColor DarkGray

        # NOTE: endpoint follows the standard CCE REST pattern for tenant deletion.
        # If this returns 404, verify the exact URL against your tenant's API docs.
        Invoke-RestMethod `
            -Method  Delete `
            -Uri     "$BaseUrl/api/azure/tenants/$OnboardingId" `
            -Headers $Headers | Out-Null

        Write-Done "Tenant '$OnboardingId' deregistered from CyberArk ISP"
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Skip "Tenant '$OnboardingId' not found in CyberArk ISP (already removed or never registered)"
        } else {
            Write-Warn "Could not deregister tenant from CyberArk ISP: $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Cleanup complete." -ForegroundColor Green
if (-not $CyberArkCleanup) {
    Write-Host "  NOTE: CyberArk ISP cleanup was skipped." -ForegroundColor Yellow
    Write-Host "  To also remove the tenant registration, re-run with:" -ForegroundColor Yellow
    Write-Host "    -Subdomain <subdomain> -ClientId <id> -ClientSecret <secret> -OnboardingId <id>" -ForegroundColor Yellow
}
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
