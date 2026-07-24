---
name: powershell-testing
description: >-
  Test, validate, syntax-check, or "tighten" a PowerShell script (.ps1/.psm1)
  from a Linux container or any environment without Windows/PowerShell already
  installed. Use this whenever you are reviewing a PowerShell script for
  correctness, are asked to make one "production-ready" or confirm it "won't
  break," or need to actually run/parse-check/unit-test PowerShell but no `pwsh`
  is present — including Windows-targeted scripts (Intune, Active Directory,
  registry, Exchange, DSC) whose collection paths are Windows-only. Do not
  assume you cannot run PowerShell just because the host is Linux: PowerShell 7
  installs without root in ~1 minute, and the pure logic of most scripts can be
  parse-checked and unit-tested even when Windows-only cmdlets cannot run.
---

# Testing PowerShell scripts without Windows

Static review of PowerShell misses real bugs — overload-resolution surprises,
`Set-StrictMode` violations, cmdlet-binding quirks — because they only surface
when the parser and runtime actually execute the code. This skill sets up a real
PowerShell runtime in a Linux container and uses it to catch those bugs, while
being honest about the layer that genuinely needs Windows.

## The two layers of "testing"

Be explicit with the user about which layer you're providing:

1. **Static + unit (you CAN do this here).** Full parser (AST) validation, plus
   executing the script's pure-logic functions against synthetic data under the
   same `Set-StrictMode` the script sets. This catches syntax errors, strict-mode
   property/variable violations, broken string/regex/parsing logic, bad overload
   resolution, and sort/group/filter mistakes.

2. **Functional / integration (needs real Windows).** Anything calling
   Windows-only surfaces — the registry (`HKLM:`), `Get-WinEvent`, `wevtutil`,
   `gpresult`, `Get-CimInstance`/WMI, AD cmdlets, Exchange, COM, `MdmDiagnosticsTool`.
   These do not exist on Linux PowerShell. Say so plainly and recommend a run on a
   representative Windows (or, for Intune/MDM, an enrolled) test device.

Delivering layer 1 is high-value on its own — it's how the two bugs in this repo's
`Test-MDMWinsOverGP.ps1` were found (a StrictMode throw on empty-array property
access, and a `.Split(@(...))` that never tokenized). Neither was visible to a
static read.

## Workflow

### 1. Install PowerShell 7 (no root needed)

Run the bundled setup script. It downloads the self-contained tarball to a cache
dir and is idempotent (skips if already installed), printing the `pwsh` path:

```bash
bash .claude/skills/powershell-testing/scripts/setup-pwsh.sh
```

It echoes `PWSH=<path>`. Capture that path; the examples below assume `$PWSH`
points at it. If the download is blocked, note the environment's egress policy
rather than silently failing.

### 2. Parse-check the whole script (fast, always do this first)

A clean parse proves there are no syntax errors and that every function compiles
— this alone would have caught the risky `Sort-Object Confidence -Descending,
GpoSetting` binding. Use the bundled checker:

```bash
"$PWSH" -NoProfile -File .claude/skills/powershell-testing/scripts/parse-check.ps1 <path-to.ps1>
```

It exits non-zero and lists `[line] message` on parse errors; on success it prints
the count and names of the functions it found.

### 3. Unit-test the pure functions

The obstacle: most Windows scripts have top-level executable code (an admin check,
`param()` wiring, registry reads) that would run — and fail — the moment you
dot-source the file on Linux. The trick is to load **only the function
definitions**, skipping the top-level body, by extracting them from the AST.

The bundled helper `load-functions.ps1` defines `Get-ScriptFunctions`, which
returns the target's function definitions as an unbound scriptblock. Write a
small harness that loads the functions under the **same strict mode the target
sets** (check the script — this repo's uses `Set-StrictMode -Version 2.0`), then
exercise the pure logic with synthetic objects shaped like the real data. Note
the **double dot-source** — the second `. (...)` is what injects the functions
into your harness scope:

```powershell
Set-StrictMode -Version 2.0          # match the target script's mode
$ErrorActionPreference = 'Stop'
. ./.claude/skills/powershell-testing/scripts/load-functions.ps1
. (Get-ScriptFunctions -Path ./MyScript.ps1)   # loads the target's functions here

$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" }
    else { Write-Host "  FAIL  $name"; $script:fail++ }
}

# Feed the function fake but realistically-shaped input and assert on output.
Check 'tokenizes on delimiters' ((@(Get-TokenSet 'AllowTelemetry/Config')).Count -eq 3)

if ($fail) { exit 1 } else { Write-Host 'ALL PASSED' }
```

Run it with `"$PWSH" -NoProfile -File harness.ps1`. Put harnesses in the
scratchpad dir, not the repo, unless the user wants committed tests.

**Deliberately test the empty / missing / null paths.** The most valuable bugs
hide where a filter matched nothing: `@()`, a `Where-Object` that returned zero
rows, a missing registry value. Under `Set-StrictMode` these throw where a static
read sees nothing wrong (see the strict-mode trap below).

### 4. Report honestly

State what passed under the runtime, and name the specific Windows-only paths you
could not exercise. Offer the real-data shortcut where it applies: if the user can
export representative inputs (e.g. a `GPResult.xml`, a registry CSV), you can push
those through the parsing/matching logic here and validate the real-data path
short of live collection.

## PowerShell 5.1 vs 7 — the compatibility caveat

The runtime here is PowerShell 7 (Core) on Linux. Many production scripts target
**Windows PowerShell 5.1**. Most language semantics — overload resolution,
`Set-StrictMode`, cmdlet binding — are shared, so bugs found here almost always
apply to 5.1 too. But do not assume the reverse: passing here is not proof of 5.1
compatibility. Keep flagging 5.1 concerns from static reading:

- `.NET` APIs available only in Core, or assemblies not present in 5.1.
- Syntax newer than 5.1: ternary `a ? b : c`, null-coalescing `??`/`?.`,
  `&&`/`||` pipeline chains, `-Parallel` on `ForEach-Object`. These PARSE on 7 but
  FAIL on 5.1 — the parser here won't catch them, so watch for them by eye.
- Prefer `[System.Net.WebUtility]` over `[System.Web.HttpUtility]` (latter needs an
  assembly load on 5.1), etc.

When it matters, note in your report that final validation should occur on 5.1.

## Recurring bug patterns worth probing under StrictMode

These are the traps that a real runtime catches and a read does not. Write a
targeted assertion for any that the script could hit:

- **Property access on an empty array.** `@().Foo` throws
  `The property 'Foo' cannot be found on this object` under `StrictMode 2.0`+.
  Common when `$matches = @($x | Where-Object {...})` returns nothing and the code
  then reads `$matches.Foo`. Fix pattern: iterate with
  `@($matches | ForEach-Object { $_.Foo })` instead of member-access on the array.
- **`.Split(@(...))` doesn't split.** Passing an untyped array to `String.Split`
  binds the single-`String` overload, so the text is returned whole. Prefer the
  `-split` regex operator, or cast `[char[]]`/`[string[]]` explicitly.
- **`Sort-Object Prop -Descending, Other`.** Mixed ascending/descending in one
  positional list mis-binds. Use hashtable keys:
  `Sort-Object @{Expression='A';Descending=$true}, @{Expression='B'}`.
- **Uninitialized variable reference.** `StrictMode` throws on reading a variable
  that was never set — easy to hit on an error path. Initialize up front.
- **`$null.Count` / scalar vs array.** Wrap pipeline results in `@()` before
  reading `.Count` so a single object or `$null` doesn't surprise you.

See `scripts/` for the bundled setup, parse-checker, and function loader.
