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
- Reports\Verified-Overlap-Results.csv
- Reports\Heuristic-Overlap-Candidates.csv
- Reports\MDM-EffectivePolicies.csv
- Reports\GPO-Settings.csv
- Reports\Event-881.csv
- Reports\PolicyMappings-Generated.csv and PolicyMappings-Generated-Filtered.csv (only written when `-GenerateMappings` was passed)
- Events\*.evtx
- GPResult\GPResult.html
- GPResult\GPResult.xml
- MDMDiagnostics\
- A ZIP containing the full evidence package

Interpretation
- The "Applied GPO settings and CSP mapping status" report section lists
  *every* GPO setting GPResult reported as applied on this device - not just
  ones with a mapping. Most rows are expected to say "No known CSP mapping";
  that reflects real Policy CSP coverage, not a collection problem. Rows
  with both a mapping and MDM evidence are the strongest signal ("Confirmed
  overlap") and are what the Summary's "Verified overlaps" count reflects.
- Heuristic candidate: Similar names only. It is not proof of a conflict.
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
