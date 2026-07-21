# Architecture & design notes

This document expands on the [README](../README.md) with the reasoning, trade-offs, and
production-hardening guidance behind the demo.

## Components

| Resource | Type | Purpose |
|---|---|---|
| Traffic Manager profile | `Microsoft.Network/trafficmanagerprofiles` | One global DNS hostname; **Priority** routing (active/passive) with an HTTPS health probe on `/adf/health`. |
| APIM (x2) | `Microsoft.ApiManagement/service` (Consumption) | Regional façade exposing `POST /adf/trigger/{pipelineName}` and `GET /adf/health`. Holds a system-assigned managed identity. |
| Data Factory (x2) | `Microsoft.DataFactory/factories` | Regional factory with a dependency-free `DemoPipeline` (single `Wait` activity). |
| Role assignment (x2) | `Microsoft.Authorization/roleAssignments` | Grants each APIM identity **Data Factory Contributor** on its regional factory. |

Everything is deployed into **one resource group** so teardown is a single `az group delete`.
Resources are regional but a resource group is just metadata — the region of each resource is
set per-module.

## Why Traffic Manager (and when to prefer Front Door)

**Traffic Manager** is a **DNS-based** global load balancer. It never sees your HTTP payload —
it just answers "which endpoint hostname should this client use right now?" That makes it a
great, low-cost fit for **API / non-web-content** failover like triggering ADF from Autosys.

Trade-off: because it's DNS-based, the client ultimately connects to the resolved backend
host, so **TLS/SNI and the `Host` header must match that backend's certificate**. Two ways to
satisfy that:

1. **Custom domain on APIM (production pattern).** Configure the *same* custom domain
   (e.g. `adf.contoso.com`) and TLS certificate on **both** APIM instances. CNAME
   `adf.contoso.com` → `<profile>.trafficmanager.net`. Clients use `adf.contoso.com`, the
   cert matches, and Traffic Manager silently picks the region.
2. **Resolve-then-call (this demo).** Without a custom domain, the demo scripts resolve the
   Traffic Manager CNAME to discover the active `*.azure-api.net` gateway and call it directly,
   so the wildcard APIM certificate validates. This proves the routing/failover behavior
   without requiring you to own a domain.

**Azure Front Door** is the L7 alternative. It terminates TLS at the edge, can **rewrite the
`Host` header** to each APIM's expected hostname, offers **managed certificates** for your
custom domain, and fails over faster than DNS TTL allows. If you want a single stable URL with
managed TLS and no custom-domain-on-APIM step, use Front Door in front of the two APIM
gateways instead of (or with) Traffic Manager.

## Managed identity & least privilege

APIM authenticates to ADF with its **system-assigned managed identity** via the
`authentication-managed-identity` policy (resource `https://management.azure.com/`). The
identity is granted **Data Factory Contributor** (`673868aa-7521-48a0-acc6-0f60742d39f5`) on
**only** its regional factory. No secrets live in Autosys, APIM, or this repo.

`createRun` requires write access to the factory; Data Factory Contributor is the built-in
role that covers it. If you split responsibilities further, a custom role limited to
`Microsoft.DataFactory/factories/pipelines/createRun/action` (plus read) is even tighter.

## Health probe & failover timing

Traffic Manager probes `HTTPS :443 /adf/health` every `30s`, tolerating `3` failures before
marking an endpoint degraded. Worst-case detection is roughly
`intervalInSeconds * (toleratedNumberOfFailures + 1)`. Client failover additionally waits for
the DNS `ttl` (30s here) to expire so resolvers re-query. Tune these down for tighter RTO, or
use Front Door for sub-DNS-TTL failover.

## The real DR boundary: data + integration runtimes

The factory *definition* is redeployable code — keep it in Git and deploy with CI/CD, exactly
as this repo does. The parts that actually need a DR strategy are the **data plane** and
**connectivity**:

- **Storage:** GRS / RA-GRS; design pipelines to read/write the paired region on failover.
- **Databases:** SQL failover groups / geo-replication; repoint linked services in the DR factory.
- **Secrets:** Key Vault in each region with a secret-sync/replication strategy.
- **Self-hosted IR:** run it in **high availability** (2+ nodes); for cross-region resilience,
  register nodes so at least one survives a regional loss, or stand up a second SHIR in the DR
  factory. Azure IR is regional but ADF can fail back to an auto-resolve/alternate region.

This demo intentionally uses a pipeline with **no data dependencies** so it deploys cleanly
anywhere and keeps the focus on the **Traffic Manager + APIM + ADF trigger** pattern.

## Naming & idempotency

Globally-unique names (APIM, Traffic Manager DNS label) are derived from
`uniqueString(resourceGroup().id)`, so redeploys into the same resource group are idempotent
and reuse the same hostnames.
