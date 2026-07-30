# Tests

Offline Pester suite for the Intune Policy Backup toolset (`scripts/`).

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester ./tests
```

No tenant, no credentials, no network, and no `ImportExcel` or `PSSQLite`
module are needed. Everything runs against an in-process fake for Microsoft
Graph.

---

## The rule this suite exists to enforce

**A test may never contain a copy of production code.**

This suite was rewritten for [Issue #14] because the previous one broke that
rule. `tests/TestHelpers.ps1` defined 27 functions and 21 of them were private
copies of functions in `scripts/Backup-IntunePolicies.ps1`. The suite ran the
copies. The copies drifted. Four real bugs — `docs/REVIEW-PHASE0.md` R-02
through R-05 — shipped to a live tenant behind a green test run, because the
suite never executed the code containing them.

So there are exactly two legitimate ways to reach production logic from here:

| What you want | How |
|---|---|
| One function, in isolation | `. (Import-ProductionFunction -Path <script> -Name <fn>)` — copies the function's source verbatim out of the file's AST |
| A whole script's behaviour | `Enable-FakeGraph`, then `& $script -OutputPath $tmp ...`, then inspect what it wrote |

`SuiteIntegrity.Tests.ps1` enforces this mechanically: it fails if any file
under `tests/` defines a function name that also exists in `scripts/` or
`MDMWinsOverGPToolKit/`, including names hidden inside a `BeforeAll` block.

---

## Layout

| File | What it covers |
|---|---|
| `TestSupport.ps1` | Infrastructure only: the AST loader, the Graph fake, fixture builders, temp folders |
| `Backup.Functions.Tests.ps1` | `Backup-IntunePolicies.ps1`, function by function |
| `Backup.Script.Tests.ps1` | `Backup-IntunePolicies.ps1` run end to end against the fake tenant |
| `SettingsCatalogSnapshot.Script.Tests.ps1` | `Get-IntuneSettingsCatalogSnapshot.ps1` end to end |
| `Restore.Script.Tests.ps1` | `Restore-IntunePolicy.ps1` end to end, asserting on the exact POST body |
| `ImportDatabase.Functions.Tests.ps1` | `Import-PolicyHistoryToDatabase.ps1`, plus drift detection against the backup script's copies |
| `ExportSummary.Functions.Tests.ps1` | `Export-PolicySummary.ps1`, plus drift detection on assignment rendering |
| `Toolkit.PureFunctions.Tests.ps1` | `MDMWinsOverGPToolKit/`'s pure helper functions (`Normalize-PolicyName`, `Get-TokenSet`, `Get-JaccardScore`, `Convert-ValueToText`), plus parity checks between the two files that each keep their own copy |
| `SuiteIntegrity.Tests.ps1` | Guards on the suite itself, and a parse check over every `.ps1` in the repo |

---

## Why whole-script tests, not just unit tests

Every bug this project has shipped in the Policy Backup toolset was a
**parameter binder rejection**: `[Parameter(Mandatory)]` refusing `$null` or
`@()` *before the function body ran*. No test of a function body can see that,
and no `@()` wrapper at the call site fixes it — only the declaration does.

The end-to-end tests catch it because they run the real script and then check
what actually landed on disk. Named regression tests exist for R-02, R-03,
R-04, R-05, R-13 and R-14; each cites its finding in
`docs/REVIEW-PHASE0.md`.

**A caution the R-02 tests earned the hard way.** A test that passes both with
and against the code it claims to cover is not coverage. The original "policy
with no assignments" tests passed whether or not `Where-Object { $_ }` was
present, because the fixture never produced the value that clause filters — see
the corrected R-02. When you add a regression test, **delete the fix and confirm
the test fails**, then put it back. That is the only way to know which line the
test is actually pinned to.

---

## Deliberately failing tests

Two tests are marked `-Skip` and would fail if run. They are not broken — each
asserts the *fixed* behaviour for an open finding, so that resolving the
finding is a one-word edit rather than a fresh investigation:

| Test | Finding |
|---|---|
| `Backup.Functions.Tests.ps1` → "orders same-day sheets numerically" | R-08 — lexicographic sheet sort picks `_9` as "previous" once `_10` exists |
| `ImportDatabase.Functions.Tests.ps1` → "agrees on a legacy snapshot whose Assignments is null" | R-15 — the two content-hash copies disagree on a pre-R-02 snapshot |

Un-skip when the finding is fixed.

---

## Pester version

This suite runs on Pester 5.x **and** Pester 6.x. That took one structural
fix: Pester 6 rejects a `BeforeEach`/`AfterEach` written directly at file
scope ("Each test setup is not supported in root") - a pattern several files
here used and Pester 5 allowed. Every test file's content is now wrapped in
one outer `Describe` so file-scope `BeforeEach`/`AfterEach` become
Describe-scope, which both versions support identically. Root-level
`BeforeAll`/`AfterAll` were never affected - only the per-test hooks were.

**If you add a new test file**: wrap its whole body (everything after
`Set-StrictMode -Off`) in one outer `Describe '<script>.ps1 <what>'  { ... }`,
even if it only has a root `BeforeAll` today. A later `BeforeEach` added
inside an unwrapped file will pass on whatever Pester version you tested
with and fail on the other.

## StrictMode

Each test file matches the StrictMode of the production code it exercises —
not one blanket setting for the whole suite:

- Files testing `scripts/` run `Set-StrictMode -Off`, because the five files
  in `scripts/` set no StrictMode at all (`docs/REVIEW-PHASE0.md` R-01).
- `Toolkit.PureFunctions.Tests.ps1` (and any future `Toolkit.*.Tests.ps1`
  file) runs `Set-StrictMode -Version 2.0`, because all three
  `MDMWinsOverGPToolKit/` scripts set exactly that.

A harness looser or stricter than the code it tests can only report failures
that cannot happen in the field — which is exactly what the old
`TestHelpers.ps1` did, as the only file in the repo carrying `-Version
Latest`, and what a `-Off` toolkit test file would do in the other direction
by missing the `.Count`-on-`$null` class this project has shipped four times.

When R-11 adopts `Set-StrictMode -Version 2.0` in `scripts/`, change the line
at the top of each `scripts/`-testing file to match and re-run: every file in
the suite then agrees, and the suite becomes the instrument that verifies the
switch. `SuiteIntegrity.Tests.ps1` has a test guarding this, with the same
note.

---

## Not covered

These need modules the suite deliberately does not depend on, so they are
still verified only by real runs. Tracked in `docs/PROJECT_STATUS.md`.

- `Export-PolicyWorkbook`, `Export-IndexWorkbook`, `Get-WorkbookPath`,
  `Set-CellColor` — need `ImportExcel`. The end-to-end tests pass `-SkipExcel`.
- `Invoke-Db`, `Get-LastInsertRowId`, `Initialize-Schema` and the ingest loop
  in `Import-PolicyHistoryToDatabase.ps1` — need `PSSQLite`.
- Most of `MDMWinsOverGPToolKit/` — it collects evidence from a live Windows
  device (registry reads, `gpresult.exe`, live `MDMDiagReport.html`).
  `Toolkit.PureFunctions.Tests.ps1` now covers the device-independent helpers
  (`Normalize-PolicyName`, `Get-TokenSet`, `Get-JaccardScore`,
  `Convert-ValueToText`); the ADMX/ADML parsers and the registry/HTML
  evidence collectors are still untested — see `docs/PROJECT_STATUS.md` item B
  for the planned next step (fixture-based tests for the parsers).

[Issue #14]: https://github.com/Wagner-Maximiliano/Intune_misc/issues/14
