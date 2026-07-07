#requires -Version 5.1

<#
Export-PolicySummary.ps1

Reads the JSON policy snapshots produced by Backup-IntunePolicies.ps1 /
Get-IntuneSettingsCatalogSnapshot.ps1 and builds ONE Excel workbook, with ONE
ROW per policy, for a quick at-a-glance review: name, created, last modified,
which groups/filters it's assigned to, and which it's excluded from.

This is a single, self-contained file - nothing to dot-source. It does NOT
connect to Graph at all; it only reads JSON files already on disk (group and
filter names are already resolved inside those JSON files).

Because Backup-IntunePolicies.ps1 only writes a JSON file for a policy when
that policy actually changed, a single run's folder can be a partial picture.
So -JsonPath is searched RECURSIVELY for *.json files, and when the same
policy (by Id) appears more than once, the most recently retrieved one wins -
this gives a complete, current-as-of-now view whether you point it at one
run's timestamped folder or the whole json/ folder.

MODULES REQUIRED - this script does NOT import it for you. Import this
yourself first, once per PowerShell session, before running the script:

    Import-Module ImportExcel

Usage (run the .ps1 file directly, don't paste it line-by-line):
    .\Export-PolicySummary.ps1 -JsonPath .\output\json
    .\Export-PolicySummary.ps1 -JsonPath .\output\json\2026-07-08_143022
    .\Export-PolicySummary.ps1 -JsonPath .\output\json -OutputFile .\output\PolicySummary.xlsx
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JsonPath,

    [string]$OutputFile = '.\PolicySummary.xlsx'
)

$ErrorActionPreference = 'Stop'

function Format-AssignmentGroup {
    <# Same rendering as the per-policy workbook header: "Group [filter: Name/Type], ...". #>
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

if (-not (Test-Path $JsonPath)) {
    throw "Path not found: $JsonPath"
}

$files = @(Get-ChildItem -Path $JsonPath -Filter '*.json' -File -Recurse)
if ($files.Count -eq 0) {
    throw "No JSON files found under '$JsonPath' (searched recursively)."
}

Write-Host "Found $($files.Count) JSON file(s) under: $JsonPath"

# Keep only the most recently retrieved snapshot per policy Id.
$latestById = @{}

foreach ($file in $files) {
    try {
        $raw = Get-Content -Path $file.FullName -Raw
        $raw = $raw.TrimStart([char]0xFEFF)   # strip BOM if present
        $snapshot = $raw | ConvertFrom-Json

        $retrievedAt = $file.LastWriteTimeUtc
        if ($snapshot.RetrievedAt) {
            try { $retrievedAt = [datetime]$snapshot.RetrievedAt } catch { }
        }

        $existing = $latestById[$snapshot.Id]
        if (-not $existing -or $retrievedAt -gt $existing.RetrievedAtParsed) {
            $latestById[$snapshot.Id] = [pscustomobject]@{
                Snapshot         = $snapshot
                RetrievedAtParsed = $retrievedAt
            }
        }
    }
    catch {
        Write-Warning "Could not read '$($file.FullName)': $_"
    }
}

if ($latestById.Count -eq 0) {
    throw "None of the $($files.Count) JSON file(s) under '$JsonPath' could be read as a valid policy snapshot."
}

$rows = foreach ($entry in $latestById.Values) {
    $s = $entry.Snapshot
    [pscustomobject]@{
        'Policy Name'   = $s.Name
        'Created'       = $s.CreatedDateTime
        'Last Modified' = $s.LastModifiedDateTime
        'Assigned To'   = Format-AssignmentGroup -Assignments $s.Assignments
        'Excluded From' = Format-AssignmentGroup -Assignments $s.Assignments -Exclude
        'Policy Id'     = $s.Id
    }
}

if (Test-Path $OutputFile) { Remove-Item $OutputFile -Force }

$rows | Sort-Object 'Policy Name' | Export-Excel -Path $OutputFile -WorksheetName 'Policy Summary' `
    -TableName 'PolicySummary' -AutoSize -FreezeTopRow -BoldTopRow

Write-Host "Done. $($latestById.Count) unique polic$(if ($latestById.Count -eq 1) {'y'} else {'ies'}) written to: $OutputFile"
