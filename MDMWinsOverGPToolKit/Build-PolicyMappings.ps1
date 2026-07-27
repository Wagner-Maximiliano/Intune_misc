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
        about. NOTE: this "default" registry tree only ever stores each
        CSP policy's out-of-box default value - it carries no GPO-equivalence
        metadata of any kind. It is used below purely as a name catalog
        (Tier B), never as registry-match evidence.

      Phase 3 - Device corroboration evidence (live registry, always
        attempted unless -SkipDeviceCorroboration is passed):
        Reads two live registry sources directly from the device this
        script is running on - no CSV import, no internet:
          - Classic GPO registry evidence: every value actually present
            under HKLM:\SOFTWARE\Policies and
            HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies.
          - Live MDM PolicyManager evidence: every value actually present
            under HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device,
            paired with its companion "<Value>_WinningProvider" value
            where present.
        Both reads are non-fatal: an unreadable/missing key is logged as a
        WARN and treated as an empty evidence set rather than aborting the
        run.

      Phase 4 - Join, with confidence tiers:
        For every ADMX policy, a name-based match is attempted against the
        CSP catalog: exact, case-insensitive match between the ADMX
        <policy name="..."> attribute and the CSP policy name.
        ADMX-backed CSP policies frequently share this internal name
        verbatim, so this is a strong signal on its own -> Tier B.

        Every Tier B match is then checked against the live device
        corroboration evidence from Phase 3:
          - GpoConfigured: is the ADMX policy's OWN declared key/valueName
            (from Phase 1) present, with an actual value, in the classic
            GPO registry evidence?
          - MdmConfigured: is the matched CSP policy's Area/Policy present,
            with an actual value, in the live MDM PolicyManager evidence?
        If BOTH are true, this is live, on-device proof that the two
        settings are the same enforced thing right now, and the row is
        promoted to Tier A (device-corroborated) via the "both-sides-
        configured" path - the strongest possible result this script can
        produce, because it is not just a name match, it is two independent
        pieces of evidence that are both currently true on this machine.

        A SECOND, independent promotion path also exists: when GpoConfigured
        is false but MdmConfigured is true AND the matched CSP policy's
        companion _WinningProvider value indicates MDM currently owns it,
        the row is ALSO promoted to Tier A. This exists because the two
        signals are not symmetric once MDMWinsOverGP actually does its job:
        when MDM wins a genuine conflict, Windows blocks the Group Policy
        engine from writing its registry value at all, so GpoConfigured
        becomes FALSE precisely because the conflict was resolved in MDM's
        favor - the "both configured" rule would then never fire for the
        exact case it exists to detect. A live _WinningProvider=MDM value on
        an on-device-effective CSP policy is suggestive of a resolved
        conflict, but on its own it is not proof the GPO side ever targeted
        this exact setting (that is only proof for the both-sides-configured
        path, where the GPO registry value is independently observed). Rows
        promoted via this path are tagged distinctly in Notes and counted
        separately in the coverage summary so this distinction is never
        blurred with the stronger both-sides-configured evidence.

        This can only corroborate the subset of ADMX policies that are
        actually GPO-configured or MDM-winning-and-effective on THIS device
        right now; most Tier B rows will simply stay Tier B, which is
        expected, not a failure.

        If neither strategy matches at all, fall back to Tier C (weakest):
        normalized/fuzzy token-similarity between the resolved GPO display
        name and the CSP policy name. Review-only; never treat as verified.

        (Earlier revisions of this script also attempted a registry-based
        match by comparing an ADMX valueName against value names captured
        under PolicyManager\default in Phase 2. That path was removed: the
        "default" hive only ever holds out-of-box default values, so that
        comparison was structurally incapable of ever matching anything -
        confirmed with 0 matches out of 3,549 ADMX policies on a real
        device. Phase 3/4's live PolicyManager\current\device-based
        corroboration replaces it with a signal that is actually meaningful.)

      Phase 5 - Output:
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

    Central deployment:
      Like Test-MDMWinsOverGP.ps1, every path here resolves from
      $PSScriptRoot, never a hardcoded absolute path or the current working
      directory, so this script (and the toolkit folder it ships in) can be
      copied to a network share, packaged as an Intune Win32 app/SCCM
      package, or pushed by an RMM tool and just work. See -DataRoot below
      and README.md's "Central deployment" section.

.PARAMETER PolicyDefinitionsPath
    Folder containing the ADMX files to parse (and the per-language ADML
    subfolder). Defaults to the local Windows policy definitions store.

.PARAMETER Language
    ADML language subfolder under -PolicyDefinitionsPath used to resolve
    $(string.X) display name references. Defaults to en-US.

.PARAMETER OutputPath
    Path to write the full generated mapping CSV. Optional - when not
    supplied, the effective path is chosen automatically (see -DataRoot
    below): normally "<script folder>\Data\Mappings\PolicyMappings-Generated.csv",
    or a machine-local fallback under $env:ProgramData when the script
    folder is not writable. Passing this parameter explicitly always wins
    over both the default and -DataRoot.

.PARAMETER DataRoot
    Optional. Forces the base folder under which this script's "Mappings"
    data subfolder is created, for centrally deployed scenarios (network
    share, Intune Win32 app, SCCM, RMM push) where an administrator wants an
    explicit, predictable location rather than the automatic
    script-folder-or-ProgramData choice. Ignored when -OutputPath is also
    supplied - -OutputPath always wins.

    When neither -OutputPath nor -DataRoot is supplied, this script first
    tries "<script folder>\Data\Mappings" (portable: works when the whole
    toolkit folder is copied anywhere writable, e.g. a USB stick or a
    writable share - matching Test-MDMWinsOverGP.ps1's own -DataRoot
    behavior, so both scripts use the same "Data" folder layout side by
    side). If that folder cannot actually be written to - common when
    running from a read-only UNC share, an Intune package cache, or a
    signed/locked deployment folder - it falls back automatically to
    "$env:ProgramData\MDMWinsOverGP\Data\Mappings", which is normally
    writable even when running as SYSTEM. Either way, which root was chosen
    and why is logged at INFO.

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

.PARAMETER SkipDeviceCorroboration
    By default (this switch off), every Tier B name match is additionally
    checked against live registry evidence read directly from this device
    (classic GPO registry values under HKLM:\SOFTWARE\Policies and
    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies, and live MDM
    PolicyManager evidence under HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device),
    and promoted to Tier A when both sides are actually configured. Pass
    this switch to skip that phase entirely - e.g. for a pure offline
    catalog run, or if reading those registry trees hits a permissions
    problem. When skipped, every match stays at Tier B or falls back to
    Tier C; no rows are ever promoted to Tier A.

.EXAMPLE
    .\Build-PolicyMappings.ps1

.EXAMPLE
    .\Build-PolicyMappings.ps1 -SampleSize 20 -Verbose

.EXAMPLE
    .\Build-PolicyMappings.ps1 -GpoSettingsCsv 'C:\...\Reports\GPO-Settings.csv' -MinimumConfidence C

.EXAMPLE
    .\Build-PolicyMappings.ps1 -DataRoot '\\fileserver\share\MDMWinsOverGP'
#>

[CmdletBinding()]
param(
    [string]$PolicyDefinitionsPath = "$env:SystemRoot\PolicyDefinitions",

    [string]$Language = 'en-US',

    [string]$OutputPath,

    [string]$DataRoot,

    [string]$GpoSettingsCsv,

    [switch]$IncludeUserScope,

    [ValidateSet('A', 'B', 'C')]
    [string]$MinimumConfidence = 'B',

    [ValidateRange(1, 100000)]
    [int]$SampleSize,

    [switch]$SkipDeviceCorroboration
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

# Same writability-probe helper as Test-MDMWinsOverGP.ps1 (kept local for the
# same standalone-script reason as Normalize-PolicyName below). Best-effort:
# can we actually create/write in $Path? Used to decide whether the portable
# "<script folder>\Data\Mappings" location is usable, or whether this is a
# read-only/locked central deployment (UNC share, Intune package cache,
# signed folder) that requires falling back to a machine-local writable
# location. Never throws - a probe failure just means "not writable".
function Test-PathWritable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        $probeFile = Join-Path $Path ".write-test-$([guid]::NewGuid().ToString('N')).tmp"
        Set-Content -LiteralPath $probeFile -Value 'probe' -Encoding UTF8 -ErrorAction Stop
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

# Same central-deployment path-resolution precedence as Test-MDMWinsOverGP.ps1
# (kept local for the same standalone-script reason as Normalize-PolicyName
# below), so both scripts share one "Data" folder layout and one fallback
# story:
#   1. An explicit path the caller passed wins outright (handled by the
#      caller before this function is even called, for -OutputPath, since
#      that is a full file path rather than a directory this function
#      manages - see the "Main" section below).
#   2. -DataRoot, if supplied, forces "<DataRoot>\<SubFolderName>".
#   3. Otherwise, try the portable "<script folder>\Data\<SubFolderName>".
#   4. If (3) is not writable, fall back to a machine-local location under
#      $env:ProgramData, which is normally writable even running as SYSTEM.
function Resolve-DataRoot {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$DataRootOverride,
        [Parameter(Mandatory)][string]$SubFolderName
    )

    if (-not [string]::IsNullOrWhiteSpace($DataRootOverride)) {
        $forced = Join-Path $DataRootOverride $SubFolderName
        Write-Log -Message "Using -DataRoot override for the '$SubFolderName' data folder: '$forced'."
        return $forced
    }

    $portableBase = Join-Path $ScriptRoot 'Data'
    $portablePath = Join-Path $portableBase $SubFolderName
    if (Test-PathWritable -Path $portableBase) {
        Write-Log -Message "Script folder is writable; using the portable data location '$portablePath'."
        return $portablePath
    }

    $fallbackPath = Join-Path (Join-Path $env:ProgramData 'MDMWinsOverGP\Data') $SubFolderName
    Write-Log -Message "Script folder '$ScriptRoot' is not writable (common for a read-only UNC share, an Intune package cache, or a signed/locked deployment folder). Falling back to the machine-local data location '$fallbackPath'."
    return $fallbackPath
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
# about (independent of whether it is currently configured). This is a
# NAME catalog only - each policy's key under "default" holds nothing but
# that policy's out-of-box default value, with no GPO-equivalence metadata
# of any kind, so it is used purely for Tier B's exact-name matching, never
# as registry-match evidence (an earlier revision of this script tried the
# latter and it was structurally incapable of ever matching - see the
# header comment). Returns an empty array - and logs a warning, not an
# error - when the key is missing or unreadable, so the script still
# produces a (Tier-B-empty) GPO-only catalog rather than aborting; a
# missing PolicyManager\default key most often means this is being run on
# a non-Windows-10/11 or heavily locked down system, not a script bug.
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

            $rows.Add([pscustomobject]@{
                Area           = $area
                Policy         = $policy
                RegistryPath   = $policyKey.Name
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

# Same value-stringification helper as Convert-ValueToText in
# Test-MDMWinsOverGP.ps1 (kept local for the same standalone-script reason
# as Normalize-PolicyName).
function Convert-ValueToText {
    param($Value)

    if ($null -eq $Value) { return '' }

    if ($Value -is [byte[]]) {
        return [BitConverter]::ToString($Value)
    }

    if ($Value -is [array]) {
        return ($Value | ForEach-Object { [string]$_ }) -join '; '
    }

    return [string]$Value
}

# Same recursive registry-value-flattening approach as Get-RegistryTreeValues
# in Test-MDMWinsOverGP.ps1 (kept local rather than dot-sourcing, for the
# same standalone-script reason as Normalize-PolicyName). Walks every value
# under -Path - the key itself plus every descendant key - and flattens it
# into one row per value. A per-key try/catch means one unreadable subkey
# degrades this to "missing that one key's values", not "abort the whole
# walk". Returns an empty array (never throws) when -Path itself does not
# exist or cannot be enumerated at all - "this registry tree is not present/
# readable on this device" is an expected, common outcome (e.g. no GPOs
# applied, or the script not running elevated), not a bug.
function Get-RegistryTreeValues {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $keys = @()
    try {
        $keys += Get-Item -LiteralPath $Path -ErrorAction Stop
        $keys += Get-ChildItem -LiteralPath $Path -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log -Level WARN -Message "Could not enumerate registry path '$Path'. $($_.Exception.Message)"
        return @()
    }

    foreach ($key in $keys) {
        try {
            $valueNames = $key.GetValueNames()

            foreach ($valueName in $valueNames) {
                $displayName = if ([string]::IsNullOrWhiteSpace($valueName)) { '(Default)' } else { $valueName }

                $relativePath = $key.Name
                $leaf = Split-Path -Path $relativePath -Leaf
                $parent = Split-Path -Path $relativePath -Parent
                $area = Split-Path -Path $parent -Leaf

                $results.Add([pscustomobject]@{
                    RegistryPath = $relativePath
                    Area         = $area
                    Policy       = $leaf
                    ValueName    = $displayName
                    Value        = Convert-ValueToText -Value $key.GetValue($valueName)
                })
            }
        }
        catch {
            Write-Verbose "Could not read $($key.PSPath): $($_.Exception.Message)"
        }
    }

    return $results.ToArray()
}

# Device corroboration, evidence source 1 of 2: reads every value actually
# present under the two classic-GPO registry roots, live, on the device
# this script is running on. This mirrors what Test-MDMWinsOverGP.ps1 reads
# as Source=GPORegistry. Unlike the removed PolicyManager\default-based
# match, this is real, current, on-device evidence, not a structurally-
# empty default-value catalog. Non-fatal: an unreadable root degrades to an
# empty evidence set for that root (Get-RegistryTreeValues already never
# throws, but this wraps it anyway as belt-and-suspenders, consistent with
# this script's style elsewhere) rather than aborting the whole run.
function Get-ClassicGpoRegistryEvidence {
    $roots = @(
        'HKLM:\SOFTWARE\Policies',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        try {
            $treeRows = @(Get-RegistryTreeValues -Path $root)
            foreach ($row in $treeRows) { $rows.Add($row) }
        }
        catch {
            Write-Log -Level WARN -Message "Could not read classic GPO registry evidence under '$root'. Continuing with no corroboration evidence from this root. $($_.Exception.Message)"
        }
    }

    return $rows.ToArray()
}

# Device corroboration, evidence source 2 of 2: reads every value actually
# present, live, under HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device
# (device scope only - unlike Test-MDMWinsOverGP.ps1 this script does not
# also walk per-user HKEY_USERS\...\PolicyManager\current\user hives, since
# every mapping row this script produces is Machine/Both-class, i.e.
# device-scoped, unless -IncludeUserScope is set, and even then this pass
# only ever checks the Device-side evidence - see the Scope guard in
# Get-DeviceCorroboration). Pairs each base value with its companion
# "<ValueName>_WinningProvider" value where present, same pairing logic as
# Get-MdmPolicyRows in Test-MDMWinsOverGP.ps1. This tells us which CSP
# policies are ACTUALLY effective on this device right now, and (via
# WinningProvider) who currently wins that policy. Non-fatal: returns an
# empty array and logs a WARN if the key is missing/unreadable.
function Get-LiveMdmEvidence {
    $path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'

    # Same "ignore these, they are not real policy values" list as
    # Get-MdmPolicyRows in Test-MDMWinsOverGP.ps1.
    $ignoredNames = @(
        '(Default)',
        'Behavior',
        'PolicyInstanceID',
        'PolicyInstanceID_ProviderSet',
        'PolicyInstanceID_WinningProvider'
    )

    $treeRows = @()
    try {
        $treeRows = @(Get-RegistryTreeValues -Path $path)
    }
    catch {
        Write-Log -Level WARN -Message "Could not read live MDM PolicyManager evidence under '$path'. Continuing with no MDM-side corroboration evidence. $($_.Exception.Message)"
        return @()
    }

    if (-not $treeRows -or $treeRows.Count -eq 0) {
        return @()
    }

    $results = New-Object System.Collections.Generic.List[object]

    $baseRows = @(
        $treeRows | Where-Object {
            $_.ValueName -notin $ignoredNames -and
            $_.ValueName -notmatch '(_ProviderSet|_WinningProvider)$'
        }
    )

    foreach ($base in $baseRows) {
        $winningProvider = $treeRows | Where-Object {
            $_.RegistryPath -eq $base.RegistryPath -and
            $_.ValueName -eq "$($base.ValueName)_WinningProvider"
        } | Select-Object -First 1

        $results.Add([pscustomobject]@{
            Area            = $base.Area
            Policy          = $base.Policy
            ValueName       = $base.ValueName
            Value           = $base.Value
            RegistryPath    = $base.RegistryPath
            WinningProvider = if ($winningProvider) { $winningProvider.Value } else { '' }
        })
    }

    return $results.ToArray()
}

# For a single ADMX policy that already received a Tier B (name-only) match
# against $Csp, checks the two live-registry evidence sets gathered above
# for two independent signals:
#
#   GpoConfigured - is the ADMX policy's OWN declared registry key/valueName
#   (captured in Phase 1, not reparsed here) present WITH AN ACTUAL VALUE in
#   the classic GPO registry evidence? ADMX 'key' is a path relative to the
#   hive implied by the policy's 'class' attribute; this pass only handles
#   Machine/Both-class policies (Device scope), which imply HKLM:\ - it is
#   never called for User-scope rows (see the $Scope guard below).
#
#   MdmConfigured - does the matched CSP policy's Area/Policy appear WITH AN
#   ACTUAL VALUE in the live MDM PolicyManager evidence? The companion
#   _WinningProvider value is captured when present.
#
# Known, accepted simplification: ADMX <policy> elements can declare
# per-element registry keys/valueNames on child <elements> nodes instead of
# (or in addition to) the policy-level key/valueName attributes captured in
# Phase 1. This pass only checks the already-captured policy-level
# key/valueName - it does NOT walk into <elements> to resolve per-element
# registry locations for multi-value policies. A multi-value policy whose
# actually-configured value lives only under a per-element key will
# therefore not be detected as GpoConfigured even though it is genuinely
# configured. This is a known, deliberate gap (resolving it would need a
# much larger ADMX <elements> parser), not a bug - the policy-level
# key/valueName pair still correctly corroborates the common single-value
# policy case.
#
# This can only corroborate the subset of ADMX policies that are CURRENTLY
# actually configured via classic GPO on THIS device - most rows will not
# have GpoConfigured = $true, and that is expected, not evidence the name
# match itself is wrong.
#
# NOTE: this function only gathers and returns the two raw signals
# (GpoConfigured/MdmConfigured/WinningProvider) - it does not decide how they
# are combined into a promotion. The caller (Get-MappingRows) applies BOTH
# promotion rules: the strict "both sides configured" rule, and the looser
# "MDM winning provider" rule that also promotes when GpoConfigured is false
# but the matched CSP policy is live with WinningProvider indicating MDM -
# see the header comment (Phase 4) for why the second rule is necessary.
function Get-DeviceCorroboration {
    param(
        [Parameter(Mandatory)][object]$Admx,
        [Parameter(Mandatory)][object]$Csp,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GpoRegistryEvidence,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MdmEvidence
    )

    $result = [ordered]@{
        GpoConfigured    = $false
        GpoEvidencePath  = ''
        GpoEvidenceValue = ''
        MdmConfigured    = $false
        MdmEvidencePath  = ''
        MdmEvidenceValue = ''
        WinningProvider  = ''
    }

    # --- GPO side ---------------------------------------------------------
    # Only meaningful for Device-scope (Machine/Both-class) rows: the classic
    # GPO registry evidence gathered above is HKLM-only, so a User-scope
    # ADMX policy's key (which would actually live under HKCU:\ when applied)
    # cannot be corroborated by this evidence set.
    if ($Scope -eq 'Device' -and
        -not [string]::IsNullOrWhiteSpace($Admx.RegistryKey) -and
        -not [string]::IsNullOrWhiteSpace($Admx.RegistryValue) -and
        $GpoRegistryEvidence -and $GpoRegistryEvidence.Count -gt 0) {

        $expectedPath = "HKEY_LOCAL_MACHINE\$($Admx.RegistryKey)"

        $gpoHit = $GpoRegistryEvidence | Where-Object {
            $_.RegistryPath -eq $expectedPath -and
            $_.ValueName -eq $Admx.RegistryValue -and
            -not [string]::IsNullOrWhiteSpace($_.Value)
        } | Select-Object -First 1

        if ($gpoHit) {
            $result.GpoConfigured = $true
            $result.GpoEvidencePath = "$($gpoHit.RegistryPath)\$($gpoHit.ValueName)"
            $result.GpoEvidenceValue = $gpoHit.Value
        }
    }

    # --- MDM side -----------------------------------------------------------
    if ($MdmEvidence -and $MdmEvidence.Count -gt 0) {
        $mdmHit = $MdmEvidence | Where-Object {
            $_.Area -eq $Csp.Area -and
            $_.Policy -eq $Csp.Policy -and
            -not [string]::IsNullOrWhiteSpace($_.Value)
        } | Select-Object -First 1

        if ($mdmHit) {
            $result.MdmConfigured = $true
            $result.MdmEvidencePath = "$($mdmHit.RegistryPath)\$($mdmHit.ValueName)"
            $result.MdmEvidenceValue = $mdmHit.Value
            $result.WinningProvider = $mdmHit.WinningProvider
        }
    }

    return [pscustomobject]$result
}

# Phase 4: joins the ADMX catalog to the CSP catalog and produces mapping
# rows tagged with the confidence tier and match category that produced
# them. Only a single row is kept per ADMX policy.
#
# Name-based matching (Tier B) is attempted for every ADMX policy. Every
# Tier B match is then checked against the live device corroboration
# evidence (-GpoRegistryEvidence / -MdmEvidence, gathered once up front by
# the caller and passed in here so this stays a pure join function) via
# Get-DeviceCorroboration. Two independent rules can promote a row to Tier A:
#   1. "BothConfigured"    - GpoConfigured AND MdmConfigured are both true.
#   2. "MdmWinningProvider" - GpoConfigured is false, but MdmConfigured is
#                             true and the CSP policy's _WinningProvider
#                             value indicates MDM currently owns it (the
#                             expected signature of MDM having blocked the
#                             GPO write - see the header comment). This path
#                             is suggestive of a resolved conflict, not proof
#                             the GPO ever targeted this setting, and is
#                             recorded/counted distinctly from rule 1.
# Only when no name match exists at all does this fall back to Tier C fuzzy
# matching.
function Get-MappingRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AdmxCatalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CspCatalog,
        [switch]$IncludeUserScope,
        [ValidateSet('A', 'B', 'C')][string]$MinimumConfidence = 'B',
        [switch]$SkipDeviceCorroboration,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GpoRegistryEvidence,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MdmEvidence
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

        # --- Name-based match (Tier B) -----------------------------------------
        # Exact, case-insensitive match between the ADMX <policy name="...">
        # attribute and the CSP policy name (PowerShell -eq on strings is
        # already ordinal case-insensitive by default).
        $nameMatch = $null
        $exactCsp = @($CspCatalog | Where-Object { $_.Policy -eq $admx.AdmxName })
        if ($exactCsp.Count -gt 0) {
            $nameMatch = $exactCsp[0]
        }

        $bestTier = $null
        $bestCsp = $null
        $bestNotes = ''
        $matchCategory = $null
        $corroborationChecked = $false
        $corroborationPromoted = $false
        # Which of the two independent Tier A promotion rules fired, if any:
        # 'BothConfigured' (strict, strongest) or 'MdmWinningProvider' (looser,
        # suggestive-only - see the header comment for why it exists). Kept
        # separate from $corroborationPromoted so the coverage summary can
        # report each path's count independently rather than blur them.
        $promotionPath = ''

        if ($nameMatch) {
            $bestTier = 'B'
            $bestCsp = $nameMatch
            $matchCategory = 'NameOnly'
            $bestNotes = "Tier B (name-only): exact match between ADMX policy name '$($admx.AdmxName)' and CSP policy name '$($bestCsp.Policy)'."

            # --- Device corroboration (Tier B -> Tier A promotion) -------------
            # Only ever attempted for a row that already has a Tier B name
            # match; see Get-DeviceCorroboration for exactly what it checks
            # and its known per-element-key limitation.
            if (-not $SkipDeviceCorroboration) {
                $corroborationChecked = $true
                $corr = Get-DeviceCorroboration -Admx $admx -Csp $bestCsp -Scope $scope `
                    -GpoRegistryEvidence $GpoRegistryEvidence -MdmEvidence $MdmEvidence

                # Rule 1 (strongest): both sides independently observed as
                # currently configured on this device.
                if ($corr.GpoConfigured -and $corr.MdmConfigured) {
                    $bestTier = 'A'
                    $matchCategory = 'DeviceCorroborated'
                    $corroborationPromoted = $true
                    $promotionPath = 'BothConfigured'
                    $providerNote = if ($corr.WinningProvider) {
                        " WinningProvider='$($corr.WinningProvider)'."
                    }
                    else {
                        ' No _WinningProvider value was present for this policy.'
                    }
                    $bestNotes = "Tier A (device-corroborated, path=BothConfigured): live registry evidence on THIS device shows both sides of this name match are currently configured - GPO: '$($corr.GpoEvidencePath)' = '$($corr.GpoEvidenceValue)'; MDM: '$($corr.MdmEvidencePath)' = '$($corr.MdmEvidenceValue)'.$providerNote This corroborates the Tier B name match with live, on-device proof; it does not by itself confirm the two settings are semantically identical - still review against Microsoft's Policy CSP documentation."
                }
                # Rule 2 (looser, suggestive only): the GPO side is absent,
                # but the CSP side is live and its WinningProvider says MDM
                # currently owns it. This is the expected registry signature
                # of MDMWinsOverGP having actually blocked the GP write for a
                # real conflict - see the header comment for the full
                # rationale. -match is a case-insensitive substring/regex
                # test here (no anchors), since observed WinningProvider
                # values are short provider labels (e.g. "MDM") rather than a
                # fixed enum this script can rely on being documented anywhere
                # reachable from this environment.
                elseif ($corr.MdmConfigured -and $corr.WinningProvider -match 'MDM') {
                    $bestTier = 'A'
                    $matchCategory = 'DeviceCorroborated'
                    $corroborationPromoted = $true
                    $promotionPath = 'MdmWinningProvider'
                    $bestNotes = "Tier A (device-corroborated, path=MdmWinningProvider): the classic GPO registry evidence for this ADMX policy's key/valueName is ABSENT (consistent with Group Policy having been blocked from writing it), but the matched CSP policy is live at MDM: '$($corr.MdmEvidencePath)' = '$($corr.MdmEvidenceValue)' with WinningProvider='$($corr.WinningProvider)'. This is SUGGESTIVE of a resolved GPO-vs-MDM conflict, consistent with MDMWinsOverGP having taken effect - it is NOT, by itself, proof that a GPO ever targeted this exact setting (only the BothConfigured path provides that independent GPO-side proof). Treat this tier A row as a strong lead, and still confirm against Microsoft's Policy CSP documentation and, ideally, the GPO's own reporting for this setting."
                }
                else {
                    $missing = New-Object System.Collections.Generic.List[string]
                    if (-not $corr.GpoConfigured) { $missing.Add("no currently-configured value found under the classic GPO registry evidence for this ADMX policy's key/valueName") }
                    if (-not $corr.MdmConfigured) { $missing.Add('no currently-effective value found under the live MDM PolicyManager evidence for the matched CSP policy') }
                    elseif ($corr.WinningProvider) { $missing.Add("the matched CSP policy's WinningProvider ('$($corr.WinningProvider)') does not indicate MDM ownership") }
                    else { $missing.Add('the matched CSP policy has no _WinningProvider value to evaluate for the MdmWinningProvider path') }
                    $bestNotes += " Device corroboration attempted but not conclusive: $($missing -join '; '). This does not mean the mapping is wrong - it usually just means this setting is not currently GPO-configured (or not currently MDM-winning) on this device."
                }
            }
        }

        # --- Tier C: fuzzy/normalized name similarity (review only) ------------
        # Only attempted as a fallback when no name match was found at all.
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
                $matchCategory = 'Fuzzy'
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

        # Tier/MatchCategory/Corroboration* are script-internal bookkeeping
        # for the coverage summary; they are not part of the CSV schema, but
        # every fact they represent is already spelled out in Notes for
        # anyone reading the CSV directly.
        $results.Add([pscustomobject]@{
            GpoSetting             = $admx.DisplayName
            GpoName                = ''
            CspArea                = $bestCsp.Area
            CspPolicy              = $bestCsp.Policy
            OmaUri                 = New-OmaUri -Area $bestCsp.Area -Policy $bestCsp.Policy -Scope $scope
            Notes                  = (@($bestNotes, $sourceNote, $registryNote) | Where-Object { $_ }) -join ' '
            Tier                   = $bestTier
            MatchCategory          = $matchCategory
            CorroborationChecked   = $corroborationChecked
            CorroborationPromoted  = $corroborationPromoted
            PromotionPath          = $promotionPath
        })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Log -Message 'Building GPO-to-Policy-CSP mapping catalog from local ADMX/ADML and registry data.'
Write-Log -Message "PolicyDefinitions path: $PolicyDefinitionsPath (Language: $Language)"

# Resolve the effective output path per the central-deployment precedence
# rules documented in the -OutputPath/-DataRoot comment-based help: an
# explicit -OutputPath always wins outright (used verbatim, e.g. when
# Test-MDMWinsOverGP.ps1's -GenerateMappings invokes this script and wants
# the output inside its own evidence folder - see that script's
# Invoke-PolicyMappingsGenerator); otherwise -DataRoot forces
# "<DataRoot>\Mappings"; otherwise the portable "<script folder>\Data\Mappings"
# is used if writable; otherwise a machine-local ProgramData fallback is used
# automatically. Resolved from $PSScriptRoot, never the current working
# directory, so this script works the same way regardless of how or from
# where it (or its caller) was launched.
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $effectiveOutputPath = $OutputPath
    Write-Log -Message "Using the explicitly supplied -OutputPath: '$effectiveOutputPath'."
}
else {
    $mappingsDataFolder = Resolve-DataRoot -ScriptRoot $PSScriptRoot -DataRootOverride $DataRoot -SubFolderName 'Mappings'
    $effectiveOutputPath = Join-Path $mappingsDataFolder 'PolicyMappings-Generated.csv'
}

Write-Log -Message 'Phase 1: parsing ADMX/ADML files...'
$admxCatalog = @(Get-AdmxCatalog -Path $PolicyDefinitionsPath -Language $Language -SampleSize $SampleSize)
Write-Log -Message "Parsed $($admxCatalog.Count) ADMX policy definition(s)."

Write-Log -Message 'Phase 2: reading the PolicyManager CSP catalog from the registry...'
$cspCatalog = @(Get-CspCatalog)
Write-Log -Message "Found $($cspCatalog.Count) CSP policy definition(s) under HKLM:\SOFTWARE\Microsoft\PolicyManager\default."

Write-Log -Message 'Phase 3: reading live device registry evidence for corroboration...'
if ($SkipDeviceCorroboration) {
    Write-Log -Message '-SkipDeviceCorroboration specified; skipping live registry evidence collection. Every match will stay at Tier B (or fall back to Tier C) - no rows can be promoted to Tier A on this run.'
    $gpoRegistryEvidence = @()
    $mdmEvidence = @()
}
else {
    # Both reads are independently non-fatal (each already catches its own
    # errors and returns @() - see Get-ClassicGpoRegistryEvidence /
    # Get-LiveMdmEvidence), so a problem reading one does not prevent
    # reading the other, and neither can abort the run.
    $gpoRegistryEvidence = @(Get-ClassicGpoRegistryEvidence)
    Write-Log -Message "Found $($gpoRegistryEvidence.Count) live classic-GPO registry value(s) under HKLM:\SOFTWARE\Policies and HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies."

    $mdmEvidence = @(Get-LiveMdmEvidence)
    Write-Log -Message "Found $($mdmEvidence.Count) live, currently-effective MDM PolicyManager policy value(s) under HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device."
}

Write-Log -Message 'Phase 4: joining ADMX policies to CSP policies...'
$mappingRows = @(Get-MappingRows -AdmxCatalog $admxCatalog -CspCatalog $cspCatalog -IncludeUserScope:$IncludeUserScope `
    -MinimumConfidence $MinimumConfidence -SkipDeviceCorroboration:$SkipDeviceCorroboration `
    -GpoRegistryEvidence $gpoRegistryEvidence -MdmEvidence $mdmEvidence)

$tierACount = @($mappingRows | Where-Object { $_.Tier -eq 'A' }).Count
$tierBCount = @($mappingRows | Where-Object { $_.Tier -eq 'B' }).Count
$tierCCount = @($mappingRows | Where-Object { $_.Tier -eq 'C' }).Count

# Device corroboration breakdown: of the Tier B name matches, how many were
# actually checked against live device registry evidence, and how many of
# those were promoted to Tier A - broken out by WHICH of the two promotion
# rules fired (see Get-MappingRows / the header comment). CorroborationPromoted
# rows are exactly the subset that matters most: name-matched settings with
# hard registry-level proof of either (a) both sides currently configured, or
# (b) MDM currently winning where the GPO side is absent in the way
# MDMWinsOverGP predicts - not just an unverified name coincidence. This is
# necessarily a subset of the full catalog (only settings actually applied
# via GPO, or actually MDM-winning, on this device can ever be corroborated
# this way); see README.md.
$corroborationCheckedCount  = @($mappingRows | Where-Object { $_.CorroborationChecked }).Count
$corroborationPromotedCount = @($mappingRows | Where-Object { $_.CorroborationPromoted }).Count
$corroborationPromotedBothCount = @($mappingRows | Where-Object { $_.PromotionPath -eq 'BothConfigured' }).Count
$corroborationPromotedMdmWinCount = @($mappingRows | Where-Object { $_.PromotionPath -eq 'MdmWinningProvider' }).Count

$mappedCspCount = @($mappingRows | Select-Object -Property CspArea, CspPolicy -Unique).Count
$cspCoveragePct = if ($cspCatalog.Count -gt 0) {
    [math]::Round(100.0 * $mappedCspCount / $cspCatalog.Count, 1)
}
else { 0 }

Write-Log -Message '--- Coverage summary --------------------------------------------'
Write-Log -Message "ADMX policies parsed:                          $($admxCatalog.Count)"
Write-Log -Message "CSP policies found:                            $($cspCatalog.Count)"
Write-Log -Message "Tier A rows (device-corroborated):             $tierACount"
Write-Log -Message "Tier B rows (name-only match):                 $tierBCount"
Write-Log -Message "Tier C rows (fuzzy, review only):              $tierCCount"
Write-Log -Message "Total mapping rows:                            $($mappingRows.Count)"
Write-Log -Message "Distinct CSP policies mapped:                  $mappedCspCount of $($cspCatalog.Count) ($cspCoveragePct%)"
Write-Log -Message "Name-matched rows checked for device corroboration: $corroborationCheckedCount"
Write-Log -Message "  -> promoted to Tier A (total, either path):                 $corroborationPromotedCount"
Write-Log -Message "     - path=BothConfigured (GPO AND MDM both currently configured, live registry proof): $corroborationPromotedBothCount"
Write-Log -Message "     - path=MdmWinningProvider (GPO absent, MDM live and winning - suggestive of a resolved conflict, not standalone proof): $corroborationPromotedMdmWinCount"
Write-Log -Message '-------------------------------------------------------------------'

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

$outputDir = Split-Path -Path $effectiveOutputPath -Parent
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputRows | Export-Csv -LiteralPath $effectiveOutputPath -NoTypeInformation -Encoding UTF8
Write-Log -Message "Wrote $($outputRows.Count) mapping row(s) to '$effectiveOutputPath'."

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
                (Split-Path -Path $effectiveOutputPath -Parent),
                ([System.IO.Path]::GetFileNameWithoutExtension($effectiveOutputPath) + '-Filtered.csv')
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
