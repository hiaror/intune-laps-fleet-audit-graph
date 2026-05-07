<#
Invoke-LAPSFleetAudit.ps1

Release Notes:
1) End-to-end Windows LAPS fleet audit via Microsoft Graph PowerShell
2) Cross-references Intune Windows inventory against LAPS escrow records in Entra ID
3) Categorises devices by Windows 11 24H2 eligibility for WLapsAdmin (Automatic Account Management)
4) Per-device account name confirmation via the beta endpoint (the only way to retrieve accountName at scale)
5) Single timestamped CSV report with audit-grade columns

Usage examples (SANITIZED):

Standard run:
.\Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000"

Skip per-device account name lookup (faster, no beta endpoint calls):
.\Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -SkipAccountNameLookup

Custom eligibility threshold and report path:
.\Invoke-LAPSFleetAudit.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -EligibilityBuild "10.0.26100" `
  -ReportPath ".\Output\LAPSFleetAudit_Custom.csv"
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$TenantId,

  [Parameter(Mandatory=$false)]
  [switch]$SkipAccountNameLookup,

  [Parameter(Mandatory=$false)]
  [string]$EligibilityBuild = "10.0.26100",

  [Parameter(Mandatory=$false)]
  [string]$ReportPath = (Join-Path $PWD ("LAPSFleetAudit_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")))
)

# ----------------------------
# Helpers
# ----------------------------

function Connect-LAPSGraph {
  param([Parameter(Mandatory=$true)][string]$TenantId)

  Set-MgGraphOption -DisableLoginByWAM $true | Out-Null

  Connect-MgGraph -TenantId $TenantId -Scopes `
      "DeviceLocalCredential.ReadBasic.All", `
      "DeviceLocalCredential.Read.All", `
      "Device.Read.All", `
      "DeviceManagementManagedDevices.Read.All", `
      "DeviceManagementConfiguration.Read.All" `
      -NoWelcome
}

function Get-AllEscrowedCredentials {
  $response = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials"
  return $response.value
}

function Get-AllIntuneWindowsDevices {
  $intuneResponse = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
  return $intuneResponse.value | Where-Object { $_['operatingSystem'] -eq 'Windows' }
}

function Get-LAPSAccountName {
  param(
    [Parameter(Mandatory=$true)][string]$DeviceLocalCredentialId
  )

  try {
    $detail = Invoke-MgGraphRequest -Method GET `
      -Uri "https://graph.microsoft.com/beta/directory/deviceLocalCredentials/$($DeviceLocalCredentialId)?`$select=credentials,deviceName,lastBackupDateTime"

    $creds = $detail['credentials']
    if ($creds -and $creds.Count -gt 0) {
      return $creds[0]['accountName']
    }
    return 'Unknown'
  } catch {
    return 'Error'
  }
}

# ----------------------------
# Main
# ----------------------------

Connect-LAPSGraph -TenantId $TenantId

Write-Host "Connected as : $((Get-MgContext).Account)"
Write-Host "TenantId     : $TenantId"
Write-Host "Eligibility  : $EligibilityBuild and above"
Write-Host "ReportPath   : $ReportPath"
Write-Host "============================================================="

Write-Host "Pulling LAPS escrow records..."
$escrowed = Get-AllEscrowedCredentials
Write-Host "  Total escrowed records         : $($escrowed.Count)"

Write-Host "Pulling Intune Windows inventory..."
$intuneDevices = Get-AllIntuneWindowsDevices
Write-Host "  Total Windows devices in Intune: $($intuneDevices.Count)"

# Build lookup tables for cross-reference
$escrowByName = @{}
foreach ($e in $escrowed) {
  $escrowByName[$e['deviceName']] = $e
}

$intuneByName = @{}
foreach ($d in $intuneDevices) {
  $intuneByName[$d['deviceName']] = $d
}

# Union of both sources so stale escrow records also surface in the report
$allNames = @(($escrowByName.Keys) + ($intuneByName.Keys)) | Select-Object -Unique | Sort-Object

Write-Host ""
Write-Host "Processing $($allNames.Count) unique device names..."

$eligibilityVersion = [version]$EligibilityBuild
$report = New-Object System.Collections.Generic.List[object]

$processed = 0
foreach ($name in $allNames) {
  $processed++
  if (($processed % 10) -eq 0 -or $processed -eq $allNames.Count) {
    Write-Progress -Activity "Auditing devices" `
      -Status "$processed / $($allNames.Count) : $name" `
      -PercentComplete (($processed / $allNames.Count) * 100)
  }

  $intuneRecord = $intuneByName[$name]
  $escrowRecord = $escrowByName[$name]

  $osVersion = $null
  $isEligible = $false
  if ($intuneRecord -and $intuneRecord['osVersion']) {
    $osVersion = $intuneRecord['osVersion']
    try {
      $isEligible = ([version]$osVersion -ge $eligibilityVersion)
    } catch {
      $isEligible = $false
    }
  }

  $accountName = ""
  if ($escrowRecord -and -not $SkipAccountNameLookup) {
    $accountName = Get-LAPSAccountName -DeviceLocalCredentialId $escrowRecord['id']
  }

  $notes = ""
  if (-not $intuneRecord -and $escrowRecord) {
    $notes = "Stale escrow record - no matching Intune device"
  } elseif ($intuneRecord -and -not $escrowRecord) {
    $notes = "Not escrowing - investigate registration"
  }

  $report.Add([pscustomobject]@{
    DeviceName  = $name
    OsVersion   = $osVersion
    IsEligible  = $isEligible
    InIntune    = [bool]$intuneRecord
    IsEscrowing = [bool]$escrowRecord
    AccountName = $accountName
    LastBackup  = if ($escrowRecord) { $escrowRecord['lastBackupDateTime'] } else { "" }
    Notes       = $notes
  }) | Out-Null
}

Write-Progress -Activity "Auditing devices" -Completed

$report | Sort-Object DeviceName | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

# Summary
$inIntune     = ($report | Where-Object { $_.InIntune }).Count
$escrowing    = ($report | Where-Object { $_.IsEscrowing }).Count
$notEscrowing = ($report | Where-Object { $_.InIntune -and -not $_.IsEscrowing }).Count
$staleEscrow  = ($report | Where-Object { -not $_.InIntune -and $_.IsEscrowing }).Count
$eligible     = ($report | Where-Object { $_.IsEligible }).Count

Write-Host ""
Write-Host "============================================================="
Write-Host "Audit Summary"
Write-Host "============================================================="
Write-Host ("Devices in Intune                  : {0}" -f $inIntune)
Write-Host ("Devices escrowing LAPS             : {0}" -f $escrowing)
Write-Host ("Devices in Intune NOT escrowing    : {0}" -f $notEscrowing)
Write-Host ("Stale escrow records (no Intune)   : {0}" -f $staleEscrow)
Write-Host ("Devices eligible for WLapsAdmin    : {0}" -f $eligible)

if (-not $SkipAccountNameLookup) {
  $wlapsAdmin    = ($report | Where-Object { $_.AccountName -eq 'WLapsAdmin' }).Count
  $administrator = ($report | Where-Object { $_.AccountName -eq 'Administrator' }).Count
  Write-Host ("Account WLapsAdmin                  : {0}" -f $wlapsAdmin)
  Write-Host ("Account Administrator               : {0}" -f $administrator)
}

Write-Host "============================================================="
Write-Host "Report saved to: $ReportPath"
