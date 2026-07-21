#requires -Version 5.1
<#
.SYNOPSIS
  Simulates a regional outage by toggling the PRIMARY Traffic Manager endpoint.
.EXAMPLE
  .\failover.ps1 -Action fail      # fail over to secondary
  .\failover.ps1 -Action restore   # return to primary
#>
[CmdletBinding()]
param(
  [ValidateSet("fail","restore")]
  [string]$Action = "fail",
  [string]$ResourceGroup = "rg-adf-dr-demo"
)
$ErrorActionPreference = "Stop"
$profileName = az deployment group show -g $ResourceGroup -n main --query properties.outputs.trafficManagerProfile.value -o tsv

if ($Action -eq "fail") {
  Write-Host "Simulating PRIMARY region outage: disabling the primary Traffic Manager endpoint..." -ForegroundColor Yellow
  az network traffic-manager endpoint update -g $ResourceGroup --profile-name $profileName -n primary --type externalEndpoints --endpoint-status Disabled -o none
} else {
  Write-Host "Restoring PRIMARY region: re-enabling the primary Traffic Manager endpoint..." -ForegroundColor Cyan
  az network traffic-manager endpoint update -g $ResourceGroup --profile-name $profileName -n primary --type externalEndpoints --endpoint-status Enabled -o none
}

Write-Host "Waiting 35s for the 30s DNS TTL to expire so clients re-resolve..."
Start-Sleep -Seconds 35
Write-Host "Done. Run .\demo.ps1 again to see which region now serves traffic."
