# Project status

**This is the single source of truth for "where are we and what's next."**
Update it in the same commit as any change. If this file and the code
disagree, the code is right and this file is a bug.

- **Last updated**: 2026-07-28
- **Updated by**: session that rewrote the test suite (Issue #14)
- **Current phase**: Phase 0 — Bootstrap & consolidation (review and tests done,
  module extraction next)

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
| ~~2~~ | ~~Fix the test suite so it tests production code~~ — **done**, see `tests/README.md` | [#14](https://github.com/Wagner-Maximiliano/Intune_misc/issues/14) | #13 ✅ |
| 3 | Extract shared `Continuum.*` modules | [#15](https://github.com/Wagner-Maximiliano/Intune_misc/issues/15) | #13 ✅, #14 ✅ |
| 4 | Fix garbled `MDMWinsOverGPToolKit/README.md` intro | [#16](https://github.com/Wagner-Maximiliano/Intune_misc/issues/16) | — (independent) |

**Start with #15**, but **run the suite first** (`Invoke-Pester ./tests`) — it
has never been executed, only desk-checked, so treat its first run as part of
the task. See "Needs verification on real hardware" below.

#15 is now much safer than it was: the suite runs the shipped code, so a
refactor that changes behaviour shows up rather than passing silently. Two
things to carry into it, both already scaffolded:

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

**#16 is still independent** and small — a good warm-up for a short session.

**Three decisions are waiting on the user** before an agent can act on them:
R-06 (fleet exit-code contract), R-11 (when to adopt StrictMode in `scripts/`)
and R-15 (a content-hash fix that would re-ingest affected policies once). All
three are in `docs/REVIEW-PHASE0.md`. Don't act on any of them unilaterally.

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

### 1. Run the test suite — it has never been executed

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester ./tests
```

**Roughly 1,200 lines of new test code, desk-checked only.** The agent sandbox
has no PowerShell interpreter, so nothing in `tests/` has ever run. Expect to
fix harness problems on the first pass — Pester scoping and PowerShell's
`-like` wildcard rules are the likeliest culprits, not the assertions
themselves. Needs no tenant, no credentials and no network.

Two tests are `-Skip`ped **on purpose** and would fail if run: they assert the
fixed behaviour for open findings R-08 and R-15. That is by design, not
breakage — see `tests/README.md`.

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
already fixed — is in **`docs/REVIEW-PHASE0.md`**, indexed R-01…R-12.

1. ~~**The Pester tests don't test production code.**~~ **Fixed** (Issue #14).
   `tests/TestHelpers.ps1` and its 21 copies of production functions are gone.
   The suite now reaches production code two ways only — an AST loader that
   copies a function's real source out of the `.ps1`, and whole-script runs
   against an offline Graph fake — and `tests/SuiteIntegrity.Tests.ps1` fails
   if any test file ever redefines a production function name again. Full
   rationale in `tests/README.md`. **Caveat: the suite has never been run**
   (see "Needs verification" above).
2. **`MDMWinsOverGPToolKit/README.md` has a garbled intro section** (roughly
   its first ~120 lines) — artifacts of an old bad edit, with fragments like
   `([Microsoft Learn][1])olicyManager device and user settings.` Deliberately
   left alone through many sessions to avoid scope creep. Worth fixing during
   Phase 0.
3. **Tier A mapping matches are persistently ~0** in `Build-PolicyMappings.ps1`.
   Diagnosed as likely structural, not a bug: when MDM wins, the GPO registry
   write is suppressed, so "both configured" is self-contradictory for a real
   conflict. A secondary `MdmWinningProvider` promotion path was added to
   partially address it; **its real-world effect has never been confirmed.**
4. **Nothing is verifiable in the agent sandbox** — no PowerShell, no Windows,
   no devices. All agent changes are desk-checked only. See AGENT_ONBOARDING §2.
5. **Branch deletion fails with HTTP 403** from the agent environment. Merged
   branches must be deleted by the user via the GitHub UI.
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
8. **An all-offline fleet run exits `0` ("clean").**
   `Invoke-MDMWinsOverGPFleet.ps1` omits `Offline` from its failure rollup,
   contradicting its own documented contract ("failed to run **or connect**").
   A fleet of powered-off machines reports success to RMM/Intune — "couldn't
   tell" presented as "found nothing". **Left unfixed deliberately**: changing
   an exit-code contract needs the user's call. Recommendation is to map
   `Offline` to the existing exit 3 (R-06).
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
    verified only by real runs. `MDMWinsOverGPToolKit/` has no tests at all
    beyond a parse check — it collects evidence from a live Windows device.
13. **Smaller open items**: lexicographic sheet sort picks the wrong "previous"
    version after >9 runs in one day (R-08); the restore path's defensive
    guards become unreachable once StrictMode lands (R-09); audit-lookup
    failures are invisible without `-Verbose`, hiding permission problems
    (R-10); one unguarded hashtable lookup in the fleet script is inconsistent
    with its guarded twin (R-12).

---

## Recently shipped

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
