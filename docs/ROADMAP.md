# Roadmap

Phases are ordered by dependency, not ambition. Each has an explicit **Done
when** so an agent can tell whether it's finished rather than guessing.

Tick items off as they land, and update `docs/PROJECT_STATUS.md` to match.

---

## Phase 0 — Bootstrap & consolidation ← **current**

Make the existing ~9,000 lines something a product can safely be built on.
Scope is **both toolsets in full** — see D-008.

- [x] Documentation scaffolding for multi-session work (this file and siblings)
- [x] **Full code review** of all three MDMWinsOverGP scripts and all five
      Policy Backup scripts — done, see `docs/REVIEW-PHASE0.md`. The MDM
      toolkit was clean on all three bug classes; every defect was in
      `scripts/`. Two live crashes fixed, plus three docs corrected for a
      false StrictMode/path-portability premise.
- [ ] **Fix the test suite** so it exercises production code instead of
      reimplementing it — **written, not yet run** (Issue #14, D-012).
      `TestHelpers.ps1` and its 21 copies are gone; the suite loads real
      function source by AST and runs whole scripts against an offline Graph
      fake, and a guard test stops the copies returning. Writing it found and
      fixed **R-13** (R-03's fix stopped one line short — a no-settings policy
      still aborted) and **R-14** ("Last Modified By" was always blank). See
      `tests/README.md`. **Remaining**: run `Invoke-Pester ./tests`, fix what
      the first run turns up, and confirm a deliberate break in `scripts/`
      turns the suite red. That last step is the Issue's own acceptance
      criterion and needs an interpreter the agent sandbox does not have.
- [ ] **Adopt `Set-StrictMode -Version 2.0` in `scripts/`** — the five files
      there have none. **Sequencing matters**: fix the latent findings first
      (R-05, R-09), or they all become crashes simultaneously. Best folded
      into the module extraction below. See R-11. The suite is now the
      instrument for this: flip the `Set-StrictMode -Off` line at the top of
      each test file to `-Version 2.0` at the same time and re-run.
- [x] **Fleet exit-code contract for offline devices, decided** (R-06,
      D-014) — an all-offline run exits `0`, contradicting the script's own
      documented contract. The user declined the fix: it's a contract their
      RMM/Intune automation already reads natively, and they don't want it
      touched. Stays as-is. Don't revisit without the user raising it again.
- [ ] **Decide whether to align the two content-hash copies** (R-15) — a
      pre-R-02 snapshot (`"Assignments": null`) hashes differently in the
      import script than in the backup script. One-line fix, but it changes
      stored hashes and re-ingests affected policies once. Needs the user's
      call. A `-Skip`ped test already asserts the fixed behaviour (D-013).
- [ ] **Extract a shared PowerShell module** — see ARCHITECTURE. Scripts
      become thin CLI wrappers over module functions; the console calls the
      same functions. No logic may live only in a script.
- [ ] Unify logging, config, and data-root resolution across both toolsets.
      **Not a merge of two implementations**, as previously assumed: only the
      MDM toolkit has `Write-Log` (and `$PSScriptRoot`/`ProgramData` paths).
      `scripts/` has neither — 61 raw `Write-Host` calls and
      working-directory-relative defaults. So this is "adopt the MDM
      toolkit's mechanism into Core and migrate 61 call sites", and it
      **blocks Phase 1/3 progress reporting** because `Write-Host` output
      cannot be captured by a web UI..
- [x] Fix the garbled intro in `MDMWinsOverGPToolKit/README.md` (Known issue #2,
      Issue #16) — the first 126 lines (chat-export artifacts, three sentences
      truncated mid-word, and a pasted duplicate of the old `README.txt`) were
      replaced with a written intro: what MDMWinsOverGP is, the four files,
      requirements, quick start, test sequence, what is collected, what is
      produced, and verified-vs-heuristic. Everything from "Blocked Group
      Policies (authoritative evidence)" onward is byte-for-byte unchanged.

### Additive work that needs no user input and no test run

Sequenced here because it is safe to do *while* the Pester run and the R-11 /
R-15 decisions are outstanding — all of it is new code paths or new tests,
not changes to working behaviour. `docs/PROJECT_STATUS.md` carries the ordered
list (items A–E) and the reasoning; keep the two in step.

- [ ] Extend the test suite to `MDMWinsOverGPToolKit/` — its ~5,200 lines have
      **no tests at all** today, while `scripts/` now has real coverage
      (Known issue #12). Pure functions first, then parsers against fixtures.
- [ ] **Deletion detection** — report policies that existed in the previous
      run and no longer do. Report-only, never auto-act. The product's stated
      core anxiety, and currently nothing implements it.
- [ ] Capture `roleScopeTagIds` and `templateReference` in snapshots.
      **Time-sensitive** — history captured before this cannot be backfilled.
- [ ] Warn (don't block) when a snapshot contains secret-typed settings that
      cannot round-trip through restore.

**Done when**: every script's logic is importable and unit-tested, the test
suite fails if production code breaks, and both toolsets share one logging
and configuration mechanism.

*Progress against that: "the suite fails if production code breaks" is done for
`scripts/` as far as an offline suite can go — the Excel and SQLite paths, and
all of `MDMWinsOverGPToolKit/`, are still uncovered (`docs/PROJECT_STATUS.md`
known issue #12). "Importable" is what Issue #15 delivers.*

---

## Phase 1 — Console shell

The smallest thing that is genuinely a product rather than a script runner.

- [ ] Local HTTP server (PowerShell) with static asset serving and a JSON API
- [ ] Navigation shell: Dashboard / Devices / Tools / Runs / Reports
- [ ] Shared SQLite schema covering both toolsets (extend the Phase 6a schema)
- [ ] Bind to localhost only. **No auth, no accounts, no actor tracking** — see
      D-009; this is a deliberate, accepted tradeoff, not an oversight.
- [ ] Light/dark theming, reusing the existing report's CSS custom properties

**Done when**: the console starts with one command, serves a navigable UI,
and reads real data from SQLite.

---

## Phase 2 — Device inventory & CSV import

- [ ] CSV import with column mapping, validation, and a preview before commit
- [ ] Device inventory persisted in SQLite (supersedes today's loose
      `deviceList.csv` for fleet runs)
- [ ] Grouping/tagging (site, OU, migration wave)
- [ ] Online/reachability status surfaced in the UI

**Done when**: a user imports a CSV in the browser and sees their fleet.

---

## Phase 3 — Run orchestration from the UI

- [ ] Trigger MDMWinsOverGP fleet runs against selected devices
- [ ] Trigger Policy Backup runs on a schedule or on demand
- [ ] Live progress (per-device state, not just a spinner)
- [ ] Run history with drill-down into any individual device's evidence
- [ ] Surface the existing 0/1/2/3 exit-code contract as first-class UI state

**Done when**: a full fleet run is startable and monitorable without a terminal.

---

## Phase 4 — Dashboard & reporting

- [ ] Fleet health dashboard: conflict counts, policy drift, trends over time
- [ ] Cross-tool device view — a device's policy history *and* its MDM/GPO
      conflicts on one page. **This is the payoff for D-001; prioritise it.**
- [ ] Export: PDF, CSV, HTML; scheduled/emailed reports
- [ ] Saved filters and views

**Done when**: someone who has never used the CLI can answer "is this fleet
ready to migrate?" from the dashboard.

---

## Phase 5 — Productionization

- [ ] Installer / packaged deployment
- [ ] Multi-user access with roles
- [ ] Audit log of who ran what
- [ ] Configuration UI (no hand-edited files)
- [ ] Operator documentation, distinct from developer documentation

**Done when**: it can be handed to a business that didn't build it.

---

## Explicitly out of scope for now

Named so nobody re-proposes them mid-phase:

- **SaaS / multi-tenant hosting.** The design shouldn't *prevent* it, but
  nothing is built for it yet.
- **Rewriting the engine in another language.** See D-002.
- **Replacing SQLite with a server database.** See D-003. Keep the schema
  portable; don't act on it.
- **Non-Windows targets.** The entire premise is Windows/Intune/GPO.

---

## Pre-existing backlog

`docs/IMPROVED-PLAN.md` (744 lines) remains the detailed backlog for the
Intune Policy Backup toolset, including ready-to-paste prompts for individual
improvements. It predates this roadmap and is still valid — fold its items in
as they become relevant rather than duplicating them here.
