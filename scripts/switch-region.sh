#!/usr/bin/env bash
# Flips the APIM 'active-region' named value so the /adf/trigger endpoint routes
# to a different ADF region — with NO change on the application side.
#   ./switch-region.sh primary
#   ./switch-region.sh secondary
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
REGION="${1:-}"
if [ "$REGION" != "primary" ] && [ "$REGION" != "secondary" ]; then
  echo "Usage: $0 [primary|secondary]"; exit 1
fi

APIM="$(az deployment group show -g "$RG" -n main --query properties.outputs.apimName.value -o tsv)"
echo "Setting active-region = $REGION on APIM '$APIM' ..."
az apim nv update -g "$RG" --service-name "$APIM" --named-value-id active-region --value "$REGION" -o none
echo "Done. https://$APIM.azure-api.net/adf/trigger/<pipeline> now routes to the $REGION factory (no app change)."
