#requires -Version 5.1
<#
.SYNOPSIS
  Flips the APIM 'active-region' named value so the /adf-ha/trigger endpoint routes to a
  different ADF region — with NO change on the application side.
.EXAMPLE
  .\switch-region.ps1 -Region secondary
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("primary", "secondary")]
  [string]$Region,
  [string]$ResourceGroup = "rg-adf-dr-demo"
)
$ErrorActionPreference = "Stop"
$apim = az deployment group show -g $ResourceGroup -n main --query properties.outputs.primaryApimName.value -o tsv
Write-Host "Setting active-region = $Region on APIM '$apim' ..." -ForegroundColor Cyan
az apim nv update -g $ResourceGroup --service-name $apim --named-value-id active-region --value $Region -o none
Write-Host "Done. https://$apim.azure-api.net/adf-ha/trigger/<pipeline> now routes to the $Region factory (no app change)."
