#requires -Version 5.1
<#
Get-IntuneSettingsCatalogSnapshot.ps1

Phase 1 (read-only) entry script: pulls every Settings Catalog policy with its
settings and assignments in a single call and writes one authoritative JSON
snapshot per policy to <OutputPath>/json. No Excel, no versioning - use
Backup-IntunePolicies.ps1 for that.

Requires: Microsoft.Graph.Authentication.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output'),
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

. "$PSScriptRoot/IntuneBackup.Common.ps1"

Initialize-IntuneBackup -OutputPath $OutputPath

$connectParams = @{ Scopes = @('DeviceManagementConfiguration.Read.All', 'Group.Read.All') }
if ($TenantId) { $connectParams.TenantId = $TenantId }
Connect-MgGraph @connectParams | Out-Null
Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"

Write-Host 'Fetching Settings Catalog policies (settings + assignments inline)...'
$expand = 'settings($expand=settingDefinitions),assignments'
$policies = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies?`$expand=$expand"
Write-Host "Found $($policies.Count) policies."

foreach ($policy in $policies) {
    Write-Host "  - $($policy.name) ($($policy.id))"

    $assignments = @($policy.assignments) | ForEach-Object { Resolve-Assignment -Assignment $_ }

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

    $file = Join-Path $script:JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $policy.name), $policy.id)
    Write-TextFile -Path $file -Text ($snapshot | ConvertTo-Json -Depth 20)
}

Write-Host "Done. JSON snapshots written to: $script:JsonPath"
Save-DefinitionCache
