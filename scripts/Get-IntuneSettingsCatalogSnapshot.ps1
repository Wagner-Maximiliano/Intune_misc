<#
Phase 1 pilot script for the Intune policy backup project.

Connects to Microsoft Graph (delegated, interactive) and pulls every Settings
Catalog policy (deviceManagement/configurationPolicies) along with its
settings and assignments, then writes one JSON file per policy to
-OutputPath. No Excel output yet - this phase is only about proving the
data we can retrieve is complete before we build the workbook export.

Requires the Microsoft.Graph.Authentication module (Install-Module
Microsoft.Graph.Authentication -Scope CurrentUser).
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output'),
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

function Get-MgGraphAllPages {
    param([Parameter(Mandatory)][string]$Uri)

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        if ($response.value) {
            $results.AddRange($response.value)
        }
        elseif ($response) {
            # Single-object response (no 'value' wrapper), used for sub-resources like /settings on some policy types
            $results.Add($response)
        }
        $nextUri = $response.'@odata.nextLink'
    }

    return $results
}

function Get-GroupDisplayName {
    param([string]$GroupId)

    if (-not $script:GroupNameCache.ContainsKey($GroupId)) {
        try {
            $group = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$GroupId`?`$select=displayName"
            $script:GroupNameCache[$GroupId] = $group.displayName
        }
        catch {
            $script:GroupNameCache[$GroupId] = "<unresolved: $GroupId>"
        }
    }

    return $script:GroupNameCache[$GroupId]
}

function Get-AssignmentFilterName {
    param([string]$FilterId)

    if (-not $FilterId) { return $null }

    if (-not $script:FilterNameCache.ContainsKey($FilterId)) {
        try {
            $filter = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceManagement/assignmentFilters/$FilterId`?`$select=displayName"
            $script:FilterNameCache[$FilterId] = $filter.displayName
        }
        catch {
            $script:FilterNameCache[$FilterId] = "<unresolved: $FilterId>"
        }
    }

    return $script:FilterNameCache[$FilterId]
}

function Resolve-Assignment {
    param($Assignment)

    $target = $Assignment.target
    $targetType = $target.'@odata.type' -replace '^#microsoft\.graph\.', ''

    $groupId = $target.groupId
    $groupName = if ($groupId) { Get-GroupDisplayName -GroupId $groupId } else { $null }

    [pscustomobject]@{
        AssignmentType = $targetType
        GroupId        = $groupId
        GroupName      = $groupName
        FilterId       = $target.deviceAndAppManagementAssignmentFilterId
        FilterName     = Get-AssignmentFilterName -FilterId $target.deviceAndAppManagementAssignmentFilterId
        FilterType     = $target.deviceAndAppManagementAssignmentFilterType
    }
}

# --- Main ---

$script:GroupNameCache = @{}
$script:FilterNameCache = @{}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$connectParams = @{
    Scopes = @(
        'DeviceManagementConfiguration.Read.All'
        'Group.Read.All'
    )
}
if ($TenantId) { $connectParams.TenantId = $TenantId }

Connect-MgGraph @connectParams | Out-Null
Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"

Write-Host 'Fetching Settings Catalog policies...'
$policies = Get-MgGraphAllPages -Uri 'beta/deviceManagement/configurationPolicies'
Write-Host "Found $($policies.Count) policies."

foreach ($policy in $policies) {
    Write-Host "  - $($policy.name) ($($policy.id))"

    $settings = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies/$($policy.id)/settings"
    $rawAssignments = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies/$($policy.id)/assignments"
    $assignments = $rawAssignments | ForEach-Object { Resolve-Assignment -Assignment $_ }

    $snapshot = [pscustomobject]@{
        PolicyType  = 'SettingsCatalog'
        Id          = $policy.id
        Name        = $policy.name
        Description = $policy.description
        Platforms   = $policy.platforms
        Technologies = $policy.technologies
        CreatedDateTime      = $policy.createdDateTime
        LastModifiedDateTime = $policy.lastModifiedDateTime
        Assignments = $assignments
        Settings    = $settings
        RetrievedAt = (Get-Date).ToString('o')
    }

    $safeName = ($policy.name -replace '[\\/:*?"<>|]', '_')
    $fileName = "SettingsCatalog_${safeName}_$($policy.id).json"
    $filePath = Join-Path $OutputPath $fileName

    $snapshot | ConvertTo-Json -Depth 20 | Set-Content -Path $filePath -Encoding utf8
}

Write-Host "Done. Snapshots written to: $OutputPath"
