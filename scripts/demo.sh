#!/usr/bin/env bash
# Triggers the ADF pipeline through Traffic Manager and shows which region served it.
# This mimics what Autosys would do: one stable hostname, no Azure credentials.
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
PIPELINE="${PIPELINE:-DemoPipeline}"
TM_FQDN="${TM_FQDN:-}"

if [ -z "$TM_FQDN" ]; then
  TM_FQDN="$(az deployment group show -g "$RG" -n main --query properties.outputs.trafficManagerFqdn.value -o tsv)"
fi

echo "=============================================================="
echo " Traffic Manager hostname : $TM_FQDN"

# Traffic Manager is DNS-based: its FQDN is a CNAME to the healthy, highest-priority
# endpoint. Resolve it to discover which regional APIM gateway is currently active,
# then call that host directly (so TLS/SNI matches the *.azure-api.net certificate).
ACTIVE_HOST=""
if command -v dig >/dev/null 2>&1; then
  ACTIVE_HOST="$(dig +short CNAME "$TM_FQDN" | sed 's/\.$//' | tail -1)"
fi
if [ -z "$ACTIVE_HOST" ] && command -v nslookup >/dev/null 2>&1; then
  ACTIVE_HOST="$(nslookup -type=cname "$TM_FQDN" 2>/dev/null | awk '/canonical name/ {print $NF}' | sed 's/\.$//' | tail -1)"
fi
[ -z "$ACTIVE_HOST" ] && ACTIVE_HOST="$TM_FQDN"

echo " Active APIM gateway      : $ACTIVE_HOST"
echo "=============================================================="
echo ""
echo "POST https://$ACTIVE_HOST/adf/trigger/$PIPELINE"
echo "--------------------------------------------------------------"
curl -sS -D - -o /tmp/adf_body.json -X POST "https://$ACTIVE_HOST/adf/trigger/$PIPELINE" \
  | grep -Ei 'HTTP/|X-Served-Region|X-Served-Factory' || true
echo ""
echo "Response body (ADF createRun -> runId):"
cat /tmp/adf_body.json 2>/dev/null || true
echo ""
