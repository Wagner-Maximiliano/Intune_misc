# Project status

**This is the single source of truth for "where are we and what's next."**
Update it in the same commit as any change. If this file and the code
disagree, the code is right and this file is a bug.

- **Last updated**: 2026-07-28
- **Updated by**: session that set up the platform bootstrap scaffolding
- **Current phase**: Phase 0 — Bootstrap & consolidation (just started)

---

## What this project is

**Working title: HybridOps Console** (name not final — see DECISIONS.md D-006)

A management console for administering and migrating hybrid Windows
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
| `tests/` (Pester) | 838 | Exists, but see Known issues #1. |

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

**Phase 0 is where you are. Do these before any UI work.**

1. **Code review + hardening pass** (not started) — see ROADMAP Phase 0.
   ~9,000 lines have never had a dedicated review. Target the recurring
   StrictMode `.Count` bug class specifically, plus the `tests/` gap below.
2. **Extract shared PowerShell module** (not started) — the UI must call
   testable functions, not shell out to monolithic scripts. See ARCHITECTURE.
3. **Then** Phase 1 (the console shell). Do not start Phase 1 before 1 and 2.

---

## Known issues / open threads

1. **The Pester tests don't test production code.** Called out in
   `docs/IMPROVED-PLAN.md`'s assessment: `tests/TestHelpers.ps1` (697 lines)
   largely reimplements logic rather than importing it. Fixing this is part
   of the Phase 0 review, and is a prerequisite for trusting any refactor.
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

---

## Recently shipped

- **PR #12** — `Invoke-MDMWinsOverGPFleet.ps1`: fleet orchestration from a
  management server. Includes two fixes found on real hardware: the
  double-hop failure (solved via `Copy` delivery mode, no delegation needed)
  and `gpresult.exe`'s 127-character output path limit (solved via a short
  `%windir%\Temp\MW-<id>` working folder).
- **PR #11** — Mapping generator, device corroboration, chained workflow,
  interactive report, central deployment, `-ReplayFromPath`.
- **PR #10, #9** — Error handling, logging, StrictMode crash fixes.
