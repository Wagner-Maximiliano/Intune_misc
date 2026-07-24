I created the PowerShell toolkit:

[Download the MDMWinsOverGP Validation Toolkit](sandbox:/mnt/data/MDMWinsOverGP-Validation-Toolkit.zip)

The ZIP contains:

* Test-MDMWinsOverGP.ps1
* PolicyMappings-Sample.csv
* README.txt

Run it from an elevated PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass

.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -RunGpUpdate `
  -SinceHours 24
```

([Microsoft Learn][1])olicyManager device and user settings.

* ProviderSet and WinningProvider metadata where Windows exposes it.
* GPResult in XML, HTML, and text formats.
* MDM diagnostic reports.
* DeviceManagement Admin, Operational, and Debug logs.
* Event 881 records.
* Traditional policy registry locations.
* Verified GPO-to-CSP overlaps from a mapping CSV.
* Heuristic overlap candidates based on policy names.
* A consolidated HTML report.
* CSV reports and the original EVTX files.
* A ZIP evidence package.

The main result is:

```text
Reports\MDMWinsOverGP-Validation.html
```

The report separates results into two important categories.

Verified mapping means you added a documented GPO-to-Policy-CSP relationship to the mapping CSV.

Heuristic candidate means the GPO and MDM setting names appear related. It is only a review candidate. It is not treated as proof of a conflict.

This distinction matters because Windows does not provide a complete machine-readable mapping between every GPResult setting and every Policy CSP setting. MDMWinsOverGP applies to Policy CSP policies, not every CSP or every Intune setting. Microsoft also documents specific exceptions, including Defender CSP and Windows Hello for Business policies. ([Microsoft Learn][1])([Microsoft Learn][1])or the best test sequence:

1. Run the script with `-EnableDebugLog`.
2. Trigger an Intune sync.
3. Run `gpupdate /force`.
4. Trigger another Intune sync.
5. Run the script again with a wider period:

```powershell
.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -SinceHours 48
```

You can disable the Debug log automatically after collection:

```powershell
.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -DisableDebugLogAfterCollection `
  -RunGpUpdate
```

Microsoft supports MDM diagnostic collection through `MdmDiagnosticsTool.exe`, and the DeviceManagement Enterprise Diagnostics Provider Admin and Debug channels are the main local Windows logs for MDM processing. ([Microsoft Learn][2])liberately does not treat Event 881 as proof of a conflict. It records those events as PolicyManager activity and uses them as supporting evidence only.

MDMWinsOverGP Validation Script

Files
- Test-MDMWinsOverGP.ps1
- PolicyMappings-Sample.csv

Recommended first run

Open Windows PowerShell 5.1 or PowerShell 7 as Administrator:

Set-ExecutionPolicy -Scope Process Bypass
.\Test-MDMWinsOverGP.ps1 -EnableDebugLog -RunGpUpdate -SinceHours 24

For a cleaner test sequence:
1. Enable the Debug channel.
2. Trigger an Intune sync from Settings or Company Portal.
3. Run gpupdate /force.
4. Trigger another Intune sync.
5. Run the script again without clearing the logs.

Example with verified mappings:

.\Test-MDMWinsOverGP.ps1 `
  -EnableDebugLog `
  -MappingCsv .\PolicyMappings-Sample.csv `
  -SinceHours 48

Main outputs
- Reports\MDMWinsOverGP-Validation.html
- Reports\Verified-Overlap-Results.csv
- Reports\Heuristic-Overlap-Candidates.csv
- Reports\MDM-EffectivePolicies.csv
- Reports\GPO-Settings.csv
- Reports\Event-881.csv
- Events\*.evtx
- GPResult\GPResult.html
- GPResult\GPResult.xml
- MDMDiagnostics\
- A ZIP containing the full evidence package

Interpretation
- Verified mapping: Based on rows you supplied in the mapping CSV.
- Heuristic candidate: Similar names only. It is not proof of a conflict.
- WinningProvider: Reported only where PolicyManager exposes the related metadata.
- Event 881: PolicyManager activity. It is not proof that MDM overrode GPO.


[1]: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-controlpolicyconflict?utm_source=chatgpt.com "Policy CSP - ControlPolicyConflict"
[2]: https://learn.microsoft.com/en-us/windows/client-management/mdm-collect-logs?utm_source=chatgpt.com "Collect MDM logs"
