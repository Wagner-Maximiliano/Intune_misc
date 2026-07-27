#requires -Version 5.1
<#
.SYNOPSIS
    Auto-generates a GPO-to-Policy-CSP mapping CSV for Test-MDMWinsOverGP.ps1
    from local ADMX/ADML files and the PolicyManager registry catalog.

.DESCRIPTION
    Test-MDMWinsOverGP.ps1 accepts an optional -MappingCsv of human-verified
    GPO-to-CSP mappings. Today that CSV has to be filled in by hand, so most
    runs fall back to weak name-similarity heuristics instead of high-
    confidence verified overlaps.

    This script builds a starting-point mapping CSV automatically, entirely
    from data that already exists on the local machine:

      Phase 1 - GPO catalog:
        Parses every *.admx file under -PolicyDefinitionsPath and resolves
        each policy's $(string.X) displayName reference against the
        matching *.adml file for -Language.

      Phase 2 - CSP catalog:
        Enumerates HKLM:\SOFTWARE\Microsoft\PolicyManager\default\<Area>\<Policy>,
        which lists every Policy CSP setting the running OS build knows
        about.

      Phase 3 - Join, with confidence tiers:
        For every ADMX policy, BOTH matching strategies below are attempted
        independently (this is not a short-circuiting waterfall), and the
        results are then reconciled:

          Registry-based match: the ADMX policy's registry valueName
          attribute is looked up against the value names actually captured
          under each CSP policy's HKLM:\...\PolicyManager\default\<Area>\<Policy>
          key in Phase 2. A match is accepted only when it is unambiguous
          (exactly one CSP policy exposes that value name); ambiguous or
          absent evidence yields no registry-based match for that policy.

          Name-based match: exact, case-insensitive match between the ADMX
          <policy name="..."> attribute and the CSP policy name.
          ADMX-backed CSP policies frequently share this internal name
          verbatim, so this is a strong signal on its own.

        Reconciliation (registry evidence always wins on conflict):
          - Both methods agree on the same Area/Policy -> Tier A,
            "corroborated" (the strongest possible result - both an
            independent registry-value signal and an exact name match
            point at the same CSP policy).
          - Both methods match, but disagree on Area/Policy -> Tier A,
            using the registry-based result as authoritative. The
            rejected name-based candidate is NOT discarded silently; it
            is recorded in Notes as a conflict for a human to adjudicate,
            and counted separately in the coverage summary.
          - Only the registry-based method matches -> Tier A ("registry-only").
          - Only the name-based method matches -> Tier B ("name-only").
          - Neither matches -> fall back to Tier C (weakest): normalized/
            fuzzy token-similarity between the resolved GPO display name
            and the CSP policy name. Review-only; never treat as verified.

      Phase 4 - Output:
        Writes a CSV with exactly the columns Test-MDMWinsOverGP.ps1 expects
        (GpoSetting,GpoName,CspArea,CspPolicy,OmaUri,Notes) plus a coverage
        summary. Optionally filters the output down to only the GPO settings
        that actually appear in a GPO-Settings.csv produced by a prior
        Test-MDMWinsOverGP.ps1 run.

    Important - intellectual honesty:
      There is no reliable machine-readable public documentation this
      environment can reach to validate ADMX-to-CSP mappings (learn.microsoft.com,
      raw.githubusercontent.com, and the GitHub API are all unreachable through
      this environment's proxy). This script therefore never invents or
      hardcodes a mapping. Every row it emits is derived from ADMX/ADML/registry
      data actually found on the machine it runs on, and is tagged with the
      tier and source evidence that produced it so a human can verify it.
      Real-world coverage (how many rows Tier A/B actually produce) is
      genuinely unknown until this runs on a real device - see README.md.

      Generated mappings are a STARTING POINT for human verification against
      Microsoft's Policy CSP documentation, not authoritative truth. Do not
      feed the Tier C output into Test-MDMWinsOverGP.ps1 as if it were
      verified; treat it exactly like the main script treats its own
      heuristic candidates.

.PARAMETER PolicyDefinitionsPath
    Folder containing the ADMX files to parse (and the per-language ADML
    subfolder). Defaults to the local Windows policy definitions store.

.PARAMETER Language
    ADML language subfolder under -PolicyDefinitionsPath used to resolve
    $(string.X) display name references. Defaults to en-US.

.PARAMETER OutputPath
    Path to write the full generated mapping CSV.

.PARAMETER GpoSettingsCsv
    Optional path to a GPO-Settings.csv produced by Test-MDMWinsOverGP.ps1.
    When supplied, a second CSV is written alongside -OutputPath containing
    only mapping rows whose GpoSetting matches a setting actually observed
    on this device, and the coverage summary reports how many of the
    device's real GPO settings received a mapping.

.PARAMETER IncludeUserScope
    By default only Machine-class (or Both-class) ADMX policies are mapped,
    and OMA-URIs are built under ./Device/Vendor/MSFT/Policy/Config. Pass
    this switch to also emit User-class policies under ./User/Vendor/MSFT/Policy/Config.
    Off by default because an admin account frequently cannot read another
    user's loaded GPO settings, making User-scope mappings hard to verify
    end-to-end on the same run.

.PARAMETER MinimumConfidence
    Controls which tiers are included in the output: 'A' (Tier A only),
    'B' (Tiers A and B), or 'C' (all tiers, including the weak fuzzy-match
    Tier C rows). Defaults to 'B' so the default output excludes the
    weakest, review-only matches. Tier C rows are always clearly marked
    in the Notes column regardless of this setting.

.PARAMETER SampleSize
    Optional. Limits ADMX parsing to the first N *.admx files (alphabetical)
    found under -PolicyDefinitionsPath. Intended for a fast smoke test of
    the script on a handful of files before running it against the full
    PolicyDefinitions store, which can contain several hundred ADMX files.

.EXAMPLE
    .\Build-PolicyMappings.ps1

.EXAMPLE
    .\Build-PolicyMappings.ps1 -SampleSize 20 -Verbose

.EXAMPLE
    .\Build-PolicyMappings.ps1 -GpoSettingsCsv 'C:\...\Reports\GPO-Settings.csv' -MinimumConfidence C
#>

[CmdletBinding()]
param(
    [string]$PolicyDefinitionsPath = "$env:SystemRoot\PolicyDefinitions",

    [string]$Language = 'en-US',

    [string]$OutputPath = "$env:PUBLIC\Documents\MDMWinsOverGP-Validation\PolicyMappings-Generated.csv",

    [string]$GpoSettingsCsv,

    [switch]$IncludeUserScope,

    [ValidateSet('A', 'B', 'C')]
    [string]$MinimumConfidence = 'B',

    [ValidateRange(1, 100000)]
    [int]$SampleSize
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Log {
    <#
        Same structured-logging convention as Test-MDMWinsOverGP.ps1: every
        message gets a timestamp and a severity level, color-coded on the
        console. This script is short-lived and does not write its own
        Log.txt (it has no evidence folder to anchor one to), but keeping
        the same format makes console output from both scripts consistent
        when they are run back to back.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Host $line }
    }
}

# Same normalization helper as Test-MDMWinsOverGP.ps1 (kept local rather than
# dot-sourcing the main script, since this script is meant to be runnable
# standalone). Lowercases, strips common policy-name verb prefixes, and
# removes all non-alphanumeric characters, for use in Tier B/C matching.
function Normalize-PolicyName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $normalized = $Text.ToLowerInvariant()
    $normalized = $normalized -replace '^(allow|enable|disable|configure|turnon|turnoff)', ''
    $normalized = $normalized -replace '[^a-z0-9]', ''
    return $normalized
}

# Same tokenizer as Test-MDMWinsOverGP.ps1, used for Tier C's Jaccard score.
function Get-TokenSet {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $expanded = $Text -creplace '([a-z])([A-Z])', '$1 $2'
    return @(
        ($expanded.ToLowerInvariant() -split '[\s_/\\.:()\[\]-]+') |
        Where-Object {
            $_.Length -gt 2 -and
            $_ -notin @('policy', 'setting', 'windows', 'microsoft', 'computer', 'user', 'configure')
        } |
        Sort-Object -Unique
    )
}

# Jaccard similarity (intersection / union) between two token sets, 0.0-1.0.
function Get-JaccardScore {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    # Under Set-StrictMode -Version 2, referencing .Count on a $null value
    # throws instead of quietly treating it as empty. Use boolean coercion
    # (-not) rather than .Count here - it is $true for both $null and an
    # empty array without ever touching a property.
    if (-not $Left -or -not $Right) { return 0 }

    $intersection = @($Left | Where-Object { $Right -contains $_ } | Sort-Object -Unique)
    $union = @($Left + $Right | Sort-Object -Unique)

    if ($union.Count -eq 0) { return 0 }
    return [math]::Round($intersection.Count / $union.Count, 3)
}

# Resolves a single ADMX attribute value that may be a literal string or a
# $(string.SomeId) reference into the ADML string table. Returns the raw
# value unchanged (rather than throwing or returning empty) when it is not
# a $(string.*) reference, and returns the raw reference text - never $null
# or an exception - when the referenced id cannot be found in $StringTable,
# so callers always get a usable display string even for a partially
# resolvable ADMX/ADML pair.
function Resolve-AdmlString {
    param(
        [string]$Value,
        [hashtable]$StringTable
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    if ($Value -match '^\$\(string\.(?<id>[^)]+)\)$') {
        $id = $Matches['id']
        if ($StringTable.ContainsKey($id)) {
            return $StringTable[$id]
        }
        # Unresolvable reference (missing ADML, id not present in this
        # language's string table, etc.) - fall back to the raw reference
        # text so the row still carries a usable, if unfriendly, label
        # instead of being dropped.
        return $Value
    }

    return $Value
}

# Loads <basename>.adml next to an ADMX file's language folder into a simple
# id -> text hashtable. Returns an empty hashtable (never throws) when the
# ADML file is missing or unparsable, so a single bad/missing translation
# file only degrades display-name resolution for that one ADMX rather than
# aborting the run.
function Import-AdmlStringTable {
    param([Parameter(Mandatory)][string]$AdmlPath)

    $table = @{}

    if (-not (Test-Path -LiteralPath $AdmlPath)) {
        return $table
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $AdmlPath -Raw
    }
    catch {
        Write-Log -Level WARN -Message "Could not parse ADML file '$AdmlPath'. $($_.Exception.Message)"
        return $table
    }

    # ADML files declare an XML namespace (xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions"),
    # which means an un-namespaced XPath like "//string" matches nothing.
    # Use local-name() so this works regardless of namespace prefix/URI,
    # the same approach Test-MDMWinsOverGP.ps1 uses in Get-FirstNodeText.
    $stringNodes = $xml.SelectNodes("//*[local-name()='string']")
    foreach ($node in $stringNodes) {
        $id = $node.Attributes['id']
        if ($id -and -not $table.ContainsKey($id.Value)) {
            $table[$id.Value] = $node.InnerText.Trim()
        }
    }

    return $table
}

# Parses a single ADMX file into a flat array of policy rows. Returns an
# empty array (never throws) on malformed XML so one bad ADMX cannot abort
# the whole catalog build; the caller logs the failure and moves on.
function Get-AdmxPolicies {
    param(
        [Parameter(Mandatory)][string]$AdmxPath,
        [Parameter(Mandatory)][string]$AdmlPath
    )

    $rows = New-Object System.Collections.Generic.List[object]

    try {
        [xml]$xml = Get-Content -LiteralPath $AdmxPath -Raw
    }
    catch {
        Write-Log -Level WARN -Message "Could not parse ADMX file '$AdmxPath'. $($_.Exception.Message)"
        return @()
    }

    $stringTable = Import-AdmlStringTable -AdmlPath $AdmlPath

    # ADMX files declare the PolicyDefinitions XML namespace on the root
    # element, so an un-namespaced "//policy" XPath matches nothing. Use
    # local-name() throughout, matching Get-FirstNodeText's approach in
    # Test-MDMWinsOverGP.ps1, instead of building a namespace manager -
    # this file is much smaller/flatter than GPResult XML, so a simple
    # local-name() XPath is sufficient and keeps this function self-contained.
    $policyNodes = $xml.SelectNodes("//*[local-name()='policy']")

    foreach ($node in $policyNodes) {
        try {
            $name = ''
            if ($node.Attributes['name']) { $name = $node.Attributes['name'].Value }

            if ([string]::IsNullOrWhiteSpace($name)) {
                # A <policy> element without a name attribute is malformed/unusable
                # as a join key; skip just this element rather than the whole file.
                continue
            }

            $class = 'Unknown'
            if ($node.Attributes['class']) { $class = $node.Attributes['class'].Value }

            $key = ''
            if ($node.Attributes['key']) { $key = $node.Attributes['key'].Value }

            $valueName = ''
            if ($node.Attributes['valueName']) { $valueName = $node.Attributes['valueName'].Value }

            $rawDisplayName = ''
            if ($node.Attributes['displayName']) { $rawDisplayName = $node.Attributes['displayName'].Value }
            $displayName = Resolve-AdmlString -Value $rawDisplayName -StringTable $stringTable

            $parentCategory = ''
            $parentCategoryNode = $node.SelectSingleNode("./*[local-name()='parentCategory']")
            if ($parentCategoryNode -and $parentCategoryNode.Attributes['ref']) {
                $parentCategory = $parentCategoryNode.Attributes['ref'].Value
            }

            $rows.Add([pscustomobject]@{
                AdmxFile       = [System.IO.Path]::GetFileName($AdmxPath)
                AdmxName       = $name
                Class          = $class
                RegistryKey    = $key
                RegistryValue  = $valueName
                DisplayName    = $displayName
                ParentCategory = $parentCategory
                NormalizedName = Normalize-PolicyName $displayName
                Tokens         = Get-TokenSet $displayName
            })
        }
        catch {
            # A single malformed <policy> element (missing expected structure,
            # unexpected attribute types, etc.) must not stop the rest of the
            # file from being processed.
            Write-Log -Level WARN -Message "Could not process a <policy> element in '$AdmxPath'. $($_.Exception.Message)"
        }
    }

    return $rows.ToArray()
}

# Builds the full GPO/ADMX catalog by enumerating every *.admx file under
# -Path and parsing each with Get-AdmxPolicies. A per-file try/catch keeps a
# single unreadable/malformed file from aborting catalog construction for
# every other file.
function Get-AdmxCatalog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Language,
        [int]$SampleSize
    )

    $catalog = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log -Level WARN -Message "PolicyDefinitions path '$Path' does not exist. The GPO catalog will be empty."
        return @()
    }

    $admxFiles = @(Get-ChildItem -LiteralPath $Path -Filter '*.admx' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    if (-not $admxFiles -or $admxFiles.Count -eq 0) {
        Write-Log -Level WARN -Message "No *.admx files found under '$Path'. The GPO catalog will be empty."
        return @()
    }

    if ($SampleSize -and $admxFiles.Count -gt $SampleSize) {
        Write-Log -Message "SampleSize $SampleSize specified: parsing the first $SampleSize of $($admxFiles.Count) ADMX file(s) found."
        $admxFiles = @($admxFiles | Select-Object -First $SampleSize)
    }

    $admlFolder = Join-Path $Path $Language

    foreach ($admxFile in $admxFiles) {
        try {
            $admlPath = Join-Path $admlFolder ([System.IO.Path]::GetFileNameWithoutExtension($admxFile.Name) + '.adml')
            $policies = Get-AdmxPolicies -AdmxPath $admxFile.FullName -AdmlPath $admlPath
            foreach ($p in $policies) { $catalog.Add($p) }
        }
        catch {
            # Belt-and-suspenders: Get-AdmxPolicies already catches its own
            # parse errors, but nothing here should be able to take down the
            # whole catalog build regardless of what fails.
            Write-Log -Level WARN -Message "Unexpected error processing '$($admxFile.FullName)'. Skipping this file. $($_.Exception.Message)"
        }
    }

    return $catalog.ToArray()
}

# Enumerates HKLM:\SOFTWARE\Microsoft\PolicyManager\default\<Area>\<Policy>,
# which lists every Policy CSP setting the running OS build/edition knows
# about (independent of whether it is currently configured). Returns an
# empty array - and logs a warning, not an error - when the key is missing
# or unreadable, so the script still produces a (Tier-A/B-empty) GPO-only
# catalog rather than aborting; a missing PolicyManager\default key most
# often means this is being run on a non-Windows-10/11 or heavily locked
# down system, not a script bug.
function Get-CspCatalog {
    $basePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default'
    $rows = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $basePath)) {
        Write-Log -Level WARN -Message "Registry path '$basePath' not found. The CSP catalog will be empty (no rows can be generated beyond a GPO-only catalog)."
        return @()
    }

    try {
        $areaKeys = @(Get-ChildItem -LiteralPath $basePath -ErrorAction Stop)
    }
    catch {
        Write-Log -Level WARN -Message "Could not enumerate '$basePath'. The CSP catalog will be empty. $($_.Exception.Message)"
        return @()
    }

    foreach ($areaKey in $areaKeys) {
        $area = $areaKey.PSChildName

        try {
            $policyKeys = @(Get-ChildItem -LiteralPath $areaKey.PSPath -ErrorAction Stop)
        }
        catch {
            Write-Log -Level WARN -Message "Could not enumerate policies under area '$area'. Skipping this area. $($_.Exception.Message)"
            continue
        }

        foreach ($policyKey in $policyKeys) {
            $policy = $policyKey.PSChildName

            # Capture whatever value data is present under this policy's key
            # (e.g. a default value) as extra join evidence for Tier A, but
            # tolerate it being absent - the Area/Policy name pair alone is
            # enough to build the catalog entry and OMA-URI.
            $regValueNames = @()
            try {
                $regValueNames = @($policyKey.GetValueNames())
            }
            catch {
                Write-Verbose "Could not read value names under '$($policyKey.PSPath)': $($_.Exception.Message)"
            }

            $rows.Add([pscustomobject]@{
                Area           = $area
                Policy         = $policy
                RegistryPath   = $policyKey.Name
                ValueNames     = $regValueNames
                NormalizedName = Normalize-PolicyName $policy
                Tokens         = Get-TokenSet $policy
            })
        }
    }

    return $rows.ToArray()
}

# Builds the OMA-URI a Policy CSP setting would use for the given scope.
function New-OmaUri {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Policy,
        [ValidateSet('Device', 'User')][string]$Scope = 'Device'
    )

    return "./$Scope/Vendor/MSFT/Policy/Config/$Area/$Policy"
}

# Phase 3: joins the ADMX catalog to the CSP catalog and produces mapping
# rows tagged with the confidence tier and match category that produced
# them. Only a single row is kept per ADMX policy.
#
# Registry-based matching and name-based matching are run INDEPENDENTLY for
# every ADMX policy (this is not a short-circuiting waterfall) and then
# reconciled, per the join-logic clarification: registry evidence is more
# reliable than name similarity, so it always wins on conflict, but a name
# match is never silently thrown away - a rejected candidate is recorded in
# Notes and counted separately so a human can see the disagreement.
function Get-MappingRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AdmxCatalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CspCatalog,
        [switch]$IncludeUserScope,
        [ValidateSet('A', 'B', 'C')][string]$MinimumConfidence = 'B'
    )

    $tierRank = @{ A = 3; B = 2; C = 1 }
    $minRank = $tierRank[$MinimumConfidence]

    $results = New-Object System.Collections.Generic.List[object]

    if (-not $CspCatalog -or $CspCatalog.Count -eq 0) {
        # No CSP data at all (registry unreadable/missing) - nothing to join
        # against. Returning early here (rather than falling through with an
        # empty inner loop) makes this explicit in the log rather than silent.
        Write-Log -Level WARN -Message 'CSP catalog is empty; no mapping rows can be produced.'
        return @()
    }

    foreach ($admx in $AdmxCatalog) {
        # Scope filtering: default is Machine-only. 'Both'-class ADMX
        # policies are valid under either scope, so they are always
        # considered; 'User'-class policies are only considered when
        # -IncludeUserScope is set, per the design note in the header
        # comment (an admin account frequently cannot see another user's
        # applied GPO settings, so User-scope rows are harder to verify).
        $scope = 'Device'
        if ($admx.Class -eq 'User') {
            if (-not $IncludeUserScope) { continue }
            $scope = 'User'
        }
        elseif ($admx.Class -ne 'Machine' -and $admx.Class -ne 'Both') {
            # Unrecognized/blank class - treat conservatively as Machine scope
            # rather than silently dropping the row.
            $scope = 'Device'
        }

        if ([string]::IsNullOrWhiteSpace($admx.DisplayName)) {
            # Nothing usable to put in GpoSetting (the column
            # Test-MDMWinsOverGP.ps1 actually matches against) - skip.
            continue
        }

        # --- Registry-based match --------------------------------------------
        # The PolicyManager\default registry tree does not expose an explicit,
        # documented "this CSP policy is backed by this GP registry key" link,
        # so there is no way to compare $admx.RegistryKey directly. The one
        # real, locally-observable signal available is weaker but genuine:
        # whether the ADMX policy's registry valueName (e.g. "Enabled",
        # "MaxSize") also appears as a value name captured under a CSP
        # policy's own PolicyManager\default\<Area>\<Policy> key in Phase 2.
        # This is accepted as a match only when it is UNAMBIGUOUS - i.e.
        # exactly one CSP policy in the whole catalog exposes that value
        # name - because common value names (e.g. "Enabled") appear under
        # many unrelated CSP policies and would otherwise produce false
        # positives. Ambiguous or absent evidence yields no registry match,
        # which is an expected, common outcome, not a bug.
        $registryMatch = $null
        if (-not [string]::IsNullOrWhiteSpace($admx.RegistryValue)) {
            $candidates = @(
                $CspCatalog | Where-Object {
                    $_.ValueNames -and ($_.ValueNames -contains $admx.RegistryValue)
                }
            )
            if ($candidates.Count -eq 1) {
                $registryMatch = $candidates[0]
            }
        }

        # --- Name-based match -------------------------------------------------
        # Exact, case-insensitive match between the ADMX <policy name="...">
        # attribute and the CSP policy name (PowerShell -eq on strings is
        # already ordinal case-insensitive by default).
        $nameMatch = $null
        $exactCsp = @($CspCatalog | Where-Object { $_.Policy -eq $admx.AdmxName })
        if ($exactCsp.Count -gt 0) {
            $nameMatch = $exactCsp[0]
        }

        # --- Reconcile the two independent signals -----------------------------
        $bestTier = $null
        $bestCsp = $null
        $bestNotes = ''

        if ($registryMatch -and $nameMatch) {
            if ($registryMatch.Area -eq $nameMatch.Area -and $registryMatch.Policy -eq $nameMatch.Policy) {
                # Strongest possible result: an independent registry-value
                # signal and an exact name match both point at the same CSP
                # policy.
                $bestTier = 'A'
                $bestCsp = $registryMatch
                $bestNotes = "Tier A (corroborated): registry value name '$($admx.RegistryValue)' and exact ADMX/CSP name match both point to '$($bestCsp.Area)/$($bestCsp.Policy)'."
            }
            else {
                # Conflict: the two signals disagree. Registry evidence is
                # the more reliable signal and wins, but the rejected
                # name-based candidate is preserved in Notes rather than
                # discarded, so a human reviewer can see and adjudicate the
                # disagreement.
                $bestTier = 'A'
                $bestCsp = $registryMatch
                $bestNotes = "Tier A (registry match preferred over conflicting name match): registry value name '$($admx.RegistryValue)' matched '$($registryMatch.Area)/$($registryMatch.Policy)'; exact name match instead pointed to '$($nameMatch.Area)/$($nameMatch.Policy)', which was rejected in favor of the registry-based result."
            }
        }
        elseif ($registryMatch) {
            $bestTier = 'A'
            $bestCsp = $registryMatch
            $bestNotes = "Tier A (registry-only): registry value name '$($admx.RegistryValue)' unambiguously matched CSP policy '$($bestCsp.Area)/$($bestCsp.Policy)'. No corroborating name match was found."
        }
        elseif ($nameMatch) {
            $bestTier = 'B'
            $bestCsp = $nameMatch
            $bestNotes = "Tier B (name-only): exact match between ADMX policy name '$($admx.AdmxName)' and CSP policy name '$($bestCsp.Policy)'. No registry-value corroboration was found."
        }

        # --- Tier C: fuzzy/normalized name similarity (review only) ------------
        # Only attempted as a fallback when neither the registry-based nor the
        # name-based method produced a match.
        if (-not $bestTier -and $minRank -le $tierRank['C']) {
            $best = $null
            $bestScore = 0.0
            $admxTokens = if ($admx.Tokens) { $admx.Tokens } else { Get-TokenSet $admx.DisplayName }

            foreach ($csp in $CspCatalog) {
                $score = 0.0
                if ($admx.NormalizedName -and $admx.NormalizedName -eq $csp.NormalizedName) {
                    $score = 0.9
                }
                else {
                    $score = Get-JaccardScore -Left $admxTokens -Right $csp.Tokens
                }

                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $best = $csp
                }
            }

            # 0.5 mirrors Test-MDMWinsOverGP.ps1's default heuristic threshold
            # (Get-HeuristicOverlapRows -MinimumScore), kept consistent so
            # "weak match" means the same thing in both scripts.
            if ($best -and $bestScore -ge 0.5) {
                $bestTier = 'C'
                $bestCsp = $best
                $bestNotes = "Tier C (REVIEW ONLY - not verified): fuzzy name similarity score $bestScore between ADMX display name '$($admx.DisplayName)' and CSP policy '$($best.Policy)'."
            }
        }

        if (-not $bestTier -or $tierRank[$bestTier] -lt $minRank) {
            continue
        }

        $registryNote = if ($admx.RegistryKey) {
            "ADMX registry key: '$($admx.RegistryKey)'" + $(if ($admx.RegistryValue) { ", value '$($admx.RegistryValue)'." } else { '.' })
        }
        else { '' }

        $sourceNote = "Source ADMX: $($admx.AdmxFile); ADMX policy name: $($admx.AdmxName)."

        # MatchCategory is script-internal bookkeeping for the coverage
        # summary (BothAgree / Conflict / RegistryOnly / NameOnly / Fuzzy);
        # it is not part of the CSV schema, but every fact it represents is
        # already spelled out in Notes for anyone reading the CSV directly.
        $matchCategory =
            if ($registryMatch -and $nameMatch -and $registryMatch.Area -eq $nameMatch.Area -and $registryMatch.Policy -eq $nameMatch.Policy) { 'BothAgree' }
            elseif ($registryMatch -and $nameMatch) { 'Conflict' }
            elseif ($registryMatch) { 'RegistryOnly' }
            elseif ($nameMatch) { 'NameOnly' }
            else { 'Fuzzy' }

        $results.Add([pscustomobject]@{
            GpoSetting     = $admx.DisplayName
            GpoName        = ''
            CspArea        = $bestCsp.Area
            CspPolicy      = $bestCsp.Policy
            OmaUri         = New-OmaUri -Area $bestCsp.Area -Policy $bestCsp.Policy -Scope $scope
            Notes          = (@($bestNotes, $sourceNote, $registryNote) | Where-Object { $_ }) -join ' '
            Tier           = $bestTier
            MatchCategory  = $matchCategory
        })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Log -Message 'Building GPO-to-Policy-CSP mapping catalog from local ADMX/ADML and registry data.'
Write-Log -Message "PolicyDefinitions path: $PolicyDefinitionsPath (Language: $Language)"

Write-Log -Message 'Phase 1: parsing ADMX/ADML files...'
$admxCatalog = @(Get-AdmxCatalog -Path $PolicyDefinitionsPath -Language $Language -SampleSize $SampleSize)
Write-Log -Message "Parsed $($admxCatalog.Count) ADMX policy definition(s)."

Write-Log -Message 'Phase 2: reading the PolicyManager CSP catalog from the registry...'
$cspCatalog = @(Get-CspCatalog)
Write-Log -Message "Found $($cspCatalog.Count) CSP policy definition(s) under HKLM:\SOFTWARE\Microsoft\PolicyManager\default."

Write-Log -Message 'Phase 3: joining ADMX policies to CSP policies...'
$mappingRows = @(Get-MappingRows -AdmxCatalog $admxCatalog -CspCatalog $cspCatalog -IncludeUserScope:$IncludeUserScope -MinimumConfidence $MinimumConfidence)

$tierACount = @($mappingRows | Where-Object { $_.Tier -eq 'A' }).Count
$tierBCount = @($mappingRows | Where-Object { $_.Tier -eq 'B' }).Count
$tierCCount = @($mappingRows | Where-Object { $_.Tier -eq 'C' }).Count

# Match-category breakdown within Tier A/B: how often the registry-based and
# name-based signals actually corroborated each other on this machine versus
# only one of them firing, and how often they disagreed outright (registry
# wins on disagreement - see Get-MappingRows). This is the concrete answer to
# "how much do the two signals actually agree in practice", which is not
# knowable ahead of a real run.
$bothAgreeCount    = @($mappingRows | Where-Object { $_.MatchCategory -eq 'BothAgree' }).Count
$conflictCount     = @($mappingRows | Where-Object { $_.MatchCategory -eq 'Conflict' }).Count
$registryOnlyCount = @($mappingRows | Where-Object { $_.MatchCategory -eq 'RegistryOnly' }).Count
$nameOnlyCount     = @($mappingRows | Where-Object { $_.MatchCategory -eq 'NameOnly' }).Count

$mappedCspCount = @($mappingRows | Select-Object -Property CspArea, CspPolicy -Unique).Count
$cspCoveragePct = if ($cspCatalog.Count -gt 0) {
    [math]::Round(100.0 * $mappedCspCount / $cspCatalog.Count, 1)
}
else { 0 }

Write-Log -Message '--- Coverage summary --------------------------------------------'
Write-Log -Message "ADMX policies parsed:            $($admxCatalog.Count)"
Write-Log -Message "CSP policies found:              $($cspCatalog.Count)"
Write-Log -Message "Tier A rows (registry-based):    $tierACount"
Write-Log -Message "  - both methods agreed:         $bothAgreeCount"
Write-Log -Message "  - registry-only match:         $registryOnlyCount"
Write-Log -Message "  - registry overrode a conflicting name match: $conflictCount"
Write-Log -Message "Tier B rows (name-only match):   $tierBCount"
Write-Log -Message "Tier C rows (fuzzy, review only): $tierCCount"
Write-Log -Message "Total mapping rows:              $($mappingRows.Count)"
Write-Log -Message "Distinct CSP policies mapped:     $mappedCspCount of $($cspCatalog.Count) ($cspCoveragePct%)"
Write-Log -Message '-------------------------------------------------------------------'

if ($conflictCount -gt 0) {
    Write-Log -Level WARN -Message "$conflictCount row(s) had a registry-based match that disagreed with the name-based match. Review these rows' Notes column closely before trusting them - see the 'registry match preferred over conflicting name match' text."
}

if ($mappingRows.Count -eq 0) {
    Write-Log -Level WARN -Message 'No mapping rows were produced. This can legitimately happen if the ADMX or CSP catalog was empty, or if MinimumConfidence excluded every candidate match. Check the coverage summary above.'
}

# Emit only the exact schema columns Test-MDMWinsOverGP.ps1's -MappingCsv
# expects (GpoSetting,GpoName,CspArea,CspPolicy,OmaUri,Notes). Tier is
# script-internal bookkeeping, not part of that schema, but its detail is
# preserved in Notes for every row so nothing is lost from the CSV itself.
# The @() wrapper is load-bearing, not cosmetic: piping an empty $mappingRows
# through Select-Object emits nothing, which leaves $outputRows as $null, and
# the .Count access below would then throw PropertyNotFoundStrict under
# Set-StrictMode -Version 2. An empty result is a legitimate outcome here (see
# the warning above), so it must not crash the run.
$outputRows = @($mappingRows | Select-Object GpoSetting, GpoName, CspArea, CspPolicy, OmaUri, Notes)

$outputDir = Split-Path -Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputRows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
Write-Log -Message "Wrote $($outputRows.Count) mapping row(s) to '$OutputPath'."

if (-not [string]::IsNullOrWhiteSpace($GpoSettingsCsv)) {
    if (-not (Test-Path -LiteralPath $GpoSettingsCsv)) {
        Write-Log -Level WARN -Message "GpoSettingsCsv path '$GpoSettingsCsv' not found. Skipping the filtered mapping output."
    }
    else {
        try {
            $deviceGpoRows = @(Import-Csv -LiteralPath $GpoSettingsCsv)
        }
        catch {
            Write-Log -Level WARN -Message "Could not read '$GpoSettingsCsv'. Skipping the filtered mapping output. $($_.Exception.Message)"
            $deviceGpoRows = @()
        }

        if ($deviceGpoRows.Count -gt 0) {
            # Build a normalized-name lookup set of the GPO settings actually
            # observed on this device, then keep only mapping rows whose
            # GpoSetting matches one of them (case/format-insensitively, via
            # the same Normalize-PolicyName used elsewhere in this toolkit).
            $deviceNormalizedNames = @(
                $deviceGpoRows |
                ForEach-Object { Normalize-PolicyName $_.GpoSetting } |
                Where-Object { $_ } |
                Sort-Object -Unique
            )

            $filteredRows = @(
                $outputRows | Where-Object {
                    $deviceNormalizedNames -contains (Normalize-PolicyName $_.GpoSetting)
                }
            )

            $filteredPath = [System.IO.Path]::Combine(
                (Split-Path -Path $OutputPath -Parent),
                ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath) + '-Filtered.csv')
            )

            $filteredRows | Export-Csv -LiteralPath $filteredPath -NoTypeInformation -Encoding UTF8

            $distinctDeviceSettings = @($deviceGpoRows | Select-Object -Property GpoSetting -Unique).Count
            $matchedDeviceSettings = @(
                $deviceNormalizedNames | Where-Object {
                    $name = $_
                    @($outputRows | Where-Object { (Normalize-PolicyName $_.GpoSetting) -eq $name }).Count -gt 0
                }
            ).Count

            Write-Log -Message "Filtered mapping CSV written to '$filteredPath' ($($filteredRows.Count) row(s))."
            Write-Log -Message "$matchedDeviceSettings of $distinctDeviceSettings distinct GPO setting(s) observed on this device received a generated mapping."
        }
        else {
            Write-Log -Level WARN -Message "'$GpoSettingsCsv' contained no rows. Skipping the filtered mapping output."
        }
    }
}

Write-Log -Message 'Done. Review every row before using this CSV with Test-MDMWinsOverGP.ps1 -MappingCsv - see README.md for what each confidence tier means and why this is a starting point, not authoritative data.'
