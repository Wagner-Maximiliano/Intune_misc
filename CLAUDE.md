# CLAUDE.md

## Start here

**Read `docs/AGENT_ONBOARDING.md` before doing anything else.** This project
spans many sessions with no shared memory; that file explains how to pick up
where the last agent stopped, and what you must update before you finish.

Quick map:
- `docs/PROJECT_STATUS.md` — where we are, what's next ← **check this first**
- `docs/DECISIONS.md` — settled decisions; don't relitigate
- `docs/ROADMAP.md` — phases and what's out of scope
- `docs/ARCHITECTURE.md` — module layout and data model
- `docs/PRODUCT-VISION.md` — what the product *is*, who buys it, and what it
  deliberately does not do. Read before any UI or feature work.
- `docs/REVIEW-PHASE0.md` — code-review findings register (R-01…R-15)
- `docs/IMPROVED-PLAN.md` — pre-existing backlog for the Policy Backup toolset.
  **Largely superseded**: its phase numbering collides with `ROADMAP.md`, and
  its "Phase 6b" static-HTML viewer is explicitly rejected by D-002. Mine it
  for feature ideas, not for plan structure.
- `docs/presentation/` — console mockup and slide deck (design mockups with
  representative data, not live system output)

---

## Hard rules

1. **Check whether you can run PowerShell before assuming you can't.** This
   used to read "you cannot" flatly; on 2026-07-30 a session ran the suite
   natively (Windows PowerShell 5.1, Pester 6.0.1) and that single fact
   overturned a HIGH review finding four sessions of desk-checking had got
   wrong (R-02). **Try it first.** If there is no interpreter, desk-check and
   **say explicitly in your final message that it is unverified** — never imply
   you tested something you didn't. Target devices and a tenant are a separate
   question; those are still the user's to provide.
   You can still *write* tests: `tests/` is an offline Pester suite over the
   real `scripts/` code that the user can run in seconds. Change `scripts/`,
   add a test — and **never copy production code into a test** (D-012;
   `tests/SuiteIntegrity.Tests.ps1` enforces it).
2. **Update the docs in the same commit as the change.** See the handover
   checklist in `docs/AGENT_ONBOARDING.md`.
3. **Never commit to `main`.** Branch as `claude/<short-topic>`.
4. **Never build on a merged branch.** Start fresh:
   `git fetch origin main && git checkout -B <branch> origin/main`
5. **Only open a PR when the user asks.**

---

## Delegation model

The top-level agent's job is to orchestrate, reason, verify, and plan — not
to do bulk reading and writing itself.

- **Delegate to Sonnet**: bulk file reading, code writing and editing,
  mechanical refactors, documentation writing, multi-file sweeps.
- **Delegate to Haiku**: cheap recon — file inventories, grep/search sweeps,
  "does X exist" checks, format/balance checks.
- **Keep for the orchestrator**: architectural decisions, reviewing delegated
  output, deciding what to do next, and all final communication with the
  user.

This is a tradeoff, not a law. For a genuinely trivial single-line edit,
spawning an agent can cost more than it saves. Use judgement — the rule is
about heavy work, not absolute.

---

## PowerShell conventions

**StrictMode coverage is split**: `MDMWinsOverGPToolKit/` sets
`Set-StrictMode -Version 2.0` in all three scripts; the five files in
`scripts/` set **none** (only `$ErrorActionPreference = 'Stop'`);
`tests/TestHelpers.ps1` uses `-Version Latest`. This file used to claim it was
universal — see `docs/REVIEW-PHASE0.md` R-01, and R-11 before you switch it on
anywhere.

Write everything as if StrictMode were on. The rules below are not style
preferences — each one corresponds to a bug that reached a real device.

### Mandatory parameters reject `$null` and `@()` — regardless of StrictMode

```powershell
param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Settings)
```

Untyped params are affected too, not just `[object[]]`. The binder rejects
*before* the body runs, so a tolerant body or a call-site `@()` will not save
you. Two HIGH bugs in the Phase 0.1 review were exactly this.

### `@($null)` is a one-element array — but only for a *literal* `$null`

`@($maybeNull) | ForEach-Object { ... }` runs once with `$_ = $null` when
`$maybeNull` came from something that really produced `$null`: a missing
property, an unset variable, an explicit `return $null`. Use
`Where-Object { $_ }` there.

**It does NOT apply to a function that emitted nothing.** That assigns
`AutomationNull`, not `$null`. The two are indistinguishable by `$null -eq $x`,
so desk-checking cannot tell them apart, but they behave oppositely:

```powershell
@($null).Count            # 1  - literal null
function F { }            # emits nothing
@(F).Count                # 0  - AutomationNull
```

This exact confusion produced a wrong HIGH finding that survived a code review
and four sessions (`docs/REVIEW-PHASE0.md` R-02). **If a claim turns on which
of the two you have, run the line — do not reason about it.**

Relatedly, `return $list` on a `List[object]` enumerates on output, so an empty
list arrives as `AutomationNull`. Wrapping the *call* in `@(...)` is still
correct and still load-bearing — it is what keeps an empty result serialising as
`[]` rather than `null`.

### `.Count` on a possibly-`$null` value throws

This project's most persistent bug, shipped **four separate times**:

```powershell
$things = @(Get-Thing)          # @() guarantees an array
if (-not $things) { ... }       # safest: never touches a property
```

Never write `$x.Count` unless `$x` was assigned through `@(...)` in the same
scope and you can see that assignment.

### `Mandatory` array parameters need `[AllowEmptyCollection()]`

Otherwise the binder rejects a legitimately empty array as "no value supplied":

```powershell
[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows
```

### Never shadow automatic variables

`$Event`, `$Error`, `$Host`, `$Input`, `$Matches`. Using `$event` as a
`foreach` variable once made every Event ID silently report as `0`.

### Other conventions

- Resolve paths from `$PSScriptRoot`, never the working directory. Fall back
  to `$env:ProgramData` when the script folder isn't writable.
- Use the shared `Write-Log` (INFO/WARN/ERROR) — log *why*, not just *what*.
- Child processes: `powershell.exe -NoProfile -NonInteractive -File ...`,
  never dot-sourcing, to avoid scope collisions.
- Non-interpolating here-strings (`@'...'@`) for embedded JS/CSS, so `$` in
  the payload isn't treated as PowerShell interpolation.
- Never collapse "found nothing" and "couldn't determine" into one state.
  That distinction is the point of the exit-code contract.

---

## Environment constraints

- `learn.microsoft.com` → 403, `raw.githubusercontent.com` → 404 from this
  sandbox. Don't build anything that scrapes Microsoft docs at runtime.
- Branch deletion fails with HTTP 403; the user deletes merged branches via
  the GitHub UI.
- No `gh` CLI. Use the GitHub MCP tools.

---

## Commits and PRs

Explain **why**, not just what — this history is used as evidence when
debugging regressions months later. In PR bodies, state plainly what was
tested on real hardware versus what was only desk-checked.
