#!/usr/bin/env bash
# Triggers the ADF pipeline through the single APIM endpoint and shows which ADF
# region served it and how the region was chosen (per-request override vs the flag).
# Optional first arg (or REGION env var): 'primary' | 'secondary' to select per-request
# via ?region=. When omitted, APIM uses the operator-controlled active-region flag.
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
REGION="${1:-${REGION:-}}"
URL="${TRIGGER_URL:-$(az deployment group show -g "$RG" -n main --query properties.outputs.triggerUrl.value -o tsv)}"
[ -n "$REGION" ] && URL="${URL}?region=${REGION}"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

echo "Application endpoint (unchanged across failovers):"
echo "  POST $URL"
echo "--------------------------------------------------------------"
curl -sS -D - -o "$BODY_FILE" -X POST "$URL" \
  | grep -Ei 'HTTP/|X-Served-Region|X-Region-Source' || true
echo ""
echo "Response body (ADF createRun -> runId):"
cat "$BODY_FILE" 2>/dev/null || true
echo ""
