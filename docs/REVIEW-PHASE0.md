# Phase 0.1 — Full code review findings

Register for the Phase 0 review of both toolsets (Issue #13, D-008). Every
finding below is either **fixed** (with the commit that fixed it) or **open**
(carried into `docs/PROJECT_STATUS.md` Known issues).

- **Date**: 2026-07-28
- **Scope**: all 8 production scripts (~8,100 lines) plus `tests/` (838)
- **Method**: desk-check only. **No PowerShell interpreter, no Windows, no
  devices in the agent sandbox — nothing here has been executed.** See
  `docs/AGENT_ONBOARDING.md` §2.

---

## The headline: the two toolsets are in very different shape

The MDMWinsOverGP toolkit is **clean on all three target bug classes**. It
carries inline comments explaining each past fix (the `$evt`-not-`$event`
rename, the load-bearing `@()` wrappers, `[AllowEmptyCollection()]` as a
blanket rule). The hardening from PRs #9/#10 clearly landed there.

**Every defect found in this review is in `scripts/`**, which received none of
that hardening. That is also where the review's biggest surprise lives — see
R-01 immediately below, which invalidates a premise in three of our own docs.

---

## R-01 — `Set-StrictMode` is absent from all five `scripts/` files — FIXED (docs)

`docs/AGENT_ONBOARDING.md`, `CLAUDE.md`, and this review's own brief all state
"every script sets `Set-StrictMode -Version 2.0`." **That is false.**

| Location | StrictMode |
|---|---|
| `MDMWinsOverGPToolKit/` (3 files) | `Set-StrictMode -Version 2.0` — present in all 3 |
| `scripts/` (5 files) | **absent from all 5** |
| `tests/TestHelpers.ps1` | `Set-StrictMode -Version Latest` |

`scripts/` sets only `$ErrorActionPreference = 'Stop'`, which governs
non-terminating cmdlet errors — not language-level property access.

**Why this matters more than a doc typo.** It splits every finding into two
populations, and the split is not obvious from reading the code:

- Findings that **crash today** — parameter-binder rejections. Binding is
  independent of StrictMode.
- Findings that are **latent** — `.Count` and property access on `$null`
  return `$null`/`0` silently today, and become hard throws the moment
  StrictMode is adopted in `scripts/`.

An agent trusting the docs would mis-triage both groups: treating live crashes
as theoretical, and assuming latent traps are already fatal.

The docs have been corrected in this commit. **The code was right; the docs
were the bug** (`docs/PROJECT_STATUS.md` states this precedence).

Related: `ARCHITECTURE.md` claimed path portability — `$PSScriptRoot` with an
`$env:ProgramData` fallback — as a property of the whole repo. Also false:
**zero occurrences in `scripts/`** (27 across the MDM toolkit). All five
`scripts/` defaults are working-directory-relative (`.\output`,
`.\PolicySummary.xlsx`, `.\output\db\PolicyHistory.sqlite`). Corrected too.

---

## Fixed in this commit

### R-02 — HIGH — A policy with no assignments aborted the backup
`Backup-IntunePolicies.ps1:671`, `Get-IntuneSettingsCatalogSnapshot.ps1:228`

```powershell
$assignments = @($rawAssignments) | ForEach-Object { Resolve-Assignment -Assignment $_ }
```

Three-step failure:

1. `Get-MgGraphAllPages` ends in `return $results` on a `List[object]`.
   PowerShell **enumerates an IEnumerable on output**, so an empty list emits
   nothing and `$rawAssignments` is **`$null`**, not an empty list.
2. `@($null)` is a **one-element array containing `$null`** — not an empty
   array. So `ForEach-Object` runs **once**, with `$_ = $null`.
3. `Resolve-Assignment`'s `[Parameter(Mandatory)]$Assignment` rejects `$null`
   at bind time. With `$ErrorActionPreference='Stop'`, the run aborts.

**Crashes today — binder rejection, independent of StrictMode.** Unassigned
Settings Catalog policies are common (staged/not-yet-deployed), so this is
reachable in an ordinary tenant.

Secondary defect in the same line: the `@()` wrapped the pipeline's *input*,
not its *output*, so `$assignments` was a bare scalar for exactly one
assignment and `$null` for none — and that `$null` was written straight into
the snapshot JSON as `"Assignments": null`, which is what makes R-04 reachable.

**Fix**: `Where-Object { $_ }` drops the phantom null; the outer `@()` now
wraps the whole pipeline.

### R-03 — HIGH — A policy with no settings aborted the backup
`Backup-IntunePolicies.ps1:298`, `Import-PolicyHistoryToDatabase.ps1:156`

```powershell
param([Parameter(Mandatory)]$Settings)
```

A bare `Mandatory` parameter rejects **both** `$null` and `@()` at bind time.
A Settings Catalog policy with no settings supplies one or the other, so
`ConvertTo-FlatSettings` threw before its body ran. Bug class 3 in an untyped
guise — the rule is usually stated for `[object[]]` params, but it bites
untyped ones too.

Note the body was already tolerant (`foreach ($s in @($Settings))` plus a
`if (-not $Instance) { return }` guard in `Walk`). Only the binder was wrong,
which is why a call-site `@()` wrapper does **not** fix it.

**Crashes today.** **Fix**: `[AllowNull()][AllowEmptyCollection()]`.

### R-04 — MEDIUM — Restore built a malformed payload from a null Settings array
`Restore-IntunePolicy.ps1:164`

`$originalSettings = @($Snapshot.Settings)` on a snapshot carrying
`"Settings": null` produces `@($null)` — one element, holding `$null`. The
payload loop then emitted a bogus
`{ '@odata.type' = <default>; settingInstance = $null }` entry.

Two consequences, both live today (this file has **no** StrictMode and **no**
`try`/`catch` anywhere):

- `$settingsPayload.Count` was `1`, not `0`, so the script's own "this
  snapshot has zero settings" warning never fired.
- A setting with `settingInstance: null` was POSTed to Graph.

**Fix**: skip null entries in the payload loop.

### R-05 — LOW (latent) — `.Count` on a possibly-`$null` collection
`Backup-IntunePolicies.ps1:618`, `Get-IntuneSettingsCatalogSnapshot.ps1:189`

Same `List[object]`-enumerated-on-return path as R-02: an empty tenant leaves
`$policies` as `$null`. Silent today (`$null.Count` is `0` without StrictMode);
a throw once StrictMode lands. Fixed defensively with `@()` since it is free.

The `.Count` calls *after* the platform filter were already safe — the filter
re-wraps in `@(...)`.

---

## Open — recorded, deliberately not fixed here

### R-06 — MEDIUM/HIGH — An all-offline fleet run exits `0` ("clean")
`Invoke-MDMWinsOverGPFleet.ps1:775`

```powershell
$failureOutcomes = @('RemoteScriptFailed', 'ConnectionFailed', 'TimedOut')
```

`Offline` is excluded — but the script's own header (line 175) promises exit
`1` when a device "failed to run **or connect**", and `Offline` is defined at
line 166 as a device that got no ping reply and had no session attempted. The
code contradicts its documented contract.

**Worst case: every device in the fleet is powered off → no failures, no
conflicts → `exit 0`, logging "All processed devices completed successfully
with no conflicts detected."** An RMM or Intune consumer reads that as a
healthy fleet. This is exactly the collapse `ARCHITECTURE.md` forbids —
"couldn't tell" reported as "found nothing".

**Not fixed: this changes an exit-code contract consumed by RMM and Intune**,
so it needs the user's decision (AGENT_ONBOARDING §5). Recommendation:
map `Offline` to the **existing exit 3 (degraded evidence)**, which
`Test-MDMWinsOverGP.ps1` defines but the fleet script never emits. That reuses
the established contract instead of inventing a state, and keeps "some devices
unreachable" distinct from both "clean" and "conflicts found".

### R-07 — MEDIUM — Throttling silently degrades definition/name resolution
`Backup-IntunePolicies.ps1:258` (`Get-SettingDefinition`), `:167`, `:180`;
`Get-IntuneSettingsCatalogSnapshot.ps1:96-124`

These call `Invoke-MgGraphRequest` **directly**, bypassing
`Get-MgGraphAllPages` — the only code path with 429/5xx retry and backoff. A
transient throttle therefore hits the same `catch` as a genuine 404, and
`Get-SettingDefinition` **negative-caches `$null` for the remainder of the
run** with no warning of any kind.

On a large tenant this can silently degrade many settings to raw GUIDs in the
Excel output, with no indication why. Not fixed because the right fix is a
shared non-paged retry helper, which belongs in `Continuum.Core` (#15).

### R-08 — LOW-MEDIUM — Previous-version sheet chosen by lexicographic sort
`Backup-IntunePolicies.ps1:471`

`Get-VersionSheetName` produces `yyyy-MM-dd`, then `_2`, `_3`, … `Sort-Object`
does a plain **string** sort, so on the 10th run in one day `..._10` sorts
before `..._2` and `$dateSheets[-1]` picks `_9`. The diff highlighting then
compares against a stale version. Needs >9 runs on one policy in one calendar
day — realistic in testing, unlikely in daily production.

### R-09 — LOW (latent) — Unreachable defensive guards in the restore path
`Restore-IntunePolicy.ps1:118, 121, 180, 181, 193, 194`

StrictMode prohibits references to non-existent properties of **any** object,
not just `$null`. `ConvertFrom-Json` yields a PSCustomObject that simply lacks
absent keys, so guards like:

```powershell
if ($Snapshot.PolicyType -and $Snapshot.PolicyType -ne 'SettingsCatalog') { throw "..." }
if (-not $Snapshot.Name) { throw "'$JsonFile' has no Name property..." }
```

would throw on the guard expression itself, making the author's friendly error
messages unreachable and surfacing an opaque StrictMode error instead.

**Currently harmless** — no StrictMode in this file, so the guards work as
written. Listed because adopting StrictMode here (R-11) turns all of them into
crashes at once. The correct pattern already exists in-repo at
`Import-PolicyHistoryToDatabase.ps1:569`:
`if ($snap.PSObject.Properties['LastModifiedBy'])`.

### R-10 — LOW — Audit-lookup failures are invisible without `-Verbose`
`Backup-IntunePolicies.ps1:233` — `catch { Write-Verbose "Audit lookup failed..." }`.
A systemic permissions problem (missing `DeviceManagementApps.Read.All`) leaves
every policy's "Last Modified By" blank with no visible explanation.

### R-11 — Adopt `Set-StrictMode -Version 2.0` in `scripts/` — needs sequencing
The obvious response to R-01 is to add StrictMode to all five files. **Do not
do that first.** R-05 and R-09 are latent precisely because it is absent;
switching it on before they are fixed converts them into simultaneous crashes
across the backup and restore paths.

Correct order: fix every latent finding → add StrictMode → run against a real
tenant. Best done as part of #15, when this logic moves into modules anyway.

### R-12 — LOW — Inconsistent guard on the same lookup
`Invoke-MDMWinsOverGPFleet.ps1:640` writes `$results[$session.ComputerName].StartedAt`
unguarded, while line 668 guards the identical lookup with `ContainsKey`. Not
currently reachable (keys come from `$deviceNames`, sessions from a subset, and
`@{}` is case-insensitive), but worth aligning.

---

## Verified NOT bugs — recorded so they are not re-raised

- **SQL injection / quoting**: clean. `Import-PolicyHistoryToDatabase.ps1`
  parameterises **every** statement carrying variable data through
  `Invoke-Db -SqlParameters` (lines 351, 486, 502, 505, 530, 546, 552, 558,
  567, 596, 613, 645). No string-concatenated SQL. Policy names with
  apostrophes are safe.
- **Graph paging**: correct. `Get-MgGraphAllPages` follows
  `@odata.nextLink` to exhaustion in both copies.
- **Bug class 2 (automatic-variable shadowing)**: **zero occurrences in all 8
  scripts.** `Build-PolicyMappings.ps1:399` (`$Matches['id']`) is a correct
  *read* after `-match`, not a shadow.
- **Bug class 3 in the MDM toolkit**: clean. Every `Mandatory` array parameter
  already carries `[AllowEmptyCollection()]`.
- **Brace/paren balance**: no real imbalance in any file. Naive `grep -o`
  counts flag `Test-MDMWinsOverGP.ps1` and `Build-PolicyMappings.ps1`, but both
  are literal characters inside prose comments.
- **Graph property access under StrictMode**: mostly a non-issue.
  `Invoke-MgGraphRequest` defaults to `-OutputType HashTable` (confirmed by the
  explicit `[pscustomobject]` casts at `Backup-IntunePolicies.ps1:263, 651`),
  and missing **hashtable keys** return `$null` without throwing. Only
  `ConvertFrom-Json` results (PSCustomObject) are exposed — which is why R-09
  is real while the superficially similar Graph accesses are not.

### Uncertain — needs a real run to settle
`Backup-IntunePolicies.ps1:149` / `Get-IntuneSettingsCatalogSnapshot.ps1:78`:

```powershell
try { $status = [int]$_.Exception.Response.StatusCode } catch { }
$isTransient = ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
```

This assumes the classic `Invoke-WebRequest` exception shape. If
`Invoke-MgGraphRequest` throws a differently-shaped exception in the installed
module version, `$status` stays `$null`, `$isTransient` is false, and **the
retry path is silently never taken** — the error is rethrown on attempt 1.
Cannot be settled without an interpreter. Worth checking against a forced 429.

---

## Evidence gathered for the next two Phase 0 tasks

### For #14 (fix the test suite) — Known issue #1, now quantified

`tests/TestHelpers.ps1` defines **27 functions; 21 of them (78%) are
reimplementations of production functions**, not fixtures: `Write-TextFile`,
`ConvertFrom-JsonFile`, `Get-MgGraphAllPages`, `Get-GroupDisplayName`,
`Get-AssignmentFilterName`, `Resolve-Assignment`, `Add-SettingDefinitionToCache`,
`Get-SettingDefinition`, `Resolve-SettingTitle`, `Resolve-ChoiceValue`,
`ConvertTo-FlatSettings`, `Get-StringSha256`, `Get-PolicyContentHash`,
`Get-PolicyLastModifiedBy`, `Get-SafeFileName`, `Get-VersionSheetName`,
`Get-WorkbookPath`, `Format-AssignmentList`, `Export-PolicyWorkbook`,
`Set-CellColor`, `Export-IndexWorkbook`.

Only 6 are genuine test infrastructure: `Test-HasProp`, `Get-Prop`,
`Initialize-IntuneBackup`, `Save-DefinitionCache`, `Read-Manifest`,
`Write-Manifest`.

**R-02 through R-05 were all invisible to the suite** because it never executes
the code containing them. The copies have also drifted from the originals.

A useful accident: `TestHelpers.ps1` is the *only* file carrying
`Set-StrictMode -Version Latest`, so its parallel copies run under stricter
rules than the production code they shadow — the suite could not have caught
these bugs, and would report a different failure if it ever did.

### For #15 (module extraction) — duplication map

28 function names are defined in more than one file. The boundaries are clean:

- **Inside `scripts/` only** → `Continuum.PolicyBackup`, with the Graph and
  hashing helpers → `Continuum.Core`: `Get-MgGraphAllPages`,
  `Get-GroupDisplayName`, `Get-AssignmentFilterName`, `Resolve-Assignment`,
  `ConvertTo-FlatSettings`, `Get-SettingDefinition`, `Resolve-SettingTitle`,
  `Resolve-ChoiceValue`, `Add-SettingDefinitionToCache`, `Get-PolicyContentHash`,
  `Get-StringSha256`, `Get-SafeFileName`, `ConvertFrom-JsonFile`,
  `Write-TextFile`, `Format-AssignmentList`
- **Inside `MDMWinsOverGPToolKit/` only** → `Continuum.MdmGpo`, with
  `Write-Log` / `Test-PathWritable` / `Resolve-DataRoot` → `Continuum.Core`:
  plus `Normalize-PolicyName`, `Get-TokenSet`, `Get-JaccardScore`,
  `Get-RegistryTreeValues`, `Convert-ValueToText`
- **Shared between the two toolsets: none.** They are fully siloed today.

Duplication is deliberate (standalone deployability) and is not a defect — it
is listed only to scope the extraction.

**Two Core gaps are sharper than the duplication itself:**

1. **Logging.** The MDM toolkit has `Write-Log` in all three scripts.
   `scripts/` has **no logging function at all** — 61 raw `Write-Host` calls
   (14/2/8/17/20). Unifying logging is therefore not a merge of two
   implementations; it is adopting the MDM toolkit's `Write-Log` into Core and
   migrating 61 call sites. `Write-Host` cannot be captured by a web UI, so
   this **blocks Phase 1/3 progress reporting**, not just tidiness.
2. **Path portability.** Per R-01 this property exists only in the MDM
   toolkit. Bringing `scripts/` onto `$PSScriptRoot` + `$env:ProgramData` is
   net-new work, not a lift-and-shift — and it is a behaviour change for
   anyone relying on today's working-directory-relative defaults.

---

## Method note — on the delegated reviews

Both toolset reviews were delegated per D-010 and **both were independently
verified against the files before anything here was accepted.** That mattered:

- The MDM report claimed it had "traced every `.Count` occurrence" and supplied
  an audit trail. The trail omitted 10 lines while listing their neighbours —
  it had sampled, not enumerated. Checking the gaps myself confirmed its
  *conclusion* was nonetheless correct.
- The Policy Backup report surfaced R-01, which contradicted the brief it was
  given and three of our own docs. Verified and upheld.
- That same report asserted `Get-MgGraphAllPages` "always returns a
  `List[object]` (never null)". **That is wrong** — PowerShell enumerates an
  IEnumerable on output, so an empty list yields `$null`. The distinction is
  what makes R-02 a live crash rather than a benign no-op, so accepting the
  claim would have understated the most serious finding in this review.

Verification is not optional here, in both directions.
