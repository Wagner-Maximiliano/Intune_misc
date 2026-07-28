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
- `docs/IMPROVED-PLAN.md` — pre-existing backlog for the Policy Backup toolset

---

## Hard rules

1. **You cannot run PowerShell here.** No interpreter, no Windows, no target
   devices. Desk-check your work and **say explicitly in your final message
   that it is unverified.** Never imply you tested something you didn't.
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

Every script uses `Set-StrictMode -Version 2.0`. The rules below are not
style preferences — each one corresponds to a bug that reached a real device.

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
