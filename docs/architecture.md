# Architecture & design notes

This document expands on the [README](../README.md) with the reasoning, trade-offs, and
production-hardening guidance behind the demo.

## Components

| Resource | Type | Purpose |
|---|---|---|
| APIM | `Microsoft.ApiManagement/service` (Consumption) | One gateway exposing `POST /adf/trigger/{pipelineName}`. Holds a system-assigned managed identity and the `active-region` named value. |
| Data Factory (x2) | `Microsoft.DataFactory/factories` | Regional factories, each with a dependency-free `DemoPipeline` (single `Wait` activity). |
| Role assignment (x2) | `Microsoft.Authorization/roleAssignments` | Grants the APIM identity **Data Factory Contributor** on **both** factories. |

Everything is deployed into **one resource group** so teardown is a single `az group delete`.
Resources are regional but a resource group is just metadata — the region of each resource is
set per-module.

## The routing policy

The operation policy on `POST /adf/trigger/{pipelineName}`:

1. Reads the `{{active-region}}` named value into a variable.
2. Selects the factory for that region (primary or secondary).
3. `send-request` (with `authentication-managed-identity`) calls `createRun` on that factory.
4. Returns the factory's real status and body, plus an `X-Served-Region` header. There is no
   automatic cross-region retry — failover is driven by flipping the flag.

A human-readable copy lives in [`policies/active-region-policy.xml`](../policies/active-region-policy.xml).
The version deployed by `infra/modules/apim.bicep` substitutes `__SUB__`, `__RG__`,
`__PRIFACTORY__`, `__SECFACTORY__` and XML-escapes operators (`<`→`&lt;`, `"`→`&quot;`).

### Passing pipeline parameters

The demo policy sends an empty body (`<set-body>{}</set-body>`), so triggered pipelines run
with their default parameter values. To let callers pass parameters through to `createRun`,
relay the incoming request body instead — e.g. `<set-body>@(context.Request.Body.As<string>(preserveContent: true))</set-body>`
— and have Autosys POST a JSON object of pipeline parameters. `TestPipeline` demonstrates a
parameterized pipeline; with the default policy it uses the default `message` value.

## Managed identity & least privilege

APIM authenticates to ADF with its **system-assigned managed identity** via the
`authentication-managed-identity` policy (resource `https://management.azure.com/`). The identity
is granted **Data Factory Contributor** (`673868aa-7521-48a0-acc6-0f60742d39f5`) on **both**
factories — which is what lets a single gateway trigger either region. No secrets live in
Autosys, APIM, or this repo. For tighter scope, a custom role limited to
`Microsoft.DataFactory/factories/pipelines/createRun/action` (plus read) also works.

## Deciding the active region

The `active-region` named value is the single source of truth. Flip it with
`scripts/switch-region` or `az apim nv update`; the gateway picks up the change within seconds.
APIM triggers only the active region and returns its real response — there is no automatic
cross-region retry. Set the flag from an **operator** during a declared failover, or from an
**automated health runbook** that watches real data-plane / integration-runtime health.

Failover is intentionally flag-driven, not automatic: because `createRun` is not idempotent,
silently retrying the other region on a lost response could start the pipeline twice.

Note the subtlety: `createRun` returning `200` only means ARM **accepted** the run — it does not
prove the pipeline will succeed (a region's integration runtime or data tier could be down while
ARM is healthy). A production active-region signal should reflect **real data-plane / IR health**
(a canary pipeline or a customer health endpoint), not merely trigger acceptance.

## Resilient ingress (what a single APIM does *not* give you)

Moving region selection into APIM removes the need for an external router for **backend
selection** — but a single APIM instance is itself a **single-region ingress point**. If that
region is lost, nothing routes. To make the ingress resilient too:

- **APIM Premium multi-region** — one logical APIM with gateways in multiple regions behind a
  single hostname; Microsoft manages the regional routing. Run the same active-region policy on
  it for resilient ingress **and** active-region backend selection. (Premium is the main cost.)
- **Azure Front Door** in front of two APIM instances — L7 global entry point with managed TLS
  and host-header rewrite; each APIM runs the active-region policy.

Pick based on whether your requirement is "steer to the active ADF region" (a single APIM is
enough) or "survive losing an entire Azure region end-to-end" (add multi-region ingress).

## The real DR boundary: data + integration runtimes

The factory *definition* is redeployable code — keep it in Git and deploy with CI/CD, exactly as
this repo does. The parts that actually need a DR strategy are the **data plane** and
**connectivity**:

- **Storage:** GRS / RA-GRS; design pipelines to read/write the paired region on failover.
- **Databases:** SQL failover groups / geo-replication; repoint linked services in the standby factory.
- **Secrets:** Key Vault in each region with a secret-sync/replication strategy.
- **Self-hosted IR:** run it in **high availability** (2+ nodes); for cross-region resilience,
  stand up a second SHIR registered to the standby factory.

This demo intentionally uses a pipeline with **no data dependencies** so it deploys cleanly
anywhere and keeps the focus on the **APIM active-region trigger** pattern.

## Naming & idempotency

Globally-unique names (APIM) are derived from `uniqueString(resourceGroup().id)`, so redeploys
into the same resource group are idempotent and reuse the same hostname.
