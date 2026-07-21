#!/usr/bin/env bash
# Triggers the ADF pipeline through the single APIM endpoint and shows which ADF
# region served it (active-region routing).
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
URL="${TRIGGER_URL:-$(az deployment group show -g "$RG" -n main --query properties.outputs.triggerUrl.value -o tsv)}"

echo "Application endpoint (unchanged across failovers):"
echo "  POST $URL"
echo "--------------------------------------------------------------"
curl -sS -D - -o /tmp/adf_body.json -X POST "$URL" \
  | grep -Ei 'HTTP/|X-Served-Region' || true
echo ""
echo "Response body (ADF createRun -> runId):"
cat /tmp/adf_body.json 2>/dev/null || true
echo ""
