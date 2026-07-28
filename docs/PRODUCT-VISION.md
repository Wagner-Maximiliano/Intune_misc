# Continuum — product scope

**A management console for organisations migrating from Group Policy to Intune.**

- **Status**: scope document. Describes what exists today, what is being built,
  and where it goes next.
- **Audience**: the product owner, and anyone being shown the plan.
- **Companions**: `ROADMAP.md` (phases), `ARCHITECTURE.md` (how it's built),
  `DECISIONS.md` (what's settled), `PROJECT_STATUS.md` (where we are today).

> **Honesty rule for this document.** Everything under "What exists today" is
> shipped and in real use. Everything else is explicitly marked *planned*.
> Section 7 lists what the product genuinely cannot do. A scope document that
> oversells is worse than useless — it produces a demo that can't be given.

---

## 1. The problem

Almost every Windows organisation is somewhere between two worlds. Group
Policy has run their estate for twenty years. Intune is where they're going.
Very few are fully in either — most will sit in the middle for years.

That middle is where three specific things go wrong.

### Intune has no undo

Group Policy admins have decades of tooling: backup, version history, change
tracking. Intune has effectively none of it. If someone edits a policy badly,
or deletes one, **there is no version history to restore from and no record of
what it used to say**. The tenant simply reflects the new state as though it
had always been that way.

### Co-managed devices lie about what's enforced

When a device receives policy from both Group Policy and Intune, **MDM
silently wins**. The GPO doesn't error. It doesn't warn. It just stops taking
effect, while still appearing correctly configured in every Group Policy tool
the admin has.

Windows *does* record this — there's a "Blocked Group Policies" table buried in
the output of `MdmDiagnosticsTool.exe`. Practically nobody reads it, and
nothing aggregates it across a fleet.

The failure mode is quiet and dangerous: an admin believes a security setting
is enforced on 500 machines. On the co-managed ones, it isn't.

### Nobody can answer "are we ready to migrate?"

Migration decisions get made on intuition, because the data to make them
properly is scattered across per-device diagnostics nobody has time to collect,
read, and correlate.

---

## 2. What Continuum is

One console, on a management server, that answers three questions:

| Question | Answered by |
|---|---|
| What did this policy look like before someone changed it? | Policy history + restore |
| Where is Intune silently overriding Group Policy? | Conflict validation across the fleet |
| Is this fleet ready to migrate? | The two above, joined per device |

The third is the point. Policy drift and MDM/GPO conflict are far more useful
side by side than apart, and no existing tool puts them together. That
combination is the product (D-001).

### The name

The GPO-to-Intune transition is a continuum, not a cliff edge. The product's
job is to give you visibility *during* a gradual migration rather than
pretending it's a switch you flip.

---

## 3. What exists today

**~8,100 lines of PowerShell, working, in real production use.** This is not a
prototype — it is a working toolset that needs a front end.

### Policy Backup — 5 scripts

| Script | What it does |
|---|---|
| `Backup-IntunePolicies.ps1` | Snapshots every Settings Catalog policy to JSON, plus a versioned Excel workbook per policy — a new dated sheet only when the policy actually changed |
| `Import-PolicyHistoryToDatabase.ps1` | Loads snapshots into a single-file SQLite history database. Idempotent and additive — re-running only appends genuinely new versions |
| `Restore-IntunePolicy.ps1` | Recreates a policy from any snapshot. **Create-only — never overwrites** |
| `Get-IntuneSettingsCatalogSnapshot.ps1` | Lighter read-only JSON pull |
| `Export-PolicySummary.ps1` | One-row-per-policy Excel summary, works offline from JSON |

Change detection is by **content hash over settings and assignments — not
display names**, so a Microsoft-side rename doesn't create a phantom version.

### MDM/GPO Conflict Validation — 3 scripts

| Script | What it does |
|---|---|
| `Test-MDMWinsOverGP.ps1` | Collects evidence from one device and builds an interactive HTML report |
| `Build-PolicyMappings.ps1` | Generates a GPO→CSP mapping catalogue from the machine's own ADMX files and registry — no internet required |
| `Invoke-MDMWinsOverGPFleet.ps1` | Runs the collector across many devices from a management server |

The collector parses Windows' own **"Blocked Group Policies"** table — the
authoritative statement of what MDM has overridden — alongside GPResult, the
PolicyManager registry tree, and DeviceManagement event logs. It produces a
self-contained interactive HTML report with sortable and filterable tables and
a dark mode, plus a full evidence ZIP.

### The existing data model

Already built and running (SQLite): `Policies`, `PolicyVersions`,
`PolicySettings`, `PolicyAssignments`, `IngestRuns`, `Meta`. The console
extends this schema rather than replacing it (D-003).

---

## 4. What makes it different

These are all real, shipped properties — not aspirations. They're also the
hardest things for a competitor to copy, because each came from a production
incident.

### It distinguishes evidence from inference

The report separates **what Windows itself states** (the Blocked Group Policies
table) from **what the tool has guessed** (name-similarity matching between GPO
and CSP settings). Guesses are labelled as guesses and given a confidence tier.

Most tools present one confidence level for everything. In an audit or an
incident review, that difference matters enormously.

### It refuses to confuse "nothing found" with "couldn't tell"

There are four outcomes, not three:

| Code | Meaning |
|---|---|
| `0` | Clean — checked, nothing found |
| `1` | Fatal — the run did not complete |
| `2` | Conflicts found — actionable, **not** a failure |
| `3` | **Degraded** — ran, but evidence was incomplete. A `0` elsewhere in this run is not conclusive |

State `3` is the one that matters. If MDM diagnostics were skipped or the
authoritative table couldn't be parsed, the tool says so rather than reporting
a reassuring green zero. That distinction survives into the UI as a
first-class state — it is never flattened.

### It doesn't need to be trusted with the keys

- **No agent to install** on managed devices.
- **No cloud service** — runs on your management server, on your network.
- **No credential delegation.** Fleet runs use a `Copy` delivery mode where the
  remote device never touches a network path, sidestepping the PowerShell
  double-hop problem entirely.
- **Report-only by default.** It never auto-modifies tenant policy. Restore is
  create-only and never touches assignments via the API.
- **Works offline.** The mapping generator uses local ADMX files and the
  registry — no internet. Reports are self-contained HTML with no CDN calls.

For a security-sensitive buyer, this list *is* the sales pitch.

### Replay

`-ReplayFromPath` regenerates the entire analysis and report from previously
collected evidence — no device access, no elevation. Re-analyse last month's
collection with this month's logic. It's also the fastest development loop the
project has.

---

## 5. Where it's going

Phases below match `ROADMAP.md` exactly. (An older document used a different,
now-colliding numbering — it has been retired.)

### Phase 0 — Foundations *(in progress)*

Make the existing code safe to build a product on. Full code review ✅, a test
suite that exercises the real code ✅ (written, needs its first run), then
extract shared `Continuum.*` modules so the UI and CLI call the same functions.

**Why it matters commercially:** the review found two crashes triggered by
completely ordinary tenants — a policy with no assignments, and a policy with
no settings. Both are fixed. That is the difference between a demo and a
product.

### Phase 1 — Console shell

A local HTTP server serving a browser dashboard: **Dashboard / Devices / Tools
/ Runs / Reports**. Localhost-only, single-admin, no accounts (D-009). One
shared SQLite schema across both toolsets.

### Phase 2 — Device inventory

CSV import with column mapping and preview. Devices persisted with grouping and
tagging by site, OU, or **migration wave** — replacing today's loose device-list
CSV.

### Phase 3 — Run orchestration

Trigger fleet runs and backups from the UI. Live per-device progress, not a
spinner. Run history with drill-down into any device's evidence. The 0/1/2/3
contract surfaced as first-class UI state.

### Phase 4 — Dashboard & reporting *(the payoff)*

Fleet health: conflict counts, policy drift, trends over time. **The cross-tool
device view** — one page showing a device's policy history *and* its MDM/GPO
conflicts. Export to PDF/CSV/HTML; scheduled reports.

This is the thing neither toolset can do alone, and the reason for unifying
them at all. Prioritise it.

### Phase 5 — Productionisation

Installer, multi-user with roles, audit log, configuration UI, operator
documentation. The point at which it can be handed to a business that didn't
build it.

---

## 6. Expansion beyond Phase 5

Where the product grows once the console is real. Ordered by value-to-effort,
not certainty — these are candidates, not commitments.

### Near-term, high value

**Deletion detection.** Compare each run against the last known set and flag
anything that vanished. The project's own backlog puts it bluntly: the entire
premise is that Intune has no recovery for deleted policies, *yet nothing
currently says "this existed last run and doesn't now."* Pair it with a
deleted-policies view that jumps straight to the last known version and offers
restore. Likely the single most-used screen in the product.

**Scheduled, unattended operation.** Certificate-based app registration,
fail-fast non-interactive mode, run-summary output, email/Teams alerting on
drift or new conflicts. Turns the product from something you run into
something that watches for you — and is a precondition for any managed-service
offering.

**Snapshot diff.** Compare any two versions of a policy — settings added,
removed, changed, plus assignment changes. The logic already exists in outline;
the console needs it as a view.

**Capture what's currently dropped.** Scope tags and template references are
real Graph fields the backup doesn't yet record. History captured before this
is added can never be backfilled, so it's worth doing early.

### Medium-term

**More policy types.** Today the backup covers Settings Catalog only. Legacy
device configurations, administrative templates, compliance policies and
endpoint security intents are all natural extensions of the same model.

**Migration recommendations.** The mapping generator already builds a GPO→CSP
catalogue. The obvious next step is turning that into guidance: *here is the
Intune equivalent of this GPO, and here is what breaks if you move it.* This
is the most defensible long-term feature — it converts a diagnostic tool into a
migration tool. It also needs the most care, because today's matching is
heuristic (see §7).

**Compliance mapping.** Map findings to CIS/NIST benchmarks. Changes the buyer
from an IT admin to a compliance owner, and the budget accordingly.

### Longer-term

**Multi-tenant / MSP mode.** One console across many customer tenants — the
natural commercial expansion, and a substantial change (isolation, per-tenant
credentials, aggregate reporting).

**Hosted offering.** Deliberately out of scope for now. The design shouldn't
prevent it, but the local-only property is currently a *feature* for security
buyers, and shouldn't be traded away lightly.

---

## 7. What it does not do

State these plainly in any demo. Every one is a known, deliberate boundary
rather than an oversight — and volunteering them is what makes the rest
credible.

- **Settings Catalog only.** Other Intune policy types aren't backed up yet.
- **Secrets don't round-trip.** Graph never returns secret-typed values on
  read, by design. A restored policy with a password or certificate field will
  have that field blank. The tool must say so — it cannot fix it.
- **Restore doesn't reassign.** It recreates the policy and prints the original
  assignments for you to reapply by hand. Deliberate: automatically assigning a
  restored policy to live groups is exactly the kind of action that should
  require a human.
- **Restore is create-only.** It never overwrites an existing policy.
- **GPO→CSP matching is heuristic and currently thin.** Name similarity, not a
  Microsoft-published mapping. On a real device, the highest-confidence match
  tier produced **0 matches out of 3,549 ADMX policies** — that is a measured
  result, and the analysis is that it's structural: when MDM wins, the GPO
  registry write is suppressed, so "both configured" is self-contradictory for
  a genuine conflict. The authoritative Blocked Group Policies table is the
  reliable signal; the mapping layer is supporting context.
- **"Last modified by" is best-effort**, limited to the tenant's audit
  retention window.
- **Device evidence is a point-in-time snapshot** of one machine as it was when
  the script ran.
- **Single administrator, no accounts** in the first release (D-009). Multi-user
  is Phase 5 and will need a schema migration — a known, accepted cost.

---

## 8. Who it's for

**Primary:** the IT administrator or infrastructure team running a hybrid
Windows estate mid-migration — enough devices that per-device diagnostics don't
scale, enough Intune adoption that co-management conflicts are real.

**Secondary:** managed service providers running migrations for clients, who
need evidence and reporting they can hand over. Multi-tenant support is what
unlocks this segment properly.

**Tertiary:** security and compliance owners who need to demonstrate that a
policy was enforced — and, crucially, evidence of when it wasn't.

### Why someone buys it

Not "we back up Intune policies." The pitch is:

> You believe your security baseline is enforced across your fleet. On your
> co-managed devices, some of it silently isn't — and Windows knows exactly
> which parts, it just never tells you. This finds them, proves it with
> Windows' own evidence, and tracks every policy change so you can see what
> moved and put it back.

---

## 9. Demo narrative

The sequence to walk through when presenting, chosen so each step motivates
the next.

1. **Open on the dashboard.** Fleet readiness at a glance — devices checked,
   conflicts found, policies tracked, and how many devices came back *degraded*
   rather than clean.
2. **Drill into a device with conflicts.** Show the Blocked Group Policies
   table — Windows' own words — then the heuristic candidates below it, clearly
   marked as lower confidence.
3. **Show a degraded device.** This is the trust moment: the product says "I
   couldn't tell" instead of showing a green tick.
4. **Switch to that same device's policy history.** The cross-tool view. Its
   conflicts and its policy drift on one page.
5. **Open a changed policy.** Version timeline, diff between versions, who
   changed it and when.
6. **Restore.** Show it creating a new policy, never overwriting — and printing
   the assignments for manual reapplication rather than touching live groups.
7. **Close on a fleet run.** Live per-device progress, then the four outcome
   states in the summary.
