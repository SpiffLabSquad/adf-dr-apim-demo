#requires -Version 5.1
<#
.SYNOPSIS
  Calls the single, unchanging APIM endpoint (Pattern 2) and shows which ADF region
  served the request and whether an automatic fallback occurred.
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-adf-dr-demo",
  [string]$HaUrl
)
$ErrorActionPreference = "Stop"
if (-not $HaUrl) {
  $HaUrl = az deployment group show -g $ResourceGroup -n main --query properties.outputs.haTriggerUrl.value -o tsv
}
Write-Host "Application endpoint (unchanged across failovers):"
Write-Host "  POST $HaUrl"
try {
  $resp = Invoke-WebRequest -Method POST -Uri $HaUrl -UseBasicParsing
  Write-Host ("Status         : {0}" -f $resp.StatusCode) -ForegroundColor Green
  Write-Host ("X-Served-Region: {0}" -f $resp.Headers["X-Served-Region"]) -ForegroundColor Yellow
  Write-Host ("X-Failover     : {0}" -f $resp.Headers["X-Failover"])
  Write-Host ("Body           : {0}" -f $resp.Content)
} catch {
  Write-Host "Request failed: $_" -ForegroundColor Red
}
