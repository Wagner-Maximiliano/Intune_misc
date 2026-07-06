# Intune Policy Backup

PowerShell + Microsoft Graph scripts to snapshot Intune configuration policies,
since Intune itself has no version history or recovery for deleted/edited
policies. Each run captures every policy's configuration and assignments, saves
a lossless JSON snapshot, and appends a **new dated worksheet to a per-policy
Excel workbook only when that policy actually changed** — giving you a
verifiable version history you can diff and, later, restore from.

## Design in one paragraph

Every pull produces **two artifacts per policy**: an authoritative **JSON
snapshot** (`output/json/`) that round-trips back to Graph for restore, and a
human-readable **Excel workbook** (`output/xlsx/`) for verification. Files are
keyed by **policy ID**, so renaming a policy never forks its history. A state
manifest plus a content hash decide whether anything changed, so re-running is
cheap and only real edits create new sheets.

## Files

| File | Purpose |
|------|---------|
| `scripts/Get-IntuneSettingsCatalogSnapshot.ps1` | Phase 1: read-only JSON pull, no Excel/versioning. **Single, self-contained file.** |
| `scripts/Backup-IntunePolicies.ps1` | Phase 2+3: JSON + versioned Excel workbooks + master index + run summary. **Single, self-contained file.** |
| `tests/` | Offline Pester tests, for development only — not needed to run the scripts above. |

Each script under `scripts/` is a standalone `.ps1` file — everything it
needs is defined inside it. There is no shared file to dot-source and nothing
else it depends on. Open one, read it top to bottom, and everything it does
is right there.

## Requirements

Each script's own header comment lists the modules it needs. **The scripts do
not import modules for you** — import them yourself first, in the same
PowerShell session, before running the script:

```powershell
Import-Module Microsoft.Graph.Authentication
Import-Module ImportExcel   # only needed for Backup-IntunePolicies.ps1
```

If you don't have them yet:

```powershell
Install-Module Microsoft.Graph.Authentication, ImportExcel -Scope CurrentUser
```

**Compatibility:** the scripts target **Windows PowerShell 5.1** (also run on
PowerShell 7). They avoid 7-only syntax and read/write UTF-8 without a BOM.

**Run the `.ps1` file directly** (e.g. `.\Backup-IntunePolicies.ps1`) rather
than pasting its contents into the console line-by-line — a couple of things
in the script (like the default output folder) assume it's running as a
saved script file.

## Usage

Import the modules (see above), then, in the same session:

```powershell
.\scripts\Backup-IntunePolicies.ps1 -OutputPath .\output
```

- `-WhatIf` — detect changes and print the summary without writing any files.
- `-SkipAudit` — skip the "Last Modified By" audit lookup (fewer scopes needed).

Delegated scopes requested: `DeviceManagementConfiguration.Read.All`,
`Group.Read.All`, and (unless `-SkipAudit`) `DeviceManagementApps.Read.All`
for audit events.

### Output layout

```
output/
  json/    <name>__<policyId>.json      # authoritative snapshot (restore source)
  xlsx/    <name>__<policyId>.xlsx       # one dated sheet per version, diff-highlighted
           _Index.xlsx                   # master list of all policies
  state/   manifest.json                 # per-policy lastModified + contentHash
           definitions.json              # cached setting definitions (reused across runs)
```

Each workbook sheet is a self-contained snapshot: a header block (name,
description, type, dates, assigned/excluded groups, filters, last-modified-by)
above a `Path | Setting | Configured Value` table. When a new version is added,
rows are highlighted vs. the previous sheet — **green** added, **amber**
changed, **red** removed. A hidden `Meta` sheet points back to the
authoritative JSON.

## Tests (run offline, no tenant needed)

```powershell
Invoke-Pester ./tests
```

Covers settings flattening (all setting-instance shapes + raw fallback),
content-hash stability/sensitivity, sheet-name collision handling, and manifest
round-trip.

## Notes & limitations

- **Setting readability** is hybrid: friendly titles/values where the setting
  definition resolves, raw definition IDs as a fallback — it never breaks on an
  unknown setting.
- **"Last Modified By"** comes from Intune audit events and only covers the
  tenant's audit retention window; it is best-effort, not guaranteed.
- **Scope:** Settings Catalog policies (`deviceManagement/configurationPolicies`)
  only, for now.

## Roadmap

1. **Phase 1** ✅ — read-only JSON pull.
2. **Phase 2** ✅ — per-policy Excel export.
3. **Phase 3** ✅ — versioning (dated sheets, hash dedup, diff highlight, audit).
4. **Phase 4** — scheduled task on a management server: app-only cert auth,
   logging, alerting (retry/backoff already built into the paging layer).
5. **Phase 5** — restore / "create policy from template": re-POST a stored JSON
   snapshot to Graph (strip read-only fields).
6. **Phase 6** — database + internal web page (the `_Index` row shape is the
   intended schema).

Additional policy types (legacy device configurations, administrative
templates, compliance, endpoint security intents) slot in via a `PolicyType`
field without reworking the Excel/versioning layers.
