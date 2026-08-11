<#
Continuum.Core

The shared foundation both Continuum toolsets build on. Issue #15, first
slice - see docs/DECISIONS.md D-018 for what was moved, what was deliberately
left behind, and why.

WHAT IS IN HERE
---------------
Only functions that were genuinely DUPLICATED across scripts/ and that are
self-contained: they read no script-level state and call nothing that differs
between their former homes. Every body below was moved VERBATIM out of
scripts/Backup-IntunePolicies.ps1 - same logic, same parameter attributes,
including the [AllowNull()] / [AllowEmptyCollection()] decorations that are
load-bearing (docs/REVIEW-PHASE0.md R-03, R-13). Nothing was "tidied" on the
way in: a behaviour-preserving move is only checkable if it is actually a move.

WHAT IS DELIBERATELY NOT IN HERE
--------------------------------
The setting-definition and name-resolution family - Add-SettingDefinitionToCache,
Get-SettingDefinition, Resolve-SettingTitle, Resolve-ChoiceValue,
ConvertTo-FlatSettings, Get-GroupDisplayName, Get-AssignmentFilterName and
Resolve-Assignment - is still duplicated in scripts/. Two things have to be
designed before it can move, and neither is a mechanical edit:

  1. Those functions read hashtables ($DefinitionCache, $GroupNameCache,
     $FilterNameCache) that their scripts declare at file scope. A module
     function cannot see its caller's script scope, so the caches need an
     owner - either this module holds them, or they are passed in.
  2. Get-SettingDefinition is NOT the same function in both scripts, on
     purpose: Backup-IntunePolicies.ps1 fetches from Graph, while
     Import-PolicyHistoryToDatabase.ps1 is offline by design and always
     returns $null. Collapsing them needs an injected resolver, not a merge.

Until that is designed, the parity tests in tests/ are what keep those copies
honest. Do not "finish the job" by merging them without reading D-018.

STRICTMODE
----------
This module deliberately sets none, matching scripts/ - the code in here came
from those files and must behave identically now that it lives elsewhere
(docs/REVIEW-PHASE0.md R-01). When R-11 turns StrictMode on in scripts/, turn
it on here in the same change.
#>

# ---------------------------------------------------------------------------
# File I/O (BOM-free, so 5.1's Set-Content -Encoding utf8 quirk never breaks a
# later ConvertFrom-Json read-back)
# ---------------------------------------------------------------------------

function Write-TextFile {
    <# Writes UTF-8 WITHOUT a BOM (5.1's Set-Content -Encoding utf8 adds one). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function ConvertFrom-JsonFile {
    <# Reads a JSON file, stripping a leading BOM if present (5.1's
       Set-Content -Encoding utf8 adds one, which breaks ConvertFrom-Json). #>
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Graph plumbing
# ---------------------------------------------------------------------------

function Get-MgGraphAllPages {
    <#
        Pages through a Graph collection, retrying on 429 / transient 5xx.

        Returns a List[object], which PowerShell enumerates on output - so an
        empty collection arrives at the call site as AutomationNull, not as an
        empty array. Every caller must therefore wrap the call in @(...).
        That wrapper is load-bearing and is what keeps an empty result
        serialising as [] rather than null (docs/DECISIONS.md D-017).

        UNVERIFIED, carried over unchanged: the retry test assumes an
        Invoke-WebRequest-shaped exception. If Invoke-MgGraphRequest throws a
        different shape, $isTransient is always false and the retry never runs
        (docs/PROJECT_STATUS.md known issue #10, R-07).
    #>
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

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

# ---------------------------------------------------------------------------
# Hashing - a policy's identity
# ---------------------------------------------------------------------------

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
        Stable hash over flattened settings + assignments - NOT display names,
        so a Microsoft-side rename doesn't create a spurious version.

        THIS FUNCTION DEFINES A STORED IDENTITY. Its canonical form is written
        into the history database and compared across runs and across tools, so
        any change to the string it builds re-versions every affected policy on
        the next ingest. That is exactly why the open finding R-15 has not been
        fixed here: the one-line change is the user's call, not an agent's
        (docs/REVIEW-PHASE0.md R-15, docs/DECISIONS.md D-011). A -Skip'ped test
        in tests/ImportDatabase.Functions.Tests.ps1 asserts the fixed behaviour.

        Note that R-15's disagreement lives at the CALL SITES, not in here: the
        two former copies of this function were byte-identical in body. Moving
        it therefore changes no hash.
    #>
    # AllowNull/AllowEmptyCollection is load-bearing: ConvertTo-FlatSettings
    # returns a List[object], PowerShell enumerates an IEnumerable on output,
    # so a policy with no settings makes the caller's $flat $null - and a bare
    # Mandatory parameter rejects that at bind time, before the body runs.
    # Fixing only ConvertTo-FlatSettings moved the crash one line down
    # (docs/REVIEW-PHASE0.md R-13).
    # The body tolerates $null: piping it yields a single canonical '=' line,
    # so an empty policy still hashes deterministically and the two tools agree.
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$FlatSettings, $Assignments)

    $settingLines = @($FlatSettings | ForEach-Object { "$($_.Path)=$($_.RawValue)" } | Sort-Object)
    $assignLines  = @(@($Assignments) | ForEach-Object { "$($_.AssignmentType)|$($_.GroupId)|$($_.FilterId)|$($_.FilterType)" } | Sort-Object)
    $canonical = ($settingLines -join "`n") + "`n##ASSIGNMENTS##`n" + ($assignLines -join "`n")
    return Get-StringSha256 -Text $canonical
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Format-AssignmentList {
    <#
        Renders resolved assignments as "GroupName [filter: FilterName/Type], ...".

        This replaces three copies: Backup-IntunePolicies.ps1's and
        Restore-IntunePolicy.ps1's Format-AssignmentList, and
        Export-PolicySummary.ps1's Format-AssignmentGroup - the same body under
        a different name, which is why a parity test was needed to notice if
        they drifted. One function needs no parity test.
    #>
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

Export-ModuleMember -Function @(
    'Write-TextFile'
    'ConvertFrom-JsonFile'
    'Get-MgGraphAllPages'
    'Get-SafeFileName'
    'Get-StringSha256'
    'Get-PolicyContentHash'
    'Format-AssignmentList'
)
