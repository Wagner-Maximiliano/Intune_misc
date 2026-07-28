#requires -Version 5.1

<#
Import-PolicyHistoryToDatabase.ps1

Phase 6 (part 1 of 2 - the data layer): reads the JSON policy snapshots
produced by Backup-IntunePolicies.ps1 / Get-IntuneSettingsCatalogSnapshot.ps1
and loads them into a single-file SQLite database that captures the full
version history - one row per distinct policy state - so a later web page
(part 2) can browse and query it. This script only builds/updates the
database; it renders no UI.

WHY A DATABASE. The Excel workbooks are a per-policy human view; the JSON is
the authoritative artifact but is one-file-per-version and awkward to query
across. This collapses every snapshot into a normalized, queryable store:

    Policies            - one row per PolicyId (latest known descriptive fields)
    PolicyVersions      - one row per DISTINCT (PolicyId, ContentHash) state
    PolicySettings      - flattened Path/Title/Value rows for each version
    PolicyAssignments   - resolved group/filter rows for each version
    IngestRuns          - provenance: one row per run of this script
    Meta                - schema version / bookkeeping

IDEMPOTENT + ADDITIVE. A version is keyed by its content hash (computed the
same way Backup-IntunePolicies.ps1 computes it - flattened settings +
assignments, NOT display names). Re-running never duplicates a version: an
unchanged policy is skipped, a new state is appended. So you can point this at
the whole json/ tree repeatedly and it just keeps the history complete.

This is a single, self-contained file. There is nothing else to dot-source
and no other file it depends on. It does NOT connect to Microsoft Graph at
all - it only reads JSON already on disk (group/filter names are already
resolved inside the JSON; setting titles are resolved from the cached
definitions file when available, raw ids otherwise).

MODULES REQUIRED - this script does NOT import them for you. Import this
yourself first, once per PowerShell session, before running the script:

    Import-Module PSSQLite

If you don't have it yet:

    Install-Module PSSQLite -Scope CurrentUser

Usage (run the .ps1 file directly, don't paste it line-by-line):
    .\Import-PolicyHistoryToDatabase.ps1 -JsonPath .\output\json
    .\Import-PolicyHistoryToDatabase.ps1 -JsonPath .\output\json\2026-07-08_143022
    .\Import-PolicyHistoryToDatabase.ps1 -JsonPath .\output\json -DatabasePath .\output\db\PolicyHistory.sqlite
    .\Import-PolicyHistoryToDatabase.ps1 -JsonPath .\output\json -WhatIf

Point -JsonPath at the whole json/ folder or a single run's timestamped
subfolder (searched recursively either way) or a single .json file.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$JsonPath,

    [string]$DatabasePath = '.\output\db\PolicyHistory.sqlite',

    # Optional path to the definitions.json cache written by
    # Backup-IntunePolicies.ps1 (output\state\definitions.json). Used ONLY to
    # resolve friendly setting titles/values offline; raw definition ids are
    # used as a fallback when it's absent. If not given, the script tries to
    # auto-locate it near -JsonPath.
    [string]$DefinitionsFile
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# File I/O helpers (BOM-free read, matching the rest of the project)
# ----------------------------------------------------------------------------

function ConvertFrom-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }   # strip UTF-8 BOM if present
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function ConvertTo-DateTimeOrMin {
    <# Parse an ISO-8601 'o' timestamp to [datetime]; MinValue on failure so
       comparisons never throw. #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [datetime]::MinValue }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) {
        return $dt
    }
    return [datetime]::MinValue
}

# ----------------------------------------------------------------------------
# Setting definitions & flattening
#
# Ported (deliberately, not dot-sourced - this project keeps each script
# self-contained) from Backup-IntunePolicies.ps1 so the flattened rows AND the
# content hash come out identical to what the backup produced. The one
# difference: Get-SettingDefinition here is CACHE-ONLY - it never calls Graph,
# because this script is fully offline.
# ----------------------------------------------------------------------------

$DefinitionCache = @{}

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
    return $null   # offline: no Graph fetch, raw id is used as the fallback
}

function Resolve-SettingTitle {
    param([string]$DefinitionId)
    $def = Get-SettingDefinition -Id $DefinitionId
    if ($def -and $def.DisplayName) { return $def.DisplayName }
    return $DefinitionId
}

function Resolve-ChoiceValue {
    param([string]$DefinitionId, [string]$OptionValue)
    if (-not $OptionValue) { return $OptionValue }
    $def = Get-SettingDefinition -Id $DefinitionId
    if ($def -and $def.Options -and $def.Options.ContainsKey($OptionValue)) { return $def.Options[$OptionValue] }
    return $OptionValue
}

function ConvertTo-FlatSettings {
    <# Flattens the settingInstance tree into { Path, Title, Value, RawValue }
       rows. Same shape/logic as Backup-IntunePolicies.ps1. #>
    # AllowNull/AllowEmptyCollection alongside Mandatory: a snapshot for a
    # policy with no settings is legitimate, and its JSON Settings value
    # arrives as either $null or an empty array. A bare Mandatory parameter
    # rejects both at bind time - before the body runs - which aborted the
    # ingest for that file. The loop below already tolerates both.
    # Kept in step with Backup-IntunePolicies.ps1's copy of this function.
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Settings)

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
# Hashing (identical canonical form to Backup-IntunePolicies.ps1, so a version
# imported here has the same identity as the backup that produced it)
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
    param([Parameter(Mandatory)]$FlatSettings, $Assignments)
    $settingLines = @($FlatSettings | ForEach-Object { "$($_.Path)=$($_.RawValue)" } | Sort-Object)
    $assignLines  = @(@($Assignments) | ForEach-Object { "$($_.AssignmentType)|$($_.GroupId)|$($_.FilterId)|$($_.FilterType)" } | Sort-Object)
    $canonical = ($settingLines -join "`n") + "`n##ASSIGNMENTS##`n" + ($assignLines -join "`n")
    return Get-StringSha256 -Text $canonical
}

# ----------------------------------------------------------------------------
# SQLite helpers (require the PSSQLite module - see header comment)
# ----------------------------------------------------------------------------

function Invoke-Db {
    <# Run a query on the shared connection, optionally parameterized. Returns
       rows for SELECTs. #>
    param([Parameter(Mandatory)][string]$Query, [hashtable]$Parameters)
    if ($Parameters) {
        return Invoke-SqliteQuery -SQLiteConnection $script:Conn -Query $Query -SqlParameters $Parameters
    }
    return Invoke-SqliteQuery -SQLiteConnection $script:Conn -Query $Query
}

function Get-LastInsertRowId {
    return [int64]((Invoke-Db -Query 'SELECT last_insert_rowid() AS Id').Id)
}

$SchemaVersion = 1

$SchemaStatements = @(
    @'
CREATE TABLE IF NOT EXISTS Meta (
    Key   TEXT PRIMARY KEY,
    Value TEXT
);
'@,
    @'
CREATE TABLE IF NOT EXISTS Policies (
    PolicyId        TEXT PRIMARY KEY,
    PolicyType      TEXT,
    Name            TEXT,
    Description     TEXT,
    Platforms       TEXT,
    Technologies    TEXT,
    CreatedDateTime TEXT,
    FirstSeen       TEXT,
    LastSeen        TEXT,
    VersionCount    INTEGER NOT NULL DEFAULT 0
);
'@,
    @'
CREATE TABLE IF NOT EXISTS PolicyVersions (
    VersionId            INTEGER PRIMARY KEY AUTOINCREMENT,
    PolicyId             TEXT NOT NULL,
    ContentHash          TEXT NOT NULL,
    SourceContentHash    TEXT,
    Name                 TEXT,
    Description          TEXT,
    Platforms            TEXT,
    Technologies         TEXT,
    CreatedDateTime      TEXT,
    LastModifiedDateTime TEXT,
    LastModifiedBy       TEXT,
    FirstRetrievedAt     TEXT,
    LastRetrievedAt      TEXT,
    SourceFile           TEXT,
    SettingCount         INTEGER NOT NULL DEFAULT 0,
    SettingsJson         TEXT,
    UNIQUE (PolicyId, ContentHash)
);
'@,
    @'
CREATE TABLE IF NOT EXISTS PolicySettings (
    SettingId INTEGER PRIMARY KEY AUTOINCREMENT,
    VersionId INTEGER NOT NULL,
    Ordinal   INTEGER NOT NULL,
    Path      TEXT,
    Title     TEXT,
    Value     TEXT,
    RawValue  TEXT
);
'@,
    @'
CREATE TABLE IF NOT EXISTS PolicyAssignments (
    AssignmentId   INTEGER PRIMARY KEY AUTOINCREMENT,
    VersionId      INTEGER NOT NULL,
    AssignmentType TEXT,
    IsExclude      INTEGER NOT NULL DEFAULT 0,
    GroupId        TEXT,
    GroupName      TEXT,
    FilterId       TEXT,
    FilterName     TEXT,
    FilterType     TEXT
);
'@,
    @'
CREATE TABLE IF NOT EXISTS IngestRuns (
    RunId            INTEGER PRIMARY KEY AUTOINCREMENT,
    StartedAt        TEXT,
    FinishedAt       TEXT,
    SourcePath       TEXT,
    FilesSeen        INTEGER,
    FilesFailed      INTEGER,
    PoliciesUpserted INTEGER,
    VersionsInserted INTEGER,
    VersionsSkipped  INTEGER
);
'@,
    'CREATE INDEX IF NOT EXISTS IX_PolicyVersions_PolicyId ON PolicyVersions (PolicyId);',
    'CREATE INDEX IF NOT EXISTS IX_PolicySettings_VersionId ON PolicySettings (VersionId);',
    'CREATE INDEX IF NOT EXISTS IX_PolicyAssignments_VersionId ON PolicyAssignments (VersionId);'
)

function Initialize-Schema {
    foreach ($stmt in $SchemaStatements) { Invoke-Db -Query $stmt | Out-Null }
    Invoke-Db -Query 'INSERT OR IGNORE INTO Meta (Key, Value) VALUES (@k, @v);' -Parameters @{ k = 'SchemaVersion'; v = "$SchemaVersion" } | Out-Null
}

# ----------------------------------------------------------------------------
# Load + normalize all snapshots from disk
# ----------------------------------------------------------------------------

if (-not (Test-Path $JsonPath)) { throw "Path not found: $JsonPath" }

if (Test-Path $JsonPath -PathType Leaf) {
    $files = @(Get-Item -Path $JsonPath)
}
else {
    $files = @(Get-ChildItem -Path $JsonPath -Filter '*.json' -File -Recurse)
}
if ($files.Count -eq 0) { throw "No JSON files found under '$JsonPath'." }

Write-Host "Found $($files.Count) JSON file(s) under: $JsonPath"

# Load the setting-definition cache (friendly titles), if we can find it.
if (-not $DefinitionsFile) {
    # Walk up from the JSON location looking for a sibling state\definitions.json.
    $probe = (Resolve-Path $JsonPath).Path
    if (Test-Path $probe -PathType Leaf) { $probe = Split-Path $probe -Parent }
    for ($i = 0; $i -lt 6 -and $probe; $i++) {
        foreach ($cand in @((Join-Path $probe 'state\definitions.json'), (Join-Path $probe 'definitions.json'))) {
            if (Test-Path $cand) { $DefinitionsFile = $cand; break }
        }
        if ($DefinitionsFile) { break }
        $probe = Split-Path $probe -Parent
    }
}
if ($DefinitionsFile -and (Test-Path $DefinitionsFile)) {
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
        Write-Host "Loaded $($DefinitionCache.Count) setting definitions for friendly titles from: $DefinitionsFile"
    }
    catch { Write-Warning "Could not read definitions cache '$DefinitionsFile'; using raw ids. $_" }
}
else {
    Write-Host 'No definitions cache found - setting titles will fall back to raw definition ids.'
}

# Parse every snapshot up front, flatten, and compute its content hash. Sorted
# ascending by RetrievedAt so that when we write descriptive fields "last wins"
# is simply the newest snapshot.
$snapshots  = New-Object System.Collections.Generic.List[object]
$filesFailed = 0

foreach ($file in $files) {
    try {
        $snap = ConvertFrom-JsonFile -Path $file.FullName
        if (-not $snap -or -not $snap.Id) {
            Write-Warning "Skipping '$($file.FullName)': not a policy snapshot (no Id)."
            $filesFailed++
            continue
        }

        $retrievedStr = if ($snap.PSObject.Properties['RetrievedAt'] -and $snap.RetrievedAt) {
            "$($snap.RetrievedAt)"
        } else {
            $file.LastWriteTimeUtc.ToString('o')
        }

        $assignments = @($snap.Assignments)
        $flat        = ConvertTo-FlatSettings -Settings $snap.Settings
        $hash        = Get-PolicyContentHash -FlatSettings $flat -Assignments $assignments

        $snapshots.Add([pscustomobject]@{
            PolicyId          = "$($snap.Id)"
            Snapshot          = $snap
            Assignments       = $assignments
            Flat              = $flat
            ContentHash       = $hash
            SourceContentHash = if ($snap.PSObject.Properties['ContentHash']) { "$($snap.ContentHash)" } else { $null }
            RetrievedStr      = $retrievedStr
            RetrievedDt       = (ConvertTo-DateTimeOrMin -Text $retrievedStr)
            SourceFile        = $file.FullName
        })
    }
    catch {
        Write-Warning "Could not read '$($file.FullName)': $_"
        $filesFailed++
    }
}

if ($snapshots.Count -eq 0) { throw "None of the $($files.Count) file(s) could be read as a policy snapshot." }

$ordered = @($snapshots | Sort-Object RetrievedDt)

# Distinct counts across the INPUT set (for the WhatIf preview / summary).
$distinctPolicies = @($ordered | Select-Object -ExpandProperty PolicyId -Unique).Count
$distinctVersions = @($ordered | ForEach-Object { "$($_.PolicyId)|$($_.ContentHash)" } | Select-Object -Unique).Count

Write-Host ("Parsed {0} snapshot(s): {1} distinct polic{2}, {3} distinct version(s) in the input." -f `
        $ordered.Count, $distinctPolicies, $(if ($distinctPolicies -eq 1) { 'y' } else { 'ies' }), $distinctVersions)

# ----------------------------------------------------------------------------
# WhatIf: report, write nothing
# ----------------------------------------------------------------------------

if (-not $PSCmdlet.ShouldProcess($DatabasePath, "Ingest $($ordered.Count) snapshot(s) into SQLite")) {
    Write-Host ''
    Write-Host '(WhatIf: no database was created or modified.)'
    Write-Host "Would ensure database at : $DatabasePath"
    Write-Host "Would upsert policies    : $distinctPolicies"
    Write-Host "Would consider versions  : $distinctVersions (new vs. existing decided against the live DB at run time)"
    return
}

# ----------------------------------------------------------------------------
# Open the database and ingest
# ----------------------------------------------------------------------------

if (-not (Get-Command Invoke-SqliteQuery -ErrorAction SilentlyContinue)) {
    throw "The PSSQLite module isn't loaded. Run 'Import-Module PSSQLite' first (see this script's header)."
}

$dbDir = Split-Path $DatabasePath -Parent
if ($dbDir -and -not (Test-Path $dbDir)) { New-Item -ItemType Directory -Path $dbDir -Force | Out-Null }

$script:Conn = New-SQLiteConnection -DataSource $DatabasePath
try {
    Initialize-Schema

    # Provenance row for this run.
    Invoke-Db -Query 'INSERT INTO IngestRuns (StartedAt, SourcePath) VALUES (@s, @p);' `
        -Parameters @{ s = (Get-Date).ToString('o'); p = (Resolve-Path $JsonPath).Path } | Out-Null
    $runId = Get-LastInsertRowId

    $policiesTouched = @{}
    $versionsInserted = 0
    $versionsSkipped  = 0

    Invoke-Db -Query 'BEGIN TRANSACTION;' | Out-Null
    try {
        foreach ($item in $ordered) {
            $policyId = $item.PolicyId
            $snap     = $item.Snapshot
            $policiesTouched[$policyId] = $true

            # --- Upsert the Policies row (descriptive fields; last write wins) ---
            $existing = @(Invoke-Db -Query 'SELECT FirstSeen, LastSeen FROM Policies WHERE PolicyId = @id;' -Parameters @{ id = $policyId })
            if ($existing.Count -eq 0) {
                Invoke-Db -Query @'
INSERT INTO Policies (PolicyId, PolicyType, Name, Description, Platforms, Technologies, CreatedDateTime, FirstSeen, LastSeen, VersionCount)
VALUES (@id, @type, @name, @desc, @plat, @tech, @created, @first, @last, 0);
'@ -Parameters @{
                    id      = $policyId
                    type    = "$($snap.PolicyType)"
                    name    = "$($snap.Name)"
                    desc    = "$($snap.Description)"
                    plat    = "$($snap.Platforms)"
                    tech    = "$($snap.Technologies)"
                    created = "$($snap.CreatedDateTime)"
                    first   = $item.RetrievedStr
                    last    = $item.RetrievedStr
                } | Out-Null
            }
            else {
                $storedFirst = ConvertTo-DateTimeOrMin -Text ("$($existing[0].FirstSeen)")
                $storedLast  = ConvertTo-DateTimeOrMin -Text ("$($existing[0].LastSeen)")

                $newFirstStr = if ($item.RetrievedDt -lt $storedFirst) { $item.RetrievedStr } else { "$($existing[0].FirstSeen)" }
                $newLastStr  = if ($item.RetrievedDt -gt $storedLast)  { $item.RetrievedStr } else { "$($existing[0].LastSeen)" }

                if ($item.RetrievedDt -ge $storedLast) {
                    # This snapshot is the newest we've seen for the policy -
                    # refresh the descriptive fields to match it.
                    Invoke-Db -Query @'
UPDATE Policies SET PolicyType=@type, Name=@name, Description=@desc, Platforms=@plat,
    Technologies=@tech, CreatedDateTime=@created, FirstSeen=@first, LastSeen=@last
WHERE PolicyId=@id;
'@ -Parameters @{
                        id      = $policyId
                        type    = "$($snap.PolicyType)"
                        name    = "$($snap.Name)"
                        desc    = "$($snap.Description)"
                        plat    = "$($snap.Platforms)"
                        tech    = "$($snap.Technologies)"
                        created = "$($snap.CreatedDateTime)"
                        first   = $newFirstStr
                        last    = $newLastStr
                    } | Out-Null
                }
                else {
                    Invoke-Db -Query 'UPDATE Policies SET FirstSeen=@first, LastSeen=@last WHERE PolicyId=@id;' `
                        -Parameters @{ id = $policyId; first = $newFirstStr; last = $newLastStr } | Out-Null
                }
            }

            # --- Insert the version if this exact content is new ---------------
            $ver = @(Invoke-Db -Query 'SELECT VersionId FROM PolicyVersions WHERE PolicyId=@p AND ContentHash=@h;' `
                    -Parameters @{ p = $policyId; h = $item.ContentHash })

            if ($ver.Count -gt 0) {
                # Already have this state - just extend its "last retrieved" window.
                $versionsSkipped++
                Invoke-Db -Query 'UPDATE PolicyVersions SET LastRetrievedAt=@r WHERE VersionId=@v AND (LastRetrievedAt IS NULL OR LastRetrievedAt < @r);' `
                    -Parameters @{ v = [int64]$ver[0].VersionId; r = $item.RetrievedStr } | Out-Null
                continue
            }

            $modifiedBy = if ($snap.PSObject.Properties['LastModifiedBy']) { "$($snap.LastModifiedBy)" } else { '' }
            $settingsJson = if ($null -ne $snap.Settings) { ($snap.Settings | ConvertTo-Json -Depth 20 -Compress) } else { '[]' }

            Invoke-Db -Query @'
INSERT INTO PolicyVersions
    (PolicyId, ContentHash, SourceContentHash, Name, Description, Platforms, Technologies,
     CreatedDateTime, LastModifiedDateTime, LastModifiedBy, FirstRetrievedAt, LastRetrievedAt,
     SourceFile, SettingCount, SettingsJson)
VALUES
    (@p, @h, @sh, @name, @desc, @plat, @tech, @created, @lastmod, @by, @first, @last, @src, @count, @json);
'@ -Parameters @{
                p       = $policyId
                h       = $item.ContentHash
                sh      = $item.SourceContentHash
                name    = "$($snap.Name)"
                desc    = "$($snap.Description)"
                plat    = "$($snap.Platforms)"
                tech    = "$($snap.Technologies)"
                created = "$($snap.CreatedDateTime)"
                lastmod = "$($snap.LastModifiedDateTime)"
                by      = $modifiedBy
                first   = $item.RetrievedStr
                last    = $item.RetrievedStr
                src     = $item.SourceFile
                count   = [int]$item.Flat.Count
                json    = $settingsJson
            } | Out-Null

            $versionId = Get-LastInsertRowId

            # --- Settings rows -------------------------------------------------
            $ordinal = 0
            foreach ($s in $item.Flat) {
                Invoke-Db -Query 'INSERT INTO PolicySettings (VersionId, Ordinal, Path, Title, Value, RawValue) VALUES (@v, @o, @path, @title, @val, @raw);' `
                    -Parameters @{
                        v     = [int64]$versionId
                        o     = [int]$ordinal
                        path  = "$($s.Path)"
                        title = "$($s.Title)"
                        val   = "$($s.Value)"
                        raw   = "$($s.RawValue)"
                    } | Out-Null
                $ordinal++
            }

            # --- Assignment rows ----------------------------------------------
            foreach ($a in $item.Assignments) {
                if ($null -eq $a) { continue }
                $isExclude = if ($a.PSObject.Properties['IsExclude']) { [int][bool]$a.IsExclude } else { [int]("$($a.AssignmentType)" -eq 'exclusionGroupAssignmentTarget') }
                Invoke-Db -Query @'
INSERT INTO PolicyAssignments (VersionId, AssignmentType, IsExclude, GroupId, GroupName, FilterId, FilterName, FilterType)
VALUES (@v, @atype, @excl, @gid, @gname, @fid, @fname, @ftype);
'@ -Parameters @{
                    v     = [int64]$versionId
                    atype = "$($a.AssignmentType)"
                    excl  = $isExclude
                    gid   = "$($a.GroupId)"
                    gname = "$($a.GroupName)"
                    fid   = "$($a.FilterId)"
                    fname = "$($a.FilterName)"
                    ftype = "$($a.FilterType)"
                } | Out-Null
            }

            $versionsInserted++
        }

        # Keep the cached VersionCount per policy in sync.
        Invoke-Db -Query @'
UPDATE Policies SET VersionCount =
    (SELECT COUNT(*) FROM PolicyVersions WHERE PolicyVersions.PolicyId = Policies.PolicyId);
'@ | Out-Null

        Invoke-Db -Query 'COMMIT;' | Out-Null
    }
    catch {
        Invoke-Db -Query 'ROLLBACK;' | Out-Null
        throw
    }

    # Close out the provenance row.
    Invoke-Db -Query @'
UPDATE IngestRuns SET FinishedAt=@f, FilesSeen=@seen, FilesFailed=@failed,
    PoliciesUpserted=@pol, VersionsInserted=@ins, VersionsSkipped=@skip
WHERE RunId=@id;
'@ -Parameters @{
        f      = (Get-Date).ToString('o')
        seen   = $files.Count
        failed = $filesFailed
        pol    = $policiesTouched.Count
        ins    = $versionsInserted
        skip   = $versionsSkipped
        id     = $runId
    } | Out-Null

    # --- Summary -------------------------------------------------------------
    $totalPolicies = [int]((Invoke-Db -Query 'SELECT COUNT(*) AS N FROM Policies;').N)
    $totalVersions = [int]((Invoke-Db -Query 'SELECT COUNT(*) AS N FROM PolicyVersions;').N)

    Write-Host ''
    Write-Host 'Ingest summary:'
    Write-Host ("  Files read           : {0} ({1} failed/skipped)" -f $files.Count, $filesFailed)
    Write-Host ("  Policies upserted    : {0}" -f $policiesTouched.Count)
    Write-Host ("  New versions inserted: {0}" -f $versionsInserted)
    Write-Host ("  Versions skipped     : {0} (already present)" -f $versionsSkipped)
    Write-Host ("  DB now holds         : {0} polic{1}, {2} version(s)" -f $totalPolicies, $(if ($totalPolicies -eq 1) { 'y' } else { 'ies' }), $totalVersions)
    Write-Host "Database: $DatabasePath"
}
finally {
    if ($script:Conn) { $script:Conn.Close() }
}
