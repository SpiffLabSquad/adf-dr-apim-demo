#!/usr/bin/env bash
# Calls the single, unchanging APIM endpoint (Pattern 2) and shows which ADF region
# served the request and whether an automatic fallback occurred.
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
HA_URL="${HA_URL:-$(az deployment group show -g "$RG" -n main --query properties.outputs.haTriggerUrl.value -o tsv)}"

echo "Application endpoint (unchanged across failovers):"
echo "  POST $HA_URL"
echo "--------------------------------------------------------------"
curl -sS -D - -o /tmp/ha_body.json -X POST "$HA_URL" \
  | grep -Ei 'HTTP/|X-Served-Region|X-Failover' || true
echo ""
echo "Response body (ADF createRun -> runId):"
cat /tmp/ha_body.json 2>/dev/null || true
echo ""
