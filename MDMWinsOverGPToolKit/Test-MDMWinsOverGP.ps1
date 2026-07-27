#requires -Version 5.1
<#
.SYNOPSIS
    Collects local evidence for validating MDMWinsOverGP on a Windows device.

.DESCRIPTION
    This script gathers:
      - MDMWinsOverGP state
      - PolicyManager effective device and user policy values
      - GPResult XML, HTML, and text
      - DeviceManagement-Enterprise-Diagnostics-Provider logs and EVTX exports
      - MDM diagnostic output
      - Registry policy snapshots
      - Candidate overlaps between GPO and MDM settings
      - Every applied GPO setting, left-joined to CSP mapping/MDM evidence
        where known (see -MappingCsv / -GenerateMappings)
      - An interactive, sortable/filterable, dark-mode-capable HTML report,
        plus CSV reports

    Troubleshooting a run:
      - Log.txt (in the evidence root folder) is a timestamped, leveled
        (INFO/WARN/ERROR) record of every step the script took. Start here.
      - Transcript.txt captures the raw PowerShell console output.
      - COLLECTION-INCOMPLETE.txt is written only when a run fails partway
        through, alongside a "-PARTIAL" suffix on the evidence ZIP name.

    Important:
      - Event 881 is treated as MDM PolicyManager activity, not proof of a GPO conflict.
      - Automatic name matching is heuristic.
      - A verified one-to-one GPO-to-CSP mapping requires a mapping CSV
        (hand-curated, or auto-generated via -GenerateMappings /
        Build-PolicyMappings.ps1) or manual validation.
      - MDMWinsOverGP applies to Policy CSP settings, not every Windows management CSP.
      - This toolkit is designed for central deployment (network share, Intune
        Win32 app, SCCM, RMM push): every path resolves from $PSScriptRoot,
        never a hardcoded absolute path or the current working directory, and
        input/output data lives under one "Data" folder next to the scripts
        (falling back automatically to a machine-local ProgramData location
        when the script folder is not writable). See -DataRoot below and
        README.md's "Central deployment" section.

.PARAMETER OutputRoot
    Parent folder for the evidence package. Optional - when not supplied, the
    effective root is chosen automatically (see -DataRoot below): normally
    "<script folder>\Data\Evidence", or a machine-local fallback under
    $env:ProgramData when the script folder is not writable. Passing this
    parameter explicitly always wins over both the default and -DataRoot.

.PARAMETER DataRoot
    Optional. Forces the base folder under which this run's per-purpose data
    subfolders (Evidence\, Mappings\, Input\) are created, for centrally
    deployed scenarios (network share, Intune Win32 app, SCCM, RMM push)
    where an administrator wants an explicit, predictable location rather
    than the automatic script-folder-or-ProgramData choice. Ignored for a
    given output when the caller also supplies the more specific explicit
    path parameter for that output (e.g. -OutputRoot) - the specific
    parameter always wins.

    When neither -OutputRoot nor -DataRoot is supplied, this script first
    tries "<script folder>\Data" (portable: works when the whole toolkit
    folder is copied anywhere and the caller can write next to it, e.g. a
    USB stick or a writable share). If that folder cannot actually be
    written to - common when the script runs from a read-only UNC share, an
    Intune package cache, or a signed/locked deployment folder - it falls
    back automatically to "$env:ProgramData\MDMWinsOverGP\Data", a
    machine-local location that is normally writable even when running as
    SYSTEM. Either way, which root was chosen and why is logged at INFO.

.PARAMETER SinceHours
    Number of hours of DeviceManagement events to include in CSV reports.

.PARAMETER MappingCsv
    Optional CSV containing verified GPO-to-CSP mappings.

    Supported columns:
      GpoSetting
      GpoName
      CspArea
      CspPolicy
      OmaUri
      Notes

    If both -MappingCsv and -GenerateMappings are supplied, -MappingCsv wins
    for the run and that choice is logged clearly; -GenerateMappings is only
    used to produce the mapping when -MappingCsv was not supplied.

.PARAMETER GenerateMappings
    Before the mapping/overlap analysis step, runs Build-PolicyMappings.ps1
    (resolved relative to this script's own folder via $PSScriptRoot, never
    the current working directory - so this works regardless of how or from
    where the script was launched) to auto-generate a GPO-to-CSP mapping CSV
    from the local ADMX catalog and live registry evidence, filtered to the
    GPO settings actually observed on this device in this run (via the
    GPO-Settings.csv this script itself just wrote). The result is written
    into this run's own evidence folder (under Reports\), never into the
    caller's working directory, and is then used as the effective
    -MappingCsv for the rest of the run - unless the caller also supplied an
    explicit -MappingCsv, which always takes precedence (logged clearly
    either way). Build-PolicyMappings.ps1 is invoked as a separate
    powershell.exe child process (not dot-sourced) specifically so its own
    Write-Log function, variables, and Set-StrictMode scope can never
    collide with or clobber this script's; see Invoke-PolicyMappingsGenerator
    for the full rationale. This entire step is non-fatal: if
    Build-PolicyMappings.ps1 cannot be found or the child process fails, a
    WARN is logged and collection continues exactly as if -GenerateMappings
    had not been passed.

.PARAMETER EnableDebugLog
    Enables the DeviceManagement-Enterprise-Diagnostics-Provider Debug channel.

.PARAMETER DisableDebugLogAfterCollection
    Disables the Debug channel after collection, but only when this run enabled it.

.PARAMETER RunGpUpdate
    Runs gpupdate /force before collecting GPResult. This is best effort: if it
    hangs or fails, the run logs the problem and continues.

.PARAMETER GpUpdateTimeoutSeconds
    Hard timeout for the gpupdate step. If gpupdate has not finished within this
    many seconds it is terminated and collection continues. Default 180.

.PARAMETER SkipMdmDiagnostics
    Skips MdmDiagnosticsTool.exe.

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -EnableDebugLog -RunGpUpdate

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -MappingCsv .\PolicyMappings.csv -SinceHours 48

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -GenerateMappings -SinceHours 48

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -DataRoot '\\fileserver\share\MDMWinsOverGP' -GenerateMappings
#>

[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$DataRoot,
    [ValidateRange(1, 720)]
    [int]$SinceHours = 24,
    [string]$MappingCsv,
    [switch]$GenerateMappings,
    [switch]$EnableDebugLog,
    [switch]$DisableDebugLogAfterCollection,
    [switch]$RunGpUpdate,
    [ValidateRange(30, 3600)]
    [int]$GpUpdateTimeoutSeconds = 180,
    [switch]$SkipMdmDiagnostics
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Populated once the evidence output folder exists (see the main script body
# below). Write-Log checks this on every call so messages logged before the
# folder is created simply go to the console, and everything after is also
# appended to Log.txt for troubleshooting after the fact.
$script:LogFilePath = $null

function Write-Log {
    <#
        Centralized logging helper. Every message gets a timestamp and a
        severity level and is written to the console (color-coded by
        severity) and, once the evidence folder exists, appended to
        Log.txt. Start-Transcript (used later) captures raw console
        output verbatim, but it is not structured or easy to grep;
        Write-Log gives troubleshooters a single, timestamped, leveled
        record of what the script did and why.
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

    if ($script:LogFilePath) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
        }
        catch {
            # Logging must never be the reason the collection itself fails.
        }
    }
}

# Returns $true when the current process token has local Administrator
# rights. Most of what this script does (event log export, registry reads
# under HKLM, wevtutil, gpupdate) requires elevation, so the caller checks
# this before doing any work rather than failing partway through.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Best-effort probe: can we actually create/write in $Path? Used to decide
# whether the portable "<script folder>\Data" location is usable, or whether
# this is a read-only/locked central deployment (UNC share, Intune package
# cache, signed folder) that requires falling back to a machine-local
# writable location instead. Never throws - a probe failure simply means
# "not writable", which is exactly the condition this exists to detect, not
# an error worth surfacing on its own.
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

# Resolves the effective base folder for one purpose-named data subfolder
# (e.g. 'Evidence'), applying this toolkit's central-deployment precedence
# rules (see the -OutputRoot/-DataRoot comment-based help above):
#   1. An explicit path the caller passed for this exact output (e.g.
#      -OutputRoot) always wins outright - not touched further.
#   2. -DataRoot, if supplied, forces "<DataRoot>\<SubFolderName>" - for an
#      administrator pinning a central-deployment location explicitly.
#   3. Otherwise, try the portable "<script folder>\Data\<SubFolderName>"
#      location, which is what makes the whole toolkit folder work when
#      simply copied somewhere writable (USB stick, writable share).
#   4. If (3) is not actually writable - the common case for a read-only UNC
#      share, an Intune package cache, or a signed/locked deployment folder,
#      i.e. exactly the central-deployment scenario this toolkit targets -
#      fall back to a machine-local location under $env:ProgramData, which
#      is normally writable even when running as SYSTEM.
# Every branch is logged at INFO so a troubleshooter can see which root was
# chosen and why without having to reproduce the decision by hand.
function Resolve-DataRoot {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$ExplicitPath,
        [string]$DataRootOverride,
        [Parameter(Mandatory)][string]$SubFolderName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        Write-Log -Message "Using the explicitly supplied path for '$SubFolderName': '$ExplicitPath'."
        return $ExplicitPath
    }

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

# Strips characters that are illegal in Windows file names (e.g. from event
# log names like ".../Debug") so a value can be safely used as a file name.
function New-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_')
}

# Converts a registry value of any kind (string, DWORD, multi-string,
# binary) into a single display-friendly string for CSV/HTML output.
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

# Recursively reads every value under a registry path and flattens it into
# one row per value, tagged with a Source (MDM/GPORegistry/Provider) and an
# optional Scope (Device or User:<SID>). Returns an empty array (never
# throws) when the path does not exist, since "this policy area is not
# configured on this device" is an expected, common result.
function Get-RegistryTreeValues {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('MDM','GPORegistry','Provider')][string]$Source,
        [string]$Scope = ''
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
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $valueNames = $key.GetValueNames()

            foreach ($valueName in $valueNames) {
                if ([string]::IsNullOrWhiteSpace($valueName)) {
                    $displayName = '(Default)'
                }
                else {
                    $displayName = $valueName
                }

                $relativePath = $key.Name
                $leaf = Split-Path -Path $relativePath -Leaf
                $parent = Split-Path -Path $relativePath -Parent
                $area = Split-Path -Path $parent -Leaf

                $results.Add([pscustomobject]@{
                    Source       = $Source
                    Scope        = $Scope
                    RegistryPath = $relativePath
                    Area         = $area
                    Policy       = $leaf
                    ValueName    = $displayName
                    Value        = Convert-ValueToText -Value $key.GetValue($valueName)
                    ValueKind    = [string]$key.GetValueKind($valueName)
                })
            }
        }
        catch {
            Write-Verbose "Could not read $($key.PSPath): $($_.Exception.Message)"
        }
    }

    return $results.ToArray()
}

# Reads the ControlPolicyConflict registry key, which is where Windows
# records the effective MDMWinsOverGP state and, per-value, which provider
# (MDM or GP) currently wins. This is the single most direct piece of
# evidence for whether MDMWinsOverGP is active on the device.
function Get-ControlPolicyConflictState {
    $path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'
    $result = [ordered]@{
        RegistryPath                = $path
        KeyPresent                  = $false
        MDMWinsOverGP               = $null
        MDMWinsOverGP_ProviderSet   = $null
        MDMWinsOverGP_WinningProvider = $null
        Interpretation              = 'Not detected'
    }

    if (Test-Path -LiteralPath $path) {
        $result.KeyPresent = $true
        $item = Get-ItemProperty -LiteralPath $path

        foreach ($name in @('MDMWinsOverGP','MDMWinsOverGP_ProviderSet','MDMWinsOverGP_WinningProvider')) {
            if ($item.PSObject.Properties.Name -contains $name) {
                $result[$name] = Convert-ValueToText $item.$name
            }
        }

        if ([string]$result.MDMWinsOverGP -eq '1') {
            $result.Interpretation = 'Enabled in the effective PolicyManager device store'
        }
        elseif ($null -ne $result.MDMWinsOverGP) {
            $result.Interpretation = 'Present, but not enabled'
        }
    }

    return [pscustomobject]$result
}

# Enables or disables the DeviceManagement-Enterprise-Diagnostics-Provider
# Debug channel via wevtutil. Throws on failure so callers can decide
# whether that is fatal (it usually is not - see the best-effort wrapper
# around -EnableDebugLog in the main script body).
function Set-DmDebugLogState {
    param([Parameter(Mandatory)][bool]$Enabled)

    $logName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Debug'
    $enabledText = if ($Enabled) { 'true' } else { 'false' }

    $output = & "$env:SystemRoot\System32\wevtutil.exe" sl $logName "/e:$enabledText" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "wevtutil failed to set Debug log state to $Enabled (exit $LASTEXITCODE): $(($output | ForEach-Object { [string]$_ }) -join ' ')"
    }
}

# Returns IsEnabled/RecordCount/size/mode for every DeviceManagement
# diagnostics log so the report can show whether logs were actually
# capturing data during the collection window.
function Get-DmLogConfiguration {
    $logPattern = '*DeviceManagement-Enterprise-Diagnostics-Provider*'
    $logs = Get-WinEvent -ListLog $logPattern -ErrorAction SilentlyContinue

    foreach ($log in $logs) {
        [pscustomobject]@{
            LogName       = $log.LogName
            IsEnabled     = $log.IsEnabled
            RecordCount   = $log.RecordCount
            MaximumSizeMB = [math]::Round($log.MaximumSizeInBytes / 1MB, 2)
            LogMode       = $log.LogMode
        }
    }
}

# For every DeviceManagement diagnostics log: exports a full EVTX copy (for
# offline analysis in Event Viewer) and reads events since $StartTime into
# flat rows (for the CSV/HTML report). Both the EVTX export and the event
# read are individually best-effort per log, so one broken/empty log never
# blocks the others.
function Export-DmEvents {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][datetime]$StartTime
    )

    $eventRows = New-Object System.Collections.Generic.List[object]
    $logConfigs = Get-DmLogConfiguration

    foreach ($config in $logConfigs) {
        $safeName = New-SafeFileName $config.LogName
        $evtxPath = Join-Path $Folder "$safeName.evtx"

        try {
            & "$env:SystemRoot\System32\wevtutil.exe" epl $config.LogName $evtxPath "/ow:true" 2>&1 | Out-Null
        }
        catch {
            Write-Log -Level WARN -Message "Could not export EVTX for '$($config.LogName)'. $($_.Exception.Message)"
        }

        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName   = $config.LogName
                StartTime = $StartTime
            } -ErrorAction Stop

            # Loop variable is named $evt, NOT $event: $Event is a PowerShell
            # automatic variable (normally populated inside
            # Register-ObjectEvent/Register-EngineEvent handler scriptblocks).
            # Reusing it as an ordinary foreach variable shadows the automatic
            # variable for the lifetime of the loop, which was the prime
            # suspect for event IDs coming through as 0 in earlier runs of
            # this script. Every other automatic-variable name in this file
            # ($input, $args, $matches, $host, $error, etc.) was also audited
            # for the same mistake - none of the others were misused as plain
            # loop/local variables.
            foreach ($evt in $events) {
                $message = ''
                try { $message = $evt.FormatDescription() } catch { $message = $evt.Message }

                # Defensive ID capture: prefer the provider-authored .Id
                # property. Do not silently fall back to 0 if it cannot be
                # read - that would reproduce the exact misleading symptom
                # this fix is for. RecordId (captured separately below) is a
                # different concept - the log's own per-record sequence
                # number - and is NOT a substitute for the provider's event
                # ID, so it is intentionally not used as an Id fallback.
                # EventLogRecord exposes no other alternate identifier, so
                # when .Id genuinely cannot be read the field is left blank
                # (visibly missing) rather than defaulted to 0.
                $evtId = $null
                try {
                    $rawId = $evt.Id
                    if ($null -ne $rawId) { $evtId = $rawId }
                }
                catch {
                    Write-Verbose "Could not read the Id property for an event in $($evt.LogName): $($_.Exception.Message)"
                }

                $eventRows.Add([pscustomobject]@{
                    TimeCreated = $evt.TimeCreated
                    LogName     = $evt.LogName
                    Id          = if ($null -ne $evtId) { $evtId } else { '' }
                    Level       = $evt.LevelDisplayName
                    Provider    = $evt.ProviderName
                    RecordId    = $evt.RecordId
                    Message     = ($message -replace "`r?`n", ' | ')
                })
            }
        }
        catch {
            Write-Verbose "No readable recent events in $($config.LogName)."
        }
    }

    return [pscustomobject]@{
        Configuration = @($logConfigs)
        Events         = $eventRows.ToArray()
    }
}

# Runs gpresult.exe three times to produce the XML (machine-parseable),
# HTML (human review), and text (quick grep) forms of Resultant Set of
# Policy. The XML output feeds Get-GpResultPolicyRows below.
function Invoke-GpResultCollection {
    param([Parameter(Mandatory)][string]$Folder)

    $xmlPath  = Join-Path $Folder 'GPResult.xml'
    $htmlPath = Join-Path $Folder 'GPResult.html'
    $textPath = Join-Path $Folder 'GPResult.txt'

    & "$env:SystemRoot\System32\gpresult.exe" /scope computer /x $xmlPath /f 2>&1 |
        Out-File -LiteralPath (Join-Path $Folder 'GPResult-XML-command.txt') -Encoding utf8

    & "$env:SystemRoot\System32\gpresult.exe" /scope computer /h $htmlPath /f 2>&1 |
        Out-File -LiteralPath (Join-Path $Folder 'GPResult-HTML-command.txt') -Encoding utf8

    & "$env:SystemRoot\System32\gpresult.exe" /r /scope computer 2>&1 |
        Out-File -LiteralPath $textPath -Encoding utf8

    return [pscustomobject]@{
        XmlPath  = $xmlPath
        HtmlPath = $htmlPath
        TextPath = $textPath
    }
}

# Runs gpupdate /force as a best-effort refresh before collecting GPResult.
# Guards against the two ways gpupdate can hang a session: its own async
# /wait, and the interactive "log off now? (Y/N)" prompt some policies
# trigger. A hard timeout guarantees the caller gets control back either way.
function Invoke-GpUpdate {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [int]$TimeoutSeconds = 180
    )

    $gpupdate  = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
    $outFile   = Join-Path $Folder 'GPUpdate.txt'
    $errFile   = Join-Path $Folder 'GPUpdate-error.txt'

    # gpupdate can stall for two reasons: its own async wait (default /wait is
    # 600 seconds) and an interactive "log off / restart now? (Y/N)" prompt it
    # shows when a policy requests a foreground refresh. Bound the first with an
    # explicit /wait, and defuse the second by redirecting stdin from a file of
    # 'N' answers so it never blocks on the console. A hard process timeout then
    # guarantees the run continues no matter what.
    $stdinFile = Join-Path $Folder 'GPUpdate-input.tmp'
    @('N','N','N') | Set-Content -LiteralPath $stdinFile -Encoding ascii

    $waitSeconds = [math]::Max(0, $TimeoutSeconds - 30)

    try {
        $proc = Start-Process -FilePath $gpupdate `
            -ArgumentList '/force', "/wait:$waitSeconds" `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -RedirectStandardInput $stdinFile

        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Log -Message "gpupdate completed with exit code $($proc.ExitCode)."
        }
        else {
            Write-Log -Level WARN -Message "gpupdate did not finish within $TimeoutSeconds seconds. Terminating it and continuing with collection."
            # Process.Kill([bool]) for the whole tree is .NET Core only; on Windows
            # PowerShell 5.1 use taskkill /T to terminate gpupdate and its children.
            & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F 2>&1 |
                Out-File -LiteralPath $errFile -Append -Encoding utf8
        }
    }
    finally {
        Remove-Item -LiteralPath $stdinFile -Force -ErrorAction SilentlyContinue
    }

    # Echo gpupdate's captured output into the transcript/log for the record.
    if (Test-Path -LiteralPath $outFile) {
        Get-Content -LiteralPath $outFile | ForEach-Object { Write-Log -Message $_ }
    }
}

# Returns the trimmed inner text of the first matching descendant element,
# checked in order across a list of possible element names. GPResult XML
# uses different element names for the same concept across Windows
# releases and policy extension types, so callers pass every known
# synonym and take whichever is present.
function Get-FirstNodeText {
    param(
        [Parameter(Mandatory)][System.Xml.XmlNode]$Node,
        # AllowEmptyCollection alongside Mandatory: without it, PowerShell's
        # binder rejects an empty array bound to a Mandatory array parameter
        # as "no value supplied," even though every call site here always
        # passes a non-empty literal - this is defensive, matching the
        # blanket rule this toolkit follows for every Mandatory array param.
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LocalNames
    )

    foreach ($name in $LocalNames) {
        $match = $Node.SelectSingleNode(".//*[local-name()='$name']")
        if ($match -and -not [string]::IsNullOrWhiteSpace($match.InnerText)) {
            return $match.InnerText.Trim()
        }
    }

    return ''
}

# Parses GPResult.xml into flat rows of candidate GPO-applied settings.
# Returns an empty array (never throws) when the XML is missing or
# unparsable, and when no Group Policy is applied that is a legitimate,
# expected empty result rather than a failure.
function Get-GpResultPolicyRows {
    param([Parameter(Mandatory)][string]$XmlPath)

    if (-not (Test-Path -LiteralPath $XmlPath)) {
        return @()
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $XmlPath -Raw
    }
    catch {
        Write-Log -Level WARN -Message "Could not parse GPResult XML at '$XmlPath'. $($_.Exception.Message)"
        return @()
    }

    $rows = New-Object System.Collections.Generic.List[object]

    # GPResult XML structure varies across Windows releases and policy extension types.
    # We capture nodes that appear to represent policy settings and retain raw XML for audit.
    $candidateNodes = $xml.SelectNodes(
        "//*[local-name()='Policy' or local-name()='Setting' or local-name()='RegistrySetting']"
    )

    foreach ($node in $candidateNodes) {
        $settingName = Get-FirstNodeText -Node $node -LocalNames @(
            'Name','PolicyName','SettingName','DisplayName','KeyName'
        )

        if ([string]::IsNullOrWhiteSpace($settingName)) {
            if ($node.Attributes['name']) {
                $settingName = $node.Attributes['name'].Value
            }
        }

        $state = Get-FirstNodeText -Node $node -LocalNames @(
            'State','Setting','Value','PolicyState'
        )

        $gpoName = Get-FirstNodeText -Node $node -LocalNames @(
            'GPOName','GPO','WinningGPO','SOMName'
        )

        $category = Get-FirstNodeText -Node $node -LocalNames @(
            'Category','CategoryName','ExtensionName'
        )

        $registryKey = Get-FirstNodeText -Node $node -LocalNames @(
            'RegistryKey','KeyPath','Path'
        )

        $registryValue = Get-FirstNodeText -Node $node -LocalNames @(
            'RegistryValue','ValueName'
        )

        if (-not [string]::IsNullOrWhiteSpace($settingName) -or
            -not [string]::IsNullOrWhiteSpace($registryKey)) {

            $rows.Add([pscustomobject]@{
                GpoSetting    = $settingName
                GpoName       = $gpoName
                State         = $state
                Category      = $category
                RegistryKey   = $registryKey
                RegistryValue = $registryValue
                XmlNodeName   = $node.LocalName
            })
        }
    }

    return $rows.ToArray() |
        Sort-Object GpoSetting, GpoName, RegistryKey, RegistryValue -Unique
}

# Lowercases, strips common policy-name verb prefixes (allow/enable/...),
# and removes all non-alphanumeric characters. Used for a strict/loose
# equality check when matching a GPO setting name to an MDM policy name.
function Normalize-PolicyName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $normalized = $Text.ToLowerInvariant()
    $normalized = $normalized -replace '^(allow|enable|disable|configure|turnon|turnoff)', ''
    $normalized = $normalized -replace '[^a-z0-9]', ''
    return $normalized
}

# Splits a name/description into a sorted, de-duplicated set of lowercase
# words (>=3 chars, stop words removed), for use as input to the Jaccard
# similarity score below when exact/substring name matching fails.
function Get-TokenSet {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $expanded = $Text -creplace '([a-z])([A-Z])', '$1 $2'
    # Use -split (regex) rather than String.Split(@(...)): passing an untyped
    # array to .Split binds the single-String overload, so the text is never
    # tokenized. The character class covers whitespace and the previous
    # delimiters (space, _ - / \ . : ( ) [ ]); the trailing '-' is literal.
    return @(
        ($expanded.ToLowerInvariant() -split '[\s_/\\.:()\[\]-]+') |
        Where-Object {
            $_.Length -gt 2 -and
            $_ -notin @('policy','setting','windows','microsoft','computer','user','configure')
        } |
        Sort-Object -Unique
    )
}

# Jaccard similarity (intersection / union) between two token sets,
# 0.0-1.0. Used as the fallback heuristic match score when a GPO setting
# name and an MDM policy name are not equal or substrings of each other.
function Get-JaccardScore {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    # Under Set-StrictMode -Version 2, referencing .Count on a $null value
    # (e.g. when Get-TokenSet's token set collapses to nothing and binds as
    # $null instead of an empty array) throws "The property 'Count' cannot
    # be found on this object" instead of quietly treating it as empty. Use
    # boolean coercion (-not) instead of .Count: it is $true for both $null
    # and an empty array, and never touches a property, so it cannot trip
    # this StrictMode check regardless of which case applies here.
    if (-not $Left -or -not $Right) { return 0 }

    $intersection = @($Left | Where-Object { $Right -contains $_ } | Sort-Object -Unique)
    $union = @($Left + $Right | Sort-Object -Unique)

    if ($union.Count -eq 0) { return 0 }
    return [math]::Round($intersection.Count / $union.Count, 3)
}

# Collapses the flat PolicyManager registry rows (one row per value,
# including the internal *_ProviderSet and *_WinningProvider companion
# values) into one row per effective policy, with its winning provider
# and pre-computed name tokens attached for the overlap matching below.
function Get-MdmPolicyRows {
    param([object[]]$RegistryRows)

    $ignoredNames = @(
        '(Default)',
        'Behavior',
        'PolicyInstanceID',
        'PolicyInstanceID_ProviderSet',
        'PolicyInstanceID_WinningProvider'
    )

    $grouped = $RegistryRows |
        Where-Object {
            $_.Source -eq 'MDM' -and
            $_.ValueName -notin $ignoredNames -and
            $_.ValueName -notmatch '(_ProviderSet|_WinningProvider)$'
        } |
        Group-Object Scope, RegistryPath, Policy

    foreach ($group in $grouped) {
        $first = $group.Group | Select-Object -First 1
        $providerSet = $RegistryRows |
            Where-Object {
                $_.RegistryPath -eq $first.RegistryPath -and
                $_.ValueName -eq "$($first.ValueName)_ProviderSet"
            } |
            Select-Object -First 1

        $winningProvider = $RegistryRows |
            Where-Object {
                $_.RegistryPath -eq $first.RegistryPath -and
                $_.ValueName -eq "$($first.ValueName)_WinningProvider"
            } |
            Select-Object -First 1

        [pscustomobject]@{
            Scope           = $first.Scope
            Area            = $first.Area
            Policy          = $first.Policy
            ValueName       = $first.ValueName
            EffectiveValue  = $first.Value
            RegistryPath    = $first.RegistryPath
            ProviderSet     = if ($providerSet) { $providerSet.Value } else { '' }
            WinningProvider = if ($winningProvider) { $winningProvider.Value } else { '' }
            NormalizedName  = Normalize-PolicyName "$($first.Area) $($first.Policy) $($first.ValueName)"
            Tokens          = Get-TokenSet "$($first.Area) $($first.Policy) $($first.ValueName)"
        }
    }
}

# Loads the optional -MappingCsv of human-verified GPO-to-CSP mappings.
# Returns an empty array when no path was given (mapping is optional); if
# a path *was* given but does not exist, this throws so the caller fails
# fast rather than silently reporting zero verified overlaps.
function Import-VerifiedMappings {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mapping CSV not found: $Path"
    }

    $rows = Import-Csv -LiteralPath $Path

    foreach ($row in $rows) {
        [pscustomobject]@{
            GpoSetting = [string]$row.GpoSetting
            GpoName    = [string]$row.GpoName
            CspArea    = [string]$row.CspArea
            CspPolicy  = [string]$row.CspPolicy
            OmaUri     = [string]$row.OmaUri
            Notes      = [string]$row.Notes
        }
    }
}

# Implements -GenerateMappings: runs Build-PolicyMappings.ps1 to auto-
# generate a starting-point GPO-to-CSP mapping CSV, filtered to the GPO
# settings actually observed on this device in this run, and returns the
# path to the resulting "*-Filtered.csv" (or $null on any failure/absence -
# every failure mode here is non-fatal to the caller by design).
#
# Why a child powershell.exe process instead of dot-sourcing:
# Build-PolicyMappings.ps1 is a large, independently-maintained standalone
# script with its own Set-StrictMode -Version 2, its own Write-Log function,
# and dozens of its own script-scope-adjacent variables ($admxCatalog,
# $cspCatalog, $mappingRows, etc.). Dot-sourcing it would run all of that
# directly in this script's scope, so its Write-Log would silently replace
# this script's Write-Log (breaking Log.txt), and any variable name
# collision (deliberate or accidental, now or in a future edit to either
# script) would silently clobber state in either direction. A child
# "powershell.exe -File" process gets a completely independent process,
# scope, and $ErrorActionPreference, so nothing it does - success or
# failure - can ever reach back into this script's state. The only price is
# marshalling its console output back in (captured and re-logged below) and
# checking its exit code / the file it was supposed to produce.
function Invoke-PolicyMappingsGenerator {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ReportsFolder,
        [Parameter(Mandatory)][string]$GpoSettingsCsvPath
    )

    $builderPath = Join-Path $ScriptRoot 'Build-PolicyMappings.ps1'
    if (-not (Test-Path -LiteralPath $builderPath)) {
        Write-Log -Level WARN -Message "-GenerateMappings was specified, but Build-PolicyMappings.ps1 was not found next to this script at '$builderPath'. Continuing without an auto-generated mapping."
        return $null
    }

    # Output goes into THIS run's own evidence folder (Reports\), never the
    # caller's working directory or the standalone Data\Mappings location -
    # an -OutputPath is always an explicit path, so Build-PolicyMappings.ps1's
    # own Resolve-DataRoot logic is bypassed entirely and this is exactly
    # where the file lands, deterministically, every time.
    $generatedPath = Join-Path $ReportsFolder 'PolicyMappings-Generated.csv'
    $filteredPath  = Join-Path $ReportsFolder 'PolicyMappings-Generated-Filtered.csv'

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        # Fall back to whatever is on PATH (e.g. pwsh.exe under PowerShell 7)
        # if the Windows PowerShell 5.1 host path is not present.
        $powershellExe = 'powershell.exe'
    }

    $arguments = @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy', 'Bypass'
        '-File', $builderPath
        '-OutputPath', $generatedPath
        '-GpoSettingsCsv', $GpoSettingsCsvPath
    )

    Write-Log -Message "Running Build-PolicyMappings.ps1 as a child process to auto-generate a mapping CSV filtered to this device's GPO settings..."

    try {
        # Capture combined stdout/stderr from the child process and re-log
        # every line through this script's own Write-Log, so the generator's
        # progress/coverage-summary output ends up in Log.txt alongside
        # everything else this run did, without letting its own Write-Log
        # function ever execute in this script's scope.
        $childOutput = & $powershellExe @arguments 2>&1
        $childExitCode = $LASTEXITCODE

        foreach ($outputLine in $childOutput) {
            Write-Log -Message "[Build-PolicyMappings] $outputLine"
        }

        if ($childExitCode -ne 0) {
            Write-Log -Level WARN -Message "Build-PolicyMappings.ps1 exited with code $childExitCode. Continuing without an auto-generated mapping."
            return $null
        }

        if (-not (Test-Path -LiteralPath $filteredPath)) {
            # A filtered CSV is only written when GpoSettingsCsv matched at
            # least one row inside Build-PolicyMappings.ps1 - see its own
            # non-fatal handling of an empty/missing GpoSettingsCsv. Falling
            # back to the unfiltered output keeps this run usable instead of
            # silently discarding a mapping that was in fact generated.
            if (Test-Path -LiteralPath $generatedPath) {
                Write-Log -Level WARN -Message "Build-PolicyMappings.ps1 did not produce a filtered mapping CSV at '$filteredPath'; falling back to the unfiltered mapping at '$generatedPath'."
                return $generatedPath
            }

            Write-Log -Level WARN -Message "Build-PolicyMappings.ps1 completed but produced no mapping CSV at '$generatedPath' or '$filteredPath'. Continuing without an auto-generated mapping."
            return $null
        }

        Write-Log -Message "Auto-generated, device-filtered mapping CSV: '$filteredPath'."
        return $filteredPath
    }
    catch {
        Write-Log -Level WARN -Message "Failed to run Build-PolicyMappings.ps1. Continuing without an auto-generated mapping. $($_.Exception.Message)"
        return $null
    }
}

# For EVERY GPO setting actually applied on this device (from GPResult),
# left-joins it to the optional -MappingCsv and to MDM evidence, and
# produces a report row with a plain-English status. This is an inversion of
# the original design, which iterated $Mappings and therefore only ever
# showed GPO settings that already had a mapping row - the majority of a
# device's applied GPO settings (which typically have no known CSP mapping)
# never appeared at all. Now every applied GPO setting is represented:
#   - has a mapping AND MDM evidence  -> "Confirmed overlap" (this is the
#     highest-confidence evidence the report can show, since it is based on
#     a mapping a person or Build-PolicyMappings.ps1 produced, not
#     name-similarity guessing at report time).
#   - has a mapping but no MDM evidence -> mapped, MDM side not configured.
#   - has NO mapping at all -> 'No known CSP mapping'. This is expected to
#     be the common case (most GPO settings have no documented Policy CSP
#     equivalent), not an error condition.
# GPResult can yield the same setting more than once (e.g. across categories
# or policy extensions), so rows are deduplicated by (GpoSetting, GpoName)
# before the join.
function Get-VerifiedOverlapRows {
    param(
        [object[]]$Mappings,
        [object[]]$GpoRows,
        [object[]]$MdmRows
    )

    $distinctGpoRows = @(
        $GpoRows |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.GpoSetting) } |
        Group-Object GpoSetting, GpoName |
        ForEach-Object { $_.Group | Select-Object -First 1 }
    )

    foreach ($gpo in $distinctGpoRows) {
        # A mapping row's GpoName is an optional additional filter (some GPO
        # setting names are ambiguous without knowing which GPO won them);
        # when the mapping row supplies one, require it to match too.
        $mapping = $Mappings | Where-Object {
            (
                $_.GpoSetting -eq $gpo.GpoSetting -or
                (Normalize-PolicyName $_.GpoSetting) -eq (Normalize-PolicyName $gpo.GpoSetting)
            ) -and (
                [string]::IsNullOrWhiteSpace($_.GpoName) -or $_.GpoName -eq $gpo.GpoName
            )
        } | Select-Object -First 1

        $matchingMdm = @()
        if ($mapping) {
            $matchingMdm = @(
                $MdmRows | Where-Object {
                    $_.Area -eq $mapping.CspArea -and
                    ($_.Policy -eq $mapping.CspPolicy -or $_.ValueName -eq $mapping.CspPolicy)
                }
            )
        }

        # This row exists precisely because it is an applied GPO setting
        # observed in GPResult, so GpoConfigured is always true here - unlike
        # the old mapping-first design, there is no "mapped but GPO side
        # missing" case any more; a mapping row whose GPO setting never
        # appears in GPResult simply never produces a row (nothing to join
        # it to). MdmConfigured is only meaningful once a mapping exists.
        $mdmConfigured = $matchingMdm.Count -gt 0

        $status =
            if (-not $mapping) {
                'No known CSP mapping'
            }
            elseif ($mdmConfigured) {
                'Confirmed overlap. Validate effective value and behavior.'
            }
            else {
                'Mapped to a CSP policy, but no MDM evidence was observed for it.'
            }

        [pscustomobject]@{
            MatchType         = if ($mapping) { 'Verified mapping' } else { 'No mapping' }
            Confidence        = if ($mapping) { 1 } else { 0 }
            GpoConfigured     = $true
            MdmConfigured     = $mdmConfigured
            GpoSetting        = $gpo.GpoSetting
            GpoName           = $gpo.GpoName
            GpoState          = $gpo.State
            CspArea           = if ($mapping) { $mapping.CspArea } else { '' }
            CspPolicy         = if ($mapping) { $mapping.CspPolicy } else { '' }
            MdmEffectiveValue = (@($matchingMdm | ForEach-Object { $_.EffectiveValue }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            WinningProvider   = (@($matchingMdm | ForEach-Object { $_.WinningProvider }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            OmaUri            = if ($mapping) { $mapping.OmaUri } else { '' }
            Status            = $status
            Notes             = if ($mapping) { $mapping.Notes } else { '' }
        }
    }
}

# Best-effort automatic matching between GPO settings and MDM policies by
# name similarity (exact normalized match, substring match, then Jaccard
# token overlap), for GPO settings that have no verified mapping. These
# are triage candidates only - see the "Interpretation limits" note in the
# generated report - not confirmed overlaps.
function Get-HeuristicOverlapRows {
    param(
        [object[]]$GpoRows,
        [object[]]$MdmRows,
        [double]$MinimumScore = 0.5
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($gpo in $GpoRows) {
        $gpoText = "$($gpo.Category) $($gpo.GpoSetting) $($gpo.RegistryValue)"
        $gpoNormalized = Normalize-PolicyName $gpoText
        $gpoTokens = Get-TokenSet $gpoText

        if ([string]::IsNullOrWhiteSpace($gpoNormalized)) { continue }

        $best = $null
        $bestScore = 0.0

        foreach ($mdm in $MdmRows) {
            $score = 0.0

            if ($gpoNormalized -eq $mdm.NormalizedName) {
                $score = 1.0
            }
            elseif ($gpoNormalized.Length -ge 6 -and
                    $mdm.NormalizedName.Length -ge 6 -and
                    ($mdm.NormalizedName.Contains($gpoNormalized) -or
                     $gpoNormalized.Contains($mdm.NormalizedName))) {
                $score = 0.8
            }
            else {
                $score = Get-JaccardScore -Left $gpoTokens -Right $mdm.Tokens
            }

            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $mdm
            }
        }

        if ($best -and $bestScore -ge $MinimumScore) {
            $results.Add([pscustomobject]@{
                MatchType         = 'Heuristic candidate'
                Confidence        = $bestScore
                GpoConfigured     = $true
                MdmConfigured     = $true
                GpoSetting        = $gpo.GpoSetting
                GpoName           = $gpo.GpoName
                GpoState          = $gpo.State
                CspArea           = $best.Area
                CspPolicy         = $best.Policy
                MdmEffectiveValue = $best.EffectiveValue
                WinningProvider   = $best.WinningProvider
                OmaUri            = ''
                Status            = 'Candidate only. Confirm the Microsoft CSP mapping before treating this as a conflict.'
                Notes             = "Name similarity score: $bestScore"
            })
        }
    }

    # Use hashtable sort keys so the mixed ascending/descending sort parses
    # unambiguously. "Sort-Object Confidence -Descending, GpoSetting" does not
    # bind the way it reads and can fail under Set-StrictMode.
    return $results.ToArray() |
        Sort-Object -Property `
            @{ Expression = 'Confidence'; Descending = $true }, `
            @{ Expression = 'GpoSetting'; Descending = $false } `
            -Unique
}

function ConvertTo-HtmlEncoded {
    param([object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

# Maps a report row's plain-English Status text to a semantic red/amber/green
# CSS class (see the .status-* rules in $css inside New-HtmlReport). Matched
# by substring/regex on purpose - Status is free text produced in a few
# different places in this script (Get-VerifiedOverlapRows), and this keeps
# working even if that wording is tweaked slightly, not only for one exact
# string. Returns '' (no class, no color) for anything unrecognized, so an
# unexpected Status value degrades to "uncolored", never to a misleading color.
function Get-StatusCssClass {
    param([string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return '' }

    if ($Status -match 'Confirmed overlap') { return 'status-red' }
    if ($Status -match 'No known CSP mapping') { return 'status-green' }
    if ($Status -match 'Mapped to a CSP policy, but no MDM evidence') { return 'status-amber' }
    if ($Status -match 'Candidate only') { return 'status-amber' }
    if ($Status -match 'not found|not conclusive') { return 'status-amber' }
    return ''
}

# Maps an event's LevelDisplayName to the same red/amber/green scheme used
# for Status above, for the "Recent warnings and errors" table.
function Get-LevelCssClass {
    param([string]$Level)

    switch ($Level) {
        'Critical'    { return 'status-red' }
        'Error'       { return 'status-red' }
        'Warning'     { return 'status-amber' }
        'Information' { return 'status-green' }
        default       { return '' }
    }
}

# Renders a collection of objects as an HTML table, one column per named
# property, with every cell HTML-encoded to prevent broken markup or HTML
# injection from registry/event data that happens to contain HTML-special
# characters. Renders a friendly empty-state message instead of an empty
# table when Rows has no items (this is common and expected, e.g. no GPO
# settings applied, no verified mappings supplied).
#
# -Interactive opts a single table into client-side sorting (and, with
# -FilterColumns, dropdown filtering) via the inline <script> block New-
# HtmlReport embeds once for the whole page - see $reportScript there. This
# is OFF by default so every existing call site keeps rendering exactly the
# plain static table it always has; only the two call sites in New-HtmlReport
# that ask for it (Applied GPO settings, Recent warnings and errors) opt in.
#
# How sorting/filtering data reaches the browser without weakening HTML
# encoding: every value written into a data-cN attribute (one per column,
# N = 0-based column index, matching each <th>'s data-col) is passed through
# the exact same ConvertTo-HtmlEncoded used for the visible <td> text - n->
# no extra/weaker encoding path is introduced for the interactive case.
function Convert-ObjectsToHtmlTable {
    param(
        [object[]]$Rows,
        # Defaults to an empty array (never $null) so a direct .Count access
        # on $Properties further down can never trip Set-StrictMode -Version
        # 2's "property 'Count' cannot be found on this object" even if a
        # future call site forgets to pass -Properties.
        [string[]]$Properties = @(),
        [string]$EmptyMessage = 'No records found.',
        [switch]$Interactive,
        [string]$TableId,
        [string[]]$FilterColumns = @(),
        # Maps a property name to a client-side sort-type hint: 'date',
        # 'number', or 'severity' (ranked, not alphabetical - see the
        # severityRank map in $reportScript). Any column not listed here
        # sorts as plain case-insensitive text. Only consulted when
        # -Interactive is set.
        [hashtable]$ColumnSortTypes = @{},
        # Optional property name whose value (via Get-StatusCssClass) sets a
        # semantic red/amber/green class on each <tr>.
        [string]$StatusColumn,
        # Optional property name whose value (via Get-LevelCssClass) sets a
        # semantic red/amber/green class on each <tr>.
        [string]$LevelColumn
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p>$([System.Net.WebUtility]::HtmlEncode($EmptyMessage))</p>"
    }

    if ($Interactive -and [string]::IsNullOrWhiteSpace($TableId)) {
        # Programming error, not a data/runtime condition - every interactive
        # call site in this file supplies a literal -TableId, so this can
        # only fire if a future call site forgets to.
        throw 'Convert-ObjectsToHtmlTable: -TableId is required when -Interactive is specified.'
    }

    $headerCells = for ($i = 0; $i -lt $Properties.Count; $i++) {
        $propertyName = $Properties[$i]
        $encodedName = ConvertTo-HtmlEncoded $propertyName
        if ($Interactive) {
            $sortType = if ($ColumnSortTypes.ContainsKey($propertyName)) { $ColumnSortTypes[$propertyName] } else { 'text' }
            "<th data-col=""$i"" data-sort=""$(ConvertTo-HtmlEncoded $sortType)"" class=""sortable"">$encodedName<span class=""sort-indicator""></span></th>"
        }
        else {
            "<th>$encodedName</th>"
        }
    }
    $header = $headerCells -join ''

    $bodyRows = foreach ($row in $Rows) {
        $rowClasses = New-Object System.Collections.Generic.List[string]
        if ($StatusColumn -and $row.PSObject.Properties.Match($StatusColumn).Count -gt 0) {
            $statusClass = Get-StatusCssClass -Status ([string]$row.$StatusColumn)
            if ($statusClass) { $rowClasses.Add($statusClass) }
        }
        if ($LevelColumn -and $row.PSObject.Properties.Match($LevelColumn).Count -gt 0) {
            $levelClass = Get-LevelCssClass -Level ([string]$row.$LevelColumn)
            if ($levelClass) { $rowClasses.Add($levelClass) }
        }
        $classAttr = if ($rowClasses.Count -gt 0) { " class=""$($rowClasses -join ' ')""" } else { '' }

        $dataAttr = ''
        if ($Interactive) {
            $attrParts = for ($i = 0; $i -lt $Properties.Count; $i++) {
                $propertyName = $Properties[$i]
                $rawValue = $row.$propertyName
                $sortType = if ($ColumnSortTypes.ContainsKey($propertyName)) { $ColumnSortTypes[$propertyName] } else { 'text' }
                # Dates get a stable, locale-independent sort key (round-trip
                # 'o' format) distinct from whatever locale-formatted text the
                # visible <td> shows, so sorting is correct regardless of how
                # the value happens to display. Everything else sorts on the
                # same text the cell shows.
                $sortValue = if ($sortType -eq 'date' -and $rawValue -is [datetime]) {
                    $rawValue.ToString('o')
                }
                else {
                    [string]$rawValue
                }
                "data-c$i=""$(ConvertTo-HtmlEncoded $sortValue)"""
            }
            $dataAttr = ' ' + ($attrParts -join ' ')
        }

        $cells = foreach ($property in $Properties) {
            "<td>$(ConvertTo-HtmlEncoded $row.$property)</td>"
        }
        "<tr$classAttr$dataAttr>$($cells -join '')</tr>"
    }

    $tableAttrs = if ($Interactive) { " id=""$(ConvertTo-HtmlEncoded $TableId)"" class=""interactive-table""" } else { '' }
    $table = "<table$tableAttrs><thead><tr>$header</tr></thead><tbody>$($bodyRows -join "`n")</tbody></table>"

    if ($Interactive -and $FilterColumns.Count -gt 0) {
        # One <select> per requested filter column, auto-populated with the
        # distinct values actually present in $Rows (never a hardcoded
        # list) plus an "All" option. data-filter-col matches the column's
        # data-col/data-cN index so the JS can locate it without depending
        # on column order or property names at runtime.
        $filterControls = foreach ($filterColumn in $FilterColumns) {
            $colIndex = [array]::IndexOf($Properties, $filterColumn)
            if ($colIndex -lt 0) { continue }

            $distinctValues = @(
                $Rows | ForEach-Object { [string]$_.$filterColumn } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
            )

            if ($distinctValues.Count -eq 0) { continue }

            $optionTags = foreach ($value in $distinctValues) {
                "<option value=""$(ConvertTo-HtmlEncoded $value)"">$(ConvertTo-HtmlEncoded $value)</option>"
            }

            $labelText = ConvertTo-HtmlEncoded $filterColumn
            "<label class=""filter-label"">$labelText: <select class=""table-filter"" data-filter-table=""$(ConvertTo-HtmlEncoded $TableId)"" data-filter-col=""$colIndex""><option value="""">All</option>$($optionTags -join '')</select></label>"
        }

        if ($filterControls) {
            $table = "<div class=""table-filters"">$($filterControls -join ' ')</div>`n$table"
        }
    }

    return $table
}

# Assembles the final human-readable HTML report from every piece of
# evidence collected by the main script body, and writes it to $Path.
function New-HtmlReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$ConflictState,
        # AllowEmptyCollection is required alongside Mandatory here: PowerShell's
        # parameter binder treats an empty array bound to a Mandatory array
        # parameter as "no value supplied" and throws "Cannot bind argument to
        # parameter '...' because it is an empty array." These rows are commonly
        # empty on a clean device (no recent events, no overlaps found), so that
        # is an expected input, not a caller bug.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LogConfiguration,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GpoRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MdmRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VerifiedRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$HeuristicRows,
        [Parameter(Mandatory)][string]$EvidenceFolder
    )

    $event881 = @($Events | Where-Object Id -eq 881)
    $eventErrors = @($Events | Where-Object { $_.Level -in @('Error','Critical','Warning') })

    # "Verified overlaps" keeps its original meaning (mapped AND both sides
    # currently configured) even though $VerifiedRows now contains every
    # applied GPO setting, not just mapped ones - see Get-VerifiedOverlapRows.
    # GpoConfigured is trivially true for every row here (the row only exists
    # because it IS an applied GPO setting), so this reduces to exactly
    # "mapped and MDM evidence found," the same metric as before the Task 2
    # change - it stays comparable across report versions.
    $verifiedBoth = @($VerifiedRows | Where-Object { $_.GpoConfigured -and $_.MdmConfigured })
    $unmappedGpoSettings = @($VerifiedRows | Where-Object { $_.MatchType -eq 'No mapping' })
    $summaryRows = @(
        [pscustomobject]@{ Metric = 'MDMWinsOverGP'; Value = $ConflictState.Interpretation }
        [pscustomobject]@{ Metric = 'GPO settings parsed'; Value = $GpoRows.Count }
        [pscustomobject]@{ Metric = 'PolicyManager effective rows'; Value = $MdmRows.Count }
        [pscustomobject]@{ Metric = 'Applied GPO settings with no known CSP mapping'; Value = $unmappedGpoSettings.Count }
        [pscustomobject]@{ Metric = 'Verified overlaps'; Value = $verifiedBoth.Count }
        [pscustomobject]@{ Metric = 'Heuristic candidates'; Value = $HeuristicRows.Count }
        [pscustomobject]@{ Metric = 'Recent Event 881 records'; Value = $event881.Count }
        [pscustomobject]@{ Metric = 'Recent warning/error/critical events'; Value = $eventErrors.Count }
        [pscustomobject]@{ Metric = 'Evidence folder'; Value = $EvidenceFolder }
    )

    # CSS custom properties (variables) so light and dark mode are one
    # stylesheet, not two - $reportScript's toggleTheme()/initTheme() below
    # only ever flip the data-theme attribute on <html>; every color comes
    # from these variables. Red/amber/green status shades are deliberately
    # different (not simply inverted) between the two modes: the light-mode
    # shades are pale backgrounds with dark, saturated text, which would be
    # nearly illegible if naively inverted onto a dark background, so the
    # dark-mode shades use darker, desaturated backgrounds with light,
    # brighter text instead - both pairs independently chosen for real
    # contrast, not derived from each other.
    $css = @'
:root {
  --bg: #ffffff;
  --fg: #202124;
  --heading: #1f3a5f;
  --border: #d0d7de;
  --th-bg: #eef3f8;
  --code-bg: #f3f4f6;
  --note-bg: #fff8dc;
  --note-border: #b8860b;
  --good-bg: #eef8ee;
  --good-border: #2e7d32;
  --status-red-bg: #fdecea;
  --status-red-fg: #8a1c1c;
  --status-amber-bg: #fff4e0;
  --status-amber-fg: #7a4b00;
  --status-green-bg: #eaf7ec;
  --status-green-fg: #1e5c2c;
  --link: #0b5fff;
  --control-bg: #f6f8fa;
}

:root[data-theme="dark"] {
  --bg: #14181d;
  --fg: #e6edf3;
  --heading: #8fb4e6;
  --border: #3a4048;
  --th-bg: #232a32;
  --code-bg: #232a32;
  --note-bg: #3a3218;
  --note-border: #d9a441;
  --good-bg: #163420;
  --good-border: #4caf50;
  --status-red-bg: #4a2020;
  --status-red-fg: #ff9b93;
  --status-amber-bg: #473512;
  --status-amber-fg: #ffcf6b;
  --status-green-bg: #163a22;
  --status-green-fg: #8fe3a4;
  --link: #6ea8fe;
  --control-bg: #1c232b;
}

/* Respect the OS preference as the initial default only when the user has
   not made an explicit choice yet (before $reportScript's initTheme() runs
   and stamps data-theme on <html> from localStorage, or on a browser with
   scripting disabled). Explicit choices below always win over this. */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]):not([data-theme="dark"]) {
    --bg: #14181d;
    --fg: #e6edf3;
    --heading: #8fb4e6;
    --border: #3a4048;
    --th-bg: #232a32;
    --code-bg: #232a32;
    --note-bg: #3a3218;
    --note-border: #d9a441;
    --good-bg: #163420;
    --good-border: #4caf50;
    --status-red-bg: #4a2020;
    --status-red-fg: #ff9b93;
    --status-amber-bg: #473512;
    --status-amber-fg: #ffcf6b;
    --status-green-bg: #163a22;
    --status-green-fg: #8fe3a4;
    --link: #6ea8fe;
    --control-bg: #1c232b;
  }
}

body { font-family: Segoe UI, Arial, sans-serif; margin: 28px; color: var(--fg); background: var(--bg); }
h1, h2 { color: var(--heading); }
a { color: var(--link); }
table { border-collapse: collapse; width: 100%; margin: 12px 0 28px 0; font-size: 12px; }
th, td { border: 1px solid var(--border); padding: 6px 8px; vertical-align: top; text-align: left; }
th { background: var(--th-bg); position: sticky; top: 0; }
.note { padding: 12px; background: var(--note-bg); border-left: 4px solid var(--note-border); }
.good { padding: 12px; background: var(--good-bg); border-left: 4px solid var(--good-border); }
code { background: var(--code-bg); padding: 2px 4px; }

/* Semantic red/amber/green row coloring (Task 5), applied via classes set
   in Convert-ObjectsToHtmlTable's -StatusColumn/-LevelColumn, never via
   inline styles - the classes carry the color so a single edit to these
   rules (or the CSS variables above) re-colors every table consistently. */
.status-red   { background: var(--status-red-bg);   color: var(--status-red-fg); }
.status-amber { background: var(--status-amber-bg); color: var(--status-amber-fg); }
.status-green { background: var(--status-green-bg); color: var(--status-green-fg); }

/* Sortable/filterable table chrome (Task 4). */
th.sortable { cursor: pointer; user-select: none; }
th.sortable:hover { filter: brightness(0.95); }
:root[data-theme="dark"] th.sortable:hover { filter: brightness(1.2); }
.sort-indicator { display: inline-block; width: 1em; }
.table-filters { margin: 8px 0; display: flex; flex-wrap: wrap; gap: 12px; }
.filter-label { font-size: 12px; }
select.table-filter {
  margin-left: 4px;
  background: var(--control-bg);
  color: var(--fg);
  border: 1px solid var(--border);
  padding: 2px 4px;
}

/* Dark mode toggle button. */
#theme-toggle {
  background: var(--control-bg);
  color: var(--fg);
  border: 1px solid var(--border);
  padding: 6px 12px;
  border-radius: 4px;
  cursor: pointer;
  font-size: 13px;
  float: right;
}
#theme-toggle:hover { filter: brightness(1.1); }
'@

    # Inline vanilla JS only - no external libraries or CDN references, so
    # the report stays a single, fully self-contained file that works
    # offline and under a strict CSP. This MUST be a single-quoted, non-
    # interpolating here-string (@'...'@, not @"..."@): the JS below uses
    # both ${...}-shaped template-literal-style text in comments and plain
    # $ is never used here, but bracing this way means neither the literal
    # '{'/'}' characters nor any '$' the script is ever edited to include
    # can accidentally be parsed as PowerShell subexpressions/variables -
    # the whole block is captured as inert text and only ever emitted
    # verbatim into the page below.
    $reportScript = @'
(function () {
  "use strict";

  var THEME_KEY = "mdmwinsovergp-theme";

  // Severity rank map for the Level column's "severity" sort type (Task 4):
  // explicit rank, not alphabetical, so Critical > Error > Warning as
  // requested, and anything unrecognized sorts lowest rather than crashing.
  var severityRank = {
    "Critical": 4,
    "Error": 3,
    "Warning": 2,
    "Information": 1,
    "Verbose": 0
  };

  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    var btn = document.getElementById("theme-toggle");
    if (btn) {
      btn.textContent = theme === "dark" ? "Switch to light mode" : "Switch to dark mode";
    }
  }

  function initTheme() {
    var stored = null;
    try { stored = localStorage.getItem(THEME_KEY); } catch (e) { /* storage disabled/unavailable */ }

    var theme = stored;
    if (!theme) {
      var prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
      theme = prefersDark ? "dark" : "light";
    }
    applyTheme(theme);
  }

  function toggleTheme() {
    var current = document.documentElement.getAttribute("data-theme") || "light";
    var next = current === "dark" ? "light" : "dark";
    applyTheme(next);
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* storage disabled/unavailable */ }
  }

  function getSortValue(row, colIndex, sortType) {
    var raw = row.getAttribute("data-c" + colIndex) || "";
    if (sortType === "number") {
      var n = parseFloat(raw);
      return isNaN(n) ? -Infinity : n;
    }
    if (sortType === "date") {
      var t = Date.parse(raw);
      return isNaN(t) ? -Infinity : t;
    }
    if (sortType === "severity") {
      return Object.prototype.hasOwnProperty.call(severityRank, raw) ? severityRank[raw] : -1;
    }
    return raw.toLowerCase();
  }

  function sortTable(table, th, colIndex, sortType) {
    var tbody = table.tBodies[0];
    if (!tbody) { return; }
    var rows = Array.prototype.slice.call(tbody.rows);

    var ascending = th.getAttribute("data-sort-dir") !== "asc";

    var headerRow = table.tHead.rows[0];
    Array.prototype.forEach.call(headerRow.cells, function (cell) {
      cell.removeAttribute("data-sort-dir");
      var indicator = cell.querySelector(".sort-indicator");
      if (indicator) { indicator.textContent = ""; }
    });
    th.setAttribute("data-sort-dir", ascending ? "asc" : "desc");
    var thIndicator = th.querySelector(".sort-indicator");
    if (thIndicator) { thIndicator.textContent = ascending ? " ▲" : " ▼"; }

    rows.sort(function (a, b) {
      var va = getSortValue(a, colIndex, sortType);
      var vb = getSortValue(b, colIndex, sortType);
      if (va < vb) { return ascending ? -1 : 1; }
      if (va > vb) { return ascending ? 1 : -1; }
      return 0;
    });

    rows.forEach(function (row) { tbody.appendChild(row); });
  }

  function applyFilters(tableId) {
    var table = document.getElementById(tableId);
    if (!table || !table.tBodies[0]) { return; }

    var selects = document.querySelectorAll('select.table-filter[data-filter-table="' + tableId + '"]');
    var rows = table.tBodies[0].rows;

    for (var r = 0; r < rows.length; r++) {
      var visible = true;
      for (var s = 0; s < selects.length; s++) {
        var sel = selects[s];
        var wanted = sel.value;
        if (!wanted) { continue; }
        var col = sel.getAttribute("data-filter-col");
        var cellValue = rows[r].getAttribute("data-c" + col) || "";
        if (cellValue !== wanted) {
          visible = false;
          break;
        }
      }
      rows[r].style.display = visible ? "" : "none";
    }
  }

  function init() {
    initTheme();

    var toggleButton = document.getElementById("theme-toggle");
    if (toggleButton) {
      toggleButton.addEventListener("click", toggleTheme);
    }

    var sortableHeaders = document.querySelectorAll("th.sortable");
    Array.prototype.forEach.call(sortableHeaders, function (th) {
      th.addEventListener("click", function () {
        var table = th.closest("table");
        if (!table) { return; }
        var colIndex = parseInt(th.getAttribute("data-col"), 10);
        var sortType = th.getAttribute("data-sort") || "text";
        sortTable(table, th, colIndex, sortType);
      });
    });

    var filterSelects = document.querySelectorAll("select.table-filter");
    Array.prototype.forEach.call(filterSelects, function (sel) {
      sel.addEventListener("change", function () {
        applyFilters(sel.getAttribute("data-filter-table"));
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
'@

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>MDMWinsOverGP Validation Report</title>
<style>$css</style>
</head>
<body>
<button type="button" id="theme-toggle">Switch to dark mode</button>
<h1>MDMWinsOverGP Validation Report</h1>
<p>Computer: $(ConvertTo-HtmlEncoded $env:COMPUTERNAME)<br>
Generated: $(ConvertTo-HtmlEncoded (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))</p>

<div class="note">
<strong>Interpretation limits:</strong>
Event 881 records PolicyManager operations. It does not prove a GPO conflict or prove which authority won.
Heuristic matches are triage candidates only. Verified mappings and effective-value checks provide stronger evidence.
MDMWinsOverGP does not cover every Windows management CSP.
</div>

<h2>Summary</h2>
$(Convert-ObjectsToHtmlTable -Rows $summaryRows -Properties @('Metric','Value'))

<h2>ControlPolicyConflict state</h2>
$(Convert-ObjectsToHtmlTable -Rows @($ConflictState) -Properties @(
    'RegistryPath','KeyPresent','MDMWinsOverGP',
    'MDMWinsOverGP_ProviderSet','MDMWinsOverGP_WinningProvider','Interpretation'
))

<h2>Applied GPO settings and CSP mapping status</h2>
<p>Every GPO setting GPResult reported as applied on this device, left-joined to the optional mapping CSV and to MDM evidence. Most rows are expected to show "No known CSP mapping" - that reflects real Policy CSP coverage, not a collection error. Sort any column by clicking its header; filter by Status or WinningProvider below the table.</p>
$(Convert-ObjectsToHtmlTable -Rows $VerifiedRows -Properties @(
    'GpoSetting','GpoName','GpoState','CspArea','CspPolicy',
    'MdmEffectiveValue','WinningProvider','Status','Notes'
) -EmptyMessage 'No GPO settings were found in GPResult for this device.' `
  -Interactive -TableId 'applied-gpo-settings-table' `
  -FilterColumns @('Status','WinningProvider') -StatusColumn 'Status')

<h2>Heuristic overlap candidates</h2>
$(Convert-ObjectsToHtmlTable -Rows ($HeuristicRows | Select-Object -First 250) -Properties @(
    'Confidence','GpoSetting','GpoName','GpoState','CspArea','CspPolicy',
    'MdmEffectiveValue','WinningProvider','Status'
))

<h2>Recent warnings and errors</h2>
<p>Sortable by TimeCreated (chronological, not text) and Level (by severity rank - Critical > Error > Warning - not alphabetically).</p>
$(Convert-ObjectsToHtmlTable -Rows ($eventErrors | Select-Object -First 250) -Properties @(
    'TimeCreated','LogName','Id','Level','Message'
) -Interactive -TableId 'recent-events-table' `
  -ColumnSortTypes @{ TimeCreated = 'date'; Id = 'number'; Level = 'severity' } `
  -LevelColumn 'Level')

<h2>Event log configuration</h2>
$(Convert-ObjectsToHtmlTable -Rows $LogConfiguration -Properties @(
    'LogName','IsEnabled','RecordCount','MaximumSizeMB','LogMode'
))

<h2>Recommended review sequence</h2>
<ol>
<li>Review verified overlaps first.</li>
<li>Confirm each mapped setting belongs to Policy CSP and supports the device's Windows edition and version.</li>
<li>Compare the expected Intune value with the effective PolicyManager value.</li>
<li>Review the related GPResult entry and winning GPO.</li>
<li>Test the actual Windows behavior.</li>
<li>Use Debug and Admin events to explain timing or application failures, not as sole proof of precedence.</li>
<li>Move confirmed settings out of GPO targeting when the migration permits it.</li>
</ol>
<script>$reportScript</script>
</body>
</html>
"@

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated Windows PowerShell or PowerShell session.'
}

# Validate optional input up front so a bad path fails fast, before we spend
# time collecting evidence that would be discarded when the import later throws.
if (-not [string]::IsNullOrWhiteSpace($MappingCsv) -and -not (Test-Path -LiteralPath $MappingCsv)) {
    throw "Mapping CSV not found: $MappingCsv"
}

# Resolve the effective evidence root per the central-deployment precedence
# rules documented in the -OutputRoot/-DataRoot comment-based help: explicit
# -OutputRoot wins outright; else -DataRoot forces "<DataRoot>\Evidence";
# else the portable "<script folder>\Data\Evidence" is used if writable;
# else a machine-local ProgramData fallback is used automatically. This is
# resolved from $PSScriptRoot, never the current working directory or a
# hardcoded absolute path, so the whole toolkit folder can be copied
# anywhere - a network share, an Intune package cache, a USB stick - and
# still work, whether launched interactively or from a scheduled
# task/RMM agent with an unpredictable working directory.
$effectiveOutputRoot = Resolve-DataRoot -ScriptRoot $PSScriptRoot -ExplicitPath $OutputRoot `
    -DataRootOverride $DataRoot -SubFolderName 'Evidence'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFolder = Join-Path $effectiveOutputRoot "$env:COMPUTERNAME-$timestamp"
$folders = @{
    Root       = $outputFolder
    GPResult   = Join-Path $outputFolder 'GPResult'
    MDM        = Join-Path $outputFolder 'MDMDiagnostics'
    Events     = Join-Path $outputFolder 'Events'
    Registry   = Join-Path $outputFolder 'Registry'
    Reports    = Join-Path $outputFolder 'Reports'
}

foreach ($folder in $folders.Values) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

# Best-effort: also ensure the shared "Data\Input" convention folder exists
# next to whichever root was chosen above, as a documented place for an
# administrator to drop a hand-curated -MappingCsv for central deployments.
# This is purely a documented convenience location - nothing in this script
# reads from it automatically - so a failure to create it (e.g. the
# ProgramData fallback path structure not existing yet in some odd way)
# must never affect the run.
try {
    $inputDataFolder = Join-Path (Split-Path -Path $effectiveOutputRoot -Parent) 'Input'
    New-Item -ItemType Directory -Path $inputDataFolder -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Log -Level WARN -Message "Could not create the Data\Input convenience folder. This does not affect collection. $($_.Exception.Message)"
}

# From this point on, Write-Log also appends to Log.txt in the evidence
# folder, giving troubleshooters a structured, timestamped record that
# survives independently of the raw transcript below.
$script:LogFilePath = Join-Path $folders.Root 'Log.txt'

$transcriptPath = Join-Path $folders.Root 'Transcript.txt'
$transcriptStarted = $false
try {
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Log -Level WARN -Message "Could not start a transcript. Continuing without one. $($_.Exception.Message)"
}

$debugWasEnabled = $false
$debugEnabledByThisRun = $false
$collectionSucceeded = $false
$collectionError = $null

try {
    Write-Log -Message "Collecting MDMWinsOverGP validation evidence from $env:COMPUTERNAME"
    Write-Log -Message "Evidence folder: $outputFolder"

    $initialLogs = @(Get-DmLogConfiguration)
    $debugConfig = $initialLogs |
        Where-Object LogName -eq 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Debug' |
        Select-Object -First 1

    if ($debugConfig) {
        $debugWasEnabled = [bool]$debugConfig.IsEnabled
    }

    if ($EnableDebugLog -and -not $debugWasEnabled) {
        Write-Log -Message 'Enabling DeviceManagement Debug log...'
        # Best effort: enabling the Debug channel can fail (access denied, the
        # channel is already enabled elsewhere, policy). That must not abort the
        # whole collection, so log the reason and carry on without it.
        try {
            Set-DmDebugLogState -Enabled $true
            $debugEnabledByThisRun = $true
        }
        catch {
            Write-Log -Level WARN -Message "Could not enable the DeviceManagement Debug log; continuing without it. $($_.Exception.Message)"
        }
    }

    if ($RunGpUpdate) {
        Write-Log -Message "Running gpupdate /force (timeout ${GpUpdateTimeoutSeconds}s)..."
        # Best effort: gpupdate is a convenience refresh, not core evidence. If it
        # hangs or fails it must never take the run down with it.
        try {
            Invoke-GpUpdate -Folder $folders.GPResult -TimeoutSeconds $GpUpdateTimeoutSeconds
        }
        catch {
            Write-Log -Level WARN -Message "gpupdate step failed; continuing with collection. $($_.Exception.Message)"
        }
    }

    Write-Log -Message 'Collecting GPResult...'
    try {
        $gpFiles = Invoke-GpResultCollection -Folder $folders.GPResult
    }
    catch {
        # gpresult.exe is core evidence, so a failure here is fatal, but wrap it
        # to make clear in the log which step failed before the run aborts.
        throw "GPResult collection failed. $($_.Exception.Message)"
    }
    $gpoRows = @(Get-GpResultPolicyRows -XmlPath $gpFiles.XmlPath)
    Write-Log -Message "Parsed $($gpoRows.Count) candidate GPO setting row(s) from GPResult."
    $gpoRows | Export-Csv -LiteralPath (Join-Path $folders.Reports 'GPO-Settings.csv') -NoTypeInformation -Encoding UTF8

    Write-Log -Message 'Reading PolicyManager effective stores...'
    $mdmRegistryRows = @()
    $mdmRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' `
        -Source MDM -Scope Device

    if (Test-Path 'Registry::HKEY_USERS') {
        foreach ($sidKey in Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSChildName -match '^S-1-5-21-' }) {

            $userPath = "Registry::$($sidKey.Name)\SOFTWARE\Microsoft\PolicyManager\current\user"
            $mdmRegistryRows += Get-RegistryTreeValues -Path $userPath -Source MDM -Scope "User:$($sidKey.PSChildName)"
        }
    }

    $mdmRegistryRows | Export-Csv `
        -LiteralPath (Join-Path $folders.Registry 'PolicyManager-AllValues.csv') `
        -NoTypeInformation -Encoding UTF8

    $mdmRows = @(Get-MdmPolicyRows -RegistryRows $mdmRegistryRows)
    Write-Log -Message "Found $($mdmRows.Count) effective PolicyManager policy row(s)."
    $mdmRows |
        Select-Object Scope,Area,Policy,ValueName,EffectiveValue,RegistryPath,ProviderSet,WinningProvider |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'MDM-EffectivePolicies.csv') `
        -NoTypeInformation -Encoding UTF8

    Write-Log -Message 'Exporting classic registry policy trees...'
    $gpoRegistryRows = @()
    $gpoRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Policies' -Source GPORegistry -Scope Device
    $gpoRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' `
        -Source GPORegistry -Scope Device
    $gpoRegistryRows |
        Export-Csv -LiteralPath (Join-Path $folders.Registry 'ClassicPolicyRegistry.csv') `
        -NoTypeInformation -Encoding UTF8

    Write-Log -Message 'Reading MDMWinsOverGP state...'
    $conflictState = Get-ControlPolicyConflictState
    Write-Log -Message "MDMWinsOverGP interpretation: $($conflictState.Interpretation)"
    $conflictState |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'MDMWinsOverGP-State.csv') `
        -NoTypeInformation -Encoding UTF8

    if (-not $SkipMdmDiagnostics) {
        Write-Log -Message 'Running MdmDiagnosticsTool.exe...'
        $mdmTool = Join-Path $env:SystemRoot 'System32\MdmDiagnosticsTool.exe'
        if (Test-Path -LiteralPath $mdmTool) {
            # Best effort: MdmDiagnosticsTool.exe is supplementary evidence. A
            # failure here should not abort a collection that otherwise succeeded.
            try {
                & $mdmTool -out $folders.MDM 2>&1 |
                    Out-File -LiteralPath (Join-Path $folders.MDM 'MdmDiagnosticsTool-command.txt') -Encoding UTF8
            }
            catch {
                Write-Log -Level WARN -Message "MdmDiagnosticsTool.exe failed; continuing without it. $($_.Exception.Message)"
            }
        }
        else {
            Write-Log -Level WARN -Message 'MdmDiagnosticsTool.exe was not found.'
        }
    }

    Write-Log -Message 'Exporting DeviceManagement event logs...'
    $startTime = (Get-Date).AddHours(-$SinceHours)
    $dmEvidence = Export-DmEvents -Folder $folders.Events -StartTime $startTime
    Write-Log -Message "Collected $($dmEvidence.Events.Count) DeviceManagement event(s) since $($startTime.ToString('o'))."
    $dmEvidence.Configuration |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'EventLog-Configuration.csv') `
        -NoTypeInformation -Encoding UTF8
    $dmEvidence.Events |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'DeviceManagement-Events.csv') `
        -NoTypeInformation -Encoding UTF8

    $dmEvidence.Events |
        Where-Object Id -eq 881 |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Event-881.csv') `
        -NoTypeInformation -Encoding UTF8

    # -GenerateMappings: auto-generate a mapping CSV via Build-PolicyMappings.ps1
    # and use it for this run, UNLESS the caller also supplied an explicit
    # -MappingCsv (which always wins - logged clearly either way). This must
    # run after GPO-Settings.csv is written (a few lines above, during
    # GPResult collection) since the generator filters its output to exactly
    # the GPO settings this run observed; that ordering is verified here by
    # construction, not by convention. The entire step is non-fatal by
    # design - Invoke-PolicyMappingsGenerator never throws outward, and the
    # outer try/catch here is belt-and-suspenders on top of that.
    $effectiveMappingCsv = $MappingCsv

    if ($GenerateMappings) {
        if (-not [string]::IsNullOrWhiteSpace($MappingCsv)) {
            Write-Log -Message "-GenerateMappings was specified, but an explicit -MappingCsv ('$MappingCsv') was also supplied. The explicit -MappingCsv takes precedence for this run; Build-PolicyMappings.ps1 will not be run."
        }
        else {
            Write-Log -Message 'Generating a GPO-to-CSP mapping CSV via Build-PolicyMappings.ps1 (-GenerateMappings was specified)...'
            try {
                $gpoSettingsCsvPath = Join-Path $folders.Reports 'GPO-Settings.csv'
                $generatedMapping = Invoke-PolicyMappingsGenerator -ScriptRoot $PSScriptRoot `
                    -ReportsFolder $folders.Reports -GpoSettingsCsvPath $gpoSettingsCsvPath

                if ($generatedMapping) {
                    $effectiveMappingCsv = $generatedMapping
                    Write-Log -Message "Using the auto-generated mapping CSV for this run: '$effectiveMappingCsv'."
                }
                else {
                    Write-Log -Level WARN -Message 'Build-PolicyMappings.ps1 did not produce a usable mapping CSV. Continuing without a mapping for this run.'
                }
            }
            catch {
                Write-Log -Level WARN -Message "Mapping generation step failed unexpectedly. Continuing without a mapping for this run. $($_.Exception.Message)"
            }
        }
    }

    $mappings = @(Import-VerifiedMappings -Path $effectiveMappingCsv)
    $verifiedRows = @(Get-VerifiedOverlapRows -Mappings $mappings -GpoRows $gpoRows -MdmRows $mdmRows)
    $heuristicRows = @(Get-HeuristicOverlapRows -GpoRows $gpoRows -MdmRows $mdmRows)
    Write-Log -Message "$($mappings.Count) verified mapping row(s) supplied; $($heuristicRows.Count) heuristic overlap candidate(s) found."

    $verifiedRows |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Verified-Overlap-Results.csv') `
        -NoTypeInformation -Encoding UTF8
    $heuristicRows |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Heuristic-Overlap-Candidates.csv') `
        -NoTypeInformation -Encoding UTF8

    $templatePath = Join-Path $folders.Reports 'PolicyMappings-Template.csv'
    @(
        [pscustomobject]@{
            GpoSetting = 'Example GPO setting display name'
            GpoName    = 'Optional winning GPO name'
            CspArea    = 'ExampleArea'
            CspPolicy  = 'ExamplePolicy'
            OmaUri     = './Device/Vendor/MSFT/Policy/Config/ExampleArea/ExamplePolicy'
            Notes      = 'Replace this row with a mapping verified against Microsoft documentation.'
        }
    ) | Export-Csv -LiteralPath $templatePath -NoTypeInformation -Encoding UTF8

    Write-Log -Message 'Generating HTML report...'
    $reportPath = Join-Path $folders.Reports 'MDMWinsOverGP-Validation.html'
    try {
        New-HtmlReport `
            -Path $reportPath `
            -ConflictState $conflictState `
            -LogConfiguration $dmEvidence.Configuration `
            -Events $dmEvidence.Events `
            -GpoRows $gpoRows `
            -MdmRows $mdmRows `
            -VerifiedRows $verifiedRows `
            -HeuristicRows $heuristicRows `
            -EvidenceFolder $folders.Root
    }
    catch {
        # The CSVs above are already on disk at this point, so a report-rendering
        # failure should still surface clearly rather than as a generic error.
        throw "HTML report generation failed. The CSV evidence in '$($folders.Reports)' is still valid. $($_.Exception.Message)"
    }

    $manifest = [ordered]@{
        ComputerName        = $env:COMPUTERNAME
        Generated           = (Get-Date).ToString('o')
        WindowsVersion      = [Environment]::OSVersion.VersionString
        PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
        SinceHours          = $SinceHours
        MappingCsvRequested = $MappingCsv
        MappingCsvEffective = $effectiveMappingCsv
        GenerateMappings    = [bool]$GenerateMappings
        DataRoot            = $DataRoot
        EffectiveOutputRoot = $effectiveOutputRoot
        DebugWasEnabled     = $debugWasEnabled
        DebugEnabledByRun   = $debugEnabledByThisRun
        OutputFolder        = $folders.Root
        HtmlReport          = $reportPath
        CollectionSucceeded = $true
        CollectionError     = $null
    }

    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $folders.Root 'Manifest.json') -Encoding UTF8

    # Mark success only after every collection step and the report/manifest are
    # written, so the ZIP naming below can distinguish a complete package from a
    # partial one salvaged after a failure.
    $collectionSucceeded = $true

    Write-Log -Message 'Collection completed.'
    Write-Log -Message "HTML report: $reportPath"
}
catch {
    # Preserve the failure for the manifest/marker below, and log it with full
    # command/position context (not just the message) so troubleshooting a
    # failed run does not require reproducing it. Then re-throw so the run
    # still surfaces the error to the caller exactly as before.
    $collectionError = $_
    Write-Log -Level ERROR -Message "Collection failed: $($_.Exception.Message)"
    Write-Log -Level ERROR -Message "At: $($_.InvocationInfo.PositionMessage)"
    throw
}
finally {
    if ($DisableDebugLogAfterCollection -and $debugEnabledByThisRun) {
        try {
            Write-Log -Message 'Disabling DeviceManagement Debug log...'
            Set-DmDebugLogState -Enabled $false
        }
        catch {
            Write-Log -Level WARN -Message "Could not disable the Debug log. $($_.Exception.Message)"
        }
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }

    # When the run failed, drop a marker into the folder so the salvaged evidence
    # is self-describing rather than relying on the file name alone.
    if (-not $collectionSucceeded -and (Test-Path -LiteralPath $outputFolder)) {
        $errorText = if ($collectionError) { $collectionError.Exception.Message } else { 'Collection did not complete.' }
        try {
            @(
                'COLLECTION INCOMPLETE'
                "Timestamp: $((Get-Date).ToString('o'))"
                "Error: $errorText"
                'This package was salvaged after a failure and may be missing evidence.'
                'See Log.txt and Transcript.txt in this folder for full troubleshooting detail.'
            ) | Set-Content -LiteralPath (Join-Path $outputFolder 'COLLECTION-INCOMPLETE.txt') -Encoding UTF8
        }
        catch { }
    }

    # Package whatever evidence was collected. This runs after the transcript is
    # stopped so the transcript file is flushed and unlocked before it is zipped,
    # and it runs even on failure so a partial collection is still preserved.
    # Partial packages get a distinct name so an incomplete collection is never
    # mistaken for a successful one. A ZIP failure must not mask the underlying
    # result, so it is non-fatal.
    if (Test-Path -LiteralPath $outputFolder) {
        $zipSuffix = if ($collectionSucceeded) { '' } else { '-PARTIAL' }
        $zipPath = "$outputFolder$zipSuffix.zip"
        try {
            Compress-Archive -Path (Join-Path $outputFolder '*') -DestinationPath $zipPath -Force
            if ($collectionSucceeded) {
                Write-Log -Message "Evidence ZIP: $zipPath"
            }
            else {
                Write-Log -Level WARN -Message "Collection did not complete. Partial evidence ZIP: $zipPath"
            }
        }
        catch {
            Write-Log -Level WARN -Message "Could not create evidence ZIP. The evidence folder is still available at $outputFolder. $($_.Exception.Message)"
        }
    }
}
