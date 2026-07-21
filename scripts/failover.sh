#!/usr/bin/env bash
# Simulates a regional outage by toggling the PRIMARY Traffic Manager endpoint,
# then waits for the DNS TTL so a subsequent ./demo.sh routes to the secondary region.
#   ./failover.sh fail      # disable primary  -> traffic fails over to secondary
#   ./failover.sh restore   # re-enable primary -> traffic returns to primary
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-adf-dr-demo}"
ACTION="${1:-fail}"
PROFILE="$(az deployment group show -g "$RG" -n main --query properties.outputs.trafficManagerProfile.value -o tsv)"

case "$ACTION" in
  fail)
    echo "Simulating PRIMARY region outage: disabling the primary Traffic Manager endpoint..."
    az network traffic-manager endpoint update -g "$RG" --profile-name "$PROFILE" \
      -n primary --type externalEndpoints --endpoint-status Disabled -o none
    ;;
  restore)
    echo "Restoring PRIMARY region: re-enabling the primary Traffic Manager endpoint..."
    az network traffic-manager endpoint update -g "$RG" --profile-name "$PROFILE" \
      -n primary --type externalEndpoints --endpoint-status Enabled -o none
    ;;
  *)
    echo "Usage: $0 [fail|restore]"; exit 1 ;;
esac

echo "Waiting 35s for the 30s DNS TTL to expire so clients re-resolve..."
sleep 35
echo "Done. Run ./demo.sh again to see which region now serves traffic."
