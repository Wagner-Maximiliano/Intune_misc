# Intune / MS Graph — Quick Reference Commands

Quick, copy-pasteable PowerShell 5.1 commands for day-to-day work on this
project. Each section is self-contained: a title, what it's for, and the
command(s) to run.

---

## 1. Check your current Graph permissions (scopes) after Connect-MgGraph

**What it's for:** `Connect-MgGraph` only grants the scopes you explicitly
request (or a minimal default if you request none) — it does **not**
automatically grant everything your Entra ID role allows. Being an **Intune
Administrator** in Entra ID means you're *allowed* to consent to Intune Graph
permissions; it does not mean your *current session* has them. A `403
Forbidden` on a call like `Get-MgDeviceManagement` almost always means the
scope needed for that call was never requested/consented in the
`Connect-MgGraph` call you used to sign in.

**Command — see everything about your current session:**

```powershell
Get-MgContext | Format-List Account, TenantId, AuthType, Scopes
```

**Command — list just the granted scopes:**

```powershell
(Get-MgContext).Scopes
```

**Command — check specific scopes this project needs against what you currently have:**

```powershell
$requiredScopes = @(
    'DeviceManagementConfiguration.Read.All'
    'Group.Read.All'
    'DeviceManagementApps.Read.All'
)

$currentScopes = (Get-MgContext).Scopes

$requiredScopes | ForEach-Object {
    [pscustomobject]@{
        Scope   = $_
        Granted = $currentScopes -contains $_
    }
}
```

**If a required scope shows `Granted = False`:** disconnect and reconnect
requesting it explicitly, then accept the consent prompt:

```powershell
Disconnect-MgGraph
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','Group.Read.All','DeviceManagementApps.Read.All'
```

If the consent prompt itself fails or is greyed out, that's a tenant-level
admin consent issue (not something `Connect-MgGraph` can fix on its own) —
that needs a Global/Privileged Role Administrator to grant admin consent for
the app once, after which any Intune Administrator can consent for
themselves.
