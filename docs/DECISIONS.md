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

---

## D-012 — Tests reach production code by AST loading and whole-script runs

- **Date**: 2026-07-28
- **Status**: Decided (by the Issue #14 session)

**Decision.** The Pester suite reaches `scripts/` two ways, and no others:

1. **`Import-ProductionFunction`** parses a production `.ps1` and re-declares
   the named functions from their AST extent — the real source, byte for byte,
   with none of the main body's side effects.
2. **Whole-script runs** against `Enable-FakeGraph`, an in-process stand-in for
   `Get-MgContext` / `Connect-MgGraph` / `Invoke-MgGraphRequest`, after which
   the test inspects what the script actually wrote to disk.

**No test may contain a copy of production logic.**
`tests/SuiteIntegrity.Tests.ps1` enforces this: it fails if any file under
`tests/` defines a function name that also exists in `scripts/` or
`MDMWinsOverGPToolKit/`, including names nested inside a `BeforeAll`.

**Why.** Every Policy Backup bug this project has shipped was a
`[Parameter(Mandatory)]` rejecting `$null` or `@()` **at bind time, before the
body ran**. A unit test of a body cannot see that, and neither can a call-site
`@()` wrapper — only the declaration matters. Running the whole script and
checking the artifacts is the only technique that catches the class. Both R-13
and R-14 were found this way, in code the full Phase 0.1 review had already
read line by line.

The AST loader specifically avoids adding a test hook (a `-InitializeOnly`
switch, say) to production scripts that nobody here can execute.

**Deliberately not covered**: anything needing `ImportExcel` or `PSSQLite`. The
suite must run anywhere with nothing installed but Pester, which is what makes
it cheap enough to run on every change. Those paths stay verified by real runs
and are listed in `docs/PROJECT_STATUS.md`.

**This is scaffolding with a known end date.** When Issue #15 moves the logic
into `Continuum.*` modules, `Import-ProductionFunction` is replaced by
`Import-Module` and the drift tests between duplicate copies become redundant.

**Rejected.**
- *Add a `-InitializeOnly` switch to each script so tests can dot-source it* —
  simpler harness and it would run the real top-level initialisation too, but
  it puts a test seam into five production files that cannot be executed in
  the agent sandbox, and it needs separate placement reasoning in each.
- *Extract modules first, then write tests against them* — cleaner order in
  the abstract, but D-005 makes a trustworthy suite the **precondition** for
  the refactor. Refactoring first is exactly the move the test gap forbids.
- *Keep the copies but add a drift check between them and production* — much
  less work, but a drift check that reads code is still not a test that runs
  it, and neither R-13 nor R-14 would have been found.

---

## D-013 — Open findings get a `-Skip`ped test, not just a doc entry

- **Date**: 2026-07-28
- **Status**: Decided (by the Issue #14 session)

**Decision.** A finding that is recorded rather than fixed gets a Pester test
asserting the **fixed** behaviour, marked `-Skip`, with a comment naming the
finding and the reason it is deferred. R-08 and R-15 have one each.

**Why.** It makes the deferral concrete and cheap to reverse: resolving the
finding is deleting `-Skip` and running the suite, rather than re-deriving what
"fixed" would even mean months later. It also keeps the docs honest — a
skipped test is visible in every run, where a paragraph in a review document is
not.

**Cost, accepted.** Anyone reading the suite sees tests that would fail. That
is why the marker must always cite its finding, and why `tests/README.md`
tabulates them.

**Rejected.** *Leave the finding in `docs/REVIEW-PHASE0.md` only* (no
maintenance cost, but nothing connects the prose to the code); *write the test
un-skipped and let the suite go red* (unambiguous, but a permanently failing
suite trains everyone to ignore failures).

---

## D-011 — Fix live crashes now; defer StrictMode adoption and contract changes

- **Date**: 2026-07-28
- **Status**: Decided (by the Phase 0.1 review session)

**Decision.** In the Phase 0.1 review, fix defects that crash or corrupt
**today**, and *record* rather than fix two categories: (a) latent bugs that
only fire once `Set-StrictMode` is adopted in `scripts/`, and (b) anything
that changes an externally-consumed contract.

Fixed: R-02, R-03 (live binder-rejection crashes), R-04 (malformed restore
payload), R-05 (free defensive `@()`).
Recorded only: R-06 (fleet exit codes), R-07…R-12.

**Why.** The review found that `scripts/` has no StrictMode at all, contrary
to what three docs claimed (R-01). That makes several findings latent rather
than live. Switching StrictMode on *and* fixing the latent bugs in one
unverifiable change would produce a large diff whose failure modes could not
be told apart on the first real run — and nothing here can be executed in the
sandbox. Keeping the fixed set small and live-only means a real-hardware run
tests a short, legible list.

R-06 is held back for a different reason: the fleet exit code is consumed by
the user's RMM and Intune automation. Changing it is the user's call
(AGENT_ONBOARDING §5), not an agent's.

**Rejected.**
- *Add StrictMode to `scripts/` in the same commit* — closes the gap
  immediately and matches the documented standard, but converts every latent
  finding into a simultaneous crash across the backup and restore paths, in a
  change nobody can execute before shipping. Correct order is: fix latent
  findings → adopt StrictMode → verify on a tenant (R-11).
- *Fix R-06 directly* — the code plainly contradicts its own documented
  contract, so "fixing" it is defensible. Rejected because either direction
  (count offline as failure, or document the exclusion) silently changes what
  the user's existing automation sees.
- *Record everything and fix nothing* — safest for the diff, but leaves two
  reachable crashes in a tool that is in real use.

---

## D-014 — Do not change the fleet script's exit-code behavior, even to fix a bug

- **Date**: 2026-07-28
- **Status**: Decided (by user)

**Decision.** `Invoke-MDMWinsOverGPFleet.ps1`'s exit-code contract
(`0`/`1`/`2`/`3`) stays exactly as it is, including the discrepancy found at
R-06 (an all-offline fleet run currently exits `0`, "clean", even though the
script's own header says it should exit `1`). **No agent may change this
script's exit-code logic on its own initiative**, even to correct a
documented contradiction.

**Why.** This exit code is not just internal to the script — it is a contract
already read by the user's RMM and Intune automation. The user does not want
that native, already-relied-upon behavior touched, independent of whether the
current behavior is technically a bug.

**Rejected.** *Remap `Offline` to exit `3` (degraded evidence)* — this was the
review's recommendation (R-06) and reuses an exit code the fleet script
already defines but never emits, so it wouldn't have invented new behavior.
Declined anyway: the user's priority here is stability of what downstream
automation already sees, not correctness of the contract in isolation.

**If this bites in practice** (e.g. an all-offline run is later mistaken for
a healthy fleet), raise it with the user again — don't fix it unilaterally.
This decision covers the exit-code *contract*; it does not forbid fixing
unrelated bugs elsewhere in the same file.

---

## D-015 — The MDM toolkit README is repo-first; its intro drops the ZIP-distribution framing

- **Date**: 2026-07-29
- **Status**: Decided (by the Issue #16 session)

**Decision.** The rewritten intro of `MDMWinsOverGPToolKit/README.md`
documents the toolkit **as a folder in this repository**. The old intro's
distribution framing is gone and should not come back: no
`sandbox:/mnt/data/...zip` download link, no "the ZIP contains..." file list,
and no `README.txt` (that file does not exist here — this `README.md` is it).
The file list is now the four files actually on disk, including
`Invoke-MDMWinsOverGPFleet.ps1`, which the old intro predated and never
mentioned.

**Why.** The damage was chat-export debris, and the framing around it was
equally stale — it described a hand-packaged ZIP delivered in a conversation,
not the repo that a reader is looking at. Restoring the "original" wording
would have documented a distribution channel that does not exist.

Two supporting choices, both deliberate:

- **Scope was the damage plus its immediate surroundings, not the file.** Old
  lines 1–126 were replaced; everything from "Blocked Group Policies
  (authoritative evidence)" onward is byte-for-byte unchanged and was verified
  by diff. That section onward is accurate, dense, and hard-won.
- **Every factual claim was re-derived from `Test-MDMWinsOverGP.ps1`**, not
  copied forward from the old intro. That check caught two things the old text
  would have had us repeat: `Blocked-GroupPolicies.csv` carries no
  `ParseStatus` column (the status is reported in the HTML report and
  `Log.txt`), and `GPO-Settings.csv` is the raw applied-GPO list — the join
  against CSP mappings happens in the HTML report, not in that CSV.

**Rejected.**
- *Reconstruct the original wording from the truncated fragments* — would have
  preserved authorial voice, but the fragments are cut mid-word and their
  sources are Microsoft Learn pages the sandbox cannot fetch (403), so the
  reconstruction would have been invention presented as recovery.
- *Rewrite the whole README while in there* — tempting given the plain-text
  "Interpretation"/"Files" headings further down, but `docs/PROJECT_STATUS.md`
  scoped this task to the damaged intro precisely because the rest is correct
  and expensive to re-verify. Untouched means diffable.
- *Delete the `?utm_source=chatgpt.com` query strings on the `[1]`/`[2]` link
  definitions* — they are cosmetic debris from the same export, but they sit
  further down the file, outside the damaged region, and the links resolve.
  Left alone rather than widening the diff.

---

## D-016 — Toolkit tests run under `Set-StrictMode -Version 2.0` and cover both duplicate copies

- **Date**: 2026-07-29
- **Status**: Decided (by the item-B session)

**Decision.** `tests/Toolkit.PureFunctions.Tests.ps1`, the first test file for
`MDMWinsOverGPToolKit/`, runs `Set-StrictMode -Version 2.0` at the top instead
of the `-Off` every `scripts/`-testing file uses. `SuiteIntegrity.Tests.ps1`'s
StrictMode guard changed from "no test file may set any StrictMode version"
to "files named `Toolkit.*` must set exactly `-Version 2.0`; every other file
must set none" — it now enforces a per-file match to the strictness of the
production code that file exercises, rather than one blanket rule for the
whole suite.

The file also tests **both** independent copies of `Normalize-PolicyName`,
`Get-TokenSet`, `Get-JaccardScore` and `Convert-ValueToText` — one in
`Build-PolicyMappings.ps1`, one in `Test-MDMWinsOverGP.ps1` — plus parity
checks between them, using the same dot-source-inside-`& { }` technique
`ImportDatabase.Functions.Tests.ps1` already uses for
`ConvertTo-FlatSettings`/`Get-PolicyContentHash`.

**Why.** `docs/AGENT_ONBOARDING.md`'s StrictMode table is explicit that all
three `MDMWinsOverGPToolKit/` scripts set `Set-StrictMode -Version 2.0`,
unlike the five files in `scripts/`, which set none (R-01). D-012's whole
rationale for matching harness strictness to production strictness is
symmetric: a harness *looser* than production (running toolkit code under
`-Off`) can hide exactly the `.Count`-on-`$null` class this project has
shipped four times, the same way a harness *stricter* than production hid
nothing useful and cost `TestHelpers.ps1` its credibility. The old blanket
guard assumed one strictness level for the entire suite because, until this
file, every test file happened to test `scripts/`; it needed to become
per-file the moment a second production strictness level entered the suite.

Testing both copies (rather than picking one "canonical" one) follows
directly from why the toolkit's own comments say each is "kept local ... so
this script is meant to be runnable standalone" — that is a deliberate
design choice, not an oversight Issue #14 should have collapsed, so a test
suite that only covered one copy would leave the other unverified and free to
drift silently, exactly the failure mode D-012 exists to prevent.

**Rejected.**
- *Test only one copy (say, `Build-PolicyMappings.ps1`'s) and assume the
  other matches* — less code, but the two files are diffed as identical only
  in comments/whitespace today (verified by diff during this session); a
  future edit to either file with no test on the other would ship a silent
  divergence, the same class of bug Issue #14 fixed for `scripts/`.
- *Keep the suite-wide `-Off` and skip StrictMode-dependent assertions in
  toolkit tests* — avoids touching the guard, but a harness that cannot even
  express `-Version 2.0` can never verify the toolkit's own
  `.Count`-on-`$null` defenses (e.g. `Get-JaccardScore`'s `-not $Left`
  guard), which is exactly the property worth testing given this project's
  bug history.
- *Weaken the guard to "no `-Version Latest`" instead of a per-file exact
  match* — simpler, but re-opens the door to a `-Version 1.0` or `-Version 3`
  file quietly testing under the wrong rules with nothing to catch it; the
  whole point of D-012's StrictMode guard is that it is mechanical, not
  reviewer-dependent.

---

## D-017 — Keep the `Where-Object { $_ }` assignment guard, and give it a real test, rather than deleting it as dead code

**Date**: 2026-07-30 · **Context**: closing Issue #14

Running the suite for the first time proved that the `Where-Object { $_ }`
clause in both backup scripts' assignment pipelines is **not** what stops an
unassigned policy from crashing. R-02's step 2 was wrong: an empty
`Get-MgGraphAllPages` returns `AutomationNull`, and `@(AutomationNull)` is an
empty array, so the pipeline never runs and the phantom `$null` the clause was
added to drop never exists on that path. Deleting the clause changes nothing
observable, which is exactly why the deliberate-break acceptance test came back
green twice.

**Decision**: keep the clause, and add a regression test that actually reaches
it (a null *element* inside a populated `value` array — the one shape that does
produce a real `$null`).

**Why**:
- The guard is one pipeline clause with no measurable cost.
- Its twin in `Get-IntuneSettingsCatalogSnapshot.ps1` sits in a script with **no
  per-policy `try/catch`**, so an unguarded null element would end the entire
  run, not degrade one policy. Verified: removing it there throws out of the
  script body.
- Untested defensive code is the thing this project keeps getting burned by. A
  guard nothing exercises is indistinguishable from a guard that doesn't work.

**Rejected.**
- *Delete it as dead code.* Defensible on "don't handle scenarios that can't
  happen" — but "Graph is not known to emit a null element" is weaker than
  "Graph cannot", and the reasoning that said this path was safe is precisely
  the reasoning that just turned out to be wrong. Removing a guard on the
  strength of the analysis that was mistaken is the wrong lesson to draw.
- *Keep it and leave it untested, noting the finding in docs only.* That is the
  status quo that hid the error for four sessions.
- *Rewrite the guard as an explicit `if ($null -ne $_)` inside `ForEach-Object`.*
  Same semantics, more lines, and it would still need the same test to be
  trustworthy.
