# Intune Policy Backup

Scripts to snapshot Intune configuration policies via Microsoft Graph, since
Intune itself has no version history or recovery for deleted/edited policies.

## Roadmap

1. **Phase 1 (current)** — read-only pull of Settings Catalog policies
   (config + assignments) to local JSON, to validate the data before
   building Excel output.
2. **Phase 2** — export each policy to an Excel workbook (via `ImportExcel`)
   matching the project's template layout.
3. **Phase 3** — versioning: detect changed `lastModifiedDateTime`, append a
   new dated sheet per change, pull "modified by" from Intune audit logs
   (`deviceManagement/auditEvents`, subject to the tenant's audit retention
   window).
4. **Phase 4** — package as a scheduled task on a management server
   (app-only auth via cert, logging, alerting).
5. **Phase 5** — reverse path: read a template and create/update a policy
   from it via Graph (restore).
6. **Phase 6 (later)** — persist to a database with a simple web front end.

## Phase 1 usage

Requires `Microsoft.Graph.Authentication`:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

Run:

```powershell
./scripts/Get-IntuneSettingsCatalogSnapshot.ps1 -OutputPath ./output
```

This prompts for an interactive sign-in (delegated auth), requiring
`DeviceManagementConfiguration.Read.All` and `Group.Read.All`, and writes one
JSON file per Settings Catalog policy to `-OutputPath` containing metadata,
resolved assignments (group names, filter names), and raw settings.
