<#
Find-DuplicateEntraDevices.ps1

Release Notes:
1) Pulls all Entra ID device objects with pagination via Microsoft Graph
2) Identifies devices with multiple Entra objects sharing the same displayName
3) Surfaces TrustType, registrationDateTime and alternativeSecurityIds for each duplicate
4) Critical for diagnosing LAPS escrow failures caused by conflicting hybrid registrations

Usage examples (SANITIZED):

Audit all devices for duplicate Entra objects:
.\Find-DuplicateEntraDevices.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000"

Inspect a specific device by name:
.\Find-DuplicateEntraDevices.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -DeviceName "CORP-PC-001"
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$TenantId,

  [Parameter(Mandatory=$false)]
  [string]$DeviceName,

  [Parameter(Mandatory=$false)]
  [string]$ReportPath = (Join-Path $PWD ("DuplicateEntraDevices_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")))
)

# ----------------------------
# Helpers
# ----------------------------

function Connect-EntraGraph {
  param([Parameter(Mandatory=$true)][string]$TenantId)
  Set-MgGraphOption -DisableLoginByWAM $true | Out-Null
  Connect-MgGraph -TenantId $TenantId -Scopes "Device.Read.All" -NoWelcome
}

function Get-AllEntraDevices {
  $allEntraDevices = New-Object System.Collections.Generic.List[object]
  $uri = "https://graph.microsoft.com/v1.0/devices"
  do {
    $r = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($d in $r.value) { [void]$allEntraDevices.Add($d) }
    $uri = $r.'@odata.nextLink'
  } while ($uri)
  return ,$allEntraDevices
}

function Get-EntraDeviceDetail {
  param([Parameter(Mandatory=$true)][string]$ObjectId)

  $u = "https://graph.microsoft.com/beta/devices/$ObjectId" + `
       "?`$select=displayName,deviceId,trustType," + `
       "registrationDateTime,alternativeSecurityIds," + `
       "approximateLastSignInDateTime,accountEnabled,createdDateTime"
  return Invoke-MgGraphRequest -Method GET -Uri $u
}

function ConvertTo-DeviceDiagnosticRow {
  param(
    [Parameter(Mandatory=$true)]$Detail,
    [Parameter(Mandatory=$true)][int]$ObjectNum
  )
  return [pscustomobject]@{
    DeviceName = $Detail['displayName']
    ObjectNum  = $ObjectNum
    DeviceId   = $Detail['deviceId']
    TrustType  = $Detail['trustType']
    Created    = $Detail['createdDateTime']
    Registered = if ($Detail['registrationDateTime']) { 'YES' } else { 'NO-PENDING' }
    HasAltSec  = if ($Detail['alternativeSecurityIds']) { 'YES' } else { 'NO' }
    LastSignIn = $Detail['approximateLastSignInDateTime']
    Enabled    = $Detail['accountEnabled']
  }
}

# ----------------------------
# Main
# ----------------------------

Connect-EntraGraph -TenantId $TenantId

Write-Host "Pulling all Entra device objects (paginated)..."
$allDevices = Get-AllEntraDevices
Write-Host "  Total Entra device objects: $($allDevices.Count)"
Write-Host ""

$report = New-Object System.Collections.Generic.List[object]

if ($DeviceName) {
  $matching = @($allDevices | Where-Object { $_['displayName'] -eq $DeviceName })

  if ($matching.Count -eq 0) {
    Write-Host "$DeviceName : not found in Entra" -ForegroundColor Yellow
    return
  }

  Write-Host "===== $DeviceName ($($matching.Count) Entra object$(if ($matching.Count -gt 1) { 's' })) ====="
  $num = 0
  foreach ($d in $matching) {
    $num++
    $detail = Get-EntraDeviceDetail -ObjectId $d['id']
    $row = ConvertTo-DeviceDiagnosticRow -Detail $detail -ObjectNum $num
    $report.Add($row) | Out-Null
    Write-Host ("  Object {0} : TrustType={1} Created={2} Registered={3} HasAltSec={4} Enabled={5}" -f `
      $num, $row.TrustType, $row.Created, $row.Registered, $row.HasAltSec, $row.Enabled)
  }
} else {
  $grouped = $allDevices | Group-Object { $_['displayName'] } | Where-Object { $_.Count -gt 1 }

  if (-not $grouped -or $grouped.Count -eq 0) {
    Write-Host "No duplicate Entra device objects found." -ForegroundColor Green
    return
  }

  Write-Host "Devices with multiple Entra objects: $($grouped.Count)"

  foreach ($g in $grouped) {
    Write-Host ""
    Write-Host "===== $($g.Name) ($($g.Count) objects) ====="
    $num = 0
    foreach ($d in $g.Group) {
      $num++
      $detail = Get-EntraDeviceDetail -ObjectId $d['id']
      $row = ConvertTo-DeviceDiagnosticRow -Detail $detail -ObjectNum $num
      $report.Add($row) | Out-Null
      Write-Host ("  Object {0} : TrustType={1} Registered={2} HasAltSec={3}" -f `
        $num, $row.TrustType, $row.Registered, $row.HasAltSec)
    }
  }
}

$report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Report saved to: $ReportPath"
