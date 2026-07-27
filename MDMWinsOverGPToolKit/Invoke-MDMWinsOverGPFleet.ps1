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
    Test-MDMWinsOverGP.ps1 (already deployed to a network share) on many
    devices from a central management server:

      1. Reads a device list from -DeviceListCsv (one DeviceName column).
      2. Checks every device is online with Test-Connection before touching
         it, so unreachable devices are reported clearly instead of hanging
         or producing a confusing WinRM error.
      3. For every online device, uses Invoke-Command to launch
         Test-MDMWinsOverGP.ps1 (by default from
         \\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1,
         see -RemoteScriptPath) as a child powershell.exe process on that
         device, so the device's own exit code contract (0/1/2/3 - see
         Test-MDMWinsOverGP.ps1's help) is captured cleanly instead of being
         entangled with the remoting session's own exit semantics.
      4. Writes one summary CSV/log covering every device: online or not,
         whether the remote run started, its exit code, and what that code
         means.

    Each device's own evidence ZIP is produced and centrally collected the
    same way it already is for a single-device run: pass -ResultsShare
    through to this script (see -ResultsShare below) and every device copies
    its own ZIP there directly, using the same credential this script uses
    to connect to that device. This script itself never touches the
    evidence data - it only starts the remote run and records its outcome.

    Credentials and the "double-hop" problem:
      Invoke-Command authenticates to each device using -Credential. Beyond
      that, this script does nothing special to delegate credentials
      further (e.g. no CredSSP) - if Test-MDMWinsOverGP.ps1 on the remote
      device needs to reach a further network resource (such as
      -ResultsShare, or gpresult needing to reach a domain controller), that
      access is evaluated using the identity actually configured on the
      remote device (commonly a domain account with rights on both the
      device and the target share). If -ResultsShare copies start failing
      only when launched through this script (and work fine on the same
      device run locally), that is the classic double-hop symptom - see
      README.md's "Running Invoke-MDMWinsOverGPFleet.ps1 from a management
      server" section for delegation options (CredSSP, resource-based
      constrained delegation, or granting the device's own computer account
      write access to the share).

.PARAMETER DeviceListCsv
    Path to a CSV file with one column, DeviceName, listing the devices to
    process (hostnames or FQDNs - whatever Test-Connection/Invoke-Command
    can resolve on this management server). Duplicate and blank rows are
    ignored; a WARN is logged for each.

.PARAMETER RemoteScriptPath
    Path to Test-MDMWinsOverGP.ps1 AS SEEN FROM EACH REMOTE DEVICE (not from
    this management server) - it is passed to powershell.exe -File inside
    the remote session, so it must be a path that device itself can read
    (typically a UNC path every domain device already has read access to).
    Defaults to
    '\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1'.

.PARAMETER Credential
    Optional. Credential Invoke-Command uses to connect to every device. If
    not supplied (the default), Invoke-Command uses the current session's
    own identity - the normal case when this script is already being run as
    a domain admin (or similarly privileged) account with local admin
    rights on every target device (Test-MDMWinsOverGP.ps1 requires elevation
    for a live collection run) and, if -ResultsShare is also used, write
    access to that share as seen from each device - see the double-hop note
    above. Only pass -Credential when you need to connect as an account
    other than the one already running this script.

.PARAMETER ResultsShare
    Optional. Passed straight through as -ResultsShare to
    Test-MDMWinsOverGP.ps1 on every device, so each device's evidence ZIP is
    centrally collected in one place. See Test-MDMWinsOverGP.ps1's own
    -ResultsShare help for exactly how that copy behaves (best-effort,
    non-fatal, unique per-device file name).

.PARAMETER RemoteScriptArguments
    Optional array of additional arguments forwarded as-is to
    Test-MDMWinsOverGP.ps1 on every device, e.g.
    -RemoteScriptArguments @('-GenerateMappings','-SinceHours','48'). Do not
    include -ResultsShare here - use the dedicated -ResultsShare parameter
    instead, so it is applied consistently and is visible in the summary
    log.

.PARAMETER ThrottleLimit
    Maximum number of devices Invoke-Command processes concurrently.
    Default 10.

.PARAMETER PingCount
    Number of Test-Connection echo requests used to decide whether a device
    is online before Invoke-Command is attempted. Default 2 (a device only
    counts as online if at least one reply is received).

.PARAMETER RemoteTimeoutSeconds
    Hard ceiling, in seconds, for how long a single device's remote
    Test-MDMWinsOverGP.ps1 run may run before this script gives up waiting
    on it and marks that device as timed out. Default 1800 (30 minutes).
    This does not stop the remote process on the device itself (Windows
    PowerShell's Invoke-Command has no reliable remote-side kill for a
    detached child process) - it only stops this script from waiting
    forever; the device's own run continues and can still be inspected via
    -ResultsShare or locally on that device.

.PARAMETER SummaryOutputPath
    Optional. Path to the summary CSV this script writes covering every
    device. When not supplied, defaults to
    "<script folder>\Data\FleetRuns\<timestamp>\FleetSummary.csv" (falling
    back to a machine-local ProgramData location using the same portability
    rules as Test-MDMWinsOverGP.ps1, if the script folder is not writable).

.EXAMPLE
    .\Invoke-MDMWinsOverGPFleet.ps1 -DeviceListCsv .\Devices.csv -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results'

.EXAMPLE
    .\Invoke-MDMWinsOverGPFleet.ps1 -DeviceListCsv .\Devices.csv -Credential $cred -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results' -RemoteScriptArguments @('-GenerateMappings') -ThrottleLimit 20

.NOTES
    Per-device outcome codes recorded in the summary CSV (Outcome column):
      Success           - remote script ran and returned exit code 0.
      ConflictsFound     - remote script ran and returned exit code 2 (an
                            actionable finding, not a failure - see
                            Test-MDMWinsOverGP.ps1's exit code contract).
      DegradedEvidence   - remote script ran and returned exit code 3.
      RemoteScriptFailed - remote script ran and returned exit code 1, or
                            any other non-zero/unrecognized code.
      Offline            - Test-Connection got no reply; Invoke-Command was
                            never attempted for this device.
      ConnectionFailed   - Test-Connection succeeded but Invoke-Command
                            could not establish a session (WinRM not
                            enabled/reachable, authentication failure,
                            etc.) - see the Detail column.
      TimedOut           - the remote run did not finish within
                            -RemoteTimeoutSeconds.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceListCsv,

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
        Set-StrictMode setting can never collide with the remote script it
        launches.
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

Write-Log -Message "Invoke-MDMWinsOverGPFleet starting. DeviceListCsv='$DeviceListCsv' RemoteScriptPath='$RemoteScriptPath' ResultsShare='$ResultsShare' ThrottleLimit=$ThrottleLimit RemoteTimeoutSeconds=$RemoteTimeoutSeconds"
Write-Log -Message "Summary will be written to '$SummaryOutputPath'."

if (-not (Test-Path -LiteralPath $DeviceListCsv)) {
    Write-Log -Level ERROR -Message "-DeviceListCsv '$DeviceListCsv' was not found."
    exit 1
}

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
    Write-Log -Message "No -Credential supplied; Invoke-Command will use the current session's identity ($([Security.Principal.WindowsIdentity]::GetCurrent().Name)) - this account needs local admin rights on every target device."
}

# One result row per device, built up across the online check and the
# remote-invocation step below, then written once as the summary CSV.
$results = @{}
foreach ($name in $deviceNames) {
    $results[$name] = [PSCustomObject]@{
        DeviceName = $name
        Online     = $false
        Outcome    = 'Offline'
        ExitCode   = $null
        Detail     = ''
        StartedAt  = $null
        FinishedAt = $null
    }
}

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
        $results[$name].Detail = 'No reply to Test-Connection; Invoke-Command was not attempted.'
        Write-Log -Level WARN -Message "Device '$name' did not respond to Test-Connection and will be skipped."
    }
}

Write-Log -Message "$($onlineDevices.Count) of $($deviceNames.Count) device(s) are online and will be processed."

if ($onlineDevices.Count -gt 0) {
    # Runs on the remote device: launches Test-MDMWinsOverGP.ps1 as a
    # separate powershell.exe child process (rather than "& $ScriptPath"
    # inside the remoting session itself) specifically so the script's own
    # "exit $script:ExitCode" terminates that child process - and is
    # captured via $LASTEXITCODE - instead of tearing down the remote
    # PowerShell session Invoke-Command is using.
    $remoteScriptBlock = {
        param($ScriptPath, $ResultsShareValue, $ExtraArgs)

        $result = [PSCustomObject]@{
            ScriptFound = $false
            ExitCode    = $null
            ErrorDetail = ''
        }

        if (-not (Test-Path -LiteralPath $ScriptPath)) {
            $result.ErrorDetail = "Remote script path '$ScriptPath' was not found from this device."
            return $result
        }
        $result.ScriptFound = $true

        $argumentList = New-Object System.Collections.Generic.List[string]
        $argumentList.Add('-NoProfile')
        $argumentList.Add('-NonInteractive')
        $argumentList.Add('-ExecutionPolicy')
        $argumentList.Add('Bypass')
        $argumentList.Add('-File')
        $argumentList.Add($ScriptPath)
        if (-not [string]::IsNullOrWhiteSpace($ResultsShareValue)) {
            $argumentList.Add('-ResultsShare')
            $argumentList.Add($ResultsShareValue)
        }
        if ($ExtraArgs) {
            foreach ($extraArg in $ExtraArgs) { $argumentList.Add($extraArg) }
        }

        try {
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            $result.ExitCode = $proc.ExitCode
        }
        catch {
            $result.ErrorDetail = $_.Exception.Message
        }

        return $result
    }

    Write-Log -Message "Starting Invoke-Command against $($onlineDevices.Count) device(s) (ThrottleLimit=$ThrottleLimit)..."

    $icmErrors = $null
    $icmParams = @{
        ComputerName   = $onlineDevices
        ThrottleLimit  = $ThrottleLimit
        ScriptBlock    = $remoteScriptBlock
        ArgumentList   = @($RemoteScriptPath, $ResultsShare, $RemoteScriptArguments)
        AsJob          = $true
        ErrorVariable  = 'icmErrors'
        ErrorAction    = 'SilentlyContinue'
        JobName        = 'MDMWinsOverGPFleet'
    }
    # Only set -Credential when the caller explicitly supplied one; leaving
    # it unset makes Invoke-Command use the current session's own identity,
    # which is the normal case when this script is already running as a
    # domain admin with rights on every target device.
    if ($Credential) { $icmParams['Credential'] = $Credential }

    $icmJob = Invoke-Command @icmParams

    foreach ($name in $onlineDevices) { $results[$name].StartedAt = Get-Date }

    $completed = Wait-Job -Job $icmJob -Timeout $RemoteTimeoutSeconds

    if (-not $completed) {
        Write-Log -Level WARN -Message "Fleet run did not finish within -RemoteTimeoutSeconds ($RemoteTimeoutSeconds s). Devices still running will be marked TimedOut; the job is left running in the background under name 'MDMWinsOverGPFleet' in case it finishes shortly after (Get-Job -Name 'MDMWinsOverGPFleet' | Receive-Job)."
    }

    $childJobsByComputer = @{}
    foreach ($child in $icmJob.ChildJobs) {
        $childComputer = $child.Location
        if ($childComputer) { $childJobsByComputer[$childComputer] = $child }
    }

    $jobResults = @()
    try {
        $jobResults = @(Receive-Job -Job $icmJob -Keep -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Log -Level WARN -Message "Receive-Job reported an error while collecting results: $($_.Exception.Message)"
    }

    foreach ($item in $jobResults) {
        $computerName = $item.PSComputerName
        if (-not $computerName -or -not $results.ContainsKey($computerName)) { continue }

        $results[$computerName].FinishedAt = Get-Date

        if (-not $item.ScriptFound) {
            $results[$computerName].Outcome = 'RemoteScriptFailed'
            $results[$computerName].Detail = $item.ErrorDetail
            continue
        }

        if ($null -eq $item.ExitCode) {
            $results[$computerName].Outcome = 'RemoteScriptFailed'
            $results[$computerName].Detail = if ($item.ErrorDetail) { $item.ErrorDetail } else { 'Remote process did not report an exit code.' }
            continue
        }

        $results[$computerName].ExitCode = [int]$item.ExitCode
        $results[$computerName].Outcome = Get-RemoteExitOutcome -ExitCode ([int]$item.ExitCode)
        $results[$computerName].Detail = "Remote Test-MDMWinsOverGP.ps1 exited with code $($item.ExitCode)."
    }

    foreach ($name in $onlineDevices) {
        $row = $results[$name]
        if ($row.FinishedAt) { continue }

        if (-not $completed -and $childJobsByComputer.ContainsKey($name) -and $childJobsByComputer[$name].State -eq 'Running') {
            $row.Outcome = 'TimedOut'
            $row.Detail = "Remote run had not finished after $RemoteTimeoutSeconds second(s)."
            continue
        }

        $childState = if ($childJobsByComputer.ContainsKey($name)) { $childJobsByComputer[$name].State } else { 'Unknown' }
        $row.Outcome = 'ConnectionFailed'
        $row.Detail = "Invoke-Command did not return a result for this device (child job state: $childState). Common causes: WinRM is not enabled/reachable, or authentication failed."
    }

    if ($icmErrors) {
        foreach ($errRecord in $icmErrors) {
            $failedComputer = $null
            try { $failedComputer = $errRecord.OriginInfo.PSComputerName } catch { $failedComputer = $null }
            if ($failedComputer -and $results.ContainsKey($failedComputer) -and $results[$failedComputer].Outcome -eq 'ConnectionFailed') {
                $results[$failedComputer].Detail = $errRecord.Exception.Message
            }
            Write-Log -Level WARN -Message "Invoke-Command error: $($errRecord.Exception.Message)"
        }
    }

    Remove-Job -Job $icmJob -Force -ErrorAction SilentlyContinue
}

$summaryRows = @($deviceNames | ForEach-Object { $results[$_] })
$summaryRows | Export-Csv -LiteralPath $SummaryOutputPath -NoTypeInformation -Encoding UTF8

$outcomeCounts = $summaryRows | Group-Object -Property Outcome | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Log -Message "Fleet run complete. $($outcomeCounts -join ', ')."
Write-Log -Message "Summary written to '$SummaryOutputPath'."

$failureOutcomes = @('RemoteScriptFailed', 'ConnectionFailed', 'TimedOut')
$anyFailures = @($summaryRows | Where-Object { $_.Outcome -in $failureOutcomes }).Count -gt 0
$anyConflicts = @($summaryRows | Where-Object { $_.Outcome -in @('ConflictsFound', 'DegradedEvidence') }).Count -gt 0

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
