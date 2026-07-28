# Agent onboarding — read this first

**You are picking up an in-progress, multi-session project. Read this file
completely before doing anything else, including before reading any code.**

This project is built across many separate agent sessions. No session
remembers the previous one. These documents are the only continuity that
exists, which means two things:

1. Everything you need to know is written down somewhere here.
2. If you don't write down what you did, the next agent loses it.

---

## The reusable start-of-session prompt

Paste this into a fresh session:

> Read `docs/AGENT_ONBOARDING.md` in this repo, then follow it. Work on the
> next item in `docs/PROJECT_STATUS.md` unless I tell you otherwise.

That is deliberately short. Everything else lives in the repo so it survives
context compaction, session limits, and model changes.

---

## Read these, in this order

| Order | File | What it tells you |
|---|---|---|
| 1 | `docs/PROJECT_STATUS.md` | **Where we are right now.** Current phase, what just shipped, what's next, known problems. The single source of truth for "what should I do?" |
| 2 | `docs/DECISIONS.md` | **What's already settled and why.** Do not relitigate these. Includes rejected options, so you don't re-propose them. |
| 3 | `docs/ROADMAP.md` | **Where we're going.** Phases, scope boundaries, and what is deliberately out of scope. |
| 4 | `docs/ARCHITECTURE.md` | **How it fits together.** Module layout, data model, and how the UI talks to the PowerShell engine. |
| 5 | `CLAUDE.md` | Coding conventions and the hard rules for this repo. |

Only after those, read code. `docs/PROJECT_STATUS.md` names the specific
files relevant to the current task, so you should rarely need to explore
blind.

---

## The five hard rules

### 1. This codebase has a recurring bug class. Know it before you write PowerShell.

Every script sets `Set-StrictMode -Version 2.0`. Under StrictMode, accessing
a property on `$null` **throws** (`PropertyNotFoundStrict`) rather than
returning `$null`. The specific trap that has bitten this project repeatedly
in production is `.Count` on something that might be `$null`:

```powershell
# WRONG - throws under StrictMode when Get-Thing returns nothing
$things = Get-Thing
if ($things.Count -eq 0) { ... }

# RIGHT - @() guarantees an array
$things = @(Get-Thing)
if ($things.Count -eq 0) { ... }

# SAFEST - boolean coercion never touches a property at all
if (-not $things) { ... }
```

This exact bug reached a real device **four separate times**. Two related
traps, both also real incidents here:

- A `[Parameter(Mandatory)]` array parameter rejects a legitimately empty
  array unless it also has `[AllowEmptyCollection()]`.
- `$Event`, `$Error`, `$Host`, `$Input`, `$Matches` are PowerShell
  *automatic variables*. Using one as a loop variable silently shadows it.
  (`foreach ($event in ...)` once made every Event ID report as `0`.)

### 2. You cannot run PowerShell here. Say so.

The agent sandbox has no PowerShell interpreter, no Windows, and no target
devices. **You cannot test your changes.** You must:

- Desk-check instead: brace/paren balance, trace every `.Count` back to its
  assignment, trace control flow by hand.
- State plainly in your final message that the change is unverified and
  needs a real run. Never imply otherwise.

The user tests on real hardware and reports back. That feedback loop is the
only real verification this project has — respect it by being honest about
what you did and did not check.

### 3. Update the docs in the same commit as the change.

Not afterwards, not "later". If you change behaviour and don't update
`docs/PROJECT_STATUS.md`, the next agent is working from a lie. See "Before
you finish" below.

### 4. Network access is restricted.

`learn.microsoft.com` returns 403 and `raw.githubusercontent.com` returns 404
from this sandbox. Do not build anything that depends on scraping Microsoft
documentation at runtime — a previous session lost time to this. Use local
data sources (ADMX files, the registry, Graph API from the *user's* machine).

### 5. Ask before big architectural turns; just do routine work.

Decisions already in `docs/DECISIONS.md` are settled. If you believe one is
wrong, say so once, concisely, and then follow it unless the user agrees to
change it — and if they do, update `DECISIONS.md`.

---

## Delegating work

The orchestrator plans, reasons, and verifies; Sonnet and Haiku do the bulk
reading and writing (see "Delegation model" in `CLAUDE.md`). Two failure
modes account for most of what goes wrong here:

1. **Subagents start cold.** They have zero context. Every delegation prompt
   must be fully self-contained: the absolute file paths, the branch, what to
   change, what NOT to touch, and whether to commit. Critically — any prompt
   that involves writing PowerShell **must restate this repo's StrictMode
   rules inline**: the `.Count`-on-`$null` trap, `[AllowEmptyCollection()]`
   on `Mandatory` array params, and never shadowing automatic variables like
   `$Event`. A subagent that hasn't been told will reintroduce these bugs —
   this has already happened repeatedly in this project's history.

2. **Never relay a subagent's report as fact.** Verify before accepting.
   There is no PowerShell interpreter here, so verification means
   independently checking the actual files: brace/paren balance, tracing
   every `.Count` back to an `@(...)` assignment, and confirming the change
   is actually present in the file. In this project's history, subagents
   have both self-reported introducing bugs *and* had bugs the orchestrator
   found independently that the subagent never mentioned.

If a running agent needs a correction mid-task, use `SendMessage` to it
rather than spawning a second agent onto the same files — two agents editing
one file will conflict.

---

## Before you finish — the handover checklist

Do all of this **before** your final message, in the same commit as your work:

- [ ] `docs/PROJECT_STATUS.md` — update "Current state", move completed items
      to "Recently shipped", set "Next up" to what genuinely comes next.
- [ ] `docs/DECISIONS.md` — add an entry for any non-obvious choice you made,
      including what you rejected and why.
- [ ] `docs/ROADMAP.md` — tick off anything finished; add anything discovered.
- [ ] `docs/ARCHITECTURE.md` — update if you added a module, endpoint, or
      table, or changed how components talk to each other.
- [ ] Record anything that **failed or is half-done** in PROJECT_STATUS.md
      under "Known issues". A half-finished feature that isn't written down
      is worse than one that was never started.
- [ ] **GitHub Issues** — close the Issue you completed, or comment on it with
      progress if it's partially done (see D-007). Issues mirror the roadmap
      for the user's visibility. **If an Issue and the markdown ever
      disagree, the markdown wins** — fix the Issue, not the doc.
- [ ] Commit and push to your branch.

Then, in your final message to the user, state:
- what you changed,
- what you verified vs. what is unverified,
- what the next agent should pick up.

---

## Repository conventions

- **Branches**: `claude/<short-topic>`. Never commit directly to `main`.
- **Merged branches are archived** (deleted after merge). Never build on top
  of an already-merged branch — start fresh from `main`:
  `git fetch origin main && git checkout -B <branch> origin/main`
- **PRs**: only when the user asks. Include what was tested vs. desk-checked.
- **Commits**: explain *why*, not just what. This project's commit history is
  used as evidence when debugging regressions months later.
