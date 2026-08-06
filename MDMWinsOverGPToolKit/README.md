I created the PowerShell toolkit:

[Download the MDMWinsOverGP Validation Toolkit](sandbox:/mnt/data/MDMWinsOverGP-Validation-Toolkit.zip)

The ZIP contains:

* Test-MDMWinsOverGP.ps1
* PolicyMappings-Sample.csv
* README.txt

Run it from an elevated PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass

.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -RunGpUpdate `
  -SinceHours 24
```

([Microsoft Learn][1])olicyManager device and user settings.

* ProviderSet and WinningProvider metadata where Windows exposes it.
* The "Blocked Group Policies" table parsed directly out of `MdmDiagReport.html` - Windows' own authoritative statement of which GPOs it actually blocked because MDM had configured the equivalent policy (see "Blocked Group Policies (authoritative evidence)" below).
* GPResult in XML, HTML, and text formats.
* MDM diagnostic reports.
* DeviceManagement Admin, Operational, and Debug logs.
* Event 881 records.
* Traditional policy registry locations.
* Verified GPO-to-CSP overlaps from a mapping CSV.
* Heuristic overlap candidates based on policy names.
* A consolidated HTML report.
* CSV reports and the original EVTX files.
* A ZIP evidence package.

The main result is:

```text
Reports\MDMWinsOverGP-Validation.html
```

The report separates results into two important categories.

Verified mapping means you added a documented GPO-to-Policy-CSP relationship to the mapping CSV.

Heuristic candidate means the GPO and MDM setting names appear related. It is only a review candidate. It is not treated as proof of a conflict.

This distinction matters because Windows does not provide a complete machine-readable mapping between every GPResult setting and every Policy CSP setting. MDMWinsOverGP applies to Policy CSP policies, not every CSP or every Intune setting. Microsoft also documents specific exceptions, including Defender CSP and Windows Hello for Business policies. ([Microsoft Learn][1])([Microsoft Learn][1])or the best test sequence:

1. Run the script with `-EnableDebugLog`.
2. Trigger an Intune sync.
3. Run `gpupdate /force`.
4. Trigger another Intune sync.
5. Run the script again with a wider period:

```powershell
.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -SinceHours 48
```

You can disable the Debug log automatically after collection:

```powershell
.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -DisableDebugLogAfterCollection `
  -RunGpUpdate
```

Microsoft supports MDM diagnostic collection through `MdmDiagnosticsTool.exe`, and the DeviceManagement Enterprise Diagnostics Provider Admin and Debug channels are the main local Windows logs for MDM processing. ([Microsoft Learn][2])liberately does not treat Event 881 as proof of a conflict. It records those events as PolicyManager activity and uses them as supporting evidence only.

MDMWinsOverGP Validation Script

Files
- Test-MDMWinsOverGP.ps1
- Build-PolicyMappings.ps1
- PolicyMappings-Sample.csv

Recommended first run

Open Windows PowerShell 5.1 or PowerShell 7 as Administrator:

Set-ExecutionPolicy -Scope Process Bypass
.\Test-MDMWinsOverGP.ps1 -EnableDebugLog -RunGpUpdate -SinceHours 24

For a cleaner test sequence:
1. Enable the Debug channel.
2. Trigger an Intune sync from Settings or Company Portal.
3. Run gpupdate /force.
4. Trigger another Intune sync.
5. Run the script again without clearing the logs.

Example with verified mappings:

.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -MappingCsv .\PolicyMappings-Sample.csv `
  -SinceHours 48

Example that auto-generates the mapping CSV via Build-PolicyMappings.ps1
instead of supplying one by hand (see "Chaining the two scripts" below):

.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -GenerateMappings `
  -SinceHours 48

Main outputs (written under `Reports\` inside the timestamped evidence
folder for this run - see "Where data lives" below for where that folder
itself is created)
- Reports\MDMWinsOverGP-Validation.html (interactive, sortable/filterable, dark-mode-capable)
- Reports\Blocked-GroupPolicies.csv (parsed from MDMDiagReport.html - see "Blocked Group Policies (authoritative evidence)" below)
- Reports\Verified-Overlap-Results.csv
- Reports\Heuristic-Overlap-Candidates.csv
- Reports\MDM-EffectivePolicies.csv
- Reports\GPO-Settings.csv
- Reports\Event-881.csv
- Reports\PolicyMappings-Generated.csv and PolicyMappings-Generated-Filtered.csv (only written when `-GenerateMappings` was passed)
- Events\*.evtx
- GPResult\GPResult.html
- GPResult\GPResult.xml
- MDMDiagnostics\ (including MdmDiagnosticsTool.exe's own MDMDiagReport.html)
- A ZIP containing the full evidence package, optionally also copied to `-ResultsShare` (see below)

## Blocked Group Policies (authoritative evidence)

`MdmDiagnosticsTool.exe` (run automatically unless `-SkipMdmDiagnostics` is
passed) writes `MDMDiagReport.html` into the evidence package's
`MDMDiagnostics\` folder. That report has its own section titled **"Blocked
Group Policies"**, subtitled "Group Policies that were blocked from GP
Engine because MDM has configured the equivalent policy" - this is
**Microsoft's own statement, from Windows itself, of which GPOs were
actually blocked** because MDMWinsOverGP took effect. It is categorically
stronger evidence than anything else in this report: every other section
(verified mappings, heuristic name-matching, Event 881, WinningProvider) is
either an inference this toolkit makes or supplementary context: this
section is not - it is Windows reporting the outcome directly.

`Test-MDMWinsOverGP.ps1` parses that table (via `Get-BlockedGroupPolicyRows`)
and surfaces it:
- As the first content section of the HTML report, immediately after the
  Summary and above every other (comparatively weaker) evidence section -
  **but only when there is something to show or a warning to raise.** When
  Windows genuinely reported an empty table (`ParseStatus` `EmptyTable`),
  this prominent section is skipped entirely rather than shown as a
  reassuring green "all clear" banner: `MDMDiagReport.html` is not reliable
  enough at confirming the absence of a conflict for an empty table to be
  presented that way. Instead you get one small, plain, factual line of
  text - "No other Group Policies were reported as blocked in the Intune
  MDM diagnostics report." - placed below the Heuristic overlap candidates
  table (see "Interpretation" below), with no color styling. A genuine
  parse failure (`HeadingNotFound`/`TableNotFound`/`FileMissing`/
  `ParseError`) or `Skipped` (from `-SkipMdmDiagnostics`) still gets the
  full, clearly visible top-of-report warning section - that distinction is
  the entire point of this design; only the "genuinely empty" case is
  softened, not the "unknown" case.
- As `Reports\Blocked-GroupPolicies.csv`.
- As a Summary metric row (a bare count, e.g. "0 (reported by Windows)" -
  deliberately not "confirmed"/"clean"/"no conflicts") and as part of the
  exit-code contract (see "Exit codes" below) - a non-empty blocked-GPO
  table always yields exit code `2` regardless of what any other section
  found.

**Why this can't use a real HTML/DOM parser, and what that means for you.**
`Invoke-WebRequest -UseBasicParsing` does not build a usable DOM for a local
file under Windows PowerShell 5.1, and the alternative - the `HTMLFile` COM
object - depends on legacy MSHTML/IE components that are not guaranteed to
be present on a modern Windows 11 device (this toolkit's actual central-
deployment target). The parser therefore uses careful, narrow, non-greedy,
explicitly timeout-bounded regular expressions instead. **Microsoft can
change `MDMDiagReport.html`'s markup at any time without notice**, and this
parser was written without access to a real sample of that file - it is
based on the documented heading/subtitle text and an ordinary HTML `<table>`
structure, and it is deliberately defensive about that uncertainty:

- If the report file is missing, its "Blocked Group Policies" heading text
  can't be found, no `<table>` follows that heading, or an unexpected error
  occurs while parsing, the run logs a clear `WARN` explaining exactly which
  step failed, and **never silently reports zero rows** in that case.
- This is tracked as a distinct `ParseStatus` on every result (`Found`,
  `EmptyTable`, `HeadingNotFound`, `TableNotFound`, `FileMissing`,
  `ParseError`, or `Skipped` when `-SkipMdmDiagnostics` was passed) so "the
  table was genuinely empty" and "we failed to parse the table" can never be
  confused with each other - both the HTML report and Log.txt state which
  one happened, in plain language. Neither case is presented as proof there
  is no conflict: `EmptyTable` gets a modest, unstyled footnote (see above),
  never a confident "0 conflicts" claim.
- **If parsing failed, the report shows an explicit warning, not a
  reassuring green "0".** In that situation, absence of rows must NOT be
  read as absence of conflicts - open `MDMDiagnostics\MDMDiagReport.html`
  in the evidence package by hand and look for its own "Blocked Group
  Policies" section yourself.

Interpretation
- The "Applied GPO settings and CSP mapping status" report section lists
  *every* GPO setting GPResult reported as applied on this device - not just
  ones with a mapping. Most rows are expected to say "No known CSP mapping";
  that reflects real Policy CSP coverage, not a collection problem. Rows
  with both a mapping and MDM evidence are the strongest signal ("Confirmed
  overlap") and are what the Summary's "Verified overlaps" count reflects.
- Heuristic candidate: Similar names only. It is not proof of a conflict.
  That said, the "Heuristic overlap candidates" section sits in a strong
  orange/amber highlighted box near the top of the report (right after
  Blocked Group Policies, ahead of "Applied GPO settings"), because
  real-world use has shown these unverified candidates frequently do turn
  out to be actual confirmed conflicts once manually reviewed - so they are
  worth checking closely even though the underlying data is still only a
  name-similarity guess, not proof. The section is sortable/filterable like
  the other interactive tables (by Confidence, CspArea, WinningProvider).
- WinningProvider: Reported only where PolicyManager exposes the related metadata.
- Event 881: PolicyManager activity. It is not proof that MDM overrode GPO.
- The HTML report's tables can be sorted by clicking a column header (click
  again to reverse), and the "Applied GPO settings" and "Recent warnings and
  errors" tables also support dropdown filtering / severity-ranked sorting.
  A dark mode toggle in the top-right remembers your choice (via
  `localStorage`) and otherwise follows your OS's light/dark preference. All
  of this is plain, inline, offline-capable JavaScript/CSS - no external
  files or network calls, so the report works fully offline and under a
  strict CSP.


[1]: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-controlpolicyconflict?utm_source=chatgpt.com "Policy CSP - ControlPolicyConflict"
[2]: https://learn.microsoft.com/en-us/windows/client-management/mdm-collect-logs?utm_source=chatgpt.com "Collect MDM logs"

## Central deployment

This toolkit is designed to be copied anywhere and run unattended - a
network share, an Intune Win32 app, an SCCM package, or pushed by an RMM
tool - and to work the same way whether launched interactively or from a
scheduled task/deployment agent with an unpredictable working directory.

- **No hardcoded absolute paths.** Every path both scripts use, including
  how `Test-MDMWinsOverGP.ps1 -GenerateMappings` locates
  `Build-PolicyMappings.ps1`, is resolved from `$PSScriptRoot` (the folder
  the running script itself lives in), never `.\`, `Get-Location`, or a
  hardcoded drive/UNC path. Copy the whole `MDMWinsOverGPToolKit` folder
  anywhere and both scripts still find each other.
- **Where data lives.** Both scripts write and read under one `Data` folder
  next to the scripts, with purpose-named subfolders created automatically
  on demand:
  - `Data\Evidence\` - timestamped per-run evidence packages from
    `Test-MDMWinsOverGP.ps1` (this replaces the previous default of
    `%PUBLIC%\Documents\MDMWinsOverGP-Validation`).
  - `Data\Mappings\` - the mapping CSV `Build-PolicyMappings.ps1` writes
    when run standalone without an explicit `-OutputPath`.
  - `Data\Input\` - a documented convenience location for a hand-curated
    `-MappingCsv`; nothing reads from it automatically, it is just where an
    administrator can drop one for a central deployment.

  (When `Test-MDMWinsOverGP.ps1 -GenerateMappings` invokes
  `Build-PolicyMappings.ps1` itself, the generated mapping is written
  directly into that run's own `Reports\` folder, not into `Data\Mappings\`
  - see "Chaining the two scripts" below.)
- **Read-only/locked script folders (the common central-deployment case).**
  A UNC share, an Intune package cache, or a signed/locked deployment folder
  is very often not writable. Both scripts probe `Data\` for writability at
  startup (create the folder / write a temp file, catch failure) before
  using it. If it is not writable, they automatically fall back to a
  machine-local location under `$env:ProgramData\MDMWinsOverGP\Data`, which
  is normally writable even running as SYSTEM, and log clearly at INFO which
  root was chosen and why. An administrator can also force an explicit
  location for either script with `-DataRoot '\\server\share\...'` (or any
  local/UNC path); `-DataRoot` itself is always overridden by a more
  specific explicit path (`-OutputRoot` / `-OutputPath`) if one is also
  supplied.
- **UNC paths** work throughout - both scripts use `Join-Path` rather than
  string concatenation and `-LiteralPath` on every cmdlet that reads/writes
  a path, so a path like `\\fileserver\share\MDMWinsOverGP` behaves the same
  as a local path.
- **No interactive prompts.** Neither script prompts for input; both are
  safe to run as SYSTEM via a deployment tool. `gpupdate /force` (via
  `-RunGpUpdate`) is the one place Windows itself can normally show an
  interactive "log off now? (Y/N)" prompt - `Invoke-GpUpdate` defuses this
  by redirecting `gpupdate`'s stdin from a file of `N` answers (not the
  console), which holds under a non-interactive SYSTEM context exactly as it
  does interactively, plus a hard timeout as a second guarantee.
- **No network/external dependencies at runtime.** The generated HTML
  report's sorting/filtering/dark-mode behavior is 100% inline, vanilla
  JavaScript and CSS - no CDN links, no external files - so the whole
  toolkit works on an isolated/air-gapped machine.

## Central result collection (`-ResultsShare`)

For a fleet-wide deployment, running the collector on every machine is only
half the job - an administrator also needs the results to actually land
somewhere central. Pass `-ResultsShare` (a UNC path or any other writable
folder) and, after the local evidence ZIP is created, `Test-MDMWinsOverGP.ps1`
also copies it there:

```powershell
.\Test-MDMWinsOverGP.ps1 -GenerateMappings -ResultsShare '\\fileserver\share\MDMWinsOverGP-Results'
```

- **Unique, self-describing names.** The ZIP's own file name already
  includes the computer name and a per-run timestamp
  (`<ComputerName>-<yyyyMMdd-HHmmss>.zip`, or `...-PARTIAL.zip` for a
  salvaged failed run), so results from many machines - and repeated runs on
  the same machine - never collide on the results share.
- **Fully non-fatal.** The copy is wrapped in its own try/catch: an
  unreachable share, an access-denied error, or a full destination disk is
  logged as a `WARN` and never changes the run's outcome or exit code, and
  never removes or replaces the local evidence. The local ZIP in the
  evidence folder is always the authoritative copy regardless of whether the
  central copy succeeds.
- **Runs even for a partial/failed collection.** The copy step lives in the
  same `finally` block as ZIP creation itself, so a `-PARTIAL` ZIP from a
  run that hit a fatal error still gets uploaded - that is genuinely useful
  diagnostic data for a central admin troubleshooting a fleet-wide rollout,
  not something to withhold just because the run didn't fully succeed.
- **Works as SYSTEM.** A centrally deployed run (Intune Win32 app, SCCM,
  scheduled task, RMM push) normally runs as the `SYSTEM` account, which
  authenticates to network shares as the machine account
  (`DOMAIN\ComputerName$`), not as any signed-in user. **The destination
  share/folder must grant write (Modify) permission to either the specific
  machine accounts involved, `Domain Computers`, or `Authenticated Users`**
  - a share that only grants access to user accounts will silently fail
  this copy (logged as a `WARN`, evidence still collected locally) when run
  under SYSTEM.
- **UNC-safe.** Implemented with `Join-Path`/`-LiteralPath` throughout
  (never string concatenation), matching this toolkit's existing UNC-path
  conventions - see "Central deployment" above.

## Replaying a previous run (`-ReplayFromPath`)

Collection (`gpresult.exe`, registry walks under `HKLM`, `MdmDiagnosticsTool.exe`,
`wevtutil`/`Get-WinEvent` event export) is comparatively slow and requires an
elevated session. Most iteration, though, happens on the *analysis/report*
side - overlap matching, the Blocked Group Policies parser, the interactive
HTML report. `-ReplayFromPath` lets you re-run just that side, repeatedly,
against the same real device data, without re-collecting anything and
**without needing to be elevated**:

```powershell
.\Test-MDMWinsOverGP.ps1 -ReplayFromPath 'C:\ProgramData\MDMWinsOverGP\Data\Evidence\CONTOSO-PC01-20260701-120000'
```

**What it needs.** `-ReplayFromPath` must point at one of this script's own
`<ComputerName>-<timestamp>` evidence folders (or its unzipped equivalent).
This is validated up front, before any output folder is created: if
`GPResult\GPResult.xml`, `Reports\`, `Registry\PolicyManager-AllValues.csv`,
`Reports\MDMWinsOverGP-State.csv`, `Reports\EventLog-Configuration.csv`, or
`Reports\DeviceManagement-Events.csv` is missing, the script throws a
specific, named list of what is missing instead of silently producing an
empty or misleading report.

**What it skips.** Nothing in replay mode touches the registry, event logs,
`gpresult.exe`, `gpupdate.exe`, or `wevtutil.exe` - it only reads back files
a previous run already produced. Because of that, `Test-IsAdministrator` is
only enforced when *not* replaying. `-SinceHours`, `-EnableDebugLog`,
`-RunGpUpdate`, and `-SkipMdmDiagnostics` all have no effect in this mode
(each logs a `WARN` up front if you pass it alongside `-ReplayFromPath`,
rather than being silently ignored).

**What it does instead of live collection:**
- GPO settings are parsed from the replayed `GPResult.xml` with the exact
  same parser a live run uses.
- MDM PolicyManager rows are read back from the replayed
  `Registry\PolicyManager-AllValues.csv`.
- The classic GPO registry snapshot (not used in overlap analysis) is
  copied forward unparsed.
- DeviceManagement event data is read back from the replayed
  `EventLog-Configuration.csv`/`DeviceManagement-Events.csv`.
- The MDMWinsOverGP/`ControlPolicyConflict` state is read back from the
  replayed `Reports\MDMWinsOverGP-State.csv`.
- **The "Blocked Group Policies" table is deliberately NOT read back from
  the old exported CSV.** It is re-parsed live, every time, from the
  replayed `MDMDiagnostics\MDMDiagReport.html`, so changes to
  `Get-BlockedGroupPolicyRows` can be tested against the same real report
  repeatedly - this is the main reason `-ReplayFromPath` exists.
- GPResult files, the `MDMDiagnostics` folder, `.evtx` files under
  `Events\`, and the classic registry CSV are all copied forward
  untouched, so the new run's evidence folder is still one complete,
  self-contained package with the same layout as a live run.

**Mapping CSV reuse.** If you don't pass `-MappingCsv`, the script looks in
`$ReplayFromPath\Reports` for a mapping CSV a previous `-GenerateMappings`
run already produced (`PolicyMappings-Generated-Filtered.csv`, falling back
to `PolicyMappings-Generated.csv`) and reuses it automatically, logging
which file it chose. An explicit `-MappingCsv` always wins. You can still
pass `-GenerateMappings` alongside `-ReplayFromPath` to force a fresh, live
mapping regeneration - that step doesn't require elevation either and keeps
working exactly as it does for a live run.

**Every other run's own outputs.** Every replay still produces a brand-new,
normal `<ComputerName>-<timestamp>` evidence folder - `-ReplayFromPath` is
never overwritten or reused as the output location. Overlap analysis, the
Blocked Group Policies report section, the interactive HTML report (dark
mode, sorting, filtering), Summary metrics, `Manifest.json` (which
additionally records `IsReplay` and `ReplaySourceFolder` for provenance),
`-ResultsShare`, ZIP creation, and the exit-code contract all run exactly as
they do for a live run, against the replayed/reconstructed data.

## Exit codes

`Test-MDMWinsOverGP.ps1` sets the process exit code (`exit <n>` at the very
end of the script, after all cleanup - transcript stop, Debug-log restore,
evidence ZIP, and `-ResultsShare` copy - has already run) to a small,
documented contract so a deployment tool can tell what happened without
parsing Log.txt:

| Code | Meaning |
|---|---|
| `0` | Completed successfully. No blocked GPOs or confirmed conflicts were detected. |
| `1` | Fatal error. Collection did not complete - see Log.txt and, if present, COLLECTION-INCOMPLETE.txt in the evidence folder. |
| `2` | Completed successfully, but blocked GPOs and/or confirmed overlaps **were** detected. This is an actionable finding, not a failure - do not treat it the same as `1`. |
| `3` | Completed, but with degraded/partial evidence: MDM diagnostics were skipped (`-SkipMdmDiagnostics`), or the "Blocked Group Policies" table in MDMDiagReport.html could not be parsed. A "0" elsewhere in this run is **not conclusive** when this code is returned. |

The chosen exit code and its meaning are always logged at `INFO` as the last
line written to `Log.txt`, e.g. `Exit code: 2 - Completed successfully;
blocked GPOs/confirmed overlaps WERE detected (...)`.

**Precedence when more than one condition applies:** a fatal error (`1`)
always wins. Otherwise, an actionable finding (`2`) is reported even if the
evidence was also degraded in some other respect, since a real, positively
detected conflict is more actionable information than a caveat about
missing evidence; only when nothing was detected does a degraded-evidence
run report `3` instead of `0` (a clean `0` requires evidence good enough to
actually support that conclusion).

### Consuming this from an Intune Win32 app

Configure the Win32 app's **install** detection to be satisfied by the
script simply running (e.g. presence of `Manifest.json` or the evidence
folder), since this script is a data-collection tool, not something that
changes device state - exit codes `0`-`3` all represent a *completed* run in
that sense. If you want Intune's install/detection *status* itself to
reflect whether a conflict was found, wrap the call and translate the
script's exit code into whatever your own install script/detection script
convention expects, e.g.:

```powershell
& "$PSScriptRoot\Test-MDMWinsOverGP.ps1" -GenerateMappings -ResultsShare '\\fileserver\share\MDMWinsOverGP-Results'
$scriptExit = $LASTEXITCODE
# $scriptExit: 0/2/3 = collection completed (2/3 carry extra meaning - see
# table above); 1 = collection failed. Map to your own Win32 app / RMM
# convention here, e.g. treat 1 as a genuine install failure and 0/2/3 as
# success with an informational code recorded elsewhere (Log.txt, your RMM's
# custom-field/tagging mechanism, etc.).
exit 0
```

(A Win32 app's *own* exit code is usually best kept `0`/success once the
collector has run at all - see above - with the richer 0/1/2/3 signal
consumed separately, e.g. by a companion detection script or an RMM
custom-field script that inspects `$LASTEXITCODE` or re-parses
`Manifest.json`'s `BlockedGroupPoliciesParseStatus`/`BlockedGroupPoliciesCount`
fields, since most Win32 app "detection" mechanisms are not designed to
carry a 4-state result.)

### Consuming this from a generic RMM

Most RMM tools (NinjaOne, Datto, Action1, etc.) can run a PowerShell script
as a monitor/task and read its exit code directly, often exposing it as a
built-in "script exit code" condition/alert. Point that at
`Test-MDMWinsOverGP.ps1` directly:

```powershell
Test-MDMWinsOverGP.ps1 -GenerateMappings -ResultsShare '\\fileserver\share\MDMWinsOverGP-Results'
exit $LASTEXITCODE
```

and alert on `1` (fatal - investigate the machine) and, separately, `2`
(informational/actionable - a real MDM/GPO conflict was found and is worth
reviewing, but the run itself succeeded) however your RMM's alerting
supports distinguishing severities. Treat `3` as "re-run or investigate
when convenient" - it means the run completed but couldn't fully answer the
question this toolkit exists to answer.

## Invoke-MDMWinsOverGPFleet.ps1 (running against a fleet from a management server)

`Test-MDMWinsOverGP.ps1` is designed to run on one device at a time -
locally, via Intune Win32 app, SCCM, or an RMM push. `Invoke-MDMWinsOverGPFleet.ps1`
is a separate, standalone script for the different scenario of a management
server with network line-of-sight (and admin rights) to many domain-joined
devices at once, where you want to trigger runs remotely rather than
deploying anything to each device individually.

It does not collect or analyze anything itself. It only:

1. Reads a device list from a CSV (`-DeviceListCsv`, one `DeviceName` column
   per row).
2. Confirms each device is online with `Test-Connection` before touching it.
3. Runs the existing, unmodified `Test-MDMWinsOverGP.ps1` on every online
   device as a child `powershell.exe` process, capturing that script's own
   0/1/2/3 exit code. Devices are processed in **batches of
   `-ThrottleLimit`** (default 10): each batch opens its own remote sessions,
   runs to completion, retrieves its evidence, and closes those sessions
   before the next batch starts, so no more than `-ThrottleLimit` devices are
   ever connected and running at once.
4. Collects each device's evidence ZIP centrally.
5. Writes one `FleetSummary.csv` covering every device: online or not, the
   remote script's own exit code (see "Exit codes" above), where its ZIP was
   collected to, and a plain-English `Outcome` (`Success`, `ConflictsFound`,
   `DegradedEvidence`, `RemoteScriptFailed`, `Offline`, `ConnectionFailed`,
   `TimedOut`, `DisconnectedMidRun`). In `Copy` mode (the default), each device's `Manifest.json` is
   also read back to add per-device metrics: `MdmWinsOverGpEnabled`,
   `MdmWinsOverGpState`, `PolicyManagerRowCount`, `GpoSettingsCount`,
   `VerifiedMappingCount`, `ConfirmedOverlapCount`, `HeuristicOverlapCount`,
   and `ConflictsFoundCount`. These are blank for `RemotePath` mode and for
   devices that never produced a manifest (e.g. `Offline`,
   `ConnectionFailed`, `TimedOut`, `DisconnectedMidRun`).

### Devices that go offline part-way through

A device that answers the initial `Test-Connection` can still disappear
before its run finishes - laptops sleep, users undock, VPNs drop. On a fleet
of any size this is routine, and it does not disturb any other device:

- The device is recorded as **`DisconnectedMidRun`**, distinct from
  `RemoteScriptFailed`, so the summary separates "this device vanished" from
  "this device's script failed". The `Detail` column gives the session and
  job state.
- Every other device in the same batch is unaffected. Results are collected
  per device rather than in one bulk read, so a dropped machine cannot
  discard the results of the machines running alongside it.
- The run continues through the remaining batches and still writes
  `FleetSummary.csv` at the end.
- Any evidence the device produced is still on the device. Re-run just the
  affected devices to collect it - filter `FleetSummary.csv` on
  `Outcome = DisconnectedMidRun` for the list.

Because sessions are opened per batch rather than all at once, a device that
goes offline while waiting its turn is simply reported as `ConnectionFailed`
when its batch starts.

   `FleetSummary.csv` is written even when the run fails part-way through, so
   a fleet-wide summary is never lost to a single device's unexpected result.

**Version skew between the fleet script and the device script.** The
per-device metric columns come from each device's `Manifest.json`, whose
schema belongs to whichever copy of `Test-MDMWinsOverGP.ps1` actually ran
there. If a device runs an older copy than this fleet script expects, the
metric columns it does not recognise are left blank and a warning names that
device - the run itself is unaffected, and the evidence ZIP is complete
either way. If you see that warning for every device, update the
`Test-MDMWinsOverGP.ps1` at `-ScriptSourcePath`: in `Copy` mode that file is
what gets pushed, and it is easy to update the fleet script alone and leave
the pushed copy stale.

```powershell
# Run as an already-elevated domain admin account - the current session's
# identity is used automatically, no -Credential needed.
.\Invoke-MDMWinsOverGPFleet.ps1 `
    -DeviceListCsv .\Devices.csv `
    -ResultsShare '\\msfssoftware\Client\MDMWinOverGPO\Results' `
    -RemoteScriptArguments @('-GenerateMappings')
```

Pass `-Credential` only when you need to connect as a *different* account
than the one already running this script (e.g. `-Credential (Get-Credential)`).

`Devices.csv`:

```csv
DeviceName
CONTOSO-PC01
CONTOSO-PC02
CONTOSO-LAPTOP-047
```

### The double-hop problem, and why `Copy` is the default delivery mode

This is the single most important thing to understand about running the
toolkit remotely, because it produces a **confusing symptom**: the device
reports that the script path "was not found", even though you can browse to
that exact UNC path from the management server without any trouble.

That is not a wrong path. It is Windows' well-known PowerShell "double-hop"
limitation. When `Invoke-Command` connects to a device, the resulting remote
session has **no network credential** - your identity got you *onto* the
device, but it is not forwarded any further. So the moment code running on
that device tries to reach a *third* machine (the script share, or the
results share), it authenticates as nobody, and the UNC path comes back as
inaccessible - which surfaces as "not found".

`-DeliveryMode` controls how the toolkit deals with this:

| Mode | What happens | Delegation required? |
|---|---|---|
| `Copy` **(default)** | The management server reads the toolkit scripts itself, pushes their contents into each session, and the device runs them from a **local temp folder**. The device writes its evidence ZIP locally too; the management server then pulls it back over the already-authenticated session and writes it to `-ResultsShare` itself. | **No.** The remote device never touches a network path. |
| `RemotePath` | The device opens `-RemoteScriptPath` over the network itself, and writes its ZIP directly to `-ResultsShare`. | **Yes** - CredSSP or resource-based constrained delegation. |

In `Copy` mode, *every* network path in play (`-ScriptSourcePath`,
`-ResultsShare`) is opened by the management server, running as your
account - the account that already has access to them. Nothing has to be
delegated, no share ACL has to be loosened, and no computer account is ever
involved. That is why it is the default, and why it is what you want unless
you have a specific reason to do otherwise.

Use `RemotePath` only if you have deliberately configured delegation:

- **CredSSP.** Enable on the management server
  (`Enable-WSManCredSSP -Role Client -DelegateComputer *.contoso.com`) and on
  every target device (`Enable-WSManCredSSP -Role Server`). Works reliably,
  but sends your credential to the remote host and widens what that host
  could do with it - a deliberate, scoped tradeoff, not a default.
- **Resource-based constrained delegation (Kerberos).** The "correct" fix
  for an AD environment that already manages delegation this way, but
  requires per-device/service AD configuration and is out of scope for this
  toolkit to set up for you.

### Where evidence ends up

In `Copy` mode the management server retrieves each device's evidence ZIP
over the same session and writes it to `-ResultsShare`. The ZIP keeps the
name `Test-MDMWinsOverGP.ps1` already gave it
(`<ComputerName>-<timestamp>[-PARTIAL].zip`), so devices cannot collide. If
`-ResultsShare` is not supplied, ZIPs are collected into `CollectedEvidence`
inside the fleet run's own output folder instead.

Each device's temp folder is removed once its ZIP has been retrieved; pass
`-KeepRemoteTempFolder` to leave it in place when you need to inspect a
failed run on the device itself.

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-DeviceListCsv` | *(required)* | CSV with a `DeviceName` column. Blank and duplicate rows are skipped with a `WARN`. |
| `-DeliveryMode` | `Copy` | `Copy` (no delegation needed) or `RemotePath` (needs delegation). See above. |
| `-ScriptSourcePath` | `Test-MDMWinsOverGP.ps1` next to this script, else the `\\msfssoftware\...` UNC | `Copy` mode only. Path to the main script **as seen from the management server**. `Build-PolicyMappings.ps1` is pushed with it when present, so `-GenerateMappings` works on the device. |
| `-RemoteScriptPath` | `\\msfssoftware\Client\MDMWinOverGPO\Script\Test-MDMWinsOverGP.ps1` | `RemotePath` mode only. Path **as seen from each device**. Ignored in `Copy` mode. |
| `-Credential` | current session's identity | Only needed to connect as a different account than the one running the script. |
| `-ResultsShare` | fleet run's `CollectedEvidence` folder | Where evidence ZIPs are collected. Written to by the management server in `Copy` mode, by the device in `RemotePath` mode. |
| `-RemoteScriptArguments` | (none) | Extra arguments forwarded as-is to `Test-MDMWinsOverGP.ps1` (e.g. `@('-GenerateMappings','-SinceHours','48')`). Do not pass `-ResultsShare` or `-OutputRoot` here - both are managed for you. |
| `-ThrottleLimit` | 10 | Max devices processed concurrently. Devices are run in batches of this size; sessions are opened and closed per batch, so this is a hard ceiling on concurrent sessions and concurrent remote runs. `-RemoteTimeoutSeconds` applies per batch, so worst-case wall clock is roughly `(devices / ThrottleLimit) * RemoteTimeoutSeconds`. |
| `-PingCount` | 2 | `Test-Connection` echoes per device before a session is attempted. |
| `-RemoteTimeoutSeconds` | 1800 | How long to wait for the fleet before marking still-running devices `TimedOut`. Remote runs are not killed - this script just stops waiting. |
| `-KeepRemoteTempFolder` | off | `Copy` mode only. Leaves the per-device temp folder (scripts, evidence, remote stdout log) on the device for inspection. |

In `Copy` mode, the per-device temp folder is deliberately created as
`%windir%\Temp\MW-<6-char-id>` rather than under the user's own `%TEMP%` -
`gpresult.exe` itself rejects an output path longer than 127 characters, and
`Test-MDMWinsOverGP.ps1` nests `GPResult.xml` four levels below
`-OutputRoot`; `%windir%\Temp` has a fixed, short length regardless of the
logon account's username, where `%TEMP%` does not.
| `-SummaryOutputPath` | `<script folder>\Data\FleetRuns\<timestamp>\FleetSummary.csv` (or a ProgramData fallback - same portability rule as `Test-MDMWinsOverGP.ps1`) | Where the per-device summary CSV is written. |
| `-DataRoot` | (none) | Pins the fleet-run output location explicitly, same convention as `Test-MDMWinsOverGP.ps1`'s `-DataRoot`. |

Note that in `Copy` mode a mapping CSV should be produced **on the device**
via `-RemoteScriptArguments @('-GenerateMappings')` rather than referenced by
path, since a `-MappingCsv` value would be resolved by the device, not the
management server.

### Requirements on the target devices

PowerShell remoting must be enabled and reachable (`Enable-PSRemoting`,
TCP 5985/5986 open), and the account you run as needs local admin rights on
each device - `Test-MDMWinsOverGP.ps1` requires elevation for a live
collection run. A device that answers a ping but refuses a session is
reported as `ConnectionFailed` with the reason in the `Detail` column,
rather than failing the whole run.

This script's own exit code is a fleet-wide rollup: `1` if any device failed
to run or connect (`RemoteScriptFailed`, `ConnectionFailed`, `TimedOut`,
`DisconnectedMidRun`),
else `2` if any device reported conflicts or degraded evidence, else `0`.
Always read `FleetSummary.csv` for the per-device breakdown.

## Build-PolicyMappings.ps1 (auto-generating the mapping CSV)

### Why this exists

`Test-MDMWinsOverGP.ps1 -MappingCsv` gives the strongest evidence the toolkit
can produce (a verified GPO-to-Policy-CSP overlap), but until now that CSV
had to be filled in by hand, row by row, against Microsoft's documentation.
Most runs therefore shipped with zero verified mappings and fell back to the
weak name-similarity heuristics instead.

There is no reliable machine-readable public mapping of every GP setting to
every Policy CSP setting, and this toolkit's environment cannot reach
`learn.microsoft.com`, `raw.githubusercontent.com`, or the GitHub API to
scrape one even if it existed (all verified unreachable through the
environment's proxy - 403/404). `Build-PolicyMappings.ps1` instead builds a
starting-point mapping CSV entirely from data that already exists on the
local Windows machine: the ADMX/ADML files under `PolicyDefinitions` (the
GPO catalog), the `PolicyManager\default` registry tree (a CSP name
catalog), and - the strongest signal - live registry evidence read directly
from the device the script is running on.

### What it does

1. **Phase 1 - GPO catalog.** Parses every `*.admx` file under
   `-PolicyDefinitionsPath` (default `C:\Windows\PolicyDefinitions`) and
   resolves each policy's `$(string.X)` display-name reference against the
   matching `*.adml` file for `-Language` (default `en-US`). A malformed or
   unreadable ADMX/ADML file is logged as a warning and skipped; it does not
   abort the run.
2. **Phase 2 - CSP catalog.** Enumerates
   `HKLM:\SOFTWARE\Microsoft\PolicyManager\default\<Area>\<Policy>`, which
   lists every Policy CSP setting the running OS build/edition knows about.
   This tree only ever holds each policy's out-of-box **default** value - it
   carries no GPO-equivalence metadata - so it is used purely as a name
   catalog for Tier B matching (see below). If this key is missing or
   unreadable, the script logs a warning and continues with an empty CSP
   catalog rather than failing.
3. **Phase 3 - Device corroboration evidence.** Reads two live registry
   sources directly from the device the script is running on - no CSV
   import, no internet required - unless `-SkipDeviceCorroboration` is
   passed:
   - **Classic GPO registry evidence:** every value actually present under
     `HKLM:\SOFTWARE\Policies` and
     `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies`.
   - **Live MDM PolicyManager evidence:** every value actually present
     under `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device`, paired
     with its companion `<Value>_WinningProvider` value where present.

   Both reads are non-fatal - a missing or unreadable key is logged as a
   warning and treated as an empty evidence set, never aborts the run - and
   neither requires elevation (plain `HKLM` read access is normally
   sufficient).
4. **Phase 4 - Join, with confidence tiers.** For every ADMX policy, an
   exact, case-insensitive match is attempted between the ADMX
   `<policy name="...">` attribute and a CSP policy name (**Tier B**).
   ADMX-backed CSP policies frequently share this internal name verbatim,
   so this is a strong signal on its own.

   Every Tier B match is then checked against the Phase 3 evidence:
   - **GpoConfigured** - is the ADMX policy's own declared registry
     `key`/`valueName` (from Phase 1) present, *with an actual value*, in
     the classic GPO registry evidence?
   - **MdmConfigured** - does the matched CSP policy's Area/Policy appear,
     *with an actual value*, in the live MDM PolicyManager evidence? The
     `_WinningProvider` value is captured when present.

   If **both** are true, this is live, on-device proof that the two
   settings are the same enforced thing right now, and the row is promoted
   to **Tier A (device-corroborated)** via the `BothConfigured` path - the
   strongest result this script can produce. A **second, independent path**
   can also promote a row to Tier A even when the GPO side is absent - see
   "Confidence tiers, in plain terms" below for the full rationale
   (`MdmWinningProvider`). The concrete evidence (registry paths, values,
   and the `_WinningProvider` value if present) is recorded in the `Notes`
   column either way, tagged with which path fired.

   If a Tier B match exists but corroboration is inconclusive, the row
   stays **Tier B**, and `Notes` records what corroboration was attempted
   and what was/wasn't found. If no name match exists at all, the script
   falls back to **Tier C**: normalized/fuzzy token-similarity between the
   GPO display name and the CSP policy name. Review-only; never treat this
   as verified.

   **Important limitation:** device corroboration can only promote the
   subset of ADMX policies that are **currently actually GPO-configured on
   the device the script is running on** - it validates a subset, not the
   full ADMX/CSP catalog, and most Tier B rows will simply stay Tier B.
   That's expected, not a failure - it's also exactly the subset that
   matters for real conflict validation, and it never replaces Tier B/C
   coverage elsewhere. There is also a known, deliberate simplification:
   this pass only checks each ADMX policy's policy-level `key`/`valueName`
   (as captured in Phase 1); it does not resolve per-element registry
   locations that some multi-value ADMX policies declare on child
   `<elements>` nodes, so a small number of genuinely-configured multi-value
   policies will not be detected as `GpoConfigured`.

   (An earlier revision of this script also attempted a registry-based
   match by comparing an ADMX `valueName` against value names captured
   under `PolicyManager\default` in Phase 2. That path has been removed: the
   `default` hive only ever holds out-of-box default values, so the
   comparison was structurally incapable of ever matching anything -
   confirmed with 0 matches out of 3,549 ADMX policies on a real device.
   Phase 3/4's live-registry-based device corroboration replaces it with a
   signal that is actually meaningful.)
5. **Phase 5 - Output.** Writes a CSV with exactly the columns
   `Test-MDMWinsOverGP.ps1` expects
   (`GpoSetting,GpoName,CspArea,CspPolicy,OmaUri,Notes`), plus a console
   coverage summary: ADMX policies parsed, CSP policies found, rows per
   tier, how many Tier B rows were checked for device corroboration, how
   many were promoted to Tier A **in total and broken out by which of the
   two promotion paths fired** (`BothConfigured` vs. `MdmWinningProvider` -
   see "Confidence tiers" below), and what percentage of the discovered CSP
   catalog got mapped. Without an explicit `-OutputPath`, the CSV is written
   under `Data\Mappings\` (see "Central deployment" above). If
   `-GpoSettingsCsv` (a `GPO-Settings.csv` from a prior
   `Test-MDMWinsOverGP.ps1` run) is supplied, it also writes a second,
   filtered CSV containing only rows whose `GpoSetting` matches a setting
   actually observed on that device, and reports how many of the device's
   real GPO settings received a mapping.

### Chaining the two scripts (`-GenerateMappings`)

Running `Build-PolicyMappings.ps1` by hand and then feeding its output into
`Test-MDMWinsOverGP.ps1 -MappingCsv` works, but `Test-MDMWinsOverGP.ps1
-GenerateMappings` does it for you in one run:

```powershell
.\Test-MDMWinsOverGP.ps1 -GenerateMappings -SinceHours 48
```

- It locates `Build-PolicyMappings.ps1` next to itself (via `$PSScriptRoot`),
  after this run's own GPResult collection has already written
  `Reports\GPO-Settings.csv` - `Build-PolicyMappings.ps1` then filters its
  output to exactly this device's applied GPO settings via
  `-GpoSettingsCsv`.
- It runs `Build-PolicyMappings.ps1` as a separate `powershell.exe -File`
  **child process**, not dot-sourced. This is deliberate: dot-sourcing would
  run `Build-PolicyMappings.ps1`'s own `Set-StrictMode -Version 2` session,
  `Write-Log` function, and many script-scope variables directly inside
  `Test-MDMWinsOverGP.ps1`'s own scope, risking a silent variable/function
  collision in either direction (now or after a future edit to either
  script). A child process gets a fully independent scope; its console
  output is captured and re-logged into this run's own `Log.txt` instead.
- The result (`Reports\PolicyMappings-Generated-Filtered.csv`, or the
  unfiltered CSV if the filtered one wasn't produced) becomes the effective
  `-MappingCsv` for the rest of the run.
- If you also pass an explicit `-MappingCsv`, that always wins - the run
  logs clearly which one was used and skips running
  `Build-PolicyMappings.ps1` entirely.
- The whole step is non-fatal: if `Build-PolicyMappings.ps1` can't be found
  or the child process fails, a WARN is logged and collection continues
  exactly as if `-GenerateMappings` had not been passed.

### Confidence tiers, in plain terms

| Tier | Meaning | Trust level |
|---|---|---|
| A (device-corroborated) | Promoted via **either** of two independent paths (see below) | Highest - still verify against docs, but this is strong, current, on-device evidence |
| B (name-only) | Exact ADMX name == CSP policy name, no (or inconclusive) device corroboration | Moderate - a common, but not universal, pattern for ADMX-backed CSP policies |
| C (fuzzy) | Token-similarity only | Weakest - review-only, never treat as verified |

**Tier A now has two independent promotion paths**, both recorded distinctly
in `Notes` and counted separately in the console coverage summary
(`path=BothConfigured` vs. `path=MdmWinningProvider`):

1. **BothConfigured (strongest).** Live registry proof that both the GPO
   side and the MDM side are currently configured on this device - the
   original rule.
2. **MdmWinningProvider (looser, suggestive).** The classic GPO registry
   value is **absent**, but the matched CSP policy is live under
   `PolicyManager\current\device` and its `_WinningProvider` value indicates
   MDM currently owns it. This exists because rule 1 is partly
   self-defeating for the exact case MDMWinsOverGP is meant to prove: when
   MDM actually wins a real conflict, Windows blocks the Group Policy engine
   from writing its registry value at all, so `GpoConfigured` becomes
   **false** precisely *because* the conflict was resolved in MDM's favor -
   rule 1 alone would then never fire for a genuinely resolved conflict.
   **This path is suggestive of a resolved conflict, not proof by itself
   that a GPO ever targeted this exact setting** - only rule 1 provides that
   independent GPO-side evidence. Treat an `MdmWinningProvider` Tier A row as
   a strong lead to confirm, not as equivalent-strength evidence to a
   `BothConfigured` row.

### `-SkipDeviceCorroboration`

Pass this switch to skip Phase 3/4's live-registry corroboration entirely -
e.g. for a pure offline catalog run, or if reading
`HKLM:\SOFTWARE\Policies`/`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies`/
`HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device` hits a permissions
problem. When skipped, every match stays at Tier B (or falls back to Tier
C) - no rows can be promoted to Tier A on that run. Device corroboration is
**on by default**.

### How to run it

```powershell
# Full run against the default PolicyDefinitions store
.\Build-PolicyMappings.ps1

# Fast smoke test on a handful of ADMX files before a full run
.\Build-PolicyMappings.ps1 -SampleSize 20 -Verbose

# Skip live-registry device corroboration (pure offline catalog run)
.\Build-PolicyMappings.ps1 -SkipDeviceCorroboration

# Also emit a CSV filtered to this device's actual GPO settings
.\Build-PolicyMappings.ps1 -GpoSettingsCsv 'C:\...\Reports\GPO-Settings.csv'

# Feed the result into the main script
.\Test-MDMWinsOverGP.ps1 -MappingCsv 'C:\...\PolicyMappings-Generated.csv'

# Or let Test-MDMWinsOverGP.ps1 run this script for you, filtered to this device
.\Test-MDMWinsOverGP.ps1 -GenerateMappings

# Central deployment: pin the data location explicitly (network share, etc.)
.\Build-PolicyMappings.ps1 -DataRoot '\\fileserver\share\MDMWinsOverGP'
```

### Caveat - read before using the output

**Generated mappings are a starting point for human verification, not
authoritative truth.** This script never invents or hardcodes a mapping -
every row is derived from ADMX/ADML/registry data actually found on the
machine it ran on - but "derived from local data" is not the same as
"confirmed correct." Real-world coverage (how many rows Tier A and Tier B
actually produce) is genuinely unknown until this runs on a real device;
the coverage summary this script prints is the honest answer for that
machine, not a guarantee for any other one. Review every row - especially
Tier C rows - against Microsoft's Policy CSP documentation before treating
it as a verified mapping in `Test-MDMWinsOverGP.ps1 -MappingCsv`.

**Device corroboration (Tier A) only covers what is currently applied on
this device.** A Tier A row means live registry evidence on *this specific
machine, at the time the script ran* showed both the GPO side and the MDM
side configured and pointing at the same policy - it is not, and cannot
be, proof for the other 3,000+ ADMX policies that happen not to be
GPO-configured here. Re-running the script on a different device, or after
changing which GPOs apply, can change which rows are Tier A. Treat Tier A
as "verified for this device, right now," not as a permanent,
machine-independent fact.
