# Decisions

Architectural decisions that are **settled**. Don't relitigate these; if you
think one is wrong, say so once, concisely, then follow it unless the user
agrees to change it — and if they do, update the entry here.

Each entry records what was rejected too, so options don't get re-proposed
by a later session that lacks the context.

Format: `D-nnn — Title` / Date / Status / Decision / Why / Rejected.

---

## D-001 — The product is a unified platform over both toolsets

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** Intune Policy Backup and MDMWinsOverGP Validation become two
*tools* inside one console, sharing storage, device inventory, run history,
and export. Not two separate products.

**Why.** They solve adjacent problems the same person hits during the same
hybrid-migration project, and the long-term goal is explicitly a "toolbox and
dashboard for migrating environments." Sharing device inventory and run
history is where the compounding value is — a device's policy drift and its
MDM/GPO conflicts are far more useful side by side than apart.

**Rejected.**
- *MDMWinsOverGP front end only* — tighter and faster, but would have shaped
  the shell around one tool's needs and made the later merge expensive.
- *Unified shell, MDM tool first* — reasonable middle ground; rejected in
  favour of designing against both data models from the start, since the
  Policy Backup SQLite schema already exists and can inform the shared one.

---

## D-002 — PowerShell backend, browser front end

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** A local HTTP server written in PowerShell serves an HTML/JS
dashboard, running on the management server. All ~9,000 lines of existing
PowerShell remain the engine.

**Why.** Keeps proven, production-tested code as-is rather than rewriting it
in another language. Gives real dashboards, menus, CSV import and export. No
install burden beyond PowerShell itself. Consistent with the pre-existing
"Phase 6b — Internal web page" commitment in `docs/IMPROVED-PLAN.md`. The
UI is plain HTTP + JSON, so the backend can later be replaced with .NET or
Node without rewriting the front end.

**Rejected.**
- *Full .NET/Node + React rewrite* — highest ceiling and most credible
  commercially, but a substantial rewrite with a hosting story attached, and
  far slower to working value. Revisit if this becomes a SaaS product.
- *WPF desktop GUI* — no dependencies and native feel, but painful to
  maintain, weak for dashboards, single-user, and hard to sell.
- *Static generated HTML* — closest to today's report, but cannot support
  menus, CSV import, or triggering runs. It's a report, not a front end.

---

## D-003 — SQLite for metadata, files for evidence

- **Date**: Pre-existing (Phase 6a), reaffirmed 2026-07-28
- **Status**: Decided

**Decision.** SQLite holds devices, runs, outcomes, findings, and history.
Raw evidence (ZIPs, GPResult XML, EVTX, MDMDiagReport.html) stays on the
file system, referenced by path from the database.

**Why.** Already built and working in `Import-PolicyHistoryToDatabase.ps1`
(673 lines). Zero install, portable, single file, but supports the real
queries a dashboard needs (trends, history, cross-device filtering). Evidence
files are large, opaque, and only ever read whole — no reason to put them in
a database.

**Rejected.**
- *Flat files only* — simplest, but trending across many runs gets slow and
  awkward, and the dashboard is fundamentally a query surface.
- *SQL Server / Azure SQL* — right answer for multi-admin or SaaS, but adds
  an infrastructure dependency that kills the "just run it" property that
  makes this deployable today. The schema should stay portable enough to
  migrate later.

---

## D-004 — Documentation in-repo is the source of truth for project state

- **Date**: 2026-07-28
- **Status**: Decided

**Decision.** `docs/PROJECT_STATUS.md`, `DECISIONS.md`, `ROADMAP.md`, and
`ARCHITECTURE.md` are authoritative. Agents must update them in the same
commit as any change (see `docs/AGENT_ONBOARDING.md`).

**Why.** Agent sessions have no memory and get compacted mid-task. Markdown
in the repo is always in the agent's context without any API call, is
reviewable in diffs, and is versioned alongside the code it describes. This
project already proved the pattern works — `docs/IMPROVED-PLAN.md` carried
detailed context across many sessions successfully.

**Rejected.**
- *GitHub Issues/Projects as source of truth* — better UI for humans, but
  costs API calls to discover and an agent may simply not think to look.
  Issues may still be used as a human-facing mirror; they are not canonical.

---

## D-005 — Existing code is reviewed and modularized before UI work

- **Date**: 2026-07-28
- **Status**: Decided

**Decision.** Phase 0 (review, harden, extract a shared module) completes
before Phase 1 (console shell) begins.

**Why.** The UI must call testable functions, not shell out to 3,000-line
scripts. Building the product layer on unreviewed monoliths would bake the
coupling in permanently, and this codebase has a *known, repeatedly-shipped*
bug class (StrictMode `.Count` on `$null`) plus a test suite that doesn't
actually exercise production code. Both must be fixed before anything is
built on top, or the refactor can't be trusted.

**Rejected.**
- *Build UI first* — faster to a demo, but couples the UI to current
  behaviour and makes the inevitable refactor more expensive.
- *Refactor incrementally as the UI needs it* — keeps momentum, but leaves
  the codebase in a mixed state for a long time.

---

## D-006 — Product name is "Continuum"

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** The product is **Continuum**. PowerShell modules are namespaced
`Continuum.Core`, `Continuum.PolicyBackup`, `Continuum.MdmGpo`,
`Continuum.Console`.

**Why.** The GPO-to-MDM transition is a continuum rather than a cliff edge,
which is exactly the story this toolbox tells: it gives visibility into a
gradual migration instead of treating it as a switch. Short, memorable, and
viable as a commercial name.

**Rejected.** *HybridOps Console* (descriptive but generic, and the term is
already common); *PolicyBridge* (very clear to a buyer, but risks reading as
narrower than the eventual scope).

---

## D-007 — GitHub Issues mirror the roadmap; markdown stays canonical

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** Roadmap items also exist as GitHub Issues on a Project board.
The markdown docs remain authoritative (D-004) — Issues are a human-facing
view. Agents open/close Issues as they work, but must never treat an Issue as
the source of truth over `docs/PROJECT_STATUS.md`.

**Why.** The user needs progress visible at a glance without reading files.
Keeping markdown canonical preserves the property that an agent has full
context with no API calls, while the board gives a kanban view for planning.

**Conflict rule.** If an Issue and the markdown disagree, **the markdown
wins** and the Issue gets corrected.

**Rejected.** *Markdown only* (zero overhead but no board); *Milestones only*
(lighter, but no per-task visibility).

---

## D-008 — Phase 0 reviews all ~9,000 lines, both toolsets

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** The Phase 0 review covers Policy Backup *and* MDMWinsOverGP in
full, plus fixing the test suite so it exercises production code.

**Why.** D-001 makes these one product sharing a module layer. Reviewing only
one half would leave the shared foundation half-vetted, and the Policy Backup
test gap would be inherited straight into `Continuum.Core`.

**Rejected.** *MDMWinsOverGP only* (faster, but leaves the test gap in place
before absorption); *targeted bug-class sweep only* (fastest to a trustworthy
refactor, but only finds problems already known to exist).

---

## D-009 — Console is single-admin, localhost-only

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** The console assumes one administrator on the management server.
No accounts, no roles, **no actor tracking on writes**. Whoever is logged into
the machine is the user.

**Why.** Fastest path to a useful tool; multi-user was not needed now.

**Accepted cost — read this before "improving" it.** The user was shown the
alternative (stamping an actor ID on runs and changes now, so multi-user is
additive later) and **deliberately chose not to**. This means adding
multi-user in Phase 5 will require a schema migration and touching every
write path. That is a known, accepted tradeoff — **do not add actor tracking
or auth scaffolding on your own initiative.** Raise it with the user if it
starts to bite; don't pre-empt it.

**Rejected.** *Single admin with multi-user-ready schema* (recommended, but
declined); *full multi-user from day one* (significant work before the tool
does anything useful).

---

## D-010 — Orchestrator/delegate split for agent work

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** A high-reasoning model orchestrates, plans, and verifies;
Sonnet and Haiku do bulk reading and writing. Details in `CLAUDE.md`.

**Why.** Cost and context efficiency. The orchestrator's context stays
focused on architecture and verification instead of being consumed by file
contents. Reviewing work is cheaper than producing it, and this project's
real failure mode has been unverified changes reaching production — an
explicit verification step addresses that directly.

**Rejected.** *Orchestrator does everything itself* (simpler, but burns the
expensive model's context on mechanical work and compacts sessions faster).
