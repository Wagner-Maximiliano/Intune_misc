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

> **⚠️ CORRECTED 2026-07-30, after the first execution of this code path.**
> Step 2 below was **wrong**, and step 3 therefore never happened on this path.
> The original text is kept struck through because the same false premise is
> quoted in several other places. Read the correction that follows it.

~~Three-step failure:~~

1. `Get-MgGraphAllPages` ends in `return $results` on a `List[object]`.
   PowerShell **enumerates an IEnumerable on output**, so an empty list emits
   nothing. ✅ *This part is correct.*
2. ~~`@($null)` is a one-element array containing `$null`, so `ForEach-Object`
   runs once with `$_ = $null`.~~ ❌ **False here.** A function that emits
   *nothing* does not assign `$null` — it assigns
   `System.Management.Automation.Internal.AutomationNull.Value`. That compares
   `-eq $null`, which is why desk-checking read it as `$null`, but
   `@(AutomationNull)` is an **empty** array (`.Count` = 0) and the pipeline
   runs **zero** times. `@($null).Count` really is 1, but only for a *literal*
   `$null` — e.g. a missing property, which is what the pre-`96f7b09` code
   (`@($policy.assignments)`) had.
3. ~~`Resolve-Assignment`'s Mandatory parameter rejects `$null` and the run
   aborts.~~ Never reached for an unassigned policy.

**What was actually true.** R-02 was a real crash in the `$expand` era
(`@($policy.assignments)` — a property access, so a literal `$null`). Commit
`96f7b09` switched to the dedicated per-policy call, and from that moment the
crash was unreachable. The `Where-Object { $_ }` added here fixed a bug that
had already stopped existing.

**What the same line's `@()` fix did do, and it is real.** The original `@()`
wrapped the pipeline's *input*, not its *output*, so `$assignments` collapsed
to `AutomationNull` for a policy with no assignments and was written into the
snapshot as `"Assignments": null` — which is what makes R-04 reachable. Removing
the outer `@()` still turns the suite red today; verified 2026-07-30.

**What `Where-Object { $_ }` is worth keeping for.** A null *element* inside a
populated collection is a genuine `$null`, and the binder does reject it. Graph
is not known to emit that shape, but the guard is one clause and in
`Get-IntuneSettingsCatalogSnapshot.ps1` — which has no per-policy `try/catch` —
it would end the whole run. Both scripts now have a regression test for exactly
that (`drops a null element in the assignments collection`), so the clause is no
longer untested. Kept, not removed.

**Method note.** This error survived a full code review, a test-suite rewrite,
and four sessions of desk-checking because `$null -eq $x` is true for
AutomationNull and nothing in the sandbox could run the distinguishing line. It
was found in ~10 minutes with an interpreter.

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

---

## Found by the rewritten test suite (Issue #14) — FIXED

Both of these were missed by this review. They are recorded here rather than in
a separate document because they belong to the same findings register, and
because how they were missed matters more than the bugs themselves.

### R-13 — HIGH — The R-03 fix stopped one line short
`Backup-IntunePolicies.ps1:673`, `Import-PolicyHistoryToDatabase.ps1:432`,
and `Backup-IntunePolicies.ps1:709`

R-03 added `[AllowNull()][AllowEmptyCollection()]` to `ConvertTo-FlatSettings`
so a policy with no settings would stop aborting the run. It did — and then the
run aborted on the **next line** instead:

```powershell
$flat = ConvertTo-FlatSettings -Settings $policy.settings   # now returns zero rows
$hash = Get-PolicyContentHash -FlatSettings $flat -Assignments $assignments
```

`ConvertTo-FlatSettings` ends `return $rows` on a `List[object]`. PowerShell
enumerates an IEnumerable on output, so **zero rows arrive at the call site as
`$null`, not as an empty list** — the exact mechanism this review already
documented for `Get-MgGraphAllPages` in R-02. `Get-PolicyContentHash`'s bare
`[Parameter(Mandatory)]$FlatSettings` then rejected it at bind time.
`Export-PolicyWorkbook -FlatSettings` (reached whenever `-SkipExcel` is not
used) had the identical declaration.

**Crashed today, on exactly the case R-03 claimed to have fixed.** The
"policy with no settings" row in `docs/PROJECT_STATUS.md`'s verification table
would have failed on real hardware.

**Fix**: `[AllowNull()][AllowEmptyCollection()]` on all three declarations. No
logic changed. The bodies were already tolerant — `foreach` over `$null` runs
zero times, and piping `$null` yields one canonical `"="` line **identically in
both copies**, so an empty policy still hashes deterministically and the two
tools agree on it.

**How it was missed.** The review traced the *declaration* that threw and
stopped there, instead of following the value's whole path. The lesson is the
one this file already states about `Get-MgGraphAllPages`: an empty collection
returned from a PowerShell function is `$null` at every call site, so fixing
one consumer never finishes the job — every consumer needs checking.

### R-14 — MEDIUM — "Last Modified By" was always blank
`Backup-IntunePolicies.ps1:225`

```powershell
$events = Get-MgGraphAllPages -Uri $uri     # ...&$top=1
if ($events -and $events.Count -gt 0) {
    $actor = $events[0].actor
```

Same enumeration rule, opposite symptom: `$top=1` returns exactly one event, so
`$events` was a **bare hashtable**, never a one-element array. A hashtable's
`.Count` is its **key count** — 1 — so the guard passed. `$events[0]` on a
hashtable is a lookup for the key `0`, which does not exist, so `$actor` was
`$null`, every candidate field was `$null`, and the function returned `$null`
every single time.

**Silently wrong output, not a crash**, which is why nothing ever surfaced it:
the "Last Modified By" column in every workbook and in `_Index.xlsx` was
permanently empty, and R-10 (audit failures invisible without `-Verbose`) made
that look like a plausible permissions problem rather than a bug.

**Fix**: `$events = @(Get-MgGraphAllPages -Uri $uri)`, and drop the now-redundant
`$events -and`. Regression test:
`tests/Backup.Script.Tests.ps1` → "resolves who last modified the policy".

---

## Open — recorded, deliberately not fixed here

### R-06 — MEDIUM/HIGH — An all-offline fleet run exits `0` ("clean") — WON'T FIX (user decision)

- **Decided**: 2026-07-28, by the user. See D-014 in `docs/DECISIONS.md`.

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

I recommended remapping `Offline` to the existing exit `3` (degraded
evidence). **The user declined**: this exit code is a contract that existing
RMM/Intune automation already reads and depends on, and the user does not
want that native behavior touched, full stop — not even to fix a real
discrepancy.

**Do not revisit this on your own initiative.** If it turns out to bite in
practice, raise it with the user again rather than changing it — see D-014.

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

### R-15 — LOW-MEDIUM — The two content-hash copies disagree on a legacy snapshot
`Backup-IntunePolicies.ps1:392` vs `Import-PolicyHistoryToDatabase.ps1:437`

Both compute the assignment half of the canonical form the same way:

```powershell
$assignLines = @(@($Assignments) | ForEach-Object { "$($_.AssignmentType)|$($_.GroupId)|..." } | Sort-Object)
```

The difference is what each hands in. `Backup-IntunePolicies.ps1:671` always
passes an `@()`-wrapped array, so zero assignments contribute zero lines.
`Import-PolicyHistoryToDatabase.ps1:430` passes `@($snap.Assignments)`, and for
a snapshot written **before the R-02 fix** — `"Assignments": null` — that is a
one-element array holding `$null`. Piping `$null` through `ForEach-Object` runs
the block once, so the phantom contributes a `"|||"` line.

**Consequence.** The same policy state hashes differently depending on which
tool computed it, which breaks the invariant the import script states in its
own header ("so a version imported here has the same identity as the backup
that produced it") and adds a spurious version row on ingest.

**Not fixed: the fix changes stored content hashes.** Adding
`Where-Object { $_ }` is a one-liner, but every affected policy would then be
ingested once more as a "new" version. That is the user's call, in the same
spirit as R-06. A `-Skip`ped test in
`tests/ImportDatabase.Functions.Tests.ps1` asserts the fixed behaviour, so
resolving this is a one-word edit.

Note the related-but-harmless case: `Get-PolicyContentHash -FlatSettings $null`
also pipes `$null`, yielding a single `"="` line. That is *identical* in both
copies, so an empty policy still hashes consistently — see R-13.

### R-12 — LOW — Inconsistent guard on the same lookup
`Invoke-MDMWinsOverGPFleet.ps1:640` writes `$results[$session.ComputerName].StartedAt`
unguarded, while line 668 guards the identical lookup with `ContainsKey`. Not
currently reachable (keys come from `$deviceNames`, sessions from a subset, and
`@{}` is case-insensitive), but worth aligning.

### R-16 — HIGH — `Test-MDMWinsOverGP.ps1` failed to parse at all — FIXED
Found the first time `tests/` actually ran (`SuiteIntegrity.Tests.ps1`'s parse
check, via `Get-ScriptFunctionDefinition`'s AST load), not by desk-check — this
review's brace/paren check does not catch it because the file parses
character-for-character fine; the defect is in how PowerShell tokenizes a
`$variable` immediately followed by `:` inside a double-quoted string.

Line ~1646 (the interactive-table column-filter renderer) had:

```powershell
"<label class=""filter-label"">$labelText: <select ...>"
```

`$labelText:` is ambiguous with `$scope:name` drive/scope-qualified variable
syntax. Because a space (not a valid variable-name character) follows the
colon, the parser rejects the whole script: `Variable reference is not valid.
':' was not followed by a valid variable name character.` Since PowerShell
parses an entire `.ps1` before running any of it, **this did not fail
gracefully at the Interactive/FilterColumns code path — it broke the ability
to run `Test-MDMWinsOverGP.ps1` at all**, evidence-collection and report
rendering included.

Fixed by delimiting explicitly: `${labelText}:`. Grepped the rest of the repo
for the same `$word:` shape immediately followed by a non-identifier,
non-`{`, non-`$` character — the only other hit is inside a `#` comment in
`Backup-IntunePolicies.ps1`, which is inert.

This revises the review's own headline above: **the MDM toolkit was clean on
the three bug classes this review specifically went looking for, but not on
every bug class** — this one is a fourth, found only because the test suite
finally executed real PowerShell for the first time. Treat "no tests reached
this file beyond a parse check" (`docs/PROJECT_STATUS.md` known issue #12) as
still true and still worth closing.

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

### For #14 (fix the test suite) — DONE, see `tests/README.md`

The suite was rewritten against this evidence. Two mechanisms replaced the
copies: an AST loader that pulls the real function source out of a production
`.ps1`, and an offline Graph fake that lets a whole script be run end to end
and its output inspected. `tests/SuiteIntegrity.Tests.ps1` now fails if any
file under `tests/` defines a function name that also exists in production.

**The rewrite immediately found R-13 and R-14 above** — both in code this
review had already read. That is the point: the suite now executes the shipped
code, so it can find what desk-checking misses.

The original evidence, for the record:

`tests/TestHelpers.ps1` defined **27 functions; 21 of them (78%) were
reimplementations of production functions**, not fixtures: `Write-TextFile`,
`ConvertFrom-JsonFile`, `Get-MgGraphAllPages`, `Get-GroupDisplayName`,
`Get-AssignmentFilterName`, `Resolve-Assignment`, `Add-SettingDefinitionToCache`,
`Get-SettingDefinition`, `Resolve-SettingTitle`, `Resolve-ChoiceValue`,
`ConvertTo-FlatSettings`, `Get-StringSha256`, `Get-PolicyContentHash`,
`Get-PolicyLastModifiedBy`, `Get-SafeFileName`, `Get-VersionSheetName`,
`Get-WorkbookPath`, `Format-AssignmentList`, `Export-PolicyWorkbook`,
`Set-CellColor`, `Export-IndexWorkbook`.

Only 6 were genuine test infrastructure: `Test-HasProp`, `Get-Prop`,
`Initialize-IntuneBackup`, `Save-DefinitionCache`, `Read-Manifest`,
`Write-Manifest`.

**R-02 through R-05 were all invisible to the suite** because it never executed
the code containing them. The copies had also drifted from the originals — the
`Resolve-Assignment` copy, for instance, was missing production's normalisation
of Intune's all-zero "no filter" GUID entirely.

A useful accident: `TestHelpers.ps1` was the *only* file carrying
`Set-StrictMode -Version Latest`, so its parallel copies ran under stricter
rules than the production code they shadowed — the suite could not have caught
these bugs, and would have reported a different failure if it ever had. The
replacement therefore runs with StrictMode off, matching `scripts/`, with a
guard test and a note about flipping both together when R-11 lands.

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
