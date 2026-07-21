#requires -Version 5.1
<#
.SYNOPSIS
  Triggers the ADF pipeline through the single APIM endpoint and shows which ADF region
  served it (active-region routing).
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-adf-dr-demo",
  [string]$TriggerUrl
)
$ErrorActionPreference = "Stop"
if (-not $TriggerUrl) {
  $TriggerUrl = az deployment group show -g $ResourceGroup -n main --query properties.outputs.triggerUrl.value -o tsv
}
Write-Host "Application endpoint (unchanged across failovers):"
Write-Host "  POST $TriggerUrl"
try {
  $resp = Invoke-WebRequest -Method POST -Uri $TriggerUrl -UseBasicParsing
  Write-Host ("Status         : {0}" -f $resp.StatusCode) -ForegroundColor Green
  Write-Host ("X-Served-Region: {0}" -f $resp.Headers["X-Served-Region"]) -ForegroundColor Yellow
  Write-Host ("Body           : {0}" -f $resp.Content)
} catch {
  Write-Host "Request failed: $_" -ForegroundColor Red
}
