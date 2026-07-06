<#
Backup-IntunePolicies.ps1

Phase 2 + 3 orchestrator. Connects to Microsoft Graph, pulls every Settings
Catalog policy (settings + definitions + assignments in one call), writes the
authoritative JSON snapshot, and appends a new dated worksheet to each policy's
Excel workbook ONLY when the policy has actually changed since the last run.
Rebuilds a master _Index.xlsx and prints a run summary.

Requires: Microsoft.Graph.Authentication, ImportExcel.

Examples:
    ./scripts/Backup-IntunePolicies.ps1
    ./scripts/Backup-IntunePolicies.ps1 -OutputPath D:\IntuneBackup -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output'),
    [string]$TenantId,
    [switch]$SkipAudit
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/IntuneBackup.Common.ps1"

Initialize-IntuneBackup -OutputPath $OutputPath

# --- Connect ------------------------------------------------------------------
$scopes = @(
    'DeviceManagementConfiguration.Read.All'
    'Group.Read.All'
)
if (-not $SkipAudit) { $scopes += 'DeviceManagementApps.Read.All' }  # audit events read

$connectParams = @{ Scopes = $scopes }
if ($TenantId) { $connectParams.TenantId = $TenantId }
Connect-MgGraph @connectParams | Out-Null
Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"

# --- Pull ---------------------------------------------------------------------
Write-Host 'Fetching Settings Catalog policies (settings + assignments inline)...'
$expand = 'settings($expand=settingDefinitions),assignments'
$policies = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies?`$expand=$expand"
Write-Host "Found $($policies.Count) policies."

$manifest = Read-Manifest
$summary  = [System.Collections.Generic.List[object]]::new()
$indexRows = [System.Collections.Generic.List[object]]::new()

foreach ($policy in $policies) {
    $name = $policy.name
    $id   = $policy.id
    $status = 'skipped'
    $sheet  = $null
    $modifiedBy = ''

    try {
        # Populate the definition cache from any inline settingDefinitions.
        foreach ($s in @($policy.settings)) {
            foreach ($def in @($s.settingDefinitions)) {
                if ($def) { Add-SettingDefinitionToCache -Definition ([pscustomobject]$def) }
            }
        }

        $assignments = @($policy.assignments) | ForEach-Object { Resolve-Assignment -Assignment $_ }
        $flat = ConvertTo-FlatSettings -Settings $policy.settings
        $hash = Get-PolicyContentHash -FlatSettings $flat -Assignments $assignments

        $prev = if ($manifest.ContainsKey($id)) { $manifest[$id] } else { $null }
        $changed = (-not $prev) -or ((Get-Prop $prev 'contentHash') -ne $hash) -or ((Get-Prop $prev 'lastModified') -ne "$($policy.lastModifiedDateTime)")

        if (-not $SkipAudit -and $changed) {
            $modifiedBy = Get-PolicyLastModifiedBy -PolicyId $id
        }
        elseif ($prev) {
            $modifiedBy = Get-Prop $prev 'lastModifiedBy'
        }

        $snapshot = [pscustomobject]@{
            PolicyType           = 'SettingsCatalog'
            Id                   = $id
            Name                 = $name
            Description          = $policy.description
            Platforms            = $policy.platforms
            Technologies         = $policy.technologies
            CreatedDateTime      = $policy.createdDateTime
            LastModifiedDateTime = $policy.lastModifiedDateTime
            LastModifiedBy       = $modifiedBy
            Assignments          = $assignments
            Settings             = $policy.settings
            ContentHash          = $hash
            RetrievedAt          = (Get-Date).ToString('o')
        }

        if ($changed) {
            $status = if ($prev) { 'updated' } else { 'created' }

            if ($PSCmdlet.ShouldProcess($name, "Write snapshot ($status)")) {
                # Authoritative JSON (the restore source of truth).
                $jsonFile = Join-Path $script:JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $name), $id)
                $snapshot | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonFile -Encoding utf8

                # Human-readable workbook, new dated sheet with diff highlight.
                $sheet = Export-PolicyWorkbook -Snapshot $snapshot -FlatSettings $flat -Date (Get-Date)

                $manifest[$id] = [ordered]@{
                    name           = $name
                    lastModified   = "$($policy.lastModifiedDateTime)"
                    lastSheetName  = $sheet
                    contentHash    = $hash
                    lastModifiedBy = $modifiedBy
                }
            }
        }

        $indexRows.Add([pscustomobject]@{
            Name           = $name
            Type           = 'SettingsCatalog'
            PolicyId       = $id
            LastModified   = $policy.lastModifiedDateTime
            LastModifiedBy = $modifiedBy
            LatestSnapshot = if ($sheet) { $sheet } elseif ($prev) { Get-Prop $prev 'lastSheetName' } else { '' }
            Workbook       = (Split-Path (Get-WorkbookPath -Snapshot $snapshot) -Leaf)
        })
    }
    catch {
        $status = 'errored'
        Write-Warning "Policy '$name' ($id) failed: $_"
    }

    Write-Host ("  [{0,-8}] {1}" -f $status, $name)
    $summary.Add([pscustomobject]@{ Policy = $name; Status = $status; Sheet = $sheet })
}

# --- Persist state + index ----------------------------------------------------
if ($PSCmdlet.ShouldProcess('output', 'Write manifest, index, definitions cache')) {
    Write-Manifest -Manifest $manifest
    Save-DefinitionCache
    if ($indexRows.Count -gt 0) { Export-IndexWorkbook -Rows $indexRows | Out-Null }
}

# --- Summary ------------------------------------------------------------------
Write-Host ''
Write-Host 'Run summary:'
$summary | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-8} : {1}" -f $_.Name, $_.Count)
}
if ($WhatIfPreference) { Write-Host '(WhatIf: no files were written.)' }
Write-Host "Output: $OutputPath"
