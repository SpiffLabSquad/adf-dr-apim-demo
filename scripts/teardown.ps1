#requires -Version 5.1
<#
.SYNOPSIS
  Deletes every resource created by the demo (one resource group).
#>
[CmdletBinding()]
param([string]$ResourceGroup = "rg-adf-dr-demo")
$ErrorActionPreference = "Stop"
Write-Host "Deleting resource group '$ResourceGroup' (all demo resources)..." -ForegroundColor Yellow
az group delete -n $ResourceGroup --yes --no-wait
Write-Host "Delete initiated (running in the background)."
