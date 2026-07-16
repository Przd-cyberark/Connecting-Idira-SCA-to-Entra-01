#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies that all Azure resources created by Stream B exist and are correctly configured.

.DESCRIPTION
    Runs all 14 checks from the live testing plan against the resources that
    "Stream B - Azure Admin - Connect-SCAtoEntra.ps1" should have created.
    Prints a pass/fail table at the end.

.PARAMETER EntraId
    The GUID of the Azure AD (Entra) tenant that was onboarded.

.PARAMETER Platform
    The platform name used when running Stream B (e.g. "Idira" or "CyberArk").

.EXAMPLE
    .\Test - Verify-AzureResources.ps1 `
        -EntraId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Platform "Idira"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)][string] $EntraId,
    [Parameter(Mandatory)][string] $Platform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-Check {
    param(
        [int]    $Number,
        [string] $Description,
        [scriptblock] $Check
    )
    Write-Host "  [$Number] $Description ..." -NoNewline
    try {
        $detail = & $Check
        $results.Add([PSCustomObject]@{ Number = $Number; Description = $Description; Result = 'PASS'; Detail = $detail })
        Write-Host " PASS" -ForegroundColor Green
    } catch {
        $results.Add([PSCustomObject]@{ Number = $Number; Description = $Description; Result = 'FAIL'; Detail = $_.Exception.Message })
        Write-Host " FAIL" -ForegroundColor Red
    }
}

function Invoke-Az {
    param([string[]]$Arguments)
    $output = az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $output" }
    return $output
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
$GraphAppId           = "00000003-0000-0000-c000-000000000000"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Verifying Azure resources for tenant: $EntraId" -ForegroundColor Cyan
Write-Host "  Platform prefix: $Platform" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Resolve app IDs — needed for subsequent checks
# ---------------------------------------------------------------------------

Write-Host "  Resolving app IDs..." -ForegroundColor DarkGray

$ScaEntraAppId     = (Invoke-Az @('ad','app','list','--display-name',$ScaEntraAppName,'--query','[0].appId','--output','tsv')).Trim()
$ScaResourcesAppId = (Invoke-Az @('ad','app','list','--display-name',$ScaResourcesAppName,'--query','[0].appId','--output','tsv')).Trim()
$CceAppId          = (Invoke-Az @('ad','app','list','--display-name',$CceAppName,'--query','[0].appId','--output','tsv')).Trim()

Write-Host "  SCA Entra App ID    : $ScaEntraAppId"
Write-Host "  SCA Resources App ID: $ScaResourcesAppId"
Write-Host "  CCE App ID          : $CceAppId"
Write-Host ""

# ---------------------------------------------------------------------------
# Checks 1–3: App registrations exist
# ---------------------------------------------------------------------------

Test-Check 1 "App registration '$ScaEntraAppName' exists" {
    if (-not $ScaEntraAppId) { throw "Not found" }
    "appId: $ScaEntraAppId"
}

Test-Check 2 "App registration '$ScaResourcesAppName' exists" {
    if (-not $ScaResourcesAppId) { throw "Not found" }
    "appId: $ScaResourcesAppId"
}

Test-Check 3 "App registration '$CceAppName' exists" {
    if (-not $CceAppId) { throw "Not found" }
    "appId: $CceAppId"
}

# ---------------------------------------------------------------------------
# Checks 4–5: Custom role definitions
# ---------------------------------------------------------------------------

Test-Check 4 "Custom role '$ScaEntraRoleName' exists with 0 Actions" {
    $role = Invoke-Az @('role','definition','list','--name',$ScaEntraRoleName,'--output','json') | ConvertFrom-Json
    if (-not $role) { throw "Role not found" }
    $actionCount = $role[0].permissions[0].actions.Count
    if ($actionCount -ne 0) { throw "Expected 0 Actions, found $actionCount" }
    "0 Actions confirmed"
}

Test-Check 5 "Custom role '$ScaResourcesRoleName' exists with 6 Actions" {
    $role = Invoke-Az @('role','definition','list','--name',$ScaResourcesRoleName,'--output','json') | ConvertFrom-Json
    if (-not $role) { throw "Role not found" }
    $actionCount = $role[0].permissions[0].actions.Count
    if ($actionCount -ne 6) { throw "Expected 6 Actions, found $actionCount" }
    "6 Actions confirmed"
}

# ---------------------------------------------------------------------------
# Checks 6–8: Federated credentials exist
# ---------------------------------------------------------------------------

Test-Check 6 "SCA Entra app has federated credential 'sca-entra-federated-credential'" {
    if (-not $ScaEntraAppId) { throw "App ID not resolved" }
    $creds = Invoke-Az @('ad','app','federated-credential','list','--id',$ScaEntraAppId,'--output','json') | ConvertFrom-Json
    $cred = $creds | Where-Object { $_.name -eq 'sca-entra-federated-credential' }
    if (-not $cred) { throw "Federated credential not found" }
    "issuer: $($cred.issuer)"
}

Test-Check 7 "SCA Resources app has federated credential 'sca-resources-federated-credential'" {
    if (-not $ScaResourcesAppId) { throw "App ID not resolved" }
    $creds = Invoke-Az @('ad','app','federated-credential','list','--id',$ScaResourcesAppId,'--output','json') | ConvertFrom-Json
    $cred = $creds | Where-Object { $_.name -eq 'sca-resources-federated-credential' }
    if (-not $cred) { throw "Federated credential not found" }
    "issuer: $($cred.issuer)"
}

Test-Check 8 "CCE app has federated credential 'cce-federated-credential'" {
    if (-not $CceAppId) { throw "App ID not resolved" }
    $creds = Invoke-Az @('ad','app','federated-credential','list','--id',$CceAppId,'--output','json') | ConvertFrom-Json
    $cred = $creds | Where-Object { $_.name -eq 'cce-federated-credential' }
    if (-not $cred) { throw "Federated credential not found" }
    "issuer: $($cred.issuer)"
}

# ---------------------------------------------------------------------------
# Checks 9–11: Role assignments at management group scope
# ---------------------------------------------------------------------------

Test-Check 9 "SCA Entra app has role assignment '$ScaEntraRoleName' at management group scope" {
    if (-not $ScaEntraAppId) { throw "App ID not resolved" }
    $assignments = Invoke-Az @('role','assignment','list','--assignee',$ScaEntraAppId,'--scope',$RoleScope,'--output','json') | ConvertFrom-Json
    $match = $assignments | Where-Object { $_.roleDefinitionName -eq $ScaEntraRoleName }
    if (-not $match) { throw "Role assignment not found" }
    "scope: $($match.scope)"
}

Test-Check 10 "SCA Resources app has role assignment '$ScaResourcesRoleName' at management group scope" {
    if (-not $ScaResourcesAppId) { throw "App ID not resolved" }
    $assignments = Invoke-Az @('role','assignment','list','--assignee',$ScaResourcesAppId,'--scope',$RoleScope,'--output','json') | ConvertFrom-Json
    $match = $assignments | Where-Object { $_.roleDefinitionName -eq $ScaResourcesRoleName }
    if (-not $match) { throw "Role assignment not found" }
    "scope: $($match.scope)"
}

Test-Check 11 "CCE app has 'Management Group Reader' assignment at management group scope" {
    if (-not $CceAppId) { throw "App ID not resolved" }
    $assignments = Invoke-Az @('role','assignment','list','--assignee',$CceAppId,'--scope',$RoleScope,'--output','json') | ConvertFrom-Json
    $match = $assignments | Where-Object { $_.roleDefinitionName -eq 'Management Group Reader' }
    if (-not $match) { throw "Role assignment not found" }
    "scope: $($match.scope)"
}

# ---------------------------------------------------------------------------
# Checks 12–14: Admin consent (Graph app role assignments)
# ---------------------------------------------------------------------------

$ScaEntraSPId     = (Invoke-Az @('ad','sp','show','--id',$ScaEntraAppId,'--query','id','--output','tsv')).Trim()
$ScaResourcesSPId = (Invoke-Az @('ad','sp','show','--id',$ScaResourcesAppId,'--query','id','--output','tsv')).Trim()
$CceSPId          = (Invoke-Az @('ad','sp','show','--id',$CceAppId,'--query','id','--output','tsv')).Trim()

$ScaEntraExpectedRoles = @(
    '9e3f62cf-723e-4eba-9247-35def7408f82'   # RoleManagement.Read.Directory
    '62a82d76-70ea-4829-96f2-1b1e37f5aa90'   # Group.ReadWrite.All
    '97235f07-e226-4f63-ace3-39588e11d3a1'   # User.ReadBasic.All
)

$ScaResourcesExpectedRoles = @(
    '62a82d76-70ea-4829-96f2-1b1e37f5aa90'   # Group.ReadWrite.All
    '97235f07-e226-4f63-ace3-39588e11d3a1'   # User.ReadBasic.All
    'dbaae8cf-10b5-4b86-a4a1-f871c94c6695'   # GroupMember.ReadWrite.All
    'bf7b1a76-6e77-406b-b258-bf5c7720e98f'   # Group.Create
)

$CceExpectedRoles = @(
    'cac88765-0581-4025-9725-5ebc13f729ee'   # CrossTenantInformation.ReadBasic.All
)

function Test-AdminConsent {
    param([string]$PrincipalId, [string[]]$ExpectedRoleIds)
    $grants = Invoke-Az @(
        'rest','--method','GET',
        '--url',"https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments",
        '--output','json'
    ) | ConvertFrom-Json
    $grantedIds = $grants.value | ForEach-Object { $_.appRoleId }
    $missing = $ExpectedRoleIds | Where-Object { $_ -notin $grantedIds }
    if ($missing) { throw "Missing consent for role IDs: $($missing -join ', ')" }
    "$($ExpectedRoleIds.Count) of $($ExpectedRoleIds.Count) permissions granted"
}

Test-Check 12 "SCA Entra app has admin consent for 3 Graph permissions" {
    if (-not $ScaEntraSPId) { throw "Service principal not resolved" }
    Test-AdminConsent $ScaEntraSPId $ScaEntraExpectedRoles
}

Test-Check 13 "SCA Resources app has admin consent for 4 Graph permissions" {
    if (-not $ScaResourcesSPId) { throw "Service principal not resolved" }
    Test-AdminConsent $ScaResourcesSPId $ScaResourcesExpectedRoles
}

Test-Check 14 "CCE app has admin consent for 1 Graph permission" {
    if (-not $CceSPId) { throw "Service principal not resolved" }
    Test-AdminConsent $CceSPId $CceExpectedRoles
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$passed = ($results | Where-Object { $_.Result -eq 'PASS' }).Count
$failed = ($results | Where-Object { $_.Result -eq 'FAIL' }).Count

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ("  Results: {0} passed, {1} failed out of {2} checks" -f $passed, $failed, $results.Count) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($r in $results) {
    $color = if ($r.Result -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("  [{0,2}] {1,-65} {2}" -f $r.Number, $r.Description, $r.Result) -ForegroundColor $color
    if ($r.Result -eq 'FAIL') {
        Write-Host ("        {0}" -f $r.Detail) -ForegroundColor DarkRed
    }
}

Write-Host ""

if ($failed -gt 0) { exit 1 }
