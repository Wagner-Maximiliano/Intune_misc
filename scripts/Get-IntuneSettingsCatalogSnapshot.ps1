#requires -Version 5.1

<#
Get-IntuneSettingsCatalogSnapshot.ps1

Phase 1 (read-only): pulls every Settings Catalog policy - its settings and
its assignments - and writes one JSON snapshot per policy to
<OutputPath>\json. No Excel, no versioning; see Backup-IntunePolicies.ps1 for
that.

This script depends on ONE file in this repository: modules/Continuum.Core,
which must stay a sibling of scripts/. It holds the helpers this file used to
carry its own copy of (Issue #15, docs/DECISIONS.md D-018). Copying this .ps1
somewhere on its own no longer works - take the repository, or at least
scripts/ and modules/ together. It is imported automatically; there is still
nothing to dot-source.

MODULES REQUIRED - this script does NOT import them for you. Import this
yourself first, once per PowerShell session, before running the script:

    Import-Module Microsoft.Graph.Authentication

CONNECTION - this script does NOT force a new Graph connection. It checks
Get-MgContext first: if you're already connected (e.g. you ran Connect-MgGraph
yourself with a specific app registration/ClientId), it uses that connection
as-is and never calls Connect-MgGraph. It only connects itself when there is
no existing connection.

Usage (run the .ps1 file directly, don't paste it line-by-line):
    Connect-MgGraph -ClientId <your app id> -TenantId <your tenant id>
    .\Get-IntuneSettingsCatalogSnapshot.ps1
    .\Get-IntuneSettingsCatalogSnapshot.ps1 -OutputPath C:\IntuneBackup
    .\Get-IntuneSettingsCatalogSnapshot.ps1 -Platform Windows
#>

[CmdletBinding()]
param(
    [string]$OutputPath = '.\output',
    [string]$TenantId,

    # Which policies to include, by platform. 'All' (default) processes every
    # Settings Catalog policy regardless of platform.
    [ValidateSet('All', 'Windows', 'iOS', 'Android', 'macOS', 'Linux')]
    [string]$Platform = 'All'
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Shared module
# ----------------------------------------------------------------------------
# Get-MgGraphAllPages, Get-SafeFileName and Write-TextFile
# used to be defined in this file, and again in the other scripts. They now
# live in modules/Continuum.Core (Issue #15, D-018). $PSScriptRoot is used here
# only to locate a repository file - no output path changed (known issue #7).
$ContinuumCorePath = if ($PSScriptRoot) {
    Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') 'Continuum.Core') 'Continuum.Core.psd1'
}
if (-not $ContinuumCorePath -or -not (Test-Path -LiteralPath $ContinuumCorePath)) {
    throw "Continuum.Core was not found (looked for '$ContinuumCorePath'). scripts/ and modules/ must stay siblings in the repository - see docs/DECISIONS.md D-018."
}
Import-Module $ContinuumCorePath -Force -ErrorAction Stop

# Each run gets its own timestamped subfolder under json/, so re-running the
# script never overwrites a previous run's snapshots - it's a version history
# by folder, one run per timestamp.
$RunTimestamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
$JsonPath     = Join-Path (Join-Path $OutputPath 'json') $RunTimestamp
if (-not (Test-Path $JsonPath)) { New-Item -ItemType Directory -Path $JsonPath -Force | Out-Null }

$GroupNameCache  = @{}
$FilterNameCache = @{}

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

# Get-MgGraphAllPages: see Continuum.Core.

function Get-GroupDisplayName {
    param([string]$GroupId)
    if (-not $GroupId) { return $null }
    if (-not $GroupNameCache.ContainsKey($GroupId)) {
        try {
            $group = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$GroupId`?`$select=displayName"
            $GroupNameCache[$GroupId] = $group.displayName
        }
        catch {
            $GroupNameCache[$GroupId] = "<unresolved: $GroupId>"
        }
    }
    return $GroupNameCache[$GroupId]
}

function Get-AssignmentFilterName {
    param([string]$FilterId)
    if (-not $FilterId) { return $null }
    if (-not $FilterNameCache.ContainsKey($FilterId)) {
        try {
            $filter = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceManagement/assignmentFilters/$FilterId`?`$select=displayName"
            $FilterNameCache[$FilterId] = $filter.displayName
        }
        catch {
            $FilterNameCache[$FilterId] = "<unresolved: $FilterId>"
        }
    }
    return $FilterNameCache[$FilterId]
}

function Resolve-Assignment {
    <# Normalizes a raw assignment into a flat, readable record. #>
    param([Parameter(Mandatory)]$Assignment)

    $target     = $Assignment.target
    $targetType = "$($target.'@odata.type')" -replace '^#microsoft\.graph\.', ''
    $groupId    = $target.groupId
    $filterId   = $target.deviceAndAppManagementAssignmentFilterId
    $filterType = $target.deviceAndAppManagementAssignmentFilterType

    # Intune represents "no filter" as the all-zero GUID with type 'none',
    # not as a blank/null value - treat that as no filter rather than trying
    # (and failing) to resolve it as a real one.
    if ($filterType -eq 'none' -or $filterId -eq '00000000-0000-0000-0000-000000000000') {
        $filterId = $null
    }

    [pscustomobject]@{
        AssignmentType = $targetType   # groupAssignmentTarget | exclusionGroupAssignmentTarget | allDevicesAssignmentTarget | allLicensedUsersAssignmentTarget
        IsExclude      = ($targetType -eq 'exclusionGroupAssignmentTarget')
        GroupId        = $groupId
        GroupName      = if ($groupId) { Get-GroupDisplayName -GroupId $groupId } else { $null }
        FilterId       = $filterId
        FilterName     = Get-AssignmentFilterName -FilterId $filterId
        FilterType     = $filterType   # include | exclude | none
    }
}

# Get-SafeFileName and Write-TextFile: see Continuum.Core.

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$existingContext = Get-MgContext
if ($existingContext) {
    Write-Host "Using existing Graph connection (Account: $($existingContext.Account), Tenant: $($existingContext.TenantId))."
}
else {
    Write-Host 'No existing Graph connection found - connecting...'
    $connectParams = @{ Scopes = @('DeviceManagementConfiguration.Read.All', 'Group.Read.All') }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-MgGraph @connectParams | Out-Null
    Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"
}

Write-Host 'Fetching Settings Catalog policies (settings inline)...'
$expand   = 'settings($expand=settingDefinitions)'
# @() is load-bearing: Get-MgGraphAllPages returns a List[object], which
# PowerShell enumerates on output, so a tenant with no policies would leave
# $policies as $null and .Count below would be a property access on $null -
# harmless today, but a hard throw the moment Set-StrictMode is adopted here
# (see docs/PROJECT_STATUS.md Known issue #6).
$policies = @(Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies?`$expand=$expand")
Write-Host "Found $($policies.Count) policies."

if ($Platform -ne 'All') {
    # Settings Catalog's 'platforms' field values: windows10 / windows10X,
    # iOS, android / androidEnterprise, macOS, linux. Wildcard match on the
    # Windows/Android prefixes so variant values are still caught.
    $platformPatterns = @{
        'Windows' = 'windows*'
        'iOS'     = 'iOS'
        'Android' = 'android*'
        'macOS'   = 'macOS'
        'Linux'   = 'linux'
    }
    $pattern     = $platformPatterns[$Platform]
    $countBefore = $policies.Count
    $policies    = @($policies | Where-Object { $_.platforms -like $pattern })
    Write-Host "Filtered to platform '$Platform': $($policies.Count) of $countBefore policies match."
}

foreach ($policy in $policies) {
    Write-Host "  - $($policy.name) ($($policy.id))"

    # Fetched via a dedicated per-policy call rather than $expand=assignments
    # on the list call above: $expand on this navigation property has been
    # observed to return a thinner assignment target object that omits the
    # device filter fields (deviceAndAppManagementAssignmentFilterId/Type).
    # The dedicated endpoint returns the full target object.
    # Get-MgGraphAllPages ends in `return $results` on a List[object], which
    # PowerShell enumerates on output, so a policy with no assignments emits
    # zero objects. That makes $rawAssignments AutomationNull, not a literal
    # $null - and @(AutomationNull) is an EMPTY array, so the pipeline runs zero
    # times. (The one-element @($null) trap is real, but only for a literal
    # $null such as a missing property; it does not apply here.)
    #
    # The outer @() is what matters for the unassigned case: without it the
    # empty pipeline assigns AutomationNull and the snapshot serialises
    # "Assignments": null instead of [].
    #
    # Where-Object guards a different, rarer shape: a null *element* inside a
    # populated collection is a real $null, which Resolve-Assignment's Mandatory
    # parameter rejects at bind time. This script has no per-policy try/catch,
    # so that would end the entire run. Both are covered in
    # tests/SettingsCatalogSnapshot.Script.Tests.ps1.
    $rawAssignments = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies/$($policy.id)/assignments"
    $assignments = @(@($rawAssignments) | Where-Object { $_ } | ForEach-Object { Resolve-Assignment -Assignment $_ })

    $snapshot = [pscustomobject]@{
        PolicyType           = 'SettingsCatalog'
        Id                   = $policy.id
        Name                 = $policy.name
        Description          = $policy.description
        Platforms            = $policy.platforms
        Technologies         = $policy.technologies
        CreatedDateTime      = $policy.createdDateTime
        LastModifiedDateTime = $policy.lastModifiedDateTime
        Assignments          = $assignments
        Settings             = $policy.settings
        RetrievedAt          = (Get-Date).ToString('o')
    }

    $file = Join-Path $JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $policy.name), $policy.id)
    Write-TextFile -Path $file -Text ($snapshot | ConvertTo-Json -Depth 20)
}

Write-Host "Done. JSON snapshots written to: $JsonPath"
