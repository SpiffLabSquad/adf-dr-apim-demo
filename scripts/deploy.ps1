#requires -Version 5.1
<#
.SYNOPSIS
  Deploys the ADF cross-region DR demo into the current Azure subscription.
.EXAMPLE
  .\deploy.ps1 -PublisherEmail me@contoso.com
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup   = "rg-adf-dr-demo",
  [string]$PrimaryRegion   = "eastus2",
  [string]$SecondaryRegion = "westus2",
  [string]$PublisherEmail  = "you@example.com",
  [string]$RgLocation      = "eastus2"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "Creating resource group '$ResourceGroup' in $RgLocation ..." -ForegroundColor Cyan
az group create -n $ResourceGroup -l $RgLocation -o none

Write-Host "Deploying infrastructure (Consumption APIM x2 + ADF x2 + Traffic Manager)..." -ForegroundColor Cyan
az deployment group create `
  -g $ResourceGroup -n main `
  -f "$root\infra\main.bicep" `
  -p primaryRegion=$PrimaryRegion secondaryRegion=$SecondaryRegion publisherEmail=$PublisherEmail `
  -o none

Write-Host "`nDeployment outputs:" -ForegroundColor Green
az deployment group show -g $ResourceGroup -n main --query properties.outputs -o jsonc
