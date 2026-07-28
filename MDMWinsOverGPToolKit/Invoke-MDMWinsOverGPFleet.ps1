#requires -Version 5.1
<#
.SYNOPSIS
    Runs Test-MDMWinsOverGP.ps1 against a fleet of remote devices from a
    management server, and summarizes the outcome of every device in one
    place.

.DESCRIPTION
    This script is the "fleet" companion to Test-MDMWinsOverGP.ps1, which is
    designed to run locally on one device. It does not collect any evidence
    itself - it only orchestrates running the existing, unmodified
    Test-MDMWinsOverGP.ps1 on many devices from a central management server:

      1. Reads a device list from -DeviceListCsv (one DeviceName column).
      2. Checks every device is online with Test-Connection before touching
         it, so unreachable devices are reported clearly instead of hanging
         or producing a confusing WinRM error.
      3. Runs Test-MDMWinsOverGP.ps1 on every online device (see "Delivery
         modes" below), capturing that script's own documented exit code
         contract (0/1/2/3).
      4. Collects each device's evidence ZIP centrally.
      5. Writes one summary CSV/log covering every device: online or not,
         whether the remote run started, its exit code, and what that code
         means.

    Delivery modes (-DeliveryMode), i.e. how the script gets to the device
    and how its results come back:

      Copy (default, and the reason it is the default)
        The MANAGEMENT SERVER reads Test-MDMWinsOverGP.ps1 (and
        Build-PolicyMappings.ps1) from -ScriptSourcePath using its own
        logged-on credential, pushes the file contents into each remote
        session, and the device runs them from a local temp folder. The
        device writes its evidence ZIP to that same local temp folder, and
        the management server then pulls the ZIP back over the same
        already-authenticated session and, if -ResultsShare is set, writes
        it to the share itself.

        The point of this mode is that THE REMOTE DEVICE NEVER TOUCHES A
        NETWORK PATH. Every network path involved (-ScriptSourcePath,
        -ResultsShare) is accessed by the management server, running as
        your account - which is exactly the account that already has access
        to them. This sidesteps the PowerShell "double-hop" problem
        completely rather than requiring you to configure delegation.

      RemotePath (opt-in, the pre-double-hop-fix behaviour)
        The device itself opens -RemoteScriptPath over the network and, if
        -ResultsShare is set, writes its ZIP straight to the share. This
        requires credential delegation to be configured (CredSSP or
        resource-based constrained delegation); WITHOUT it, the remote
        session has no network credential and the device will report that
        the script path "was not found" even though you can browse to that
        exact path fine from the management server. Only use this mode if
        you have deliberately set delegation up.

.PARAMETER DeviceListCsv
    Path to a CSV file with one column, DeviceName, listing the devices to
    process (hostnames or FQDNs - whatever Test-Connection/Invoke-Command
    can resolve on this management server). Duplicate and blank rows are
    ignored; a WARN is logged for each.

.PARAMETER DeliveryMode
    'Copy' (default) or 'RemotePath'. See "Delivery modes" above. Copy is
    strongly recommended unless you have explicitly configured credential
    delegation.

.PARAMETER ScriptSourcePath
    Copy mode only. Path to Test-MDMWinsOverGP.ps1 AS SEEN FROM THIS
    MANAGEMENT SERVER. When not supplied, this script looks for
    Test-MDMWinsOverGP.ps1 next to itself first (the normal case when the
    whole toolkit folder is kept together), and otherwise falls back to
    '\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1'.
    Which one was chosen is logged at INFO.

    Build-PolicyMappings.ps1, if present in the same folder, is pushed
    alongside it so -GenerateMappings works on the device. Note that in Copy
    mode a mapping CSV should be produced on the device via
    -RemoteScriptArguments @('-GenerateMappings') rather than referenced by
    path, since a -MappingCsv path would be resolved by the device.

.PARAMETER RemoteScriptPath
    RemotePath mode only. Path to Test-MDMWinsOverGP.ps1 AS SEEN FROM EACH
    REMOTE DEVICE. Defaults to
    '\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1'.
    Ignored in Copy mode.

.PARAMETER Credential
    Optional. Credential used to connect to every device. If not supplied
    (the default), the current session's own identity is used - the normal
    case when this script is already being run as a domain admin (or
    similarly privileged) account with local admin rights on every target
    device. Only pass -Credential when you need to connect as an account
    other than the one already running this script.

.PARAMETER ResultsShare
    Optional. Where every device's evidence ZIP is centrally collected.

    In Copy mode (default) this path is written to BY THIS MANAGEMENT
    SERVER, as your account, after pulling each ZIP back from the device -
    so it just needs to be somewhere you can already write. In RemotePath
    mode it is passed through to Test-MDMWinsOverGP.ps1 on the device and
    the device writes to it directly (which is the part that needs
    delegation).

    When -ResultsShare is not supplied, ZIPs are collected into
    "CollectedEvidence" inside this run's own fleet output folder instead.

.PARAMETER RemoteScriptArguments
    Optional array of additional arguments forwarded as-is to
    Test-MDMWinsOverGP.ps1 on every device, e.g.
    -RemoteScriptArguments @('-GenerateMappings','-SinceHours','48'). Do not
    include -ResultsShare or -OutputRoot here - both are managed by this
    script.

.PARAMETER ThrottleLimit
    Maximum number of devices processed concurrently. Default 10.

.PARAMETER PingCount
    Number of Test-Connection echo requests used to decide whether a device
    is online before a session is attempted. Default 2 (a device only counts
    as online if at least one reply is received).

.PARAMETER RemoteTimeoutSeconds
    Hard ceiling, in seconds, for how long the remote runs may take before
    this script gives up waiting and marks still-running devices as timed
    out. Default 1800 (30 minutes). This does not stop the remote work on
    the device itself - it only stops this script from waiting forever.

.PARAMETER KeepRemoteTempFolder
    Copy mode only. Leaves the per-device temp folder (script copies,
    evidence folder, remote stdout log) on each device instead of deleting
    it after the ZIP has been retrieved. Useful when a device's run fails
    and you want to inspect what it produced in place.

.PARAMETER SummaryOutputPath
    Optional. Path to the summary CSV this script writes covering every
    device. When not supplied, defaults to
    "<script folder>\Data\FleetRuns\<timestamp>\FleetSummary.csv" (falling
    back to a machine-local ProgramData location using the same portability
    rules as Test-MDMWinsOverGP.ps1, if the script folder is not writable).

.PARAMETER DataRoot
    Optional. Pins this fleet run's output location explicitly, same
    convention as Test-MDMWinsOverGP.ps1's -DataRoot.

.EXAMPLE
    # Recommended: run as a domain admin, no delegation required anywhere.
    .\Invoke-MDMWinsOverGPFleet.ps1 -DeviceListCsv .\Devices.csv -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results'

.EXAMPLE
    .\Invoke-MDMWinsOverGPFleet.ps1 -DeviceListCsv .\Devices.csv -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results' -RemoteScriptArguments @('-GenerateMappings') -ThrottleLimit 20

.EXAMPLE
    # Only if CredSSP/constrained delegation is already configured.
    .\Invoke-MDMWinsOverGPFleet.ps1 -DeviceListCsv .\Devices.csv -DeliveryMode RemotePath -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results'

.NOTES
    Per-device outcome codes recorded in the summary CSV (Outcome column):
      Success            - remote script ran and returned exit code 0.
      ConflictsFound     - remote script ran and returned exit code 2 (an
                           actionable finding, not a failure - see
                           Test-MDMWinsOverGP.ps1's exit code contract).
      DegradedEvidence   - remote script ran and returned exit code 3.
      RemoteScriptFailed - remote script ran and returned exit code 1, or
                           any other non-zero/unrecognized code.
      Offline            - Test-Connection got no reply; no session was
                           attempted for this device.
      ConnectionFailed   - Test-Connection succeeded but a remote session
                           could not be established (WinRM not
                           enabled/reachable, authentication failure, etc.)
                           - see the Detail column.
      TimedOut           - the remote run did not finish within
                           -RemoteTimeoutSeconds.

    This script's own exit code is a fleet-wide rollup: 1 if any device
    failed to run or connect, else 2 if any device reported conflicts or
    degraded evidence, else 0. Always read FleetSummary.csv for the
    per-device breakdown.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceListCsv,

    [ValidateSet('Copy', 'RemotePath')]
    [string]$DeliveryMode = 'Copy',

    [string]$ScriptSourcePath,

    [string]$RemoteScriptPath = '\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1',

    [System.Management.Automation.PSCredential]$Credential,

    [string]$ResultsShare,

    [string[]]$RemoteScriptArguments = @(),

    [ValidateRange(1, 100)]
    [int]$ThrottleLimit = 10,

    [ValidateRange(1, 10)]
    [int]$PingCount = 2,

    [ValidateRange(60, 21600)]
    [int]$RemoteTimeoutSeconds = 1800,

    [switch]$KeepRemoteTempFolder,

    [string]$SummaryOutputPath,

    [string]$DataRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LogFilePath = $null

function Write-Log {
    <#
        Self-contained on purpose (duplicated from Test-MDMWinsOverGP.ps1
        rather than dot-sourced) so this script's scope, variables, and
        Set-StrictMode setting can never collide with the script it runs.
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
            # Logging must never be the reason this run fails.
        }
    }
}

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

function Resolve-FleetRunFolder {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$DataRootOverride
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if (-not [string]::IsNullOrWhiteSpace($DataRootOverride)) {
        $forced = Join-Path (Join-Path $DataRootOverride 'FleetRuns') $timestamp
        Write-Log -Message "Using -DataRoot override for this fleet run's output folder: '$forced'."
        return $forced
    }

    $portableBase = Join-Path $ScriptRoot 'Data'
    if (Test-PathWritable -Path $portableBase) {
        $portablePath = Join-Path (Join-Path $portableBase 'FleetRuns') $timestamp
        Write-Log -Message "Script folder is writable; using the portable fleet-run output location '$portablePath'."
        return $portablePath
    }

    $fallbackPath = Join-Path (Join-Path $env:ProgramData 'MDMWinsOverGP\Data\FleetRuns') $timestamp
    Write-Log -Message "Script folder '$ScriptRoot' is not writable. Falling back to the machine-local fleet-run output location '$fallbackPath'."
    return $fallbackPath
}

# Maps a remote Test-MDMWinsOverGP.ps1 exit code (its documented 0/1/2/3
# contract - see that script's .NOTES) to this script's own per-device
# Outcome label used in the summary CSV.
function Get-RemoteExitOutcome {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return 'Success' }
        2 { return 'ConflictsFound' }
        3 { return 'DegradedEvidence' }
        default { return 'RemoteScriptFailed' }
    }
}

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

$fleetRunFolder = Resolve-FleetRunFolder -ScriptRoot $scriptRoot -DataRootOverride $DataRoot
New-Item -ItemType Directory -Path $fleetRunFolder -Force | Out-Null
$script:LogFilePath = Join-Path $fleetRunFolder 'Log.txt'

if ([string]::IsNullOrWhiteSpace($SummaryOutputPath)) {
    $SummaryOutputPath = Join-Path $fleetRunFolder 'FleetSummary.csv'
}

Write-Log -Message "Invoke-MDMWinsOverGPFleet starting. DeliveryMode=$DeliveryMode DeviceListCsv='$DeviceListCsv' ResultsShare='$ResultsShare' ThrottleLimit=$ThrottleLimit RemoteTimeoutSeconds=$RemoteTimeoutSeconds"
Write-Log -Message "Fleet run output folder: '$fleetRunFolder'."

if (-not (Test-Path -LiteralPath $DeviceListCsv)) {
    Write-Log -Level ERROR -Message "-DeviceListCsv '$DeviceListCsv' was not found."
    exit 1
}

# ---------------------------------------------------------------------------
# Copy mode: resolve and read the toolkit scripts HERE, on the management
# server, as the account running this script. This is the whole point of Copy
# mode - the device is never asked to open a network path, so no credential
# delegation is required for the script to reach it.
# ---------------------------------------------------------------------------
$scriptPayload = @{}
if ($DeliveryMode -eq 'Copy') {
    if ([string]::IsNullOrWhiteSpace($ScriptSourcePath)) {
        $localCandidate = Join-Path $scriptRoot 'Test-MDMWinsOverGP.ps1'
        if (Test-Path -LiteralPath $localCandidate) {
            $ScriptSourcePath = $localCandidate
            Write-Log -Message "No -ScriptSourcePath supplied; using the copy next to this script: '$ScriptSourcePath'."
        }
        else {
            $ScriptSourcePath = '\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1'
            Write-Log -Message "No -ScriptSourcePath supplied and Test-MDMWinsOverGP.ps1 is not next to this script; falling back to '$ScriptSourcePath'."
        }
    }

    if (-not (Test-Path -LiteralPath $ScriptSourcePath)) {
        Write-Log -Level ERROR -Message "-ScriptSourcePath '$ScriptSourcePath' was not found or is not readable from THIS management server (as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)). Check the path and your access to it."
        exit 1
    }

    try {
        # -Encoding UTF8 is deliberate, not incidental: Test-MDMWinsOverGP.ps1
        # contains non-ASCII characters (the U+25B2/U+25BC sort-indicator
        # glyphs in the report's inline JavaScript). Letting Get-Content fall
        # back to the system codepage would corrupt them in transit.
        $scriptPayload['Test-MDMWinsOverGP.ps1'] = Get-Content -LiteralPath $ScriptSourcePath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log -Level ERROR -Message "Could not read '$ScriptSourcePath': $($_.Exception.Message)"
        exit 1
    }

    # Build-PolicyMappings.ps1 is optional, but Test-MDMWinsOverGP.ps1's
    # -GenerateMappings resolves it via its own $PSScriptRoot - so pushing it
    # into the same temp folder is what makes that switch work on the device.
    $mappingsSource = Join-Path (Split-Path -Path $ScriptSourcePath -Parent) 'Build-PolicyMappings.ps1'
    if (Test-Path -LiteralPath $mappingsSource) {
        try {
            $scriptPayload['Build-PolicyMappings.ps1'] = Get-Content -LiteralPath $mappingsSource -Raw -Encoding UTF8 -ErrorAction Stop
            Write-Log -Message "Build-PolicyMappings.ps1 found alongside the main script and will be pushed with it (enables -GenerateMappings on the device)."
        }
        catch {
            Write-Log -Level WARN -Message "Build-PolicyMappings.ps1 exists but could not be read: $($_.Exception.Message). -GenerateMappings will not work on the device."
        }
    }
    else {
        Write-Log -Level WARN -Message "Build-PolicyMappings.ps1 was not found next to '$ScriptSourcePath'. -GenerateMappings will not work on the device."
    }

    Write-Log -Message "Copy mode: $($scriptPayload.Keys.Count) script file(s) will be pushed to each device. No remote device will open a network path."
}
else {
    Write-Log -Level WARN -Message "DeliveryMode 'RemotePath' requires credential delegation (CredSSP or resource-based constrained delegation) for the device to open '$RemoteScriptPath' and, if set, write to -ResultsShare. Without it, devices will report that the script path was not found. Use the default 'Copy' mode if you have not configured delegation."
}

# ---------------------------------------------------------------------------
# Device list
# ---------------------------------------------------------------------------
$rawRows = @(Import-Csv -LiteralPath $DeviceListCsv)
if (-not $rawRows -or -not ($rawRows | Get-Member -Name 'DeviceName' -MemberType NoteProperty)) {
    Write-Log -Level ERROR -Message "-DeviceListCsv '$DeviceListCsv' must contain a 'DeviceName' column with at least one row."
    exit 1
}

$deviceNames = New-Object System.Collections.Generic.List[string]
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $rawRows) {
    $name = if ($row.DeviceName) { $row.DeviceName.ToString().Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Log -Level WARN -Message 'Skipping a row with a blank DeviceName.'
        continue
    }
    if (-not $seen.Add($name)) {
        Write-Log -Level WARN -Message "Skipping duplicate DeviceName '$name'."
        continue
    }
    $deviceNames.Add($name)
}

if ($deviceNames.Count -eq 0) {
    Write-Log -Level ERROR -Message 'No usable DeviceName rows were found after de-duplication and blank filtering.'
    exit 1
}

Write-Log -Message "$($deviceNames.Count) unique device(s) loaded from '$DeviceListCsv'."

if ($Credential) {
    Write-Log -Message "Connecting as the explicitly supplied credential '$($Credential.UserName)'."
}
else {
    Write-Log -Message "No -Credential supplied; connecting as the current session's identity ($([Security.Principal.WindowsIdentity]::GetCurrent().Name)) - this account needs local admin rights on every target device."
}

# One result row per device, built up across the online check, the remote
# run, and the evidence-collection step, then written once as the summary CSV.
$results = @{}
foreach ($name in $deviceNames) {
    $results[$name] = [PSCustomObject]@{
        DeviceName   = $name
        Online       = $false
        Outcome      = 'Offline'
        ExitCode     = $null
        CollectedZip = ''
        Detail       = ''
        StartedAt    = $null
        FinishedAt   = $null
    }
}

# ---------------------------------------------------------------------------
# Online check
# ---------------------------------------------------------------------------
Write-Log -Message "Checking online status for $($deviceNames.Count) device(s) (Test-Connection, $PingCount echo(s) each)..."
$onlineDevices = New-Object System.Collections.Generic.List[string]
foreach ($name in $deviceNames) {
    $isOnline = $false
    try {
        $isOnline = Test-Connection -ComputerName $name -Count $PingCount -Quiet -ErrorAction Stop
    }
    catch {
        $isOnline = $false
    }

    if ($isOnline) {
        $results[$name].Online = $true
        $onlineDevices.Add($name)
        Write-Log -Message "Device '$name' is online."
    }
    else {
        $results[$name].Outcome = 'Offline'
        $results[$name].Detail = 'No reply to Test-Connection; no session was attempted.'
        Write-Log -Level WARN -Message "Device '$name' did not respond to Test-Connection and will be skipped."
    }
}

Write-Log -Message "$($onlineDevices.Count) of $($deviceNames.Count) device(s) are online and will be processed."

# Where retrieved ZIPs land. In Copy mode the management server writes here
# itself (as your account), so a UNC -ResultsShare needs no delegation.
$collectionFolder = if (-not [string]::IsNullOrWhiteSpace($ResultsShare)) { $ResultsShare } else { Join-Path $fleetRunFolder 'CollectedEvidence' }

$sessions = @()

if ($onlineDevices.Count -gt 0) {

    # -----------------------------------------------------------------------
    # Establish sessions. Explicit PSSessions (rather than
    # Invoke-Command -ComputerName) because Copy mode needs a session object
    # to pull each evidence ZIP back with Copy-Item -FromSession.
    # -----------------------------------------------------------------------
    Write-Log -Message "Opening remote sessions to $($onlineDevices.Count) device(s)..."
    $sessionErrors = $null
    $sessionParams = @{
        ComputerName  = $onlineDevices
        ThrottleLimit = $ThrottleLimit
        ErrorVariable = 'sessionErrors'
        ErrorAction   = 'SilentlyContinue'
    }
    if ($Credential) { $sessionParams['Credential'] = $Credential }

    $sessions = @(New-PSSession @sessionParams)

    if ($sessionErrors) {
        foreach ($errRecord in $sessionErrors) {
            Write-Log -Level WARN -Message "Session error: $($errRecord.Exception.Message)"
        }
    }

    $connectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($session in $sessions) { [void]$connectedNames.Add($session.ComputerName) }

    foreach ($name in $onlineDevices) {
        if (-not $connectedNames.Contains($name)) {
            $results[$name].Outcome = 'ConnectionFailed'
            $results[$name].Detail = 'Responded to ping, but a PowerShell remoting session could not be established. Common causes: WinRM is not enabled/reachable (Enable-PSRemoting), a firewall is blocking 5985/5986, or authentication failed.'
            Write-Log -Level WARN -Message "Could not open a session to '$name'."
        }
    }

    Write-Log -Message "$($sessions.Count) session(s) established."
}

if ($sessions.Count -gt 0) {

    # -----------------------------------------------------------------------
    # The remote payload.
    #
    # Test-MDMWinsOverGP.ps1 is launched as a child powershell.exe process
    # (not dot-sourced or called with '&' inside the session) because it ends
    # in "exit $script:ExitCode" - running it inline would terminate the
    # remoting session instead of handing back an exit code. Calling
    # powershell.exe as a native command waits synchronously and exposes the
    # child's code via $LASTEXITCODE, which is more reliable inside a
    # remoting session than Start-Process -Wait.
    # -----------------------------------------------------------------------
    $remoteScriptBlock = {
        param($Mode, $ScriptFiles, $RemotePathValue, $ResultsShareValue, $ExtraArgs, $KeepTemp)

        $result = [PSCustomObject]@{
            ExitCode    = $null
            ZipPath     = ''
            WorkFolder  = ''
            ErrorDetail = ''
            OutputTail  = ''
        }

        try {
            if ($Mode -eq 'Copy') {
                # Local temp folder on the device. Everything the run needs -
                # the scripts, the evidence, the ZIP - lives here, so the
                # device performs no network I/O at all.
                #
                # Kept as short as possible: gpresult.exe itself rejects an
                # /x or /h output path longer than 127 characters, and
                # Test-MDMWinsOverGP.ps1 nests GPResult.xml four levels below
                # -OutputRoot ("...\<Computer>-<timestamp>\GPResult\GPResult.xml").
                # $env:windir\Temp is used instead of $env:TEMP (the user
                # profile temp folder) because its length is fixed
                # ("C:\Windows\Temp"), whereas $env:TEMP varies with the
                # logon account's username and can push the total over the
                # limit on its own; a 6-character id and no extra "Evidence"
                # subfolder keep the rest of the path minimal too. Falls back
                # to $env:TEMP if C:\Windows\Temp is not writable for some
                # reason (e.g. a locked-down device policy).
                $shortId = ([guid]::NewGuid().ToString('N')).Substring(0, 6)
                $tempBase = Join-Path $env:windir 'Temp'
                if (-not (Test-Path -LiteralPath $tempBase)) { $tempBase = $env:TEMP }
                $work = Join-Path $tempBase "MW-$shortId"
                New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
                $result.WorkFolder = $work

                foreach ($fileName in $ScriptFiles.Keys) {
                    Set-Content -LiteralPath (Join-Path $work $fileName) -Value $ScriptFiles[$fileName] -Encoding UTF8 -NoNewline -ErrorAction Stop
                }

                $targetScript = Join-Path $work 'Test-MDMWinsOverGP.ps1'
                # -OutputRoot points directly at $work (no extra "Evidence"
                # subfolder) to keep the resulting GPResult.xml path short -
                # see the path-length comment above $work's assignment. The
                # evidence subfolder Test-MDMWinsOverGP.ps1 creates under it
                # is named "<ComputerName>-<timestamp>", so it cannot collide
                # with the script files also sitting directly in $work.
                $evidenceRoot = $work
                $stdoutPath = Join-Path $work 'remote-stdout.txt'

                # -OutputRoot pins where the evidence folder and its sibling
                # ZIP land, so the ZIP can be located deterministically below
                # rather than guessed at. -ResultsShare is deliberately NOT
                # passed: the management server does that copy instead.
                $argv = @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $targetScript,
                    '-OutputRoot', $evidenceRoot
                )
                if ($ExtraArgs) { $argv += $ExtraArgs }

                & powershell.exe @argv *> $stdoutPath
                $result.ExitCode = $LASTEXITCODE

                $zip = Get-ChildItem -LiteralPath $evidenceRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($zip) { $result.ZipPath = $zip.FullName }

                if (Test-Path -LiteralPath $stdoutPath) {
                    $tail = Get-Content -LiteralPath $stdoutPath -Tail 25 -ErrorAction SilentlyContinue
                    if ($tail) { $result.OutputTail = ($tail -join "`n") }
                }

                if (-not $result.ZipPath) {
                    $result.ErrorDetail = "The remote run produced no evidence ZIP under '$evidenceRoot'."
                }
            }
            else {
                # RemotePath mode: the device opens the script over the
                # network itself and writes to -ResultsShare itself. Both
                # require credential delegation.
                if (-not (Test-Path -LiteralPath $RemotePathValue)) {
                    $result.ErrorDetail = "Remote script path '$RemotePathValue' was not found FROM THIS DEVICE. If the path is correct and reachable from the management server, this is the PowerShell double-hop problem: the remoting session has no network credential. Use the default -DeliveryMode Copy, or configure CredSSP/constrained delegation."
                    return $result
                }

                $argv = @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $RemotePathValue
                )
                if (-not [string]::IsNullOrWhiteSpace($ResultsShareValue)) {
                    $argv += @('-ResultsShare', $ResultsShareValue)
                }
                if ($ExtraArgs) { $argv += $ExtraArgs }

                & powershell.exe @argv *>&1 | Out-Null
                $result.ExitCode = $LASTEXITCODE
            }
        }
        catch {
            $result.ErrorDetail = $_.Exception.Message
            if ($Mode -eq 'Copy' -and -not $KeepTemp -and $result.WorkFolder) {
                Remove-Item -LiteralPath $result.WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        return $result
    }

    Write-Log -Message "Running Test-MDMWinsOverGP.ps1 on $($sessions.Count) device(s) (ThrottleLimit=$ThrottleLimit)..."

    $icmErrors = $null
    $icmJob = Invoke-Command -Session $sessions -ScriptBlock $remoteScriptBlock -AsJob -JobName 'MDMWinsOverGPFleet' `
        -ArgumentList $DeliveryMode, $scriptPayload, $RemoteScriptPath, $ResultsShare, $RemoteScriptArguments, ([bool]$KeepRemoteTempFolder) `
        -ErrorVariable icmErrors -ErrorAction SilentlyContinue

    foreach ($session in $sessions) { $results[$session.ComputerName].StartedAt = Get-Date }

    $completed = Wait-Job -Job $icmJob -Timeout $RemoteTimeoutSeconds

    if (-not $completed) {
        Write-Log -Level WARN -Message "Fleet run did not finish within -RemoteTimeoutSeconds ($RemoteTimeoutSeconds s). Devices still running are marked TimedOut; their own runs continue on the device."
    }

    $childJobsByComputer = @{}
    foreach ($child in $icmJob.ChildJobs) {
        if ($child.Location) { $childJobsByComputer[$child.Location] = $child }
    }

    $jobResults = @()
    try {
        $jobResults = @(Receive-Job -Job $icmJob -Keep -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Log -Level WARN -Message "Receive-Job reported an error while collecting results: $($_.Exception.Message)"
    }

    # Sessions keyed by name, so the evidence pull below can find the right
    # one for each returned result.
    $sessionsByName = @{}
    foreach ($session in $sessions) { $sessionsByName[$session.ComputerName] = $session }

    foreach ($item in $jobResults) {
        $computerName = $item.PSComputerName
        if (-not $computerName -or -not $results.ContainsKey($computerName)) { continue }

        $row = $results[$computerName]
        $row.FinishedAt = Get-Date

        if ($null -eq $item.ExitCode) {
            $row.Outcome = 'RemoteScriptFailed'
            $row.Detail = if ($item.ErrorDetail) { $item.ErrorDetail } else { 'The remote process did not report an exit code.' }
            Write-Log -Level WARN -Message "[$computerName] $($row.Detail)"
        }
        else {
            $row.ExitCode = [int]$item.ExitCode
            $row.Outcome = Get-RemoteExitOutcome -ExitCode ([int]$item.ExitCode)
            $row.Detail = "Test-MDMWinsOverGP.ps1 exited with code $($item.ExitCode)."
            if ($item.ErrorDetail) { $row.Detail = "$($row.Detail) $($item.ErrorDetail)" }
        }

        # ------------------------------------------------------------------
        # Copy mode evidence retrieval: pull the ZIP back over the session
        # that is already authenticated, then let THIS machine write it to
        # $collectionFolder as your account. This is the second half of
        # avoiding the double-hop - the device never writes to the share.
        # ------------------------------------------------------------------
        if ($DeliveryMode -eq 'Copy' -and $item.ZipPath) {
            try {
                if (-not (Test-Path -LiteralPath $collectionFolder)) {
                    New-Item -ItemType Directory -Path $collectionFolder -Force -ErrorAction Stop | Out-Null
                }
                # The remote ZIP is already named "<Computer>-<timestamp>.zip"
                # by Test-MDMWinsOverGP.ps1, so it cannot collide with
                # another device's.
                Copy-Item -FromSession $sessionsByName[$computerName] -LiteralPath $item.ZipPath `
                    -Destination $collectionFolder -Force -ErrorAction Stop
                $row.CollectedZip = Join-Path $collectionFolder (Split-Path -Path $item.ZipPath -Leaf)
                Write-Log -Message "[$computerName] Evidence collected to '$($row.CollectedZip)'."
            }
            catch {
                Write-Log -Level WARN -Message "[$computerName] Ran successfully but its evidence ZIP could not be retrieved to '$collectionFolder': $($_.Exception.Message)"
                $row.Detail = "$($row.Detail) Evidence retrieval failed: $($_.Exception.Message)"
            }
        }

        # Surface the tail of the remote console output when something went
        # wrong, so a failure is diagnosable without logging on to the device.
        if ($row.Outcome -eq 'RemoteScriptFailed' -and $item.OutputTail) {
            Write-Log -Level WARN -Message "[$computerName] Last lines of remote output:`n$($item.OutputTail)"
        }

        # Clean up the device's temp folder once its ZIP is safely retrieved.
        if ($DeliveryMode -eq 'Copy' -and -not $KeepRemoteTempFolder -and $item.WorkFolder) {
            try {
                Invoke-Command -Session $sessionsByName[$computerName] -ErrorAction Stop -ArgumentList $item.WorkFolder -ScriptBlock {
                    param($Folder)
                    Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-Log -Level WARN -Message "[$computerName] Could not remove the temp folder '$($item.WorkFolder)': $($_.Exception.Message)"
            }
        }
    }

    # Any connected device that never returned a result: timed out, or the
    # session died mid-run.
    foreach ($session in $sessions) {
        $name = $session.ComputerName
        $row = $results[$name]
        if ($row.FinishedAt) { continue }

        if (-not $completed -and $childJobsByComputer.ContainsKey($name) -and $childJobsByComputer[$name].State -eq 'Running') {
            $row.Outcome = 'TimedOut'
            $row.Detail = "The remote run had not finished after $RemoteTimeoutSeconds second(s). It continues on the device; re-run with a higher -RemoteTimeoutSeconds or collect its evidence manually."
        }
        else {
            $childState = if ($childJobsByComputer.ContainsKey($name)) { $childJobsByComputer[$name].State } else { 'Unknown' }
            $row.Outcome = 'RemoteScriptFailed'
            $row.Detail = "No result was returned for this device (job state: $childState)."
        }
        Write-Log -Level WARN -Message "[$name] $($row.Detail)"
    }

    if ($icmErrors) {
        foreach ($errRecord in $icmErrors) {
            Write-Log -Level WARN -Message "Invoke-Command error: $($errRecord.Exception.Message)"
        }
    }

    Remove-Job -Job $icmJob -Force -ErrorAction SilentlyContinue
}

if ($sessions.Count -gt 0) {
    Remove-PSSession -Session $sessions -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$summaryRows = @($deviceNames | ForEach-Object { $results[$_] })
$summaryRows | Export-Csv -LiteralPath $SummaryOutputPath -NoTypeInformation -Encoding UTF8

$outcomeCounts = $summaryRows | Group-Object -Property Outcome | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Log -Message "Fleet run complete. $($outcomeCounts -join ', ')."
if ($DeliveryMode -eq 'Copy') {
    Write-Log -Message "Evidence ZIPs collected to '$collectionFolder'."
}
Write-Log -Message "Summary written to '$SummaryOutputPath'."

$failureOutcomes = @('RemoteScriptFailed', 'ConnectionFailed', 'TimedOut')
$anyFailures = @($summaryRows | Where-Object { $failureOutcomes -contains $_.Outcome }).Count -gt 0
$anyConflicts = @($summaryRows | Where-Object { @('ConflictsFound', 'DegradedEvidence') -contains $_.Outcome }).Count -gt 0

if ($anyFailures) {
    Write-Log -Level WARN -Message 'At least one device failed to run or connect. Review the Detail column in the summary CSV.'
    exit 1
}
elseif ($anyConflicts) {
    Write-Log -Message 'At least one device reported conflicts and/or degraded evidence. This is an actionable finding, not a failure - review each device''s own evidence package.'
    exit 2
}
else {
    Write-Log -Message 'All processed devices completed successfully with no conflicts detected.'
    exit 0
}
