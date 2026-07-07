#requires -Version 5.1

<#
Backup-IntunePolicies.ps1

Connects to Microsoft Graph, pulls every Settings Catalog policy (settings +
definitions inline, assignments via a dedicated per-policy call - $expand on
assignments was found to omit device filter fields), writes the authoritative
JSON snapshot, and appends a new dated worksheet to each policy's Excel
workbook ONLY when the policy has actually changed since the last run.
Rebuilds a master _Index.xlsx and prints a run summary.

This is a single, self-contained file. There is nothing else to dot-source
and no other file it depends on.

MODULES REQUIRED - this script does NOT import them for you. Import these
yourself first, once per PowerShell session, before running the script:

    Import-Module Microsoft.Graph.Authentication
    Import-Module ImportExcel   # not needed at all if you use -SkipExcel

CONNECTION - this script does NOT force a new Graph connection. It checks
Get-MgContext first: if you're already connected (e.g. you ran Connect-MgGraph
yourself with a specific app registration/ClientId), it uses that connection
as-is and never calls Connect-MgGraph. It only connects itself when there is
no existing connection.

Usage (run the .ps1 file directly, don't paste it line-by-line):
    Connect-MgGraph -ClientId <your app id> -TenantId <your tenant id>
    .\Backup-IntunePolicies.ps1
    .\Backup-IntunePolicies.ps1 -OutputPath C:\IntuneBackup
    .\Backup-IntunePolicies.ps1 -Platform Windows
    .\Backup-IntunePolicies.ps1 -SkipExcel
    .\Backup-IntunePolicies.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OutputPath = '.\output',
    [string]$TenantId,
    [switch]$SkipAudit,

    # Which policies to include, by platform. 'All' (default) processes every
    # Settings Catalog policy regardless of platform.
    [ValidateSet('All', 'Windows', 'iOS', 'Android', 'macOS', 'Linux')]
    [string]$Platform = 'All',

    # Skip the Excel workbook / _Index.xlsx export entirely - only write the
    # JSON snapshots. Also means the ImportExcel module is not required.
    [switch]$SkipExcel
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Output folders + in-memory caches
# ----------------------------------------------------------------------------

# Each run gets its own timestamped subfolder under json/, so re-running the
# script never overwrites a previous run's snapshots - it's a version history
# by folder, one run per timestamp.
$RunTimestamp    = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
$JsonPath        = Join-Path (Join-Path $OutputPath 'json') $RunTimestamp
$XlsxPath        = Join-Path $OutputPath 'xlsx'
$StatePath       = Join-Path $OutputPath 'state'
$ManifestFile    = Join-Path $StatePath 'manifest.json'
$DefinitionsFile = Join-Path $StatePath 'definitions.json'

foreach ($p in @($JsonPath, $XlsxPath, $StatePath)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$GroupNameCache  = @{}
$FilterNameCache = @{}
$DefinitionCache = @{}

# ----------------------------------------------------------------------------
# File I/O helpers (BOM-free JSON, so 5.1's Set-Content -Encoding utf8 quirk
# never breaks a later ConvertFrom-Json read-back)
# ----------------------------------------------------------------------------

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function ConvertFrom-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

# ----------------------------------------------------------------------------
# Load persistent caches from previous runs
# ----------------------------------------------------------------------------

if (Test-Path $DefinitionsFile) {
    try {
        $raw = ConvertFrom-JsonFile -Path $DefinitionsFile
        if ($raw) {
            foreach ($prop in $raw.PSObject.Properties) {
                $options = @{}
                if ($prop.Value.Options) {
                    foreach ($o in $prop.Value.Options.PSObject.Properties) { $options[$o.Name] = $o.Value }
                }
                $DefinitionCache[$prop.Name] = [pscustomobject]@{ DisplayName = $prop.Value.DisplayName; Options = $options }
            }
        }
        Write-Verbose "Loaded $($DefinitionCache.Count) cached setting definitions."
    }
    catch { Write-Warning "Could not read definitions cache; starting fresh. $_" }
}

$Manifest = @{}
if (Test-Path $ManifestFile) {
    try {
        $raw = ConvertFrom-JsonFile -Path $ManifestFile
        if ($raw) { foreach ($prop in $raw.PSObject.Properties) { $Manifest[$prop.Name] = $prop.Value } }
    }
    catch { Write-Warning "Could not read manifest; treating as empty. $_" }
}

# ----------------------------------------------------------------------------
# Graph plumbing
# ----------------------------------------------------------------------------

function Get-MgGraphAllPages {
    <# Pages through a Graph collection, retrying on 429 / transient 5xx. #>
    param([Parameter(Mandatory)][string]$Uri, [int]$MaxRetries = 5)

    $results = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri

    while ($nextUri) {
        $attempt  = 0
        $response = $null

        while ($true) {
            try {
                $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -ErrorAction Stop
                break
            }
            catch {
                $attempt++
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }

                $isTransient = ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
                if (-not $isTransient -or $attempt -gt $MaxRetries) { throw }

                $delay = [int][math]::Pow(2, $attempt)   # 2,4,8,16,32 seconds
                Write-Warning "Graph request failed (status=$status, attempt=$attempt/$MaxRetries). Retrying in ${delay}s."
                Start-Sleep -Seconds $delay
            }
        }

        if ($response.value) { $results.AddRange([object[]]$response.value) }
        $nextUri = $response.'@odata.nextLink'
    }

    return $results
}

function Get-GroupDisplayName {
    param([string]$GroupId)
    if (-not $GroupId) { return $null }
    if (-not $GroupNameCache.ContainsKey($GroupId)) {
        try {
            $group = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$GroupId`?`$select=displayName"
            $GroupNameCache[$GroupId] = $group.displayName
        }
        catch { $GroupNameCache[$GroupId] = "<unresolved: $GroupId>" }
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
        catch { $FilterNameCache[$FilterId] = "<unresolved: $FilterId>" }
    }
    return $FilterNameCache[$FilterId]
}

function Resolve-Assignment {
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
        AssignmentType = $targetType
        IsExclude      = ($targetType -eq 'exclusionGroupAssignmentTarget')
        GroupId        = $groupId
        GroupName      = if ($groupId) { Get-GroupDisplayName -GroupId $groupId } else { $null }
        FilterId       = $filterId
        FilterName     = Get-AssignmentFilterName -FilterId $filterId
        FilterType     = $filterType
    }
}

function Get-PolicyLastModifiedBy {
    <# Best-effort "who edited it" from Intune audit events; only covers the tenant's audit retention window. #>
    param([Parameter(Mandatory)][string]$PolicyId)
    try {
        $uri = "beta/deviceManagement/auditEvents?`$filter=resources/any(r:r/resourceId eq '$PolicyId')&`$orderby=activityDateTime desc&`$top=1"
        $events = Get-MgGraphAllPages -Uri $uri
        if ($events -and $events.Count -gt 0) {
            $actor = $events[0].actor
            foreach ($cand in @($actor.userPrincipalName, $actor.userId, $actor.applicationDisplayName)) {
                if ($cand) { return $cand }
            }
        }
    }
    catch { Write-Verbose "Audit lookup failed for $PolicyId : $_" }
    return $null
}

# ----------------------------------------------------------------------------
# Setting definitions & flattening
# ----------------------------------------------------------------------------

function Add-SettingDefinitionToCache {
    param([Parameter(Mandatory)]$Definition)
    $id = $Definition.id
    if (-not $id) { return }
    if ($DefinitionCache.ContainsKey($id) -and $null -ne $DefinitionCache[$id]) { return }

    $options = @{}
    if ($Definition.options) {
        foreach ($opt in @($Definition.options)) {
            $itemId  = $opt.itemId
            $optName = if ($opt.name) { $opt.name } else { $itemId }
            if ($itemId) { $options["$itemId"] = $optName }
        }
    }
    $DefinitionCache[$id] = [pscustomobject]@{ DisplayName = $Definition.displayName; Options = $options }
}

function Get-SettingDefinition {
    param([Parameter(Mandatory)][string]$Id)
    if ($DefinitionCache.ContainsKey($Id)) { return $DefinitionCache[$Id] }
    try {
        $def = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceManagement/configurationSettings/$Id"
        Add-SettingDefinitionToCache -Definition ([pscustomobject]$def)
        return $DefinitionCache[$Id]
    }
    catch {
        $DefinitionCache[$Id] = $null   # negative cache: don't re-fetch a missing definition
        return $null
    }
}

function Resolve-SettingTitle {
    param([string]$DefinitionId)
    $def = Get-SettingDefinition -Id $DefinitionId
    if ($def -and $def.DisplayName) { return $def.DisplayName }
    return $DefinitionId   # raw fallback
}

function Resolve-ChoiceValue {
    param([string]$DefinitionId, [string]$OptionValue)
    if (-not $OptionValue) { return $OptionValue }
    $def = Get-SettingDefinition -Id $DefinitionId
    if ($def -and $def.Options -and $def.Options.ContainsKey($OptionValue)) { return $def.Options[$OptionValue] }
    return $OptionValue   # raw fallback
}

function ConvertTo-FlatSettings {
    <#
        Flattens the Settings Catalog settingInstance tree into rows:
        { Path, Title, Value, RawValue }. Title/Value fall back to the raw
        definition id/value when a definition can't be resolved.
    #>
    param([Parameter(Mandatory)]$Settings)

    $rows = New-Object System.Collections.Generic.List[object]

    function Emit {
        param($DefinitionId, $ParentPath, $RawValue)
        $path  = if ($ParentPath) { "$ParentPath \ $DefinitionId" } else { $DefinitionId }
        $title = Resolve-SettingTitle -DefinitionId $DefinitionId
        $value = $RawValue
        if ($null -ne $RawValue -and $RawValue -is [string]) {
            $value = Resolve-ChoiceValue -DefinitionId $DefinitionId -OptionValue $RawValue
        }
        [pscustomobject]@{ Path = $path; Title = $title; Value = $value; RawValue = "$RawValue" }
    }

    function Walk {
        param($Instance, $ParentPath)
        if (-not $Instance) { return }
        $type  = "$($Instance.'@odata.type')" -replace '^#microsoft\.graph\.', ''
        $defId = $Instance.settingDefinitionId
        $path  = if ($ParentPath) { "$ParentPath \ $defId" } else { $defId }

        switch -Wildcard ($type) {

            '*SimpleSettingInstance' {
                $val = $Instance.simpleSettingValue.value
                $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue $val))
            }

            '*SimpleSettingCollectionInstance' {
                foreach ($v in @($Instance.simpleSettingCollectionValue)) {
                    if ($null -ne $v) { $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue $v.value)) }
                }
            }

            '*ChoiceSettingInstance' {
                $cv = $Instance.choiceSettingValue
                $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue $cv.value))
                foreach ($child in @($cv.children)) { Walk -Instance $child -ParentPath $path }
            }

            '*ChoiceSettingCollectionInstance' {
                foreach ($cv in @($Instance.choiceSettingCollectionValue)) {
                    $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue $cv.value))
                    foreach ($child in @($cv.children)) { Walk -Instance $child -ParentPath $path }
                }
            }

            '*GroupSettingInstance' {
                foreach ($child in @($Instance.groupSettingValue.children)) { Walk -Instance $child -ParentPath $path }
            }

            '*GroupSettingCollectionInstance' {
                foreach ($gv in @($Instance.groupSettingCollectionValue)) {
                    foreach ($child in @($gv.children)) { Walk -Instance $child -ParentPath $path }
                }
            }

            default {
                $rows.Add([pscustomobject]@{ Path = $path; Title = (Resolve-SettingTitle -DefinitionId $defId); Value = "<unhandled type: $type>"; RawValue = "<unhandled:$type>" })
            }
        }
    }

    foreach ($s in @($Settings)) {
        $instance = if ($s.settingInstance) { $s.settingInstance } else { $s }
        Walk -Instance $instance -ParentPath $null
    }

    return $rows
}

# ----------------------------------------------------------------------------
# Hashing / change detection
# ----------------------------------------------------------------------------

function Get-StringSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-PolicyContentHash {
    <# Stable hash over flattened settings + assignments - NOT display names, so a Microsoft-side rename doesn't create a spurious version. #>
    param([Parameter(Mandatory)]$FlatSettings, $Assignments)

    $settingLines = @($FlatSettings | ForEach-Object { "$($_.Path)=$($_.RawValue)" } | Sort-Object)
    $assignLines  = @(@($Assignments) | ForEach-Object { "$($_.AssignmentType)|$($_.GroupId)|$($_.FilterId)|$($_.FilterType)" } | Sort-Object)
    $canonical = ($settingLines -join "`n") + "`n##ASSIGNMENTS##`n" + ($assignLines -join "`n")
    return Get-StringSha256 -Text $canonical
}

# ----------------------------------------------------------------------------
# Naming helpers
# ----------------------------------------------------------------------------

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

function Get-VersionSheetName {
    param([datetime]$Date = (Get-Date), [string[]]$ExistingNames = @())
    $base = $Date.ToString('yyyy-MM-dd')
    if ($ExistingNames -notcontains $base) { return $base }
    $i = 2
    while ($ExistingNames -contains "${base}_$i") { $i++ }
    return "${base}_$i"
}

function Get-WorkbookPath {
    param([Parameter(Mandatory)]$Snapshot)
    $safe = Get-SafeFileName -Name $Snapshot.Name
    return (Join-Path $XlsxPath ("{0}__{1}.xlsx" -f $safe, $Snapshot.Id))
}

function Format-AssignmentList {
    param($Assignments, [switch]$Exclude)
    $items = @($Assignments) | Where-Object { $_.IsExclude -eq [bool]$Exclude -and $_.GroupId }
    if (-not $items) {
        if (-not $Exclude) {
            $special = @($Assignments) | Where-Object { -not $_.GroupId -and -not $_.IsExclude } | ForEach-Object { $_.AssignmentType }
            if ($special) { return ($special -join ', ') }
        }
        return ''
    }
    return (($items | ForEach-Object {
        if ($_.FilterName) { "$($_.GroupName) [filter: $($_.FilterName)/$($_.FilterType)]" } else { $_.GroupName }
    }) -join ', ')
}

# ----------------------------------------------------------------------------
# Excel export (requires the ImportExcel module - see header comment)
# ----------------------------------------------------------------------------

function Set-CellColor {
    param($Worksheet, [int]$Row, [string]$Color)
    1..3 | ForEach-Object {
        $cell = $Worksheet.Cells[$Row, $_]
        $cell.Style.Fill.PatternType = 'Solid'
        $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($Color))
    }
}

function Export-PolicyWorkbook {
    <# Appends a new dated worksheet to the policy's workbook, highlighting changes vs. the previous sheet. Returns the sheet name written. #>
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$FlatSettings,
        [datetime]$Date = (Get-Date)
    )

    $path = Get-WorkbookPath -Snapshot $Snapshot

    # The header block always has the same 11 label/value rows + 1 blank row,
    # so the settings table always starts at a fixed row - no need to track
    # this across calls.
    $headerRowCount   = 11
    $settingsTableRow = $headerRowCount + 2

    $existingNames = @()
    $prevRows = @()
    if (Test-Path $path) {
        $pkgInfo = Open-ExcelPackage -Path $path
        try {
            $existingNames = @($pkgInfo.Workbook.Worksheets | ForEach-Object { $_.Name } | Where-Object { $_ -ne 'Meta' })
            # Must stay wrapped in @(...): with exactly one match, an unwrapped
            # pipeline collapses to a plain string, and [-1] on a string
            # indexes its last CHARACTER, not the last array element.
            $dateSheets = @($existingNames | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' } | Sort-Object)
            if ($dateSheets.Count -gt 0) {
                $prevName = $dateSheets[-1]
                try {
                    $prevRows = @(Import-Excel -ExcelPackage $pkgInfo -WorksheetName $prevName -StartRow $settingsTableRow)
                }
                catch {
                    # Don't let a bad/unreadable previous sheet kill the whole
                    # policy - fall back to "no prior version" so this run
                    # still writes a fresh sheet, just without diff colouring.
                    Write-Warning "Could not read previous sheet '$prevName' in '$path' for diffing - writing this version without change highlighting. $_"
                    $prevRows = @()
                }
            }
        }
        finally { Close-ExcelPackage $pkgInfo -NoSave }
    }

    $sheetName = Get-VersionSheetName -Date $Date -ExistingNames $existingNames

    $modifiedBy = $Snapshot.LastModifiedBy
    $header = [ordered]@{
        'Policy Name'      = $Snapshot.Name
        'Description'      = $Snapshot.Description
        'Policy Type'      = $Snapshot.PolicyType
        'Platforms'        = $Snapshot.Platforms
        'Created'          = $Snapshot.CreatedDateTime
        'Last Modified'    = $Snapshot.LastModifiedDateTime
        'Last Modified By' = $modifiedBy
        'Assigned Groups'  = (Format-AssignmentList -Assignments $Snapshot.Assignments)
        'Excluded Groups'  = (Format-AssignmentList -Assignments $Snapshot.Assignments -Exclude)
        'Snapshot Date'    = $Date.ToString('yyyy-MM-dd HH:mm')
        'Policy Id'        = $Snapshot.Id
    }

    $pkg = Open-ExcelPackage -Path $path -Create:(-not (Test-Path $path))
    try {
        $ws = Add-Worksheet -ExcelPackage $pkg -WorksheetName $sheetName

        $r = 1
        foreach ($k in $header.Keys) {
            $ws.Cells[$r, 1].Value = $k
            $ws.Cells[$r, 1].Style.Font.Bold = $true
            $ws.Cells[$r, 2].Value = "$($header[$k])"
            $r++
        }

        # Column order: Setting, Configured Value, Path (Path last). Diffing
        # below reads $pr.Path / $pr.'Configured Value' by Import-Excel's
        # header-name matching, so column order here doesn't affect that.
        $tableStart = $settingsTableRow
        $ws.Cells[$tableStart, 1].Value = 'Setting'
        $ws.Cells[$tableStart, 2].Value = 'Configured Value'
        $ws.Cells[$tableStart, 3].Value = 'Path'
        1..3 | ForEach-Object { $ws.Cells[$tableStart, $_].Style.Font.Bold = $true }

        $prevByPath = @{}
        foreach ($pr in $prevRows) { if ($pr.Path) { $prevByPath[$pr.Path] = "$($pr.'Configured Value')" } }
        $havePrev = ($prevRows.Count -gt 0)

        $row = $tableStart + 1
        foreach ($s in $FlatSettings) {
            $ws.Cells[$row, 1].Value = $s.Title
            $ws.Cells[$row, 2].Value = "$($s.Value)"
            $ws.Cells[$row, 3].Value = $s.Path

            if ($havePrev) {
                if (-not $prevByPath.ContainsKey($s.Path)) {
                    Set-CellColor -Worksheet $ws -Row $row -Color '#C6EFCE'   # added -> green
                }
                elseif ($prevByPath[$s.Path] -ne "$($s.Value)") {
                    Set-CellColor -Worksheet $ws -Row $row -Color '#FFEB9C'   # changed -> amber
                }
            }
            $row++
        }

        if ($havePrev) {
            $currentPaths = @{}
            foreach ($s in $FlatSettings) { $currentPaths[$s.Path] = $true }
            foreach ($pr in $prevRows) {
                if ($pr.Path -and -not $currentPaths.ContainsKey($pr.Path)) {
                    $ws.Cells[$row, 1].Value = '(removed)'
                    $ws.Cells[$row, 2].Value = "$($pr.'Configured Value')"
                    $ws.Cells[$row, 3].Value = $pr.Path
                    Set-CellColor -Worksheet $ws -Row $row -Color '#FFC7CE'   # removed -> red
                    $row++
                }
            }
        }

        $ws.Cells[$ws.Dimension.Address].AutoFitColumns()
        $ws.View.FreezePanes($tableStart + 1, 1)

        $meta = $pkg.Workbook.Worksheets['Meta']
        if (-not $meta) { $meta = Add-Worksheet -ExcelPackage $pkg -WorksheetName 'Meta' }
        $meta.Cells[1, 1].Value = 'PolicyId';    $meta.Cells[1, 2].Value = $Snapshot.Id
        $meta.Cells[2, 1].Value = 'PolicyType';  $meta.Cells[2, 2].Value = $Snapshot.PolicyType
        $meta.Cells[3, 1].Value = 'LatestSheet'; $meta.Cells[3, 2].Value = $sheetName
        $meta.Cells[4, 1].Value = 'JsonPath';    $meta.Cells[4, 2].Value = (Join-Path $JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $Snapshot.Name), $Snapshot.Id))
        $meta.Hidden = 'Hidden'

        Close-ExcelPackage $pkg
    }
    catch {
        Close-ExcelPackage $pkg -NoSave -ErrorAction SilentlyContinue
        throw
    }

    return $sheetName
}

function Export-IndexWorkbook {
    param([Parameter(Mandatory)]$Rows)
    $indexPath = Join-Path $XlsxPath '_Index.xlsx'
    if (Test-Path $indexPath) { Remove-Item $indexPath -Force }
    $Rows | Sort-Object Name | Export-Excel -Path $indexPath -WorksheetName 'Policies' `
        -TableName 'PolicyIndex' -AutoSize -FreezeTopRow -BoldTopRow
    return $indexPath
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$scopes = @('DeviceManagementConfiguration.Read.All', 'Group.Read.All')
if (-not $SkipAudit) { $scopes += 'DeviceManagementApps.Read.All' }

$existingContext = Get-MgContext
if ($existingContext) {
    Write-Host "Using existing Graph connection (Account: $($existingContext.Account), Tenant: $($existingContext.TenantId))."
}
else {
    Write-Host 'No existing Graph connection found - connecting...'
    $connectParams = @{ Scopes = $scopes }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-MgGraph @connectParams | Out-Null
    Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"
}

Write-Host 'Fetching Settings Catalog policies (settings inline)...'
$expand   = 'settings($expand=settingDefinitions)'
$policies = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies?`$expand=$expand"
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

$summary   = New-Object System.Collections.Generic.List[object]
$indexRows = New-Object System.Collections.Generic.List[object]

foreach ($policy in $policies) {
    $name = $policy.name
    $id   = $policy.id
    $status = 'skipped'
    $sheet  = $null
    $modifiedBy = ''

    try {
        foreach ($s in @($policy.settings)) {
            foreach ($def in @($s.settingDefinitions)) {
                if ($def) { Add-SettingDefinitionToCache -Definition ([pscustomobject]$def) }
            }
        }

        # Fetched via a dedicated per-policy call rather than $expand=assignments
        # on the list call above: $expand on this navigation property has been
        # observed to return a thinner assignment target object that omits the
        # device filter fields (deviceAndAppManagementAssignmentFilterId/Type).
        # The dedicated endpoint returns the full target object.
        $rawAssignments = Get-MgGraphAllPages -Uri "beta/deviceManagement/configurationPolicies/$id/assignments"
        $assignments = @($rawAssignments) | ForEach-Object { Resolve-Assignment -Assignment $_ }
        $flat = ConvertTo-FlatSettings -Settings $policy.settings
        $hash = Get-PolicyContentHash -FlatSettings $flat -Assignments $assignments

        $prev = if ($Manifest.ContainsKey($id)) { $Manifest[$id] } else { $null }
        $changed = (-not $prev) -or ($prev.contentHash -ne $hash) -or ($prev.lastModified -ne "$($policy.lastModifiedDateTime)")

        if (-not $SkipAudit -and $changed) {
            $modifiedBy = Get-PolicyLastModifiedBy -PolicyId $id
        }
        elseif ($prev) {
            $modifiedBy = $prev.lastModifiedBy
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
                $jsonFile = Join-Path $JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $name), $id)
                Write-TextFile -Path $jsonFile -Text ($snapshot | ConvertTo-Json -Depth 20)

                if (-not $SkipExcel) {
                    $sheet = Export-PolicyWorkbook -Snapshot $snapshot -FlatSettings $flat -Date (Get-Date)
                }

                $Manifest[$id] = [ordered]@{
                    name           = $name
                    lastModified   = "$($policy.lastModifiedDateTime)"
                    lastSheetName  = if ($sheet) { $sheet } elseif ($prev) { $prev.lastSheetName } else { '' }
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
            LatestSnapshot = if ($sheet) { $sheet } elseif ($prev) { $prev.lastSheetName } else { '' }
            Workbook       = (Split-Path (Get-WorkbookPath -Snapshot $snapshot) -Leaf)
        })
    }
    catch {
        $status = 'errored'
        Write-Warning "Policy '$name' ($id) failed at line $($_.InvocationInfo.ScriptLineNumber): $_"
    }

    Write-Host ("  [{0,-8}] {1}" -f $status, $name)
    $summary.Add([pscustomobject]@{ Policy = $name; Status = $status; Sheet = $sheet })
}

# --- Persist state + index ---------------------------------------------------

if ($PSCmdlet.ShouldProcess('output', 'Write manifest, index, definitions cache')) {
    $manifestOut = [ordered]@{}
    foreach ($key in ($Manifest.Keys | Sort-Object)) { $manifestOut[$key] = $Manifest[$key] }
    Write-TextFile -Path $ManifestFile -Text ($manifestOut | ConvertTo-Json -Depth 10)

    $defsOut = [ordered]@{}
    foreach ($key in ($DefinitionCache.Keys | Sort-Object)) {
        $def = $DefinitionCache[$key]
        if ($null -eq $def) { continue }
        $opts = [ordered]@{}
        foreach ($ok in ($def.Options.Keys | Sort-Object)) { $opts[$ok] = $def.Options[$ok] }
        $defsOut[$key] = [ordered]@{ DisplayName = $def.DisplayName; Options = $opts }
    }
    Write-TextFile -Path $DefinitionsFile -Text ($defsOut | ConvertTo-Json -Depth 10)

    if (-not $SkipExcel -and $indexRows.Count -gt 0) { Export-IndexWorkbook -Rows $indexRows | Out-Null }
}

# --- Summary ------------------------------------------------------------------

Write-Host ''
Write-Host 'Run summary:'
$summary | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-8} : {1}" -f $_.Name, $_.Count)
}
if ($WhatIfPreference) { Write-Host '(WhatIf: no files were written.)' }
if ($SkipExcel) { Write-Host '(SkipExcel: no workbook or index was written, JSON only.)' }
Write-Host "Output: $OutputPath"
Write-Host "This run's JSON snapshots: $JsonPath"
