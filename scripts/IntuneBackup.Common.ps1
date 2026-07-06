<#
IntuneBackup.Common.ps1

Shared helpers for the Intune policy backup/versioning scripts. Dot-source
this file from an entry script:

    . "$PSScriptRoot/IntuneBackup.Common.ps1"

No module manifest on purpose - a plain dot-sourced file keeps things simple
and easy to iterate. Requires Microsoft.Graph.Authentication for the Graph
calls and ImportExcel for the workbook export.

Caches (group names, filter names, setting definitions) live in the script
scope of whoever dot-sources this file and are initialized by
Initialize-IntuneBackup.
#>

Set-StrictMode -Version Latest

# --- Small utilities ----------------------------------------------------------

function Test-HasProp {
    <#
        True if $Object has member/key $Name. Works for both IDictionary
        (what Invoke-MgGraphRequest returns) and PSCustomObject (ConvertFrom-Json
        without -AsHashtable), so the same code is safe under StrictMode either
        way.
    #>
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return (@($Object.PSObject.Properties.Name) -contains $Name)
}

function Get-Prop {
    <# Safe property/key read: returns $null when absent instead of throwing. #>
    param($Object, [string]$Name)
    if (Test-HasProp -Object $Object -Name $Name) { return $Object.$Name }
    return $null
}

function Write-TextFile {
    <#
        Writes UTF-8 WITHOUT a BOM. Windows PowerShell 5.1's
        `Set-Content -Encoding utf8` emits a BOM, which can make a later
        ConvertFrom-Json fail; this keeps files clean and identical across
        5.1 and 7.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function ConvertFrom-JsonFile {
    <# Reads a JSON file, strips a leading BOM if present, returns the object. #>
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }  # strip UTF-8 BOM if present
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

# --- Paths / caches -----------------------------------------------------------

function Initialize-IntuneBackup {
    <#
        Sets up output folders and in-memory caches. Loads the persistent
        setting-definition cache from disk if present. Call once per run
        before using the other helpers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath
    )

    $script:OutputPath      = $OutputPath
    $script:JsonPath        = Join-Path $OutputPath 'json'
    $script:XlsxPath        = Join-Path $OutputPath 'xlsx'
    $script:StatePath       = Join-Path $OutputPath 'state'
    $script:ManifestFile    = Join-Path $script:StatePath 'manifest.json'
    $script:DefinitionsFile = Join-Path $script:StatePath 'definitions.json'

    foreach ($p in @($script:JsonPath, $script:XlsxPath, $script:StatePath)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }

    $script:GroupNameCache  = @{}
    $script:FilterNameCache = @{}
    $script:DefinitionCache = @{}

    if (Test-Path $script:DefinitionsFile) {
        try {
            $raw = ConvertFrom-JsonFile -Path $script:DefinitionsFile
            if ($raw) {
                foreach ($prop in $raw.PSObject.Properties) {
                    $options = @{}
                    if ($prop.Value.Options) {
                        foreach ($o in $prop.Value.Options.PSObject.Properties) {
                            $options[$o.Name] = $o.Value
                        }
                    }
                    $script:DefinitionCache[$prop.Name] = [pscustomobject]@{
                        DisplayName = $prop.Value.DisplayName
                        Options     = $options
                    }
                }
            }
            Write-Verbose "Loaded $($script:DefinitionCache.Count) cached setting definitions."
        }
        catch {
            Write-Warning "Could not read definitions cache; starting fresh. $_"
        }
    }
}

function Save-DefinitionCache {
    <# Flushes the setting-definition cache to disk for reuse across runs. #>
    [CmdletBinding()]
    param()

    if (-not $script:DefinitionCache) { return }

    $out = [ordered]@{}
    foreach ($key in ($script:DefinitionCache.Keys | Sort-Object)) {
        $def = $script:DefinitionCache[$key]
        if ($null -eq $def) { continue }   # skip negative-cache misses
        $opts = [ordered]@{}
        foreach ($ok in ($def.Options.Keys | Sort-Object)) { $opts[$ok] = $def.Options[$ok] }
        $out[$key] = [ordered]@{ DisplayName = $def.DisplayName; Options = $opts }
    }
    Write-TextFile -Path $script:DefinitionsFile -Text ($out | ConvertTo-Json -Depth 10)
}

# --- Graph plumbing -----------------------------------------------------------

function Get-MgGraphAllPages {
    <#
        Pages through a Graph collection using Invoke-MgGraphRequest, with
        retry/backoff on throttling (429, honoring Retry-After) and transient
        5xx errors. Returns a flat list of items. For single-object responses
        (no 'value' wrapper) returns the object itself in a one-element list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxRetries = 5
    )

    $results = [System.Collections.Generic.List[object]]::new()
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

                # Honor Retry-After if the server sent one, else exponential backoff.
                $delay = [math]::Pow(2, $attempt)  # 2,4,8,16,32
                try {
                    $ra = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                    if ($ra -gt 0) { $delay = $ra }
                } catch { }

                $delay = [int][math]::Ceiling($delay)
                Write-Warning "Graph request '$nextUri' failed (status=$status, attempt=$attempt/$MaxRetries). Retrying in ${delay}s."
                Start-Sleep -Seconds $delay
            }
        }

        if (Test-HasProp $response 'value') {
            $val = Get-Prop $response 'value'
            if ($val) { $results.AddRange([object[]]$val) }
        }
        else {
            $results.Add($response)
        }

        $nextUri = Get-Prop $response '@odata.nextLink'
    }

    return $results
}

function Get-GroupDisplayName {
    [CmdletBinding()]
    param([string]$GroupId)

    if (-not $GroupId) { return $null }
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
    [CmdletBinding()]
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
    <# Normalizes a raw assignment into a flat, readable record. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Assignment)

    $target     = Get-Prop $Assignment 'target'
    $targetType = "$(Get-Prop $target '@odata.type')" -replace '^#microsoft\.graph\.', ''
    $groupId    = Get-Prop $target 'groupId'
    $filterId   = Get-Prop $target 'deviceAndAppManagementAssignmentFilterId'
    $filterType = Get-Prop $target 'deviceAndAppManagementAssignmentFilterType'

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

# --- Setting definitions & flattening -----------------------------------------

function Add-SettingDefinitionToCache {
    <#
        Populates the definition cache from an inline settingDefinition object
        (as returned by $expand=settingDefinitions), so we don't have to fetch
        it separately.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Definition)

    $id = Get-Prop $Definition 'id'
    if (-not $id) { return }
    # Allow a real definition to upgrade a prior negative-cache ($null) miss,
    # but don't re-do work if we already have a real entry.
    if ($script:DefinitionCache.ContainsKey($id) -and $null -ne $script:DefinitionCache[$id]) { return }

    $options = @{}
    $rawOptions = Get-Prop $Definition 'options'
    if ($rawOptions) {
        foreach ($opt in @($rawOptions)) {
            $itemId  = Get-Prop $opt 'itemId'
            $optName = Get-Prop $opt 'name'
            if (-not $optName) { $optName = $itemId }
            if ($itemId) { $options["$itemId"] = $optName }
        }
    }

    $script:DefinitionCache[$id] = [pscustomobject]@{
        DisplayName = (Get-Prop $Definition 'displayName')
        Options     = $options
    }
}

function Get-SettingDefinition {
    <#
        Returns { DisplayName, Options } for a setting definition id, using the
        cache first and falling back to a Graph fetch. On any failure returns
        $null so callers use the raw id.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    if ($script:DefinitionCache.ContainsKey($Id)) { return $script:DefinitionCache[$Id] }

    try {
        $def = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceManagement/configurationSettings/$Id"
        Add-SettingDefinitionToCache -Definition ([pscustomobject]$def)
        return $script:DefinitionCache[$Id]
    }
    catch {
        $script:DefinitionCache[$Id] = $null  # negative cache: don't re-fetch a missing def
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
        Recursively walks the Settings Catalog settingInstance tree and emits
        flat rows: { Path, Title, Value, RawValue }.

          Path     - chain of settingDefinitionIds (always available, stable)
          Title    - resolved display name, raw definitionId fallback
          Value    - resolved display value, raw fallback
          RawValue - the raw value/optionId (used for hashing/diffing)

        Accepts the policy's 'settings' array (each element wrapping a
        'settingInstance'), or a bare list of settingInstances.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)

    $rows = [System.Collections.Generic.List[object]]::new()

    function Emit {
        param($DefinitionId, $ParentPath, $RawValue)
        $path  = if ($ParentPath) { "$ParentPath \ $DefinitionId" } else { $DefinitionId }
        $title = Resolve-SettingTitle -DefinitionId $DefinitionId
        $value = $RawValue
        # Try choice resolution; harmless for simple values (returns raw).
        if ($null -ne $RawValue -and $RawValue -is [string]) {
            $value = Resolve-ChoiceValue -DefinitionId $DefinitionId -OptionValue $RawValue
        }
        [pscustomobject]@{ Path = $path; Title = $title; Value = $value; RawValue = "$RawValue" }
    }

    function Walk {
        param($Instance, $ParentPath)

        if (-not $Instance) { return }
        $type  = "$(Get-Prop $Instance '@odata.type')" -replace '^#microsoft\.graph\.', ''
        $defId = Get-Prop $Instance 'settingDefinitionId'
        $path  = if ($ParentPath) { "$ParentPath \ $defId" } else { $defId }

        switch -Wildcard ($type) {

            '*SimpleSettingInstance' {
                $val = Get-Prop (Get-Prop $Instance 'simpleSettingValue') 'value'
                $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue $val))
            }

            '*SimpleSettingCollectionInstance' {
                foreach ($v in @(Get-Prop $Instance 'simpleSettingCollectionValue')) {
                    if ($null -ne $v) { $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue (Get-Prop $v 'value'))) }
                }
            }

            '*ChoiceSettingInstance' {
                $cv = Get-Prop $Instance 'choiceSettingValue'
                $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue (Get-Prop $cv 'value')))
                foreach ($child in @(Get-Prop $cv 'children')) { Walk -Instance $child -ParentPath $path }
            }

            '*ChoiceSettingCollectionInstance' {
                foreach ($cv in @(Get-Prop $Instance 'choiceSettingCollectionValue')) {
                    $rows.Add((Emit -DefinitionId $defId -ParentPath $ParentPath -RawValue (Get-Prop $cv 'value')))
                    foreach ($child in @(Get-Prop $cv 'children')) { Walk -Instance $child -ParentPath $path }
                }
            }

            '*GroupSettingInstance' {
                $gv = Get-Prop $Instance 'groupSettingValue'
                foreach ($child in @(Get-Prop $gv 'children')) { Walk -Instance $child -ParentPath $path }
            }

            '*GroupSettingCollectionInstance' {
                foreach ($gv in @(Get-Prop $Instance 'groupSettingCollectionValue')) {
                    foreach ($child in @(Get-Prop $gv 'children')) { Walk -Instance $child -ParentPath $path }
                }
            }

            default {
                # Unknown shape - record it rather than dropping it silently.
                $rows.Add([pscustomobject]@{ Path = $path; Title = (Resolve-SettingTitle -DefinitionId $defId); Value = "<unhandled type: $type>"; RawValue = "<unhandled:$type>" })
            }
        }
    }

    foreach ($s in @($Settings)) {
        $instance = if (Test-HasProp $s 'settingInstance') { Get-Prop $s 'settingInstance' } else { $s }
        Walk -Instance $instance -ParentPath $null
    }

    return $rows
}

# --- Hashing / change detection -----------------------------------------------

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
    <#
        Deterministic content hash of a policy version, based on stable data
        only (flattened Path|RawValue plus normalized assignments) - NOT on
        display names, so a Microsoft-side rename of a setting won't create a
        spurious new version. Assignment changes DO create a new version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$FlatSettings,
        $Assignments
    )

    $settingLines = @(
        $FlatSettings | ForEach-Object { "$($_.Path)=$($_.RawValue)" } | Sort-Object
    )
    $assignLines = @(
        @($Assignments) | ForEach-Object { "$($_.AssignmentType)|$($_.GroupId)|$($_.FilterId)|$($_.FilterType)" } | Sort-Object
    )
    $canonical = ($settingLines -join "`n") + "`n##ASSIGNMENTS##`n" + ($assignLines -join "`n")
    return Get-StringSha256 -Text $canonical
}

# --- Manifest -----------------------------------------------------------------

function Read-Manifest {
    [CmdletBinding()]
    param()
    $manifest = @{}
    if (Test-Path $script:ManifestFile) {
        try {
            $raw = ConvertFrom-JsonFile -Path $script:ManifestFile
            if ($raw) { foreach ($prop in $raw.PSObject.Properties) { $manifest[$prop.Name] = $prop.Value } }
        }
        catch { Write-Warning "Could not read manifest; treating as empty. $_" }
    }
    return $manifest
}

function Write-Manifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)
    $out = [ordered]@{}
    foreach ($key in ($Manifest.Keys | Sort-Object)) { $out[$key] = $Manifest[$key] }
    Write-TextFile -Path $script:ManifestFile -Text ($out | ConvertTo-Json -Depth 10)
}

# --- Audit (best effort) ------------------------------------------------------

function Get-PolicyLastModifiedBy {
    <#
        Best-effort "who edited it" from Intune audit events. Only covers the
        tenant's audit retention window; returns $null when nothing is found.
    #>
    [CmdletBinding()]
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

# --- Naming helpers -----------------------------------------------------------

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

function Get-VersionSheetName {
    <#
        Returns a yyyy-MM-dd sheet name, appending _2, _3 ... if that date is
        already present in $ExistingNames.
    #>
    param(
        [datetime]$Date = (Get-Date),
        [string[]]$ExistingNames = @()
    )
    $base = $Date.ToString('yyyy-MM-dd')
    if ($ExistingNames -notcontains $base) { return $base }
    $i = 2
    while ($ExistingNames -contains "${base}_$i") { $i++ }
    return "${base}_$i"
}

# --- Excel export (ImportExcel) -----------------------------------------------

function Get-WorkbookPath {
    param([Parameter(Mandatory)]$Snapshot)
    $safe = Get-SafeFileName -Name $Snapshot.Name
    return (Join-Path $script:XlsxPath ("{0}__{1}.xlsx" -f $safe, $Snapshot.Id))
}

function Format-AssignmentList {
    param($Assignments, [switch]$Exclude)
    $items = @($Assignments) | Where-Object { $_.IsExclude -eq [bool]$Exclude -and $_.GroupId }
    if (-not $items) {
        # allDevices / allUsers targets have no group; surface them on the include side.
        if (-not $Exclude) {
            $special = @($Assignments) | Where-Object { -not $_.GroupId -and -not $_.IsExclude } |
                ForEach-Object { $_.AssignmentType }
            if ($special) { return ($special -join ', ') }
        }
        return ''
    }
    return (($items | ForEach-Object {
        if ($_.FilterName) { "$($_.GroupName) [filter: $($_.FilterName)/$($_.FilterType)]" } else { $_.GroupName }
    }) -join ', ')
}

function Export-PolicyWorkbook {
    <#
        Appends a new dated worksheet (a full, self-contained snapshot) to the
        policy's workbook. Highlights rows that changed vs. the previous sheet.
        Requires the ImportExcel module.

        Returns the sheet name that was written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,          # the snapshot object
        [Parameter(Mandatory)]$FlatSettings,      # output of ConvertTo-FlatSettings
        [datetime]$Date = (Get-Date)
    )

    $path = Get-WorkbookPath -Snapshot $Snapshot

    # Determine existing sheet names + the most recent prior sheet (for diffing).
    $existingNames = @()
    $prevRows = @()
    if (Test-Path $path) {
        $pkgInfo = Open-ExcelPackage -Path $path
        try {
            $existingNames = @($pkgInfo.Workbook.Worksheets | ForEach-Object { $_.Name } | Where-Object { $_ -ne 'Meta' })
            $dateSheets = $existingNames | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' } | Sort-Object
            if ($dateSheets) {
                $prevName = $dateSheets[-1]
                $prevRows = @(Import-Excel -ExcelPackage $pkgInfo -WorksheetName $prevName -StartRow $script:SettingsHeaderRow)
            }
        }
        finally { Close-ExcelPackage $pkgInfo -NoSave }
    }

    $sheetName = Get-VersionSheetName -Date $Date -ExistingNames $existingNames

    # Header block (label/value pairs) written as plain cells above the table.
    $modifiedBy = Get-Prop $Snapshot 'LastModifiedBy'
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

        # Settings table starts after a blank row.
        $tableStart = $r + 1
        $script:SettingsHeaderRow = $tableStart
        $ws.Cells[$tableStart, 1].Value = 'Path'
        $ws.Cells[$tableStart, 2].Value = 'Setting'
        $ws.Cells[$tableStart, 3].Value = 'Configured Value'
        1..3 | ForEach-Object { $ws.Cells[$tableStart, $_].Style.Font.Bold = $true }

        # Build a lookup of previous values by Path for diff highlighting.
        $prevByPath = @{}
        foreach ($pr in $prevRows) { if ($pr.Path) { $prevByPath[$pr.Path] = "$($pr.'Configured Value')" } }
        $havePrev = ($prevRows.Count -gt 0)

        $row = $tableStart + 1
        foreach ($s in $FlatSettings) {
            $ws.Cells[$row, 1].Value = $s.Path
            $ws.Cells[$row, 2].Value = $s.Title
            $ws.Cells[$row, 3].Value = "$($s.Value)"

            if ($havePrev) {
                if (-not $prevByPath.ContainsKey($s.Path)) {
                    # Added setting -> green
                    Set-CellColor -Worksheet $ws -Row $row -Color '#C6EFCE'
                }
                elseif ($prevByPath[$s.Path] -ne "$($s.Value)") {
                    # Changed value -> amber
                    Set-CellColor -Worksheet $ws -Row $row -Color '#FFEB9C'
                }
            }
            $row++
        }

        # Removed settings (present before, gone now) -> red, appended at bottom.
        if ($havePrev) {
            $currentPaths = @{}
            foreach ($s in $FlatSettings) { $currentPaths[$s.Path] = $true }
            foreach ($pr in $prevRows) {
                if ($pr.Path -and -not $currentPaths.ContainsKey($pr.Path)) {
                    $ws.Cells[$row, 1].Value = $pr.Path
                    $ws.Cells[$row, 2].Value = "(removed)"
                    $ws.Cells[$row, 3].Value = "$($pr.'Configured Value')"
                    Set-CellColor -Worksheet $ws -Row $row -Color '#FFC7CE'
                    $row++
                }
            }
        }

        $ws.Cells[$ws.Dimension.Address].AutoFitColumns()
        $ws.View.FreezePanes($tableStart + 1, 1)

        # Hidden Meta sheet: pointer to the authoritative JSON for restore tooling.
        $meta = $pkg.Workbook.Worksheets['Meta']
        if (-not $meta) { $meta = Add-Worksheet -ExcelPackage $pkg -WorksheetName 'Meta' }
        $meta.Cells[1, 1].Value = 'PolicyId';    $meta.Cells[1, 2].Value = $Snapshot.Id
        $meta.Cells[2, 1].Value = 'PolicyType';  $meta.Cells[2, 2].Value = $Snapshot.PolicyType
        $meta.Cells[3, 1].Value = 'LatestSheet'; $meta.Cells[3, 2].Value = $sheetName
        $meta.Cells[4, 1].Value = 'JsonPath';    $meta.Cells[4, 2].Value = (Join-Path $script:JsonPath ("{0}__{1}.json" -f (Get-SafeFileName -Name $Snapshot.Name), $Snapshot.Id))
        $meta.Hidden = 'Hidden'

        Close-ExcelPackage $pkg
    }
    catch {
        Close-ExcelPackage $pkg -NoSave -ErrorAction SilentlyContinue
        throw
    }

    return $sheetName
}

function Set-CellColor {
    param($Worksheet, [int]$Row, [string]$Color)
    1..3 | ForEach-Object {
        $cell = $Worksheet.Cells[$Row, $_]
        $cell.Style.Fill.PatternType = 'Solid'
        $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($Color))
    }
}

function Export-IndexWorkbook {
    <# Rebuilds the master index workbook: one row per policy. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rows)

    $indexPath = Join-Path $script:XlsxPath '_Index.xlsx'
    if (Test-Path $indexPath) { Remove-Item $indexPath -Force }
    $Rows | Sort-Object Name | Export-Excel -Path $indexPath -WorksheetName 'Policies' `
        -TableName 'PolicyIndex' -AutoSize -FreezeTopRow -BoldTopRow
    return $indexPath
}

# Row at which the settings table header lives; updated per-sheet on write and
# used when re-reading a prior sheet for diffing. 11 header labels + blank row.
$script:SettingsHeaderRow = 13
