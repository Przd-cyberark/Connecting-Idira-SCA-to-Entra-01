#Requires -Version 5.1
<#
.SYNOPSIS
    Connects ACME's Azure Entra tenant to CyberArk Identity Security Platform (SCA + CCE).

.DESCRIPTION
    Creates all Azure resources required for the CyberArk SCA and CCE onboarding:
      - Two SCA app registrations (Entra and Resources) with Graph permissions,
        custom roles, service principals, federated credentials, role assignments,
        and admin consent grants.
      - One CCE app registration with its federated credential, service principal,
        role assignment, and admin consent grant.

    Mirrors every step in "Stream B - Azure Admin Guide.md".
    Run this script as a user with Global Administrator or Privileged Role Administrator
    rights in the target Entra tenant.

.PARAMETER EntraId
    The GUID of the ACME Azure AD (Entra) tenant.

.PARAMETER Platform
    The platform name prefix used in all resource display names.
    Use "Idira" for tenants created on or after 2026-06-14 (or older tenants with no
    services onboarded yet). Use "CyberArk" for older tenants that already have
    services onboarded.

.PARAMETER ScaIdentityIssuerEntra
    SCA Identity Issuer URL for the Entra app federated credential.
    Obtained from the CyberArk admin via GET /api/azure/identity-params.

.PARAMETER ScaIdentityUserEntra
    SCA Identity User (subject) for the Entra app federated credential.

.PARAMETER ScaIdentityIssuerResources
    SCA Identity Issuer URL for the Resources app federated credential.

.PARAMETER ScaIdentityUserResources
    SCA Identity User (subject) for the Resources app federated credential.

.PARAMETER CceIdentityIssuer
    CCE Identity Issuer URL for the CCE app federated credential.

.PARAMETER CceIdentityUserId
    CCE Identity User ID (subject) for the CCE app federated credential.

.PARAMETER CceIdentityAudience
    CCE Identity Audience for the CCE app federated credential.

.EXAMPLE
    .\"Stream B - Azure Admin - Connect-SCAtoEntra.ps1" `
        -EntraId           "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Platform          "Idira" `
        -ScaIdentityIssuerEntra    "https://..." `
        -ScaIdentityUserEntra      "SCA_ISOLATED_SYSTEM_USER_..." `
        -ScaIdentityIssuerResources "https://..." `
        -ScaIdentityUserResources   "SCA_ISOLATED_SYSTEM_USER_..." `
        -CceIdentityIssuer         "https://..." `
        -CceIdentityUserId         "..." `
        -CceIdentityAudience       "api://AzureADTokenExchange"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)][string] $EntraId,
    [Parameter(Mandatory)][string] $Platform,
    [Parameter(Mandatory)][string] $ScaIdentityIssuerEntra,
    [Parameter(Mandatory)][string] $ScaIdentityUserEntra,
    [Parameter(Mandatory)][string] $ScaIdentityIssuerResources,
    [Parameter(Mandatory)][string] $ScaIdentityUserResources,
    [Parameter(Mandatory)][string] $CceIdentityIssuer,
    [Parameter(Mandatory)][string] $CceIdentityUserId,
    [Parameter(Mandatory)][string] $CceIdentityAudience
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

function Write-Done {
    param([string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

# Invoke az and return parsed JSON, throwing on non-zero exit.
function Invoke-Az {
    param([string[]]$Arguments)
    $result = az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed: $result"
    }
    return $result
}

# Grant a single Microsoft Graph app role to a service principal (admin consent).
function Grant-GraphAppRole {
    param(
        [string] $PrincipalId,
        [string] $GraphResourceId,
        [string] $AppRoleId,
        [string] $PermissionName
    )
    Write-Host "    Granting $PermissionName ..." -ForegroundColor DarkGray
    $body = @{
        principalId = $PrincipalId
        resourceId  = $GraphResourceId
        appRoleId   = $AppRoleId
    } | ConvertTo-Json -Compress

    Invoke-Az @(
        'rest', '--method', 'POST',
        '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments",
        '--body', $body
    ) | Out-Null
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

Write-Step "Verifying Azure CLI login"
$account = Invoke-Az @('account', 'show', '--output', 'json') | ConvertFrom-Json
Write-Done "Signed in as $($account.user.name), subscription: $($account.name)"

# ---------------------------------------------------------------------------
# Common values
# ---------------------------------------------------------------------------

$RoleScope            = "/providers/Microsoft.Management/managementGroups/$EntraId"
$GraphAppId           = "00000003-0000-0000-c000-000000000000"   # Microsoft Graph
$FederatedAudience    = "api://AzureADTokenExchange"

Write-Step "Resolving Microsoft Graph service principal ID"
$GraphResourceId = (Invoke-Az @(
    'ad', 'sp', 'list',
    '--filter', "appId eq '$GraphAppId'",
    '--query', '[].id',
    '--output', 'tsv'
)).Trim()
Write-Done "Graph resource ID: $GraphResourceId"

# ---------------------------------------------------------------------------
# PART 1 — SCA (Security Cloud Access)
# ---------------------------------------------------------------------------

$ScaEntraAppName      = "$Platform-SCA-app-entra"
$ScaResourcesAppName  = "$Platform-SCA-app-resource"
$ScaEntraRoleName     = "$Platform-SCA-entra-role"
$ScaResourcesRoleName = "$Platform-SCA-resources-role"

# -- Step 1.2 / 1.3  Custom role definitions ---------------------------------

Write-Step "Creating custom role: $ScaEntraRoleName (no Actions)"
$ScaEntraRoleDef = @{
    Name             = $ScaEntraRoleName
    IsCustom         = $true
    Actions          = @()
    AssignableScopes = @($RoleScope)
} | ConvertTo-Json -Depth 5 -Compress

$ScaEntraRoleResult = Invoke-Az @(
    'role', 'definition', 'create',
    '--role-definition', $ScaEntraRoleDef,
    '--output', 'json'
) | ConvertFrom-Json
Write-Done "Created role: $($ScaEntraRoleResult.roleName)"

Write-Step "Creating custom role: $ScaResourcesRoleName"
$ScaResourcesRoleDef = @{
    Name             = $ScaResourcesRoleName
    IsCustom         = $true
    Actions          = @(
        'Microsoft.Authorization/roleAssignments/read',
        'Microsoft.Authorization/roleAssignments/write',
        'Microsoft.Authorization/roleAssignments/delete',
        'Microsoft.Authorization/roleDefinitions/read',
        'Microsoft.ResourceGraph/resources/read',
        'Microsoft.Management/managementGroups/read'
    )
    AssignableScopes = @($RoleScope)
} | ConvertTo-Json -Depth 5 -Compress

$ScaResourcesRoleResult = Invoke-Az @(
    'role', 'definition', 'create',
    '--role-definition', $ScaResourcesRoleDef,
    '--output', 'json'
) | ConvertFrom-Json
Write-Done "Created role: $($ScaResourcesRoleResult.roleName)"

# -- Step 1.4  App registrations ---------------------------------------------

Write-Step "Creating app registration: $ScaEntraAppName"
$ScaEntraPermissions = @(
    @{
        resourceAppId  = $GraphAppId
        resourceAccess = @(
            @{ id = '9e3f62cf-723e-4eba-9247-35def7408f82'; type = 'Role' }   # RoleManagement.Read.Directory
            @{ id = '62a82d76-70ea-4829-96f2-1b1e37f5aa90'; type = 'Role' }   # Group.ReadWrite.All
            @{ id = '97235f07-e226-4f63-ace3-39588e11d3a1'; type = 'Role' }   # User.ReadBasic.All
        )
    }
) | ConvertTo-Json -Depth 5 -Compress

$ScaEntraAppId = (Invoke-Az @(
    'ad', 'app', 'create',
    '--display-name', $ScaEntraAppName,
    '--required-resource-accesses', $ScaEntraPermissions,
    '--query', 'appId',
    '--output', 'tsv'
)).Trim()
Write-Done "SCA Entra App ID: $ScaEntraAppId"

Write-Step "Creating app registration: $ScaResourcesAppName"
$ScaResourcesPermissions = @(
    @{
        resourceAppId  = $GraphAppId
        resourceAccess = @(
            @{ id = '62a82d76-70ea-4829-96f2-1b1e37f5aa90'; type = 'Role' }   # Group.ReadWrite.All
            @{ id = '97235f07-e226-4f63-ace3-39588e11d3a1'; type = 'Role' }   # User.ReadBasic.All
            @{ id = 'dbaae8cf-10b5-4b86-a4a1-f871c94c6695'; type = 'Role' }   # GroupMember.ReadWrite.All
            @{ id = 'bf7b1a76-6e77-406b-b258-bf5c7720e98f'; type = 'Role' }   # Group.Create
        )
    }
) | ConvertTo-Json -Depth 5 -Compress

$ScaResourcesAppId = (Invoke-Az @(
    'ad', 'app', 'create',
    '--display-name', $ScaResourcesAppName,
    '--required-resource-accesses', $ScaResourcesPermissions,
    '--query', 'appId',
    '--output', 'tsv'
)).Trim()
Write-Done "SCA Resources App ID: $ScaResourcesAppId"

# -- Step 1.5  Service principals --------------------------------------------

Write-Step "Creating service principal for SCA Entra app"
$ScaEntraPrincipalId = (Invoke-Az @(
    'ad', 'sp', 'create',
    '--id', $ScaEntraAppId,
    '--query', 'id',
    '--output', 'tsv'
)).Trim()
Write-Done "SCA Entra SP object ID: $ScaEntraPrincipalId"

Write-Step "Creating service principal for SCA Resources app"
$ScaResourcesPrincipalId = (Invoke-Az @(
    'ad', 'sp', 'create',
    '--id', $ScaResourcesAppId,
    '--query', 'id',
    '--output', 'tsv'
)).Trim()
Write-Done "SCA Resources SP object ID: $ScaResourcesPrincipalId"

# -- Step 1.6  Federated credentials -----------------------------------------

Write-Step "Creating federated credential on SCA Entra app"
$ScaEntraCred = @{
    name      = 'sca-entra-federated-credential'
    issuer    = $ScaIdentityIssuerEntra
    subject   = $ScaIdentityUserEntra
    audiences = @($FederatedAudience)
} | ConvertTo-Json -Compress

Invoke-Az @(
    'ad', 'app', 'federated-credential', 'create',
    '--id', $ScaEntraAppId,
    '--parameters', $ScaEntraCred
) | Out-Null
Write-Done "Federated credential created on $ScaEntraAppName"

Write-Step "Creating federated credential on SCA Resources app"
$ScaResourcesCred = @{
    name      = 'sca-resources-federated-credential'
    issuer    = $ScaIdentityIssuerResources
    subject   = $ScaIdentityUserResources
    audiences = @($FederatedAudience)
} | ConvertTo-Json -Compress

Invoke-Az @(
    'ad', 'app', 'federated-credential', 'create',
    '--id', $ScaResourcesAppId,
    '--parameters', $ScaResourcesCred
) | Out-Null
Write-Done "Federated credential created on $ScaResourcesAppName"

# -- Step 1.7  Role assignments ----------------------------------------------

Write-Step "Assigning $ScaEntraRoleName to SCA Entra app"
Invoke-Az @(
    'role', 'assignment', 'create',
    '--assignee', $ScaEntraAppId,
    '--role', $ScaEntraRoleName,
    '--scope', $RoleScope
) | Out-Null
Write-Done "Role assigned"

Write-Step "Assigning $ScaResourcesRoleName to SCA Resources app"
Invoke-Az @(
    'role', 'assignment', 'create',
    '--assignee', $ScaResourcesAppId,
    '--role', $ScaResourcesRoleName,
    '--scope', $RoleScope
) | Out-Null
Write-Done "Role assigned"

# -- Step 1.8  Admin consent -------------------------------------------------

Write-Step "Granting admin consent for SCA Entra app (3 permissions)"
Grant-GraphAppRole $ScaEntraPrincipalId $GraphResourceId '9e3f62cf-723e-4eba-9247-35def7408f82' 'RoleManagement.Read.Directory'
Grant-GraphAppRole $ScaEntraPrincipalId $GraphResourceId '62a82d76-70ea-4829-96f2-1b1e37f5aa90' 'Group.ReadWrite.All'
Grant-GraphAppRole $ScaEntraPrincipalId $GraphResourceId '97235f07-e226-4f63-ace3-39588e11d3a1' 'User.ReadBasic.All'
Write-Done "Admin consent granted for $ScaEntraAppName"

Write-Step "Granting admin consent for SCA Resources app (4 permissions)"
Grant-GraphAppRole $ScaResourcesPrincipalId $GraphResourceId '62a82d76-70ea-4829-96f2-1b1e37f5aa90' 'Group.ReadWrite.All'
Grant-GraphAppRole $ScaResourcesPrincipalId $GraphResourceId '97235f07-e226-4f63-ace3-39588e11d3a1' 'User.ReadBasic.All'
Grant-GraphAppRole $ScaResourcesPrincipalId $GraphResourceId 'dbaae8cf-10b5-4b86-a4a1-f871c94c6695' 'GroupMember.ReadWrite.All'
Grant-GraphAppRole $ScaResourcesPrincipalId $GraphResourceId 'bf7b1a76-6e77-406b-b258-bf5c7720e98f' 'Group.Create'
Write-Done "Admin consent granted for $ScaResourcesAppName"

# ---------------------------------------------------------------------------
# PART 2 — CCE App
# ---------------------------------------------------------------------------

$CceAppName = "$Platform-CCE-app"

# -- Step 2.1  App registration ----------------------------------------------

Write-Step "Creating app registration: $CceAppName"
$CcePermissions = '[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"cac88765-0581-4025-9725-5ebc13f729ee","type":"Role"}]}]'

$CceAppId = (Invoke-Az @(
    'ad', 'app', 'create',
    '--display-name', $CceAppName,
    '--required-resource-accesses', $CcePermissions,
    '--query', 'appId',
    '--output', 'tsv'
)).Trim()
Write-Done "CCE App ID: $CceAppId"

# -- Step 2.2 / 2.3  Identity parameters are passed as script parameters; create federated credential --

Write-Step "Creating federated credential on CCE app"
$CceCred = @{
    name      = 'cce-federated-credential'
    issuer    = $CceIdentityIssuer
    subject   = $CceIdentityUserId
    audiences = @($CceIdentityAudience)
} | ConvertTo-Json -Compress

Invoke-Az @(
    'ad', 'app', 'federated-credential', 'create',
    '--id', $CceAppId,
    '--parameters', $CceCred
) | Out-Null
Write-Done "Federated credential created on $CceAppName"

# -- Step 2.4  Service principal ---------------------------------------------

Write-Step "Creating service principal for CCE app"
$CcePrincipalId = (Invoke-Az @(
    'ad', 'sp', 'create',
    '--id', $CceAppId,
    '--query', 'id',
    '--output', 'tsv'
)).Trim()
Write-Done "CCE SP object ID: $CcePrincipalId"

# -- Step 2.5  Role assignment -----------------------------------------------

Write-Step "Assigning 'Management Group Reader' role to CCE app"
Invoke-Az @(
    'role', 'assignment', 'create',
    '--assignee', $CceAppId,
    '--role', 'Management Group Reader',
    '--scope', $RoleScope
) | Out-Null
Write-Done "Role assigned"

# -- Step 2.6  Admin consent -------------------------------------------------

Write-Step "Granting admin consent for CCE app (1 permission)"
Grant-GraphAppRole $CcePrincipalId $GraphResourceId 'cac88765-0581-4025-9725-5ebc13f729ee' 'CrossTenantInformation.ReadBasic.All'
Write-Done "Admin consent granted for $CceAppName"

# ---------------------------------------------------------------------------
# PART 3 — Summary for CyberArk admin
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  All Azure resources created successfully." -ForegroundColor Yellow
Write-Host "  Provide the following App IDs to the CyberArk admin:" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  CCE App ID           : $CceAppId"
Write-Host "  SCA Entra App ID     : $ScaEntraAppId"
Write-Host "  SCA Resources App ID : $ScaResourcesAppId"
Write-Host ""
