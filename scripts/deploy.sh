#!/usr/bin/env bash
# Deploys the ADF cross-region DR demo into the current Azure subscription.
# Override defaults with env vars, e.g. RESOURCE_GROUP=rg-foo PUBLISHER_EMAIL=me@x.com ./deploy.sh
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
PRIMARY="${PRIMARY_REGION:-eastus2}"
SECONDARY="${SECONDARY_REGION:-westus2}"
EMAIL="${PUBLISHER_EMAIL:-you@example.com}"
RG_LOCATION="${RG_LOCATION:-eastus2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

echo "Creating resource group '$RG' in $RG_LOCATION ..."
az group create -n "$RG" -l "$RG_LOCATION" -o none

echo "Deploying infrastructure (Consumption APIM + 2x ADF, active-region routing)..."
az deployment group create \
  -g "$RG" -n main \
  -f "$ROOT/infra/main.bicep" \
  -p primaryRegion="$PRIMARY" secondaryRegion="$SECONDARY" publisherEmail="$EMAIL" \
  -o none

echo ""
echo "Deployment outputs:"
az deployment group show -g "$RG" -n main --query properties.outputs -o json
