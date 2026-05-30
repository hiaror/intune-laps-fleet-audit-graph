# Intune LAPS Fleet Audit (Microsoft Graph PowerShell)

## Overview
This repository contains PowerShell automation that uses **Microsoft Graph** to audit Windows LAPS deployment health across an Intune-managed fleet.

The toolset cross-references Intune Windows device inventory against LAPS escrow records in Entra ID, categorises devices by Windows 11 24H2 eligibility for Automatic Account Management (`WLapsAdmin`), and confirms the actual managed account name on every escrowing device. A second script identifies devices with multiple conflicting Entra device objects, a known LAPS escrow blocker.

## Why This Exists

In hybrid Intune tenants, the LAPS recovery portal often shows a mix of `WLapsAdmin` and `Administrator` account names across devices. The Intune portal does not expose this at fleet scale, and Microsoft Graph's v1.0 list endpoint deliberately blocks bulk account name retrieval with HTTP 400.

This toolset answers four questions every engineer running Windows LAPS at scale will eventually face:
- How many devices are actually escrowing LAPS passwords?
- Which devices in Intune are NOT escrowing, and why?
- Which devices are eligible for `WLapsAdmin` (Windows 11 24H2 or later) and which are not?
- For escrowing devices, what is the actual managed account name?

## Key Capabilities
- Microsoft Graph based, delegated admin auth
- Three-way cross-reference: Intune inventory vs Entra escrow vs Entra device objects
- OS eligibility analysis using build version comparison against `10.0.26100`
- Per-device account name confirmation via the beta endpoint (the only way to get account names at scale)
- Detection of duplicate or conflicting Entra device objects
- Detailed CSV reporting with audit-grade columns

## Repository Structure
```
.
├── scripts/
│   ├── Invoke-LAPSFleetAudit.ps1
│   └── Find-DuplicateEntraDevices.ps1
├── sample-data/
│   └── LAPSFleetAudit.sample.csv
└── README.md
```

## Prerequisites
- PowerShell 5.1 or PowerShell 7.x
- `Microsoft.Graph` PowerShell SDK installed
- Admin account with these Graph scopes consented:
  - `DeviceLocalCredential.ReadBasic.All`
  - `DeviceLocalCredential.Read.All`
  - `Device.Read.All`
  - `DeviceManagementManagedDevices.Read.All`
  - `DeviceManagementConfiguration.Read.All`

## CSV Input Format

This toolset is fully Graph-driven and does not require a CSV input. The `sample-data/` folder contains a sanitized example of the **output** report produced by `Invoke-LAPSFleetAudit.ps1`.

### Sample Output (LAPSFleetAudit.sample.csv)
```csv
DeviceName,OsVersion,IsEligible,InIntune,IsEscrowing,AccountName,LastBackup,Notes
CORP-PC-001,10.0.26100.4946,True,True,True,WLapsAdmin,2026-05-05T01:20:13Z,
CORP-PC-002,10.0.22631.6936,False,True,True,Administrator,2026-05-04T23:15:02Z,
CORP-PC-003,10.0.26100.5023,True,True,False,,,Not escrowing - investigate registration
CORP-PC-004,10.0.21996.1,False,True,False,,,Unsupported OS build for LAPS
```

## Usage Examples

### Standard Fleet Audit
```powershell
./Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000"
```

### Skip Per-Device Account Name Lookup (Faster)
```powershell
./Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -SkipAccountNameLookup
```

### Custom Eligibility Threshold and Report Path
```powershell
./Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -EligibilityBuild "10.0.26100" `
  -ReportPath ".\Output\LAPSFleetAudit_Custom.csv"
```

### Find Devices with Duplicate Entra Objects
```powershell
./Find-DuplicateEntraDevices.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000"
```

### Inspect a Single Device by Name
```powershell
./Find-DuplicateEntraDevices.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -DeviceName "CORP-PC-001"
```

## Reporting
Each `Invoke-LAPSFleetAudit.ps1` run produces a timestamped CSV with one row per unique device name across the union of Intune and Entra escrow records:
- DeviceName
- OsVersion
- IsEligible (True if OS build is at or above the eligibility threshold)
- InIntune
- IsEscrowing
- AccountName (`WLapsAdmin` or `Administrator`)
- LastBackup
- Notes (diagnostic context for non-escrowing or stale records)

Each `Find-DuplicateEntraDevices.ps1` run produces a timestamped CSV showing every Entra device object for any device name that has more than one record:
- DeviceName
- ObjectNum
- DeviceId
- TrustType (`ServerAd`, `AzureAd`, or `Workplace`)
- Created
- Registered (`YES` or `NO-PENDING`)
- HasAltSec (`YES` or `NO`)
- LastSignIn
- Enabled

## Safety Notes
This is a read-only audit toolset against Intune and Entra ID. No modification is made to devices, policies, or directory objects.

`Find-DuplicateEntraDevices.ps1` only reports. Stale Entra object cleanup must be done separately, only after confirming the correct device object should remain. Always verify the remediation path on a test device before running it across a fleet.

## Disclaimer
Provided as-is for reference and learning purposes. Sample data and identifiers are sanitized.

## Blog Post

A full write-up of the findings, the Graph queries, and the gotchas is at [AroraMSP: WLapsAdmin or Administrator? Auditing Windows LAPS at fleet scale](https://aroramsp.com/blog/laps-fleet-audit-graph).
