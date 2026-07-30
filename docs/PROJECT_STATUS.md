# Project status

**This is the single source of truth for "where are we and what's next."**
Update it in the same commit as any change. If this file and the code
disagree, the code is right and this file is a bug.

- **Last updated**: 2026-07-30
- **Updated by**: a session that ran the deliberate-break acceptance test on a
  real interpreter, found the suite was right to stay green (the chosen break
  was a no-op), corrected the wrong premise behind review finding R-02, and
  closed Issue #14
- **Current phase**: Phase 0 — Bootstrap & consolidation (review and tests done,
  **#14 closed**, module extraction next)

> **⚠️ An agent session on this machine can run PowerShell.** Windows PowerShell
> 5.1 with Pester 6.0.1, confirmed 2026-07-30. The docs asserted the opposite
> for months and it cost a wrong HIGH finding. **Try `Invoke-Pester ./tests`
> before claiming anything is unverifiable.** A tenant and target devices are
> still the user's to provide.

> ## ⚠️ Where this work lives — read before you branch
>
> All Phase 0 work is on **`claude/platform-bootstrap`**, which is **not merged
> and has no open PR**. `main` does **not** contain `docs/` at all — no
> onboarding, no status, no roadmap. An agent that starts from `main` will find
> none of this and will have no idea the project exists.
>
> **Start every session with:**
> ```
> git fetch origin claude/platform-bootstrap && git checkout claude/platform-bootstrap
> ```
>
> This is the one place the usual convention ("never build on a merged branch;
> start fresh from `main`") does **not** apply — that rule is about *merged*
> branches. This one is unmerged and is the only copy of the project's memory.
> Keep working on it until the user merges it, then follow the normal rule
> again.

---

## What this project is

**Continuum** — a management console for administering and migrating hybrid Windows
environments. Today it is two mature but separate PowerShell toolsets; the
goal is to unify them behind one browser-based dashboard that a business
could actually deploy, and eventually sell.

The two toolsets solve adjacent problems that migration teams hit together:

1. **Intune Policy Backup** — Intune has no version history and no recovery
   for edited/deleted policies. This snapshots every policy + assignment,
   keeps a per-policy change history, and can restore.
2. **MDMWinsOverGP Validation** — when a device is co-managed, MDM policy can
   silently override Group Policy. This collects evidence from a device (or a
   fleet) and reports where MDM and GPO actually conflict.

**For the full product scope** — positioning, differentiators, the expansion
plan beyond Phase 5, who buys it, and an explicit list of what the product
does *not* do — see **`docs/PRODUCT-VISION.md`**. Read it before any UI or
feature work; it is where the "why" lives, while this file tracks the "where".

Presentation material lives in `docs/presentation/`: an interactive console
mockup and a slide deck. **Both contain representative sample data, not real
tenant output** — never cite their numbers as measured results.

---

## Current state — what actually exists and works

Both toolsets are **working and in real use**. Nothing below is speculative.

### Intune Policy Backup (`scripts/`, `tests/`) — ~2,100 lines

| File | Lines | State |
|---|---|---|
| `Backup-IntunePolicies.ps1` | 751 | Working. Graph API snapshot → JSON + per-policy Excel history. |
| `Import-PolicyHistoryToDatabase.ps1` | 673 | Working. **SQLite history DB** (Phase 6a). |
| `Restore-IntunePolicy.ps1` | 234 | Working (Phase 5). |
| `Get-IntuneSettingsCatalogSnapshot.ps1` | 233 | Working. |
| `Export-PolicySummary.ps1` | 120 | Working. |
| `tests/` (Pester) | ~1,200 | **Rewritten** (Issue #14). Exercises production code; see `tests/README.md`. |

Detailed roadmap and a long list of concrete improvement prompts already
exist in **`docs/IMPROVED-PLAN.md`** (744 lines) — that document is still
valid and should be treated as the backlog for this toolset. It was written
after Phase 6a.

### MDMWinsOverGP Toolkit (`MDMWinsOverGPToolKit/`) — ~5,200 lines

| File | Lines | State |
|---|---|---|
| `Test-MDMWinsOverGP.ps1` | 3,135 | Working. Single-device evidence collection + interactive HTML report. |
| `Build-PolicyMappings.ps1` | 1,319 | Working. Auto-generates GPO→CSP mapping CSV from local ADMX + registry. |
| `Invoke-MDMWinsOverGPFleet.ps1` | 790 | Working. Fleet runs from a management server. Verified on real hardware. |

Key capabilities, all verified on real devices by the user:
- Parses the authoritative "Blocked Group Policies" table from `MDMDiagReport.html`
- Interactive HTML report: sortable/filterable tables, dark mode, RAG colouring
- `-ReplayFromPath` regenerates reports from prior evidence without re-collection or elevation
- `-ResultsShare` central evidence collection
- Deterministic exit codes: `0` clean / `1` fatal / `2` conflicts found / `3` degraded evidence
- Fleet runs avoid the PowerShell double-hop problem entirely via `Copy` delivery mode

Full documentation: `MDMWinsOverGPToolKit/README.md`.

---

## Next up — in order

**Phase 0 is where you are. Do these before any UI work (D-005).**

| # | Task | Issue | Depends on |
|---|---|---|---|
| ~~1~~ | ~~Full code review, both toolsets~~ — **done**, see `docs/REVIEW-PHASE0.md` | [#13](https://github.com/Wagner-Maximiliano/Intune_misc/issues/13) | — |
| ~~2~~ | ~~Fix the test suite so it tests production code~~ — **done and closed 2026-07-30**. 137 passed / 0 failed / 2 skipped, and the deliberate-break round-trip is confirmed. | [#14](https://github.com/Wagner-Maximiliano/Intune_misc/issues/14) | #13 ✅ |
| 3 | Extract shared `Continuum.*` modules — **now genuinely unblocked** | [#15](https://github.com/Wagner-Maximiliano/Intune_misc/issues/15) | #13 ✅, #14 ✅ |
| ~~4~~ | ~~Fix garbled `MDMWinsOverGPToolKit/README.md` intro~~ — **done** | [#16](https://github.com/Wagner-Maximiliano/Intune_misc/issues/16) | — (independent) |

---

### ⚡ Ready now — an agent can do these with no user input

**If you are a fresh session and the user has not told you otherwise, start at
the top of this list and work down.** Everything here is either additive (new
code paths, no change to working behaviour) or documentation-only, so none of
it needs the Pester suite to have been run first. Take one item, finish it
properly, update the docs, commit.

| Order | Task | Why it's safe to do now |
|---|---|---|
| ~~**A**~~ | ~~**Fix the garbled `MDMWinsOverGPToolKit/README.md` intro**~~ ([#16](https://github.com/Wagner-Maximiliano/Intune_misc/issues/16)) — **done**, see "Recently shipped" | Documentation only, zero code risk. Was constrained to the damaged intro alone; everything from "Blocked Group Policies" onward is unchanged. |
| **B** | **Extend the test suite to `MDMWinsOverGPToolKit/`** (known issue #12) — **pure-functions half done**, see "Recently shipped"; ADMX/HTML parsers against fixture files still to do | Purely additive — new test files cannot break production code. |
| **C** | **Deletion detection** (new capability — see `PRODUCT-VISION.md` §6) | Net-new code path; nothing existing changes behaviour. Compare each run's policy set against the manifest's known set and report anything that vanished. **Report only — never auto-delete or auto-restore.** This is the product's core anxiety ("Intune has no recovery for deleted policies") and nothing currently says *"this existed last run and doesn't now."* Add a `-Skip`ped test per D-013 if any part needs a decision. |
| **D** | **Capture `roleScopeTagIds` and `templateReference` in snapshots** | Two real Graph fields the backup silently drops. Additive to the snapshot shape. **Time-sensitive:** history captured before this lands can never be backfilled, so earlier is strictly better. |
| **E** | **Warn when a snapshot contains secret-typed settings** | Graph never returns secret values on read, so a restored policy's password/certificate field is silently blank. Scan for `@odata.type` containing `Secret` and **warn, don't block**. Small, additive, and a trust requirement for restore. |

Items C, D and E each want a matching test, since the suite now exercises real
code (D-012). Write the test even though you cannot run it — say plainly in
your final message that it is unverified.

---

### ⛔ Previously blocked — now cleared

**#15 (module extraction) is unblocked as of 2026-07-30.** The blocker was that
the suite had never actually been executed. It has now been run repeatedly, and
— more importantly — *proven to fail when production code breaks*, which is the
property the refactor's safety argument actually needs. The same clearance
applies to the two items parked behind it: **unifying logging** (61
`Write-Host` calls in `scripts/`) and the **`_Index.xlsx` merge-not-wipe fix**.

Items B–E below are still perfectly good work; they are just no longer the
*only* safe work.

---

### Closing #14 — done, and it did not go as expected

**Closed 2026-07-30.** The final acceptance criterion — "a deliberate break in
production code turns the suite red" — initially appeared to fail: the chosen
break (deleting `Where-Object { $_ } | ` at `Backup-IntunePolicies.ps1:692`)
left the suite at an unchanged 135/0/2 across repeated runs.

**The suite was right. The break was a no-op, and the reason is a bug in this
project's own documentation.** R-02 claimed that an empty `Get-MgGraphAllPages`
yields a literal `$null`, which `@(...)` turns into a one-element array that
then crashes `Resolve-Assignment`'s Mandatory binder. Step 2 is false: a
function emitting nothing returns `AutomationNull`, not `$null`, and
`@(AutomationNull)` is an **empty** array. The pipeline runs zero times, so
there is nothing for `Where-Object` to filter. `$null -eq $x` is true for both
values, which is exactly why desk-checking never caught it.

What was verified with the interpreter instead:

| Break | Result |
|---|---|
| Delete `Where-Object { $_ }` (the user's choice) | **Green** — genuinely a no-op on this path |
| Delete the **outer `@()`** on the same line | **Red** — `"Assignments"` serialises as `{}` not `[]`; caught by "records Assignments as an empty array, not null" |
| Delete `Where-Object { $_ }` **after adding the new null-element test** | **Red** in both scripts, citing the exact line |

So the round-trip (red → revert → green) **is** confirmed; it just needed a
break that was actually load-bearing. Two new regression tests now cover the
`Where-Object` clause so it can never again be silently deletable — see D-017.
`docs/REVIEW-PHASE0.md` R-02 carries the correction; `CLAUDE.md` and
`AGENT_ONBOARDING.md` now state the `@($null)` rule with its AutomationNull
caveat.

---

When #15 does become unblocked, two things are already scaffolded for it:

- `tests/TestSupport.ps1`'s AST loader is **temporary**. When the logic moves
  into `Continuum.*`, replace `Import-ProductionFunction` with `Import-Module`;
  the tests themselves should barely change. Note its stated limit: functions
  loaded by AST have no `$PSScriptRoot`, so bringing path portability into
  `scripts/` (known issue #7) needs the module route.
- The drift tests in `ImportDatabase.Functions.Tests.ps1` and
  `ExportSummary.Functions.Tests.ps1` compare the deliberate duplicate copies
  of `ConvertTo-FlatSettings`, `Get-PolicyContentHash` and the assignment
  renderer. Those tests are what the extraction is *for*; when the copies
  collapse into `Continuum.Core`, they become redundant and should be deleted
  rather than left asserting a tautology.

**Two things are waiting on the user.** Neither blocks items B–E above:

1. **R-11** — when to adopt `Set-StrictMode` in `scripts/`.
2. **R-15** — a content-hash fix that would re-ingest affected policies once.

R-11 and R-15 are both in `docs/REVIEW-PHASE0.md`. Don't act on either
unilaterally.

**R-06 (fleet exit-code contract) is now decided — leave it alone.** The user
declined the recommended fix: the fleet script's exit codes are a contract
already read by their RMM/Intune automation, and they don't want that native
behavior changed, even to correct the documented discrepancy. See D-014 in
`docs/DECISIONS.md`. **Do not "fix" this on your own initiative.**

Then Phase 1 ([#17](https://github.com/Wagner-Maximiliano/Intune_misc/issues/17)),
Phase 2 ([#18](https://github.com/Wagner-Maximiliano/Intune_misc/issues/18)),
Phase 3 ([#19](https://github.com/Wagner-Maximiliano/Intune_misc/issues/19)),
Phase 4 ([#20](https://github.com/Wagner-Maximiliano/Intune_misc/issues/20)),
Phase 5 ([#21](https://github.com/Wagner-Maximiliano/Intune_misc/issues/21)).

GitHub Issues mirror this roadmap for human visibility (D-007). **If an Issue
and this file disagree, this file wins** — correct the Issue.

---

## Needs verification on real hardware

The agent sandbox cannot run any of this. The user's testing is the project's
only real verification, so **unverified changes are listed here until a real
run confirms them**, then moved to "Recently shipped".

### 1. ~~Run the test suite~~ — **done; nothing left here**

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester ./tests
```

**Current: 137 passed, 0 failed, 2 skipped** (2026-07-30, Windows PowerShell
5.1 / Pester 6.0.1). The two extra tests over the previous 135 are the new
null-element regression tests. `Toolkit.PureFunctions.Tests.ps1` — flagged
below as never having been exercised — has now run clean, including under its
`Set-StrictMode -Version 2.0`.

The deliberate-break acceptance step is **complete**; see "Closing #14" above
for what it actually found, which was not what was expected. The historical
record of that step is kept below for context.

The user's first run (2026-07-29, Pester 6.0.1) found two harness bugs — a
Pester 6 incompatibility and a real parse-breaking bug in
`Test-MDMWinsOverGP.ps1` (R-16) — both fixed the same day (see "Recently
shipped"). **Their re-run on 2026-07-30 came back clean: 135 passed, 0
failed, 2 skipped** (the deliberate R-08/R-15 skips — by design, not
breakage). This is the suite's first genuinely confirmed green run.

**The acceptance step this section used to describe was run on 2026-07-30, and
the break it recommended turned out to be a no-op.** Deleting
`Where-Object { $_ } | ` at `Backup-IntunePolicies.ps1:692` does not change any
observable behaviour, because the "phantom null" it was written to drop does
not exist on that path — see "Closing #14" above and the corrected R-02 in
`docs/REVIEW-PHASE0.md`. If you want to re-demonstrate that the suite catches
breaks, delete the **outer `@()`** on that line instead, or delete the
`Where-Object` now that the null-element tests exist. Both go red.

`tests/Toolkit.PureFunctions.Tests.ps1` has now been exercised and passes,
including under its `Set-StrictMode -Version 2.0`.

### 2. Outstanding tenant checks — from the review (commit `8ab55c1`) and this one

| What to test | Expected result | Covers |
|---|---|---|
| `Backup-IntunePolicies.ps1` against a tenant containing **at least one policy with no assignments** | Completes; that policy's JSON has `"Assignments": []` (not `null`, and no crash) | R-02 |
| Same run, with **at least one policy with no settings** | Completes; that policy is snapshotted with zero settings rows | R-03, **R-13** |
| Same run, **with Excel enabled** (no `-SkipExcel`) on that no-settings policy | A workbook sheet is written with an empty settings table | **R-13** |
| Same run: check the **"Last Modified By"** column in a workbook and in `_Index.xlsx` | Populated for a changed policy, where it was previously always blank | **R-14** |
| `Get-IntuneSettingsCatalogSnapshot.ps1` against the same tenant | Same two outcomes as above | R-02, R-05 |
| `Restore-IntunePolicy.ps1 -WhatIf` on a snapshot whose `Settings` is `null` or `[]` | Prints "Settings count: 0" and warns about an empty policy — instead of silently building a 1-entry payload | R-04 |
| `Import-PolicyHistoryToDatabase.ps1` over a folder containing a no-settings snapshot | Ingests it rather than erroring on that file | R-03, **R-13** |

**The no-settings cases still crashed before this commit** — R-03's fix moved
the failure one line down into `Get-PolicyContentHash` rather than removing it
(R-13). If you tested that case after the review and it failed, this is why.

**Before the review commit, the unassigned-policy case aborted the whole
backup**, so if you have ever run a backup successfully, your tenant probably
has no unassigned policy — worth creating one deliberately to test.

Nothing else changed, so no other behaviour should differ. R-14 is the one
change that alters *output* rather than just preventing a crash.

---

## Known issues / open threads

Full detail for everything the Phase 0.1 review found — including the items
already fixed — is in **`docs/REVIEW-PHASE0.md`**, indexed R-01…R-16.

1. ~~**The Pester tests don't test production code.**~~ **Fixed** (Issue #14).
   `tests/TestHelpers.ps1` and its 21 copies of production functions are gone.
   The suite now reaches production code two ways only — an AST loader that
   copies a function's real source out of the `.ps1`, and whole-script runs
   against an offline Graph fake — and `tests/SuiteIntegrity.Tests.ps1` fails
   if any test file ever redefines a production function name again. Full
   rationale in `tests/README.md`. **Closed 2026-07-30**: 137 passed, 0 failed,
   2 skipped as designed, and the deliberate-break round-trip is confirmed —
   though it took three attempts to find a break that was actually load-bearing,
   which is how R-02's wrong premise surfaced. See "Closing #14" above.
2. ~~**`MDMWinsOverGPToolKit/README.md` has a garbled intro section.**~~
   **Fixed** (Issue #16) — the first 126 lines were replaced; the rest of the
   file is untouched. See "Recently shipped".
3. **Tier A mapping matches are persistently ~0** in `Build-PolicyMappings.ps1`.
   Diagnosed as likely structural, not a bug: when MDM wins, the GPO registry
   write is suppressed, so "both configured" is self-contradictory for a real
   conflict. A secondary `MdmWinningProvider` promotion path was added to
   partially address it; **its real-world effect has never been confirmed.**
4. ~~**Nothing is verifiable in the agent sandbox.**~~ **No longer true on this
   machine** (2026-07-30): an agent session ran Windows PowerShell 5.1 and
   Pester 6.0.1 directly and executed the full suite. A tenant and target
   devices are still the user's to provide, so Graph-facing and device-facing
   behaviour remains desk-checked. **Check for an interpreter before claiming
   you have none** — assuming otherwise is what let R-02 stay wrong for four
   sessions. See AGENT_ONBOARDING §2.
5. **Branch deletion fails with HTTP 403** from the agent environment. Merged
   branches must be deleted by the user via the GitHub UI. (An agent session
   with local `git` can delete a merged branch directly if asked — three were
   cleaned up this way on 2026-07-30, see "Branches" below.)
15. **An orphan branch nobody has triaged: `claude/intune-gpo-policy-binding-7m496u`.**
    Two commits, **no PR, and no mention anywhere in these docs until now** —
    it binds GPO GUIDs and CSP OMA-URIs into the overlap results
    (+320 lines in `Test-MDMWinsOverGP.ps1`, +36 in the toolkit README).
    Checked 2026-07-30: it **parses clean** (41 functions) and is **current with
    `main`** — 0 commits behind, and it already carries the R-16 `${labelText}`
    fix, so it is not stale and would not regress anything. What is missing is
    any evidence it was ever **run on a real device**, which is what this
    feature is entirely about. Deliberately **not merged** on the agent's own
    judgement; the user was asked on 2026-07-30 and chose to leave it. Triage it
    before it rots — either run it on hardware and merge, or delete it.
6. **StrictMode coverage is split, and the docs used to deny it.**
   `MDMWinsOverGPToolKit/` sets `Set-StrictMode -Version 2.0` in all three
   scripts; **the five files in `scripts/` set none.** AGENT_ONBOARDING,
   CLAUDE.md and this project's review brief all claimed it was universal —
   corrected in this commit. Consequence: several `scripts/` bugs are *latent*
   rather than live, and **adopting StrictMode there must come after fixing
   them** or they all fire at once (R-01, R-11).
7. **`scripts/` has no path portability.** Zero uses of `$PSScriptRoot` or
   `$env:ProgramData` across all five files; defaults are
   working-directory-relative. ARCHITECTURE.md claimed this property
   repo-wide; it holds only for the MDM toolkit. Bringing `scripts/` onto it
   during #15 is net-new work **and a behaviour change** for anyone relying on
   today's relative defaults (R-01).
8. **An all-offline fleet run exits `0` ("clean") — accepted, will not be
   changed.** `Invoke-MDMWinsOverGPFleet.ps1` omits `Offline` from its
   failure rollup, contradicting its own documented contract ("failed to run
   **or connect**"). A fleet of powered-off machines reports success to
   RMM/Intune — "couldn't tell" presented as "found nothing". The user was
   shown the fix (map `Offline` to the existing exit 3) and **declined it**:
   this exit code is a contract their RMM/Intune automation already reads,
   and they don't want that native behavior touched. See D-014.
   **Do not revisit this without the user raising it again.**
9. **Throttling silently degrades name/definition resolution.**
   `Get-SettingDefinition`, `Get-GroupDisplayName` and `Get-AssignmentFilterName`
   bypass the only retry-capable helper, so a transient 429 is treated as a
   permanent 404 and **negative-cached for the rest of the run** with no
   warning. On a large tenant this quietly degrades many settings to raw GUIDs.
   Fix belongs in `Continuum.Core` (R-07).
10. **Unverified: the 429 retry path may never execute.** The backoff logic
    assumes an `Invoke-WebRequest`-shaped exception. If `Invoke-MgGraphRequest`
    throws a different shape, `$isTransient` is always false and the retry is
    silently skipped. Cannot be settled without an interpreter — needs a real
    run against a forced 429 (R-07 "Uncertain").
11. **The two content-hash copies disagree on a legacy snapshot.** For a
    snapshot written before the R-02 fix — `"Assignments": null` —
    `Import-PolicyHistoryToDatabase.ps1` hashes a phantom `"|||"` assignment
    line that `Backup-IntunePolicies.ps1` does not, so the same policy state
    gets two identities and an extra version row on ingest. **Left unfixed
    deliberately**: the one-line fix changes stored hashes, re-ingesting every
    affected policy once. Needs the user's call (R-15). A `-Skip`ped test
    asserts the fixed behaviour.
12. **Excel and SQLite code paths are still untested.** `Export-PolicyWorkbook`,
    `Export-IndexWorkbook`, `Get-WorkbookPath` and `Set-CellColor` need
    `ImportExcel`; `Invoke-Db`, `Initialize-Schema` and the ingest loop need
    `PSSQLite`. The suite deliberately depends on neither, so these are still
    verified only by real runs. **`MDMWinsOverGPToolKit/`'s device-independent
    helpers now have tests** (`tests/Toolkit.PureFunctions.Tests.ps1` —
    `Normalize-PolicyName`, `Get-TokenSet`, `Get-JaccardScore`,
    `Convert-ValueToText`, in both files that keep a copy); everything else in
    the toolkit — the ADMX/ADML parsers, and anything touching a live device
    (registry reads, `gpresult.exe`, `MDMDiagReport.html`) — still has no
    coverage beyond the parse check.
13. **Smaller open items**: lexicographic sheet sort picks the wrong "previous"
    version after >9 runs in one day (R-08); the restore path's defensive
    guards become unreachable once StrictMode lands (R-09); audit-lookup
    failures are invisible without `-Verbose`, hiding permission problems
    (R-10); one unguarded hashtable lookup in the fleet script is inconsistent
    with its guarded twin (R-12).
14. ~~**`Test-MDMWinsOverGP.ps1` failed to parse at all.**~~ **Fixed** (R-16).
    A `$labelText:` variable-immediately-followed-by-colon ambiguity around
    line 1646 made the *entire script* fail to parse — not just the
    interactive-table filter renderer it lived in. Invisible to desk-checking
    (the review's own brace/paren check doesn't catch tokenizer ambiguity) and
    invisible to the Phase 0.1 review's three target bug classes; found only
    because the suite's parse check finally ran real PowerShell. Worth a
    reminder: "the MDM toolkit was clean" (Phase 0.1 headline) meant clean on
    the classes the review went looking for, not clean on everything.

---

## Branches — current state (2026-07-30)

| Branch | State | What to do |
|---|---|---|
| `main` | — | Has **no `docs/`**. Do not start a session here. |
| `claude/platform-bootstrap` | Unmerged, no PR. **All Phase 0 work + every doc.** | Keep working here. The user was asked on 2026-07-30 about merging and chose to leave it unmerged for now, so the "check out this branch first" instruction in `AGENT_ONBOARDING.md` **still stands**. |
| `claude/intune-gpo-policy-binding-7m496u` | Unmerged, no PR, untriaged | See known issue #15. Not abandoned, not approved — parked. |

**Deleted on 2026-07-30** after confirming their content was in `main`:
`claude/fleet-remote-invoke` (PR #12), `claude/mdm-wins-over-gpo-script-wov07d`
(PRs #9/#10/#11), `claude/feetsummary-additional-columns-qfd0br` (PR #22).

⚠️ **`git branch -r --merged` is not sufficient here.** PR #22 was
**squash-merged**, so its branch tip is not an ancestor of `main` and both
`--merged` and `git cherry` reported it as unmerged even though every line was
already in `main`. Confirm containment with `git diff --stat origin/main
origin/<branch>` (empty output = fully contained) or by checking the PR's merge
commit with `git merge-base --is-ancestor`, before deleting anything.

---

## Recently shipped

- **Issue #14 closed, and R-02 corrected in the process** (2026-07-30). The
  deliberate-break acceptance step was run on a real interpreter and appeared to
  fail — the suite stayed at 135/0/2 with the break in place. It was not a stale
  save or a wrong file; the break was genuinely a no-op. **R-02's stated
  mechanism was wrong**: a function that emits nothing returns `AutomationNull`,
  not `$null`, and `@(AutomationNull)` is an *empty* array, so the one-element
  `@($null)` the finding described never materialises on that path. `$null -eq
  $x` is true for both values, which is why a code review, a suite rewrite and
  four sessions of desk-checking all read past it. R-02 *was* a real crash
  before commit `96f7b09` changed `@($policy.assignments)` (a property access —
  a genuine `$null`) to a function call; the fix landed on already-unreachable
  code. Changes: two new regression tests that actually reach the
  `Where-Object { $_ }` guard (a null *element* inside a populated collection,
  the one shape that produces a real `$null`) in both
  `Backup.Script.Tests.ps1` and `SettingsCatalogSnapshot.Script.Tests.ps1`;
  corrected comments in both production scripts; R-02 corrected in
  `REVIEW-PHASE0.md`; the `@($null)` rule in `CLAUDE.md` and
  `AGENT_ONBOARDING.md` amended with the AutomationNull caveat; D-017 records
  why the guard was kept rather than deleted as dead code. **Suite: 137 passed,
  0 failed, 2 skipped**, and verified red for two separate load-bearing breaks.
  No production behaviour changed — comments only.
- **The Pester suite's first confirmed green run** (2026-07-30): 135 passed,
  0 failed, 2 skipped (R-08 and R-15, by design). Confirms both fixes from
  the previous entry actually work, not just that they were plausible on
  desk-check. Only the deliberate-break acceptance step remains before #14
  can close — see "Closing #14" above.
- **First tests for `MDMWinsOverGPToolKit/`** (item B, known issue #12,
  pure-functions half only). New file `tests/Toolkit.PureFunctions.Tests.ps1`
  covers `Normalize-PolicyName`, `Get-TokenSet`, `Get-JaccardScore` and
  `Convert-ValueToText` — the toolkit's only functions that need no live
  device. Both `Build-PolicyMappings.ps1` and `Test-MDMWinsOverGP.ps1`
  deliberately keep their own copy of each (each file's own comments say this
  is so the script stays runnable standalone, unlike the scripts/ copies
  Issue #14 collapsed), so this file tests **both** copies plus parity checks
  between them — the same shape `ImportDatabase.Functions.Tests.ps1` already
  uses for `ConvertTo-FlatSettings`/`Get-PolicyContentHash`.
  **Runs under `Set-StrictMode -Version 2.0`, not `-Off`** — the first test
  file in the suite to do so — because that is what all three
  `MDMWinsOverGPToolKit/` scripts actually set (unlike `scripts/`, R-01);
  `SuiteIntegrity.Tests.ps1`'s StrictMode guard was updated (previously a
  blanket "no test file may set any StrictMode version") to require exactly
  `-Version 2.0` in any `Toolkit.*.Tests.ps1` file and exactly none elsewhere,
  rather than weakened or bypassed. **Not yet done**: the ADMX/ADML parsers
  and everything needing a live device (registry reads, `gpresult.exe`,
  `MDMDiagReport.html`) still have no coverage beyond the parse check — see
  known issue #12. **Desk-checked only, not executed** — see "Needs
  verification" below.
- **First real Pester run, and two harness bugs it found, both fixed**
  (2026-07-29). The user's own Pester install resolved to 6.0.1, which
  rejects a `BeforeEach`/`AfterEach` written directly at file scope — 5 of the
  8 test files used that pattern. Fixed by wrapping each file's body in one
  outer `Describe`, which changes nothing under Pester 5 and is required
  under Pester 6; see `tests/README.md`. The run's parse check also caught a
  genuine, previously-unknown defect: `Test-MDMWinsOverGP.ps1` failed to parse
  at all because of a `$labelText:` variable/colon tokenizing ambiguity around
  line 1646 (R-16, fixed). **Neither fix is re-verified yet — ask the user to
  run `Invoke-Pester ./tests` again.**
- **`MDMWinsOverGPToolKit/README.md`'s intro rewritten** (Issue #16, item A,
  D-015). The first 126 lines were chat-export debris: a `sandbox:` download
  link for a ZIP that does not exist, a file list naming a `README.txt` this
  repo does not have, three sentences truncated mid-word by a bad edit
  (`([Microsoft Learn][1])olicyManager device and user settings.`), and a
  verbatim paste of the old `README.txt` duplicating the quick start. Replaced
  with a written intro — what MDMWinsOverGP is and why it matters, the four
  files in the folder, requirements, quick start, the recommended test
  sequence, what is collected, what a run produces, and verified-vs-heuristic.
  **Everything from "Blocked Group Policies (authoritative evidence)" (old line
  127) onward is byte-for-byte identical** — verified by diffing the tail
  against the pre-edit file. Every factual claim in the new text was checked
  against `Test-MDMWinsOverGP.ps1` itself (parameter behaviour, output file
  names, evidence-folder layout, exit codes), not carried over on trust; two
  claims were corrected during that check. Documentation only — no code
  changed, so nothing here needs a test or a hardware run.
- **Phase 0.2 — the test suite now tests production code** (Issue #14, D-012).
  `tests/TestHelpers.ps1` deleted along with its 21 copies of production
  functions; ~1,200 lines of new tests reach the shipped code through an AST
  loader and an offline Graph fake. Every script in `scripts/` is now exercised,
  and `tests/SuiteIntegrity.Tests.ps1` guards against the copies coming back.
  **The rewrite immediately found two bugs this project's own full code review
  had read past:**
  - **R-13** — R-03's fix stopped one line short. A policy with no settings
    still aborted, at `Get-PolicyContentHash`'s parameter binder instead of
    `ConvertTo-FlatSettings`'. `Export-PolicyWorkbook` had the same
    declaration. Three declarations fixed; no logic changed.
  - **R-14** — `Get-PolicyLastModifiedBy` returned `$null` **every time**, so
    "Last Modified By" was permanently blank in every workbook and in
    `_Index.xlsx`. A `$top=1` result arrived as a bare hashtable, whose
    `.Count` is its key count, so the guard passed and `[0]` found nothing.
  Also recorded R-15 (open, needs a user decision). **All desk-checked, none
  executed — the suite itself has never been run.**
- **Phase 0.1 — full code review of both toolsets** (Issue #13, D-008).
  Findings register: `docs/REVIEW-PHASE0.md`. Headline: the MDM toolkit is
  **clean on all three target bug classes** — every defect found was in
  `scripts/`, which never received the PR #9/#10 hardening.
  Fixed: two **live crashes** in the backup path — a policy with no
  assignments and a policy with no settings each aborted the run via
  parameter-binder rejection (independent of StrictMode, so reachable today);
  a malformed restore payload; and two latent `.Count`-on-`$null` sites.
  Also corrected three docs that asserted a false premise about StrictMode and
  path portability. **All desk-checked, none executed** — needs a real run
  against a tenant containing an unassigned policy and a policy with no
  settings.
- **PR #12** — `Invoke-MDMWinsOverGPFleet.ps1`: fleet orchestration from a
  management server. Includes two fixes found on real hardware: the
  double-hop failure (solved via `Copy` delivery mode, no delegation needed)
  and `gpresult.exe`'s 127-character output path limit (solved via a short
  `%windir%\Temp\MW-<id>` working folder).
- **PR #11** — Mapping generator, device corroboration, chained workflow,
  interactive report, central deployment, `-ReplayFromPath`.
- **PR #10, #9** — Error handling, logging, StrictMode crash fixes.
