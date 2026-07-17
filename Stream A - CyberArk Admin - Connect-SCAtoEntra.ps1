#Requires -Version 5.1
<#
.SYNOPSIS
    CyberArk admin script for connecting ACME's Azure Entra tenant to the
    CyberArk Identity Security Platform (SCA onboarding).

.DESCRIPTION
    Covers both CyberArk admin phases from "Stream A - CyberArk Admin Guide.md":

    Phase 1 (run BEFORE the Azure admin starts):
      Calls GET /api/azure/identity-params and prints all identity values the
      Azure admin needs to configure Azure app registrations.

    Phase 2 (run AFTER the Azure admin has finished):
      Calls POST /api/azure/manual to register the Entra tenant in CCE and
      prints the returned onboarding ID.

    Run Phase 1 first, hand the output to the Azure admin, wait for them to
    complete their work and return the three app IDs, then run Phase 2.

.PARAMETER Subdomain
    Your CyberArk tenant subdomain.
    The API base URL will be https://<Subdomain>.cloudonboarding.cyberark.cloud

.PARAMETER IdentityTenantId
    The internal identity tenant ID used to construct the token URL:
    https://<IdentityTenantId>.id.cyberark.cloud/oauth2/platformtoken
    This is NOT the same as the portal subdomain. Find it by logging into
    the CyberArk ISP portal and checking Settings > General, or by
    inspecting the login page source for the ShellUrl/tenant hostname.
    Example: if the token URL is https://acm4048.id.cyberark.cloud/... then
    the IdentityTenantId is "acm4048".

.PARAMETER ClientId
    Client ID of the service account used to authenticate to the CyberArk
    Identity Security Platform. Used to obtain a bearer token automatically
    via the /oauth2/platformtoken endpoint.

.PARAMETER ClientSecret
    Client secret corresponding to -ClientId.

.PARAMETER Phase
    Which phase to execute:
      1  - Retrieve and display identity parameters for the Azure admin.
      2  - Register the Entra tenant in CCE (requires Azure admin app IDs).

.PARAMETER EntraId
    (Phase 2) The GUID of the ACME Azure AD (Entra) tenant.

.PARAMETER ScaEntraAppId
    (Phase 2) Application (client) ID of the SCA Entra app created by the Azure admin.

.PARAMETER ScaResourcesAppId
    (Phase 2) Application (client) ID of the SCA Resources app created by the Azure admin.

.PARAMETER ScaIdentityTrustedUserEntra
    (Phase 2) The SCA identity trusted username for the Entra app.
    This is the "SCA Identity User (Entra)" value returned by Phase 1.

.PARAMETER ScaIdentityTrustedUserResources
    (Phase 2) The SCA identity trusted username for the Resources app.
    This is the "SCA Identity User (Resources)" value returned by Phase 1.

.PARAMETER CceAppId
    (Phase 2) Application (client) ID of the CCE app created by the Azure admin.

.EXAMPLE
    # Phase 1 — retrieve identity parameters
    .\Stream A - CyberArk Admin - Connect-SCAtoEntra.ps1 `
        -Phase              1 `
        -Subdomain          "acme" `
        -IdentityTenantId   "acm4048" `
        -ClientId           "svc-account@acme" `
        -ClientSecret       "s3cr3t"

.EXAMPLE
    # Phase 2 — register the tenant
    .\Stream A - CyberArk Admin - Connect-SCAtoEntra.ps1 `
        -Phase                           2 `
        -Subdomain                       "acme" `
        -IdentityTenantId                "acm4048" `
        -ClientId                        "svc-account@acme" `
        -ClientSecret                    "s3cr3t" `
        -EntraId                         "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ScaEntraAppId                   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ScaResourcesAppId               "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ScaIdentityTrustedUserEntra     "SCA_ISOLATED_SYSTEM_USER_FOR_AZURE_..._ENTRA" `
        -ScaIdentityTrustedUserResources "SCA_ISOLATED_SYSTEM_USER_FOR_AZURE_..._RESOURCE" `
        -CceAppId                        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)][ValidateSet(1, 2)][int] $Phase,
    [Parameter(Mandatory)][string] $Subdomain,
    [Parameter(Mandatory)][string] $IdentityTenantId,
    [Parameter(Mandatory)][string] $ClientId,
    [Parameter(Mandatory)][string] $ClientSecret,

    # Phase 2 parameters
    [string] $EntraId,
    [string] $ScaEntraAppId,
    [string] $ScaResourcesAppId,
    [string] $ScaIdentityTrustedUserEntra,
    [string] $ScaIdentityTrustedUserResources,
    [string] $CceAppId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pre-flight: warn if ClientSecret contains shell metacharacters that bash
# will corrupt when passing arguments via -File or -Command.
# These characters are safe inside PowerShell but become redirection/pipe
# operators when the shell interprets the argument before PowerShell sees it.
# ---------------------------------------------------------------------------
$dangerousChars = @('<', '>', '|', '&', '^', '`')
$found = $dangerousChars | Where-Object { $ClientSecret.Contains($_) }
if ($found) {
    Write-Host ""
    Write-Host "  ERROR: -ClientSecret contains shell metacharacter(s): $($found -join ' ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  These characters are stripped or misinterpreted by the shell before" -ForegroundColor Yellow
    Write-Host "  PowerShell receives the value, causing authentication failures." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Solutions:" -ForegroundColor Yellow
    Write-Host "    1. Change the service account password in CyberArk ISP to one that" -ForegroundColor Yellow
    Write-Host "       contains only alphanumeric characters and safe symbols (- _ . @)." -ForegroundColor Yellow
    Write-Host "    2. Or run this script directly from a PowerShell window (not bash)" -ForegroundColor Yellow
    Write-Host "       using single-quoted string: -ClientSecret 'your+secret&here'" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

$BaseUrl = "https://$Subdomain.cloudonboarding.cyberark.cloud"
$Headers = $null

function Get-CyberArkToken {
    $tokenResponse = Invoke-RestMethod `
        -Method      Post `
        -Uri         "https://$IdentityTenantId.id.cyberark.cloud/oauth2/platformtoken" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body        "grant_type=client_credentials&client_id=$([uri]::EscapeDataString($ClientId))&client_secret=$([uri]::EscapeDataString($ClientSecret))"
    return $tokenResponse.access_token
}

function New-AuthHeaders {
    $token = Get-CyberArkToken
    return @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json'
    }
}

# ---------------------------------------------------------------------------
# PHASE 1 — Retrieve identity parameters for the Azure admin
# ---------------------------------------------------------------------------

if ($Phase -eq 1) {

    Write-Step "Step 2.1 — Obtaining bearer token from CyberArk ISP"
    $Headers = New-AuthHeaders
    Write-Done "Bearer token retrieved"

    Write-Step "Step 2.2 — Calling GET /api/azure/identity-params"

    $Response = Invoke-RestMethod `
        -Method  Get `
        -Uri     "$BaseUrl/api/azure/identity-params" `
        -Headers $Headers

    Write-Done "Identity parameters retrieved."

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  Pass ALL of the following values to the Azure admin." -ForegroundColor Yellow
    Write-Host "  They are needed BEFORE the Azure admin can start their work." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""

    # Print every property returned so nothing is missed regardless of
    # exact field naming in the API response.
    $Response.PSObject.Properties | ForEach-Object {
        Write-Host ("  {0,-45}: {1}" -f $_.Name, $_.Value)
    }

    Write-Host ""
    Write-Host "  Key values needed by the Azure admin:" -ForegroundColor Yellow
    Write-Host ""

    # Attempt to surface the specific fields the Azure admin needs.
    # Field names are shown as-received; adjust the property paths if your
    # tenant's API response uses different casing or nesting.
    $fields = @(
        @{ Label = "SCA Identity Issuer (Entra)    "; Path = "scaIdentityIssuerEntra" },
        @{ Label = "SCA Identity User (Entra)      "; Path = "scaIdentityUserEntra" },
        @{ Label = "SCA Identity Issuer (Resources)"; Path = "scaIdentityIssuerResources" },
        @{ Label = "SCA Identity User (Resources)  "; Path = "scaIdentityUserResources" },
        @{ Label = "CCE Identity Issuer            "; Path = "cceIdentityIssuer" },
        @{ Label = "CCE Identity User ID           "; Path = "cceIdentityUserId" },
        @{ Label = "CCE Identity Audience          "; Path = "cceIdentityAudience" }
    )

    foreach ($field in $fields) {
        $value = $Response.($field.Path)
        if ($value) {
            Write-Host ("  {0}: {1}" -f $field.Label, $value)
        }
    }

    Write-Host ""
    Write-Host "  Next step: share these values with the Azure admin and wait" -ForegroundColor DarkGray
    Write-Host "  for them to return the three app IDs (CCE, SCA Entra, SCA Resources)." -ForegroundColor DarkGray
    Write-Host "  Then re-run this script with -Phase 2." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# PHASE 2 — Register the Entra tenant in CCE
# ---------------------------------------------------------------------------

# Validate that all Phase 2 parameters were supplied.
$missing = @()
if (-not $EntraId)                        { $missing += '-EntraId' }
if (-not $ScaEntraAppId)                  { $missing += '-ScaEntraAppId' }
if (-not $ScaResourcesAppId)              { $missing += '-ScaResourcesAppId' }
if (-not $ScaIdentityTrustedUserEntra)    { $missing += '-ScaIdentityTrustedUserEntra' }
if (-not $ScaIdentityTrustedUserResources){ $missing += '-ScaIdentityTrustedUserResources' }
if (-not $CceAppId)                       { $missing += '-CceAppId' }

if ($missing.Count -gt 0) {
    Write-Error "Phase 2 requires the following parameters that are missing: $($missing -join ', ')"
}

# -- Step 3.2 — POST /api/azure/manual ---------------------------------------

Write-Step "Step 3.1 — Obtaining bearer token from CyberArk ISP"
$Headers = New-AuthHeaders
Write-Done "Bearer token retrieved"

Write-Step "Step 3.2 — Calling POST /api/azure/manual to register the Entra tenant"

$Body = @{
    deploymentType = "organization"
    entraId        = $EntraId
    services       = @(
        @{
            serviceName = "sca"
            resources   = @{
                applications = @(
                    @{
                        application_id           = $ScaEntraAppId
                        identity_trusted_username = $ScaIdentityTrustedUserEntra
                    },
                    @{
                        application_id           = $ScaResourcesAppId
                        identity_trusted_username = $ScaIdentityTrustedUserResources
                    }
                )
            }
        }
    )
    cceResources   = @{
        appId = $CceAppId
    }
} | ConvertTo-Json -Depth 10

$Response = Invoke-RestMethod `
    -Method  Post `
    -Uri     "$BaseUrl/api/azure/manual" `
    -Headers $Headers `
    -Body    $Body

Write-Done "Tenant registered successfully."

# -- Step 3.3 — Save the onboarding ID --------------------------------------

if ($Response.id)             { $OnboardingId = $Response.id }
elseif ($Response.onboardingId) { $OnboardingId = $Response.onboardingId }
else                            { $OnboardingId = $Response.PSObject.Properties.Value[0] }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  Onboarding complete. Save the onboarding ID below." -ForegroundColor Yellow
Write-Host "  It is required for all future API calls for this tenant." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Onboarding ID: $OnboardingId"
Write-Host ""
Write-Host "  Full API response:" -ForegroundColor DarkGray
$Response | ConvertTo-Json -Depth 10 | Write-Host
Write-Host ""
