# Architecture

Describes both **what exists today** and the **target shape**. Keep the
"today" sections honest — an aspirational architecture document that
describes code that doesn't exist is worse than none.

---

## Today (pre-Phase 1)

Two independent sets of standalone PowerShell scripts. No shared code, no
shared configuration, no shared logging. Each script is self-contained and
runnable on its own — deliberately, since they're deployed to devices and
management servers by copy.

```
Intune_misc/
├── scripts/                      Intune Policy Backup toolset
│   ├── Backup-IntunePolicies.ps1          Graph API → JSON + Excel history
│   ├── Import-PolicyHistoryToDatabase.ps1 → SQLite  (the existing data layer)
│   ├── Restore-IntunePolicy.ps1
│   ├── Get-IntuneSettingsCatalogSnapshot.ps1
│   └── Export-PolicySummary.ps1
├── tests/                        Pester, offline. Runs the real scripts/ and
│                                 MDMWinsOverGPToolKit/ code (D-012, D-016)
├── MDMWinsOverGPToolKit/         MDM-vs-GPO validation toolset
│   ├── Test-MDMWinsOverGP.ps1             Single-device collection + HTML report
│   ├── Build-PolicyMappings.ps1           ADMX/registry → GPO↔CSP mapping CSV
│   └── Invoke-MDMWinsOverGPFleet.ps1      Fleet orchestration from mgmt server
└── docs/
```

### Notable existing design properties worth preserving

These were hard-won and should survive the refactor:

- **Path portability — `MDMWinsOverGPToolKit/` only.** There, everything
  resolves from `$PSScriptRoot`, never the current working directory, with an
  automatic fallback to `$env:ProgramData` when the script folder isn't
  writable (read-only share, Intune package cache). Central deployment depends
  on this.

  **`scripts/` does not have this property** — zero occurrences of
  `$PSScriptRoot` or `$env:ProgramData` in all five files; its defaults
  (`.\output`, `.\PolicySummary.xlsx`, `.\output\db\PolicyHistory.sqlite`) are
  working-directory-relative. This document previously claimed the property
  repo-wide, which was wrong (`docs/REVIEW-PHASE0.md` R-01). Bringing
  `scripts/` onto it during the module extraction is **net-new work and a
  behaviour change** for anyone depending on today's relative defaults — not a
  lift-and-shift.
- **Deterministic exit codes.** `0` clean / `1` fatal / `2` conflicts found /
  `3` degraded evidence. RMM and Intune consume these. The distinction
  between "found nothing" and "couldn't tell" is deliberate and must not be
  collapsed — it should become first-class UI state, not be flattened.
- **Evidence/inference separation.** The reports carefully distinguish
  Windows' own authoritative statements (the "Blocked Group Policies" table)
  from this toolkit's inferences (heuristic name matching). The UI must
  preserve that distinction rather than presenting one confidence level.
- **Replay.** `-ReplayFromPath` regenerates all analysis and reports from
  previously collected evidence without re-collection or elevation. This is
  the fastest development loop available and should be preserved and exposed.
- **No-double-hop fleet delivery.** `Copy` mode ensures remote devices never
  touch a network path, so no credential delegation is needed. Any future
  remote execution must keep this property.

### How `tests/` reaches the code (transitional)

`tests/` is offline and needs nothing but Pester — no tenant, no `ImportExcel`,
no `PSSQLite`. Because every script in `scripts/` is a monolith (parameters,
functions, then a main body that connects to Graph), tests reach it two ways,
both defined in `tests/TestSupport.ps1` and settled in D-012:

`MDMWinsOverGPToolKit/`'s pure functions are reached the same way via
`Import-ProductionFunction`, just against `Get-ToolkitScriptPath` instead of
`Get-ProductionScriptPath` — see `tests/Toolkit.PureFunctions.Tests.ps1`
(D-016). It runs under `Set-StrictMode -Version 2.0`, not the `-Off` the
`scripts/`-testing files use, because that is what the toolkit's own scripts
set; `SuiteIntegrity.Tests.ps1` enforces the match per file.

```
tests/*.Tests.ps1
   │
   ├── Import-ProductionFunction ──► parses scripts/<x>.ps1, re-declares the
   │                                 named functions from their AST extent
   │                                 (real source, no main body)
   │
   └── Enable-FakeGraph ──► stubs Get-MgContext / Connect-MgGraph /
                            Invoke-MgGraphRequest at global scope, then the
                            test runs `& scripts/<x>.ps1 -OutputPath <tmp>`
                            and inspects the files it wrote
```

**Both halves are scaffolding for the current shape.** Once the module
extraction lands, `Import-ProductionFunction` becomes `Import-Module
Continuum.PolicyBackup` and the whole-script tests become thin CLI-wrapper
tests over the same module functions. Note the loader's limit before relying on
it during the extraction: an AST-loaded function has no backing file, so
`$PSScriptRoot` is empty inside it.

---

## Target (Phase 1 onward)

```
┌──────────────────────────────────────────────┐
│  Browser UI  (HTML/CSS/JS, no build step)    │
│  Dashboard · Devices · Tools · Runs · Reports│
└───────────────────┬──────────────────────────┘
                    │ HTTP + JSON
┌───────────────────▼──────────────────────────┐
│  Console host  (PowerShell HTTP server)      │
│  routing · job queue · JSON API (localhost)  │
└───────────────────┬──────────────────────────┘
                    │ direct function calls
┌───────────────────▼──────────────────────────┐
│  Continuum PowerShell module(s)              │
│  ┌────────────┬──────────────┬─────────────┐ │
│  │ .Core      │ .PolicyBackup│ .MdmGpo     │ │
│  │ log/config │ Graph, hist. │ collect,    │ │
│  │ db, devices│ restore      │ map, fleet  │ │
│  └────────────┴──────────────┴─────────────┘ │
└───────────────────┬──────────────────────────┘
                    │
        ┌───────────▼───────────┐
        │ SQLite  +  evidence   │
        │ metadata   files/ZIPs │
        └───────────────────────┘
```

### The load-bearing rule

**No logic lives only in a script.** Scripts become thin CLI wrappers that
parse parameters and call module functions. The console calls the *same*
functions. This is what makes the engine testable and keeps the CLI and UI
from drifting apart — the CLI must keep working, since it's how the tools get
deployed to devices and run under Intune/SCCM/RMM.

### Module split

| Module | Holds |
|---|---|
| `Continuum.Core` | Logging, configuration, data-root resolution, SQLite access, device inventory, run history. Everything both tools need. |
| `Continuum.PolicyBackup` | Graph API, snapshots, change history, restore. |
| `Continuum.MdmGpo` | Evidence collection, ADMX/CSP mapping, overlap analysis, report generation, fleet orchestration. |
| `Continuum.Console` | HTTP host, routing, JSON API, static assets. |

`Core` must not depend on the tool modules. The tool modules must not depend
on each other — anything they'd share belongs in `Core`.

### Data model direction

Extend the existing Phase 6a SQLite schema rather than replacing it. The
shared entities are `devices`, `runs`, and `findings`; each tool adds its own
tables referencing those. `devices` is the join that makes the cross-tool
view in Phase 4 possible, so it must not be tool-specific.

Evidence files stay on disk, referenced by path — see D-003.

**No actor/user columns.** Per D-009 the console is single-admin and
localhost-only, and the user explicitly declined multi-user-ready schema.
Do not add `created_by`/`actor_id` columns speculatively.

### Deployment shape

The console runs on a management server. Device-side scripts keep working
exactly as they do today (copied to a share, run locally, or pushed via the
fleet script) — the console orchestrates them, it does not replace them.
Nothing about the console may become a requirement for running a collection
on a device.
