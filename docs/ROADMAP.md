# Roadmap

Phases are ordered by dependency, not ambition. Each has an explicit **Done
when** so an agent can tell whether it's finished rather than guessing.

Tick items off as they land, and update `docs/PROJECT_STATUS.md` to match.

---

## Phase 0 — Bootstrap & consolidation ← **current**

Make the existing ~9,000 lines something a product can safely be built on.
Scope is **both toolsets in full** — see D-008.

- [x] Documentation scaffolding for multi-session work (this file and siblings)
- [ ] **Full code review** of all three MDMWinsOverGP scripts and all five
      Policy Backup scripts. Specifically hunt the recurring StrictMode
      `.Count`-on-`$null` bug class, automatic-variable shadowing, and
      `Mandatory` array params missing `[AllowEmptyCollection()]`.
- [ ] **Fix the test suite** so it exercises production code instead of
      reimplementing it (Known issue #1). Prerequisite for trusting any
      refactor that follows.
- [ ] **Extract a shared PowerShell module** — see ARCHITECTURE. Scripts
      become thin CLI wrappers over module functions; the console calls the
      same functions. No logic may live only in a script.
- [ ] Unify logging, config, and data-root resolution across both toolsets
      (they currently each have their own `Write-Log` and path logic).
- [ ] Fix the garbled intro in `MDMWinsOverGPToolKit/README.md` (Known issue #2)

**Done when**: every script's logic is importable and unit-tested, the test
suite fails if production code breaks, and both toolsets share one logging
and configuration mechanism.

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
