#requires -Version 5.1
<#
.SYNOPSIS
  Triggers the ADF pipeline through the single APIM endpoint and shows which ADF region
  served it and how the region was chosen (per-request override vs the active-region flag).
.PARAMETER Region
  Optional. 'primary' or 'secondary' to select the region per-request (?region=). When omitted,
  APIM uses the operator-controlled active-region flag.
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-adf-dr-demo",
  [ValidateSet("primary", "secondary", "")]
  [string]$Region = "",
  [string]$TriggerUrl
)
$ErrorActionPreference = "Stop"
if (-not $TriggerUrl) {
  $TriggerUrl = az deployment group show -g $ResourceGroup -n main --query properties.outputs.triggerUrl.value -o tsv
}
$url = if ($Region) { "$TriggerUrl`?region=$Region" } else { $TriggerUrl }
Write-Host "Application endpoint (unchanged across failovers):"
Write-Host "  POST $url"
try {
  $resp = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing
  Write-Host ("Status         : {0}" -f $resp.StatusCode) -ForegroundColor Green
  Write-Host ("X-Served-Region: {0}" -f $resp.Headers["X-Served-Region"]) -ForegroundColor Yellow
  Write-Host ("X-Region-Source: {0}" -f $resp.Headers["X-Region-Source"])
  Write-Host ("Body           : {0}" -f $resp.Content)
} catch {
  Write-Host "Request failed: $_" -ForegroundColor Red
}

