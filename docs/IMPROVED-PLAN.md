# Intune Policy Backup — Improved Plan & Recommendations

This document is a snapshot of a planning review done after Phase 5 (restore)
and Phase 6a (SQLite history database) were built. It captures:

1. An honest assessment of the project as it stood at that point.
2. An improved/reordered roadmap.
3. A numbered list of individual recommendations, each with a **ready-to-paste
   prompt** you can hand to a fresh Claude Code session to build just that
   one thing.

Nothing in this document has been "decided" — it's a menu. Pick the numbers
you want, in any order, and use the matching prompt. Each prompt is written
to stand alone: paste it into a new session with this repo attached and it
has enough context to work without you re-explaining the project.

---

## 1. Assessment (as of Phase 6a)

The foundations are genuinely good, and most of what makes this project
pleasant to hand over already exists: self-contained scripts you can read
top-to-bottom, a README that explains *why* decisions were made (the
`$expand` filter bug, the BOM issue, the all-zero-GUID sentinel), consistent
conventions across all five scripts, and hard-won bugs documented in place.
That's rarer than it should be.

The honest weaknesses, found by re-reading the code rather than the plan:

1. **The tests don't test the production code.** `tests/TestHelpers.ps1` is a
   hand-maintained *mirror* of the logic in `Backup-IntunePolicies.ps1` (its
   own header admits this). The flattening/hashing logic now lives in
   **four places** (Backup, Import-DB, Restore shares Format-AssignmentList,
   TestHelpers). Tests can pass while the real script is broken, and the
   copies can silently drift — this is the single biggest structural risk.
2. **Snapshots silently drop two real policy fields.** The Graph policy
   object carries `roleScopeTagIds` (scope tags) and `templateReference`
   (endpoint-security/template-based policies), and the backup doesn't store
   either. For a *backup* tool that's quiet data loss: a restored policy
   loses its scope tags, and a template-based policy may not restore
   correctly at all.
3. **The tool never actually detects deletion.** The entire reason this
   project exists is that Intune has no recycle bin — yet if a policy is
   deleted, it just quietly stops appearing. Nothing compares the manifest
   (every policy ever seen) against the live pull and says "these 2 policies
   are GONE."
4. **`-Platform` wipes the index.** `_Index.xlsx` is deleted and rebuilt from
   only the current run's (filtered) policies, so running `-Platform Windows`
   erases all iOS/macOS rows from the master index. Errored policies drop out
   of it too.
5. **Unattended runs would hang.** Every script falls back to *interactive*
   `Connect-MgGraph` when no context exists — in a scheduled task that hangs
   forever instead of failing loudly. Must be fixed before Phase 4.
6. **No automation checks anything.** No CI, no linting. A tiny GitHub
   Actions workflow running PSScriptAnalyzer + Pester on real PowerShell 5.1
   and 7 would catch a whole class of errors before merge.

---

## 2. The improved plan

Reordered so correctness fixes land before the pretty things built on top of
them, with an explicit quality bar every PR must meet. Phase numbering
preserved where it exists in the README's existing roadmap.

### Quality bar (applies to every PR from now on)

- Single self-contained `.ps1`, no dot-sourcing, no `Import-Module`, reuse
  existing Graph context, PS 5.1 compatible, BOM-free UTF-8 — unchanged.
- Header comment states: purpose, required modules, required scopes, usage
  examples, and *what the script will never do* (like Restore's "never
  touches assignments").
- `-WhatIf` on anything that writes (files count; Graph writes absolutely).
- README updated in the same PR; tests updated where the logic is testable
  offline.
- One PR = one reviewable slice; merged to `main` via PR, branch deleted
  after.

### Phase 6.5 — Hardening & trust (NEW — recommended before 6b)

Small, high-value correctness work; each bullet is one small PR and maps to
a numbered recommendation below:

- **a.** Capture `roleScopeTagIds` + `templateReference` in snapshots
  (Backup + Phase-1 script), store them in the DB, and have Restore send
  `roleScopeTagIds` / refuse-with-clear-message on template-based policies
  it can't faithfully restore. *(→ Recommendation 1)*
- **b.** Deletion detection: Backup compares manifest vs. live pull and
  reports "policies missing since last run" in the summary; mark
  `IsDeleted`/`DeletedDetectedAt` in the DB. Report-only — no automatic
  anything. *(→ Recommendation 2)*
- **c.** Fix `_Index.xlsx` rebuild to merge rather than wipe when
  `-Platform` filters or a policy errors. *(→ Recommendation 3)*
- **d.** Make tests exercise production code instead of a hand-maintained
  mirror. *(→ Recommendation 6)*
- **e.** CI: PSScriptAnalyzer + Pester on PS 5.1 and 7. *(→ Recommendation 7)*

### Phase 6b — Internal web page (already agreed, unchanged)

One script, `Export-PolicyHistorySite.ps1`: reads **only the SQLite DB**,
emits a **single self-contained HTML file** — inline CSS/JS, data embedded
as JSON, zero CDN/network dependencies so it works on a locked-down
management server and can be emailed/copied. Views: searchable policy list →
per-policy version timeline → version-to-version settings diff (reusing the
green/amber/red idea from Excel) → assignments per version → "what changed
in the last N days". Read-only by construction.

### Phase 4 — Scheduled/unattended runs (after 6.5, since it depends on 6.5's fail-fast fix)

- `-NoInteractive` (or auto-detect) so a missing connection **fails fast
  with a non-zero exit code** instead of prompting. *(→ Recommendation 4)*
- A thin wrapper script (don't rewrite Backup): app-only cert auth,
  `Start-Transcript` logging with rotation, machine-readable run-summary
  JSON for monitoring, optional alert on failure/deletion-detected (Teams
  webhook or SMTP — pick one, keep it optional).
- Documented least-privilege app registration setup (application
  permissions, cert creation) in the ops runbook. *(→ Recommendation 11)*

### Phase 7 — Additional policy types (existing roadmap item, unchanged)

Legacy device configurations, compliance, etc. via the `PolicyType` field.
Only after 4 and 6 are done — each new type multiplies surface area.

### Continuous — Documentation & handover

See recommendations 8–13 below.

---

## 3. Individual recommendations, with prompts

Each entry: what it is, why it matters, size, and a **prompt** you can paste
into a fresh Claude Code session (with this repo attached) to build just
that item. The prompts assume the session will branch off `main`, follow the
existing script conventions, update the README, and open a PR itself — you
don't need to add any of that.

Prompts are self-contained on purpose — paste one alone, or paste several in
one session back-to-back.

---

### Correctness / data completeness

*(Recommendations 1–3 are near-mandatory — they're bugs/gaps, not ideas.)*

#### 1. Capture `roleScopeTagIds` and `templateReference` in snapshots — Small

Graph's policy object includes `roleScopeTagIds` (scope tags) and
`templateReference` (set for endpoint-security/template-based policies), and
neither is currently stored in the JSON snapshot written by
`Backup-IntunePolicies.ps1` or `Get-IntuneSettingsCatalogSnapshot.ps1`. For a
backup tool that's silent data loss — history captured before this fix can
never be backfilled. `Restore-IntunePolicy.ps1` should also send
`roleScopeTagIds` on create, and should detect a `templateReference` on the
source snapshot and either restore it faithfully or refuse with a clear
message (rather than silently producing a policy that looks right but isn't
template-linked).

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> `scripts/Backup-IntunePolicies.ps1`, `scripts/Get-IntuneSettingsCatalogSnapshot.ps1`,
> and `scripts/Restore-IntunePolicy.ps1` first.
>
> Currently the JSON snapshot these scripts write does NOT capture two real
> fields from the Graph `deviceManagementConfigurationPolicy` object:
> `roleScopeTagIds` (a string array) and `templateReference` (an object,
> present when the policy is based on an endpoint-security/compliance
> template). Add both to the snapshot object in both backup scripts
> (alongside the existing `Platforms`/`Technologies` fields). Then update
> `Restore-IntunePolicy.ps1` to include `roleScopeTagIds` in its create
> payload when present, and to detect a non-null `templateReference` on the
> source snapshot: print a clear warning that template-based policies may
> not restore correctly via a raw settings POST, and let `-Force` (a new
> switch) proceed anyway, otherwise abort before the POST with a clear
> message pointing at the limitation. Update the content-hash function
> (`Get-PolicyContentHash`) to NOT include `roleScopeTagIds`/`templateReference`
> in the hash unless you deliberately decide they should trigger a new
> version — think it through and document your choice in a comment. Update
> `tests/TestHelpers.ps1` and `tests/fixtures/policy-mixed.json` /
> `IntuneBackup.Tests.ps1` if the hash logic changes. Update README.md's
> notes on what's captured. Follow the project's existing conventions:
> self-contained scripts, PS 5.1 compatible, no dot-sourcing, no
> Import-Module. Open a PR into main when done."

---

#### 2. Deletion detection & reporting — Small

The entire premise of this project is that Intune has no recovery for
deleted policies — but today, if a policy is deleted, the backup script just
quietly stops seeing it. Nothing ever says "this policy existed last run and
doesn't anymore." This is the single most valuable missing feature relative
to the project's stated purpose.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> `scripts/Backup-IntunePolicies.ps1` first, paying attention to how
> `$Manifest` (output/state/manifest.json) tracks every policy ever seen by
> PolicyId.
>
> Add deletion detection: after fetching the current live list of policies
> from Graph, compare the set of PolicyIds in `$Manifest` against the set
> just fetched. Any manifest PolicyId NOT in the live fetch is a policy that
> has disappeared since the last run (deleted, or the app lost access to
> it — note that ambiguity in the output). Print these clearly in the run
> summary (e.g. a 'deleted' status group alongside the existing
> created/updated/skipped/errored groups), and add a `deletedDetectedAt`
> field to that policy's manifest entry (don't remove it from the manifest —
> its JSON/Excel history must stay discoverable). Do NOT delete or modify
> anything for that policy automatically — this is report-only, matching the
> project's existing safety posture. If `scripts/Import-PolicyHistoryToDatabase.ps1`
> exists on this branch, also add an `IsDeleted`/`DeletedDetectedAt` column
> to the `Policies` table and set it during ingestion when the manifest
> shows a deletion (read the manifest via the same path convention as
> Backup-IntunePolicies.ps1: output/state/manifest.json, sibling to the
> -JsonPath the DB script is pointed at, same probing pattern already used
> for definitions.json). Update README.md to describe the new behavior.
> Follow the project's existing conventions throughout. Open a PR into main
> when done."

---

#### 3. Fix `_Index.xlsx` to merge instead of wipe — Small

`Export-IndexWorkbook` in `Backup-IntunePolicies.ps1` deletes and rebuilds
`_Index.xlsx` from only the current run's `$indexRows` every time. Since
`$indexRows` only contains policies from *this run* (filtered by
`-Platform`, and excluding any that errored), running with `-Platform
Windows` silently erases every iOS/macOS/etc. row from the master index,
and a transient error on one policy drops it from the index until the next
clean run.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> `scripts/Backup-IntunePolicies.ps1` closely, especially
> `Export-IndexWorkbook` and how `$indexRows` is built in the main loop.
>
> Bug: `Export-IndexWorkbook` deletes `_Index.xlsx` and rewrites it from only
> the current run's `$indexRows`, which only contains policies actually
> processed this run. Running with `-Platform Windows` (or `-Platform` set
> to anything other than `All`) silently erases every other platform's rows
> from the master index. A policy that errors this run also drops out of
> the index. Fix this so the index always reflects every policy the tool has
> ever seen, merged: before rebuilding, read the existing `_Index.xlsx` (if
> present) to get prior rows, key by PolicyId, and upsert this run's rows on
> top of that — never simply drop rows for policies not touched this run.
> Handle the case where the workbook doesn't exist yet (first run). Keep
> the `-WhatIf` behavior consistent (no write happens under -WhatIf). Add or
> update a test if there's a testable piece of this logic (the merge-by-key
> logic can likely be extracted into a small pure function and tested
> offline the same way `Get-VersionSheetName` is tested in
> tests/IntuneBackup.Tests.ps1 — mirror that pattern in TestHelpers.ps1 too
> if that file still exists on this branch). Update README.md if its
> description of `_Index.xlsx` behavior needs correcting. Open a PR into
> main when done."

---

#### 4. Fail-fast non-interactive mode — Small (prerequisite for Phase 4)

Every script currently falls back to interactive `Connect-MgGraph` if no
Graph context exists. That's correct for a human running the script by
hand, but fatal for a scheduled task: it will hang indefinitely waiting for
a sign-in prompt nobody will ever see.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and all
> scripts under scripts/ that call `Connect-MgGraph` (Backup-IntunePolicies.ps1,
> Get-IntuneSettingsCatalogSnapshot.ps1, Restore-IntunePolicy.ps1) — note the
> shared pattern: check `Get-MgContext` first, and only call
> `Connect-MgGraph` (interactive) if nothing exists.
>
> Add a `-NoInteractive` switch to each of these scripts. When set and no
> existing Graph context is found, the script must fail immediately with a
> clear, actionable error message (e.g. 'No Graph connection and
> -NoInteractive was set. Connect first with Connect-MgGraph
> -CertificateThumbprint ... -ClientId ... -TenantId ..., or omit
> -NoInteractive for an interactive sign-in.') and exit with a non-zero exit
> code (`exit 1`, not just `throw`, so a calling scheduled task sees
> failure) — don't fall through to the interactive `Connect-MgGraph` call at
> all in that branch. When an existing context IS found, `-NoInteractive`
> should have no effect (that's already the non-interactive path). Keep
> everything else about the connection logic unchanged. Update each script's
> header comment and the README's CONNECTION explanation to document the new
> switch. This is a prerequisite for the planned Phase 4 (scheduled task)
> work, so keep it minimal and focused — don't build the scheduled task
> wrapper itself in this PR. Open a PR into main when done."

---

#### 5. Document the secrets/masked-value limitation — Small

Some Settings Catalog values (certificates, passwords, secret fields) come
back from Graph masked or tokenized rather than as usable plaintext. A
restore built from such a snapshot may create a policy where that field
doesn't actually work, with no obvious error. This should be documented
plainly rather than "fixed" (there's no good fix — Graph doesn't return
secrets on read, by design).

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> `scripts/Restore-IntunePolicy.ps1` first.
>
> Some Settings Catalog setting values (e.g. `secretSettingValue`-typed
> settings, or others Graph masks on read) don't round-trip through a
> read-then-write cycle — Graph will not return the real secret on GET, so a
> snapshot built from a read call cannot faithfully restore that specific
> setting even though the rest of the policy restores fine. Add: (1) a
> clear, single paragraph in README.md's 'Notes & limitations' section
> explaining this in plain terms — what a user might see (a restored policy
> where a secret-backed setting is blank/broken) and why it isn't a bug in
> this project; (2) a best-effort check in `Restore-IntunePolicy.ps1` that
> scans the snapshot's settings for any `@odata.type` containing
> 'Secret' (case-insensitive) before the POST, and if found, prints a
> visible warning (not an error — don't block the restore) listing which
> setting path(s) are affected so the human knows to manually re-enter that
> value in Intune afterward. Follow existing script conventions (the
> settings-scanning logic can reuse the same `foreach ($s in
> $originalSettings)` loop already in the script, just add a check). Open a
> PR into main when done."

---

### Engineering practices & tooling

#### 6. AST-based tests + parity test (kill the TestHelpers mirror) — Medium

`tests/TestHelpers.ps1` is a hand-copied duplicate of logic from
`Backup-IntunePolicies.ps1`. The two can drift silently: a real bug fixed in
the production script might never get mirrored into the test copy, so tests
keep passing against stale logic. This is the highest-leverage engineering
change available in this project.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md,
> `scripts/Backup-IntunePolicies.ps1`, `tests/TestHelpers.ps1`, and
> `tests/IntuneBackup.Tests.ps1` closely first.
>
> Problem: `tests/TestHelpers.ps1`'s header admits it is 'a test-only mirror
> of the logic in scripts/Backup-IntunePolicies.ps1' — hand-copied, not
> dot-sourced (dot-sourcing production scripts was deliberately rejected
> earlier in this project after it caused hard-to-diagnose 'function not
> recognized' failures — do NOT reintroduce dot-sourcing of the production
> script into itself). The mirror can drift from the real implementation
> silently.
>
> Fix this WITHOUT changing the production scripts' self-contained,
> no-dot-source nature. Approach: in `tests/TestHelpers.ps1`'s `BeforeAll`
> (or a new loader function), parse `scripts/Backup-IntunePolicies.ps1` using
> the PowerShell AST (`[System.Management.Automation.Language.Parser]::ParseFile`),
> extract the specific function definitions under test (ConvertTo-FlatSettings,
> Get-PolicyContentHash, Get-VersionSheetName, and their dependencies like
> Resolve-SettingTitle/Resolve-ChoiceValue/Get-SettingDefinition/
> Add-SettingDefinitionToCache/Get-StringSha256), and dot-source ONLY those
> extracted function ASTs into the test session's scope (e.g. write them to
> a temp .ps1 and dot-source that, or use `Invoke-Expression` on the
> extracted function text — pick whichever is more robust and explain your
> choice in a comment). This way the tests always run against the actual
> current production code, and `TestHelpers.ps1` shrinks to just the
> extraction/loading mechanism plus any pure test-only helpers (Test-HasProp,
> Get-Prop, etc. that have no production equivalent). Confirm all existing
> tests in `tests/IntuneBackup.Tests.ps1` still pass conceptually against the
> extracted functions (adjust for any behavioral differences between the old
> mirror and the real functions — if the real function behaves differently
> than the mirror did, that's exactly the kind of drift this fix should have
> caught; note it explicitly rather than quietly changing test expectations
> to match). If full AST extraction proves too fragile for some function,
> it's fine to leave that one as an explicit, clearly-commented exception
> with a reason. Open a PR into main when done."

---

#### 7. CI: PSScriptAnalyzer + Pester on PowerShell 5.1 and 7 — Small

There is currently no automation checking anything — no CI, no linting. A
syntax error, a PS-7-only construct, or a broken test can be merged without
anyone noticing until it's run against a real tenant.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and skim
> all scripts under scripts/ and tests/ first to understand the project's
> conventions (self-contained scripts, PS 5.1 compatibility target, no
> Import-Module inside production scripts, offline Pester suite in tests/).
>
> Add a GitHub Actions workflow at `.github/workflows/ci.yml` that runs on
> push and pull_request. It should run on `windows-latest` (needed for real
> Windows PowerShell 5.1 availability via `powershell.exe`, alongside `pwsh`
> for PowerShell 7) and do two things: (1) run PSScriptAnalyzer against
> everything under scripts/ (install via `Install-Module
> PSScriptAnalyzer -Force`; fail the build on any Error-severity finding, and
> decide/document whether Warnings should also fail the build or just be
> reported — lean toward failing on Warnings too unless that produces a lot
> of noise against the existing scripts, in which case list specific rules
> to exclude with a one-line reason each); (2) run
> `Invoke-Pester ./tests` under BOTH `powershell.exe` (5.1) and `pwsh` (7),
> failing the build on any test failure — this matches the project's stated
> 'PowerShell 5.1 compatible, also runs on 7' requirement, so both must
> actually be exercised, not just claimed. Add a
> `PSScriptAnalyzerSettings.psd1` at the repo root that encodes the
> project's actual conventions (e.g. if it deliberately uses `Write-Host` for
> user-facing script output — check whether PSScriptAnalyzer's default rules
> flag that — decide and document whether to suppress that rule given this
> project's console-output style, rather than silently rewriting scripts to
> avoid it). Add a status badge to the top of README.md pointing at the
> workflow. Open a PR into main when done."

---

#### 8. Comment-based help on every script — Small–medium, mechanical

The header comment blocks are excellent for a human reading the file, but
they're plain comments, not PowerShell's comment-based help format, so
`Get-Help .\Backup-IntunePolicies.ps1 -Full` and `-Examples` don't work.
Converting is mechanical (no logic changes) and is standard PowerShell best
practice.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> ALL FIVE scripts under scripts/ first (Get-IntuneSettingsCatalogSnapshot.ps1,
> Backup-IntunePolicies.ps1, Export-PolicySummary.ps1,
> Restore-IntunePolicy.ps1, Import-PolicyHistoryToDatabase.ps1).
>
> Convert each script's header `<# ... #>` comment block into proper
> PowerShell comment-based help, so `Get-Help .\<script>.ps1 -Full` and
> `Get-Help .\<script>.ps1 -Examples` work correctly. Use `.SYNOPSIS` (one
> line), `.DESCRIPTION` (the fuller explanation, preserve all the existing
> important context — the safety-boundary explanations, the 'this is
> self-contained' notes, the 'never touches assignments' language, etc. —
> don't lose any of it, just restructure), `.PARAMETER <Name>` for EVERY
> parameter (pull the description from existing inline `#` comments on each
> param where present, write one where missing), `.EXAMPLE` for each usage
> line already shown in the header (convert each `.\Script.ps1 -Foo` line
> into a proper `.EXAMPLE` block with a one-line explanation of what that
> example does), and `.NOTES` for the 'MODULES REQUIRED' / 'CONNECTION'
> sections and any other operational notes that don't fit the other tags.
> This must be a comment-based-help conversion ONLY — do not change any
> actual script logic, parameter names, defaults, or behavior. Verify by
> reading each converted file that the comment-based help block still
> immediately precedes the `param()` block or is the very first thing after
> `#requires`, per PowerShell's comment-based-help placement rules (a blank
> line or any other statement between the help block and `param()` breaks
> `Get-Help`'s ability to associate them). Open a PR into main when done."

---

#### 9. Pin/document tested module versions + `.gitignore` cleanup — Trivial

README currently says "Install-Module X, Y, Z" with no version guidance, so
a future reader has no idea which versions this was actually built/tested
against. Also, `Import-PolicyHistoryToDatabase.ps1` (Phase 6a) writes a
`.sqlite` file under `output/db/` — `.gitignore` currently only excludes
`output/` broadly (which already covers this), but this should be double
-checked and made explicit given SQLite files are new to the project.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md,
> `.gitignore`, and `scripts/Import-PolicyHistoryToDatabase.ps1` first.
>
> Two small changes: (1) In README.md's Requirements section, next to each
> `Install-Module` instruction, add the specific module version(s) this
> project has actually been tested against (Microsoft.Graph.Authentication,
> ImportExcel, PSSQLite, Pester) — if you don't have a specific tested
> version pinned already, install the current stable release of each module
> in a sandbox, confirm the existing test suite / a script's basic syntax
> still works against it, and document that version explicitly (e.g.
> 'tested with ImportExcel 7.8.x') rather than leaving version guidance
> absent. Note in README that these are minimum/tested versions, not hard
> pins — the project doesn't want to force exact-version installs. (2)
> Confirm `.gitignore` (currently just `output/` and `*.xlsx`) actually
> covers every artifact these scripts produce, including the new
> `output/db/*.sqlite` file from Phase 6a, and add any missing patterns with
> a short comment explaining what each pattern excludes and why (e.g. why
> `output/` as a whole is excluded rather than more narrowly). Don't remove
> any existing pattern. Open a PR into main when done."

---

#### 10. Version marker per script + git tag on known-good states — Trivial

There's currently no way for an operator running these scripts on a
management server to answer "which version of this script am I running?"
without diffing against git manually.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and all
> scripts under scripts/ first.
>
> Add a simple version marker to each script under scripts/: a
> `$ScriptVersion = 'x.y.z'` variable near the top (right after
> `$ErrorActionPreference = 'Stop'` or equivalent) and print it as part of
> each script's opening `Write-Host` output (e.g.
> 'Backup-IntunePolicies.ps1 v1.0.0'). Decide on a simple versioning
> convention (semantic versioning is fine — start every script at whatever
> version makes sense given how much it's changed since creation; look at
> git log per file with `git log --oneline -- scripts/<file>` to gauge this
> reasonably, doesn't need to be perfectly precise) and document the
> convention in a short new 'Versioning' section in README.md (e.g. 'each
> script's $ScriptVersion is bumped on any behavior change; see git log for
> full history'). Do not build any auto-bump tooling — this should be
> manual and simple. After merging, tag the resulting main commit as
> `v1.0.0` (or whatever you determine the current aggregate project state
> warrants) using `git tag` and push the tag, so there's a known-good
> reference point. Open a PR into main for the code changes; tagging can
> happen as a separate step after merge, mention in your PR description that
> a tag should follow."

---

### Documentation & handover

#### 11. Operations runbook (`docs/OPERATIONS.md`) — Medium, mostly writing

This is the single highest-value item for making the project truly
hand-off-ready to someone who didn't build it.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md and
> `scripts/basic-commands.md` and ALL scripts under scripts/ thoroughly
> first — this task is about writing accurate operational documentation, so
> you need to actually understand what each script does, what can go wrong,
> and how to recover.
>
> Create `docs/OPERATIONS.md`, a runbook for someone operating this project
> day-to-day who did not build it. Include, at minimum: (1) **Fresh machine
> setup** — a step-by-step checklist from 'nothing installed' to 'first
> successful backup run', covering PowerShell version check, module
> installs, app registration / Graph permissions needed (cross-reference
> `basic-commands.md`), first Connect-MgGraph, first run of each script in
> the recommended order. (2) **Routine health checks** — what a healthy
> daily/weekly run looks like (what the console summary should show), and
> what to look for that indicates a problem (recurring 'errored' entries,
> growing output/json size without bound, manifest not updating, etc). (3)
> **Recovery walkthrough** — the exact end-to-end steps to recover a
> deleted or badly-edited policy: find the right JSON snapshot (by name, by
> date, by browsing output/json/), run Restore-IntunePolicy.ps1 with
> -WhatIf first, review the printed assignment summary, run for real,
> manually reassign in the Intune portal. Write this as a literal numbered
> walkthrough a non-expert could follow under pressure. (4)
> **Troubleshooting table** — common failure symptom → likely cause →
> fix, covering at minimum: 403 Forbidden (→ missing Graph scope, link to
> basic-commands.md's scope-check commands), 'module not found' (→ which
> Install-Module command), throttling/429s (→ already handled by retry
> logic, explain what the user will see and that it's expected), BOM/JSON
> parse errors on old files edited outside this toolset, and Excel file
> locked/in-use errors from ImportExcel. Cross-reference README.md and
> basic-commands.md rather than duplicating their content — link instead
> of copy where reasonable, but the recovery walkthrough and troubleshooting
> table should be fully self-contained since that's what someone reads
> during an actual incident. Add a link to docs/OPERATIONS.md from
> README.md. Open a PR into main when done."

---

#### 12. Data-retention guidance — Trivial

`output/json/<timestamp>/` grows forever by design (every changed policy
gets a new file, every run gets a new timestamped folder). This is
intentional — the JSON is authoritative — but nobody has written down what
"forever" should actually mean operationally.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md first,
> particularly the 'Output layout' section.
>
> Add a short 'Data retention' section to README.md (near 'Output layout')
> explaining that `output/json/<timestamp>/` grows without bound by design —
> every run that finds a changed policy adds new files, nothing is ever
> auto-deleted — and that this is intentional since the JSON is the
> authoritative, restore-from artifact. Give clear, simple guidance: archive
> (zip) `json/` folders older than some threshold (suggest a sensible
> default like 12 months, but phrase it as a suggestion the operator should
> tune to their tenant's change frequency and available storage) rather than
> deleting them — recommend NEVER deleting old snapshots outright, since
> that defeats the project's whole purpose, but moving cold ones to
> cheaper/archival storage is fine. Mention the Excel workbooks
> (output/xlsx/) are a read-only human view derived from JSON and can always
> be regenerated/aren't the thing to protect if storage is tight. This is a
> documentation-only change — no code. Open a PR into main when done."

---

#### 13. Sensitivity note on `output/` — Trivial

`output/` contains the tenant's actual security configuration (policy
settings) and internal group names. This should be called out explicitly
rather than left implicit.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md first.
>
> Add a short, clearly-labeled paragraph to README.md (a new subsection near
> the top, e.g. right after 'Design in one paragraph', or folded into
> 'Notes & limitations' — use your judgment on the best placement) noting
> that everything under `output/` (JSON snapshots, Excel workbooks, and the
> SQLite database if Phase 6a is present on this branch) contains the
> tenant's actual security configuration — full Settings Catalog values and
> internal Entra ID group display names — and should be treated with the
> same sensitivity as the source tenant: not committed to a public repo
> (note `.gitignore` already excludes `output/`, confirm this), not
> synced to a general-purpose cloud drive without the same access controls
> the tenant itself has, and access-restricted the same way the app
> registration's Graph permissions are. This is a documentation-only change
> — no code. Open a PR into main when done."

---

### New feature ideas (optional — genuinely separable from the core plan)

#### 14. `Compare-PolicySnapshot.ps1` — Medium

A standalone script to diff any two JSON snapshots (or, if the SQLite DB
exists, any two versions of the same policy from it) directly in the
console — "what exactly changed between these two dates" without opening
Excel.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read README.md,
> `scripts/Backup-IntunePolicies.ps1` (especially `ConvertTo-FlatSettings`
> and the diff-highlighting logic in `Export-PolicyWorkbook`), and
> `scripts/Export-PolicySummary.ps1` first to understand the existing
> conventions.
>
> Build a new script, `scripts/Compare-PolicySnapshot.ps1`, that takes two
> JSON snapshot file paths (`-Before <path> -After <path>`) and prints a
> clear console diff of what changed between them: settings added (not in
> Before), removed (not in After), and changed (same Path, different Value),
> using the same flattening logic as Backup-IntunePolicies.ps1 (port it in,
> don't dot-source, matching this project's established no-dot-sourcing
> convention for production scripts), plus a similar diff of assignments
> (added/removed groups and filters, using the same Format-AssignmentList
> rendering already used elsewhere in the project). Output should be
> readable directly in a terminal — consider color-coding with Write-Host
> `-ForegroundColor` (Green for added, Yellow for changed showing old→new,
> Red for removed) matching the existing green/amber/red convention from the
> Excel diff highlighting. No Graph connection needed — this is fully
> offline, reading JSON already on disk, same pattern as
> Export-PolicySummary.ps1. Support comparing two files for the same policy
> (validate the Ids match, or warn clearly if comparing different policies).
> Follow all existing conventions: self-contained, PS 5.1 compatible,
> BOM-free reads. Add a usage section to README.md. Consider whether this
> logic is testable offline the same way ConvertTo-FlatSettings is tested,
> and add tests if so. Open a PR into main when done."

---

#### 15. Drift summary in Backup output — Small

When `Backup-IntunePolicies.ps1` detects a policy changed, it currently just
says "updated" in the summary. The actual diff data already exists (it's
what drives the Excel green/amber/red highlighting) — surfacing a short
"what changed" list directly in the console would save a trip to Excel for
the common case of just wanting a quick glance.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. Read
> `scripts/Backup-IntunePolicies.ps1` closely, especially the main loop
> where `$status = if ($prev) { 'updated' } else { 'created' }` is set, and
> `Export-PolicyWorkbook`'s diff logic (`$prevByPath`, the added/changed/
> removed row coloring).
>
> When a policy is detected as 'updated' (not 'created'), print a short
> summary directly to the console of what actually changed — reuse the same
> comparison the Excel export already does (current flattened settings vs.
> the previous sheet's rows) rather than recomputing it a different way.
> Keep it concise: e.g. print up to the first 5 changed setting paths with
> old→new values, and a count if there are more ('...and 12 more — see the
> Excel workbook for the full diff'). This should not require opening
> Excel or the ImportExcel module when `-SkipExcel` is set — if `-SkipExcel`
> is active, either skip this feature gracefully (there's no 'previous
> sheet' to diff against without ImportExcel) or, better, compute the diff
> against the previous JSON snapshot for the same policy instead of the
> Excel sheet, so drift summaries work even with -SkipExcel — use your
> judgment on which is cleaner given the existing code structure, and
> explain your choice in a comment. Keep output concise — this is a console
> summary, not a replacement for the Excel diff view. Update README.md's
> description of the run summary. Open a PR into main when done."

---

#### 16. Deleted-policies view in the Phase 6b web page — Small (depends on Recommendation 2)

Once deletion detection (#2) exists, the Phase 6b static HTML viewer should
have a dedicated view for it — this is likely the single most-used view in
practice, since "what got deleted and when" is the core anxiety this project
exists to solve.

> **Prompt:**
> "I'm working on the Intune Policy Backup project in
> Wagner-Maximiliano/Intune_misc, branch off `main`. This depends on
> deletion detection already being implemented (an `IsDeleted`/
> `DeletedDetectedAt` column on the `Policies` table in the SQLite database
> from `scripts/Import-PolicyHistoryToDatabase.ps1` — read that script and
> confirm those columns exist before starting; if they don't, this task
> isn't ready yet and you should say so rather than inventing the columns
> yourself). Also read README.md and
> `scripts/Import-PolicyHistoryToDatabase.ps1`'s schema section fully.
>
> If `scripts/Export-PolicyHistorySite.ps1` (the Phase 6b static HTML
> viewer) already exists on this branch, add a dedicated 'Deleted
> Policies' view to it: a filtered list of every policy where `IsDeleted` is
> true, showing name, when it was first seen, when deletion was detected,
> and a link into that policy's full version history (so the human can see
> exactly what the policy looked like right before it vanished, and jump
> straight to restoring it via Restore-IntunePolicy.ps1 using the JSON
> snapshot referenced by its last version's SourceFile column). If
> Export-PolicyHistorySite.ps1 does NOT exist yet on this branch, stop and
> report that back rather than building the whole viewer as a side effect of
> this task — this task is scoped to just the deleted-policies view. Keep
> the page fully self-contained (inline CSS/JS, no CDN/network dependencies,
> matching the rest of Phase 6b's design). Open a PR into main when done."

---

## 4. Suggested sequence

If you want to work through most of this, a sensible order is:

**1 → 2 → 3 → 4** (each a small, independent hardening PR)
**→ 6 → 7** (test/CI PR — do this before more feature work piles on top of
the untested logic)
**→ Phase 6b viewer** (the already-agreed next big piece)
**→ 16** (once 2 and 6b both exist)
**→ 8 → 9 → 10 → 11 → 12 → 13** (documentation/handover pass)
**→ Phase 4** (scheduled/unattended runs, now that 4 already laid the
groundwork)
**→ 5, 14, 15** (whenever convenient — fully independent of everything else)

Nothing here is binding — pick freely.
