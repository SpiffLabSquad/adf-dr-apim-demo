#!/usr/bin/env bash
# Deletes every resource created by the demo (one resource group).
set -euo pipefail
RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
echo "Deleting resource group '$RG' (all demo resources)..."
az group delete -n "$RG" --yes --no-wait
echo "Delete initiated (running in the background)."
