#requires -Version 5.1
<#
.SYNOPSIS
  Triggers the ADF pipeline through Traffic Manager and shows which region served it.
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-adf-dr-demo",
  [string]$Pipeline      = "DemoPipeline",
  [string]$TmFqdn
)
$ErrorActionPreference = "Stop"

if (-not $TmFqdn) {
  $TmFqdn = az deployment group show -g $ResourceGroup -n main --query properties.outputs.trafficManagerFqdn.value -o tsv
}

Write-Host "==============================================================" -ForegroundColor DarkGray
Write-Host " Traffic Manager hostname : $TmFqdn"

# Resolve the Traffic Manager CNAME to find the currently-active regional APIM gateway.
$cname = $null
try { $cname = (Resolve-DnsName -Name $TmFqdn -Type CNAME -ErrorAction Stop | Select-Object -First 1).NameHost } catch { }
if (-not $cname) { $cname = $TmFqdn }

Write-Host " Active APIM gateway      : $cname"
Write-Host "==============================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "POST https://$cname/adf/trigger/$Pipeline"
try {
  $resp = Invoke-WebRequest -Method POST -Uri "https://$cname/adf/trigger/$Pipeline" -UseBasicParsing
  Write-Host ("Status          : {0}" -f $resp.StatusCode) -ForegroundColor Green
  Write-Host ("X-Served-Region : {0}" -f $resp.Headers["X-Served-Region"]) -ForegroundColor Yellow
  Write-Host ("X-Served-Factory: {0}" -f $resp.Headers["X-Served-Factory"])
  Write-Host ("Body            : {0}" -f $resp.Content)
} catch {
  Write-Host "Request failed: $_" -ForegroundColor Red
  if ($_.Exception.Response) {
    $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host $sr.ReadToEnd()
  }
}
