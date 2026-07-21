# ADF Cross-Region DR — Traffic Manager + APIM + Data Factory

A deployable reference demo that answers a real customer question:

> *"We trigger Azure Data Factory pipelines from Autosys using the ADF REST API. Can we
> put that behind Traffic Manager so it survives a regional outage?"*

**Short answer:** you don't put the ADF control-plane API itself behind Traffic Manager —
you put a thin **API Management (APIM)** façade in front of ADF, deploy that façade in **two
regions**, and let **Azure Traffic Manager** hand out one stable hostname with automatic
regional failover.

```
Autosys  ─▶  Traffic Manager  ─┬─(priority 1)─▶  APIM (Primary)   ─▶  Data Factory (Primary)
   one stable hostname         └─(priority 2)─▶  APIM (Secondary) ─▶  Data Factory (Secondary)
```

Autosys just does `POST https://<stable-name>/adf/trigger/<pipeline>`. It never touches
Azure AD tokens or region-specific URLs — APIM's **managed identity** calls ADF's `createRun`
API on its behalf. When the primary region is unhealthy, Traffic Manager's health probe fails
it out and the **same hostname** resolves to the secondary region.

> **This repo ships two patterns.** **Pattern 1** (above) uses **Traffic Manager** for
> regional *ingress* failover across two APIM gateways. **Pattern 2** keeps a **single APIM
> endpoint** and lets APIM route to whichever ADF region is *currently active* — no Traffic
> Manager and no application change. See
> [Pattern 2 — APIM-only active-region routing](#pattern-2--apim-only-active-region-routing-no-traffic-manager).

---

## Architecture

```mermaid
flowchart LR
    AJ["Autosys job<br/>(curl / REST)"]
    TM{{"Azure Traffic Manager<br/>Priority routing • HTTPS /adf/health probe"}}

    subgraph P["Primary region (East US 2)"]
        AP["APIM (Consumption)<br/>System-assigned identity"]
        FP["Data Factory<br/>DemoPipeline"]
        AP -- "createRun (MI token)" --> FP
    end

    subgraph S["Secondary region (West US 2)"]
        AS["APIM (Consumption)<br/>System-assigned identity"]
        FS["Data Factory<br/>DemoPipeline"]
        AS -- "createRun (MI token)" --> FS
    end

    AJ --> TM
    TM -- "priority 1 (active)" --> AP
    TM -. "priority 2 (failover)" .-> AS
```

### Request flow
1. Autosys calls `POST https://<traffic-manager-fqdn>/adf/trigger/DemoPipeline`.
2. Traffic Manager resolves the hostname to the **healthy, highest-priority** APIM gateway.
3. That APIM operation runs a policy that:
   - builds the ADF `createRun` URL for the requested pipeline,
   - attaches an ARM token from APIM's **system-assigned managed identity**
     (which holds **Data Factory Contributor** on the regional factory),
   - relays ADF's response and stamps `X-Served-Region` so you can see the active region.
4. ADF starts the pipeline run and returns a `runId`.

---

## Why not put ADF *directly* behind Traffic Manager?

`https://management.azure.com/.../factories/{name}/pipelines/{p}/createRun` is the **Azure
Resource Manager control plane** — a shared, global Microsoft endpoint. You can't front it
with your own Traffic Manager profile, and it already requires an Azure AD token per call.
The APIM façade gives you:

- a **stable, ownable hostname** you can point Traffic Manager (or Front Door) at,
- **credential isolation** — Autosys uses a simple key/secret, not Azure AD,
- a place to add **throttling, logging, IP allow-lists, request shaping**,
- clean **per-region failover** decoupled from ADF itself.

---

## Repository layout

```
infra/
  main.bicep                 # Orchestration (RG-scoped): 2x ADF, 2x APIM, RBAC, Traffic Manager
  main.parameters.json       # Sample parameters
  modules/
    dataFactory.bicep        # ADF + a dependency-free DemoPipeline (single Wait activity)
    apim.bicep               # APIM Consumption + MI + /trigger/{pipeline} + /health policies
    trafficManager.bicep     # Priority profile + HTTPS health probe + 2 external endpoints
    apimActiveRegion.bicep   # Pattern 2: adf-ha API + active-region named value + failover policy
policies/
  trigger-policy.xml         # Human-readable copy of the trigger operation policy
  health-policy.xml          # Human-readable copy of the health operation policy
  active-region-policy.xml   # Human-readable copy of the Pattern 2 active-region policy
scripts/
  deploy.{sh,ps1}            # Create RG + deploy
  demo.{sh,ps1}              # Pattern 1: trigger through Traffic Manager, print the serving region
  failover.{sh,ps1}          # Pattern 1: toggle the primary endpoint to prove failover
  demo-ha.{sh,ps1}           # Pattern 2: call the single APIM endpoint, print serving region
  switch-region.{sh,ps1}     # Pattern 2: flip the active-region flag (no app change)
  teardown.{sh,ps1}          # Delete everything (one resource group)
docs/
  architecture.md            # Deeper design notes + production hardening
```

---

## Prerequisites

- **Azure CLI** 2.60+ and **Bicep** (`az bicep install`)
- Signed in: `az login` and `az account set --subscription "<name-or-id>"`
- Role: **Owner** or **User Access Administrator** on the subscription/RG
  (needed to grant APIM's identity **Data Factory Contributor**)
- Providers registered (the deploy handles this if you haven't):
  ```bash
  az provider register -n Microsoft.ApiManagement
  az provider register -n Microsoft.DataFactory
  az provider register -n Microsoft.Network
  ```

---

## Deploy

```bash
# bash
export PUBLISHER_EMAIL="you@contoso.com"
./scripts/deploy.sh
```
```powershell
# PowerShell
.\scripts\deploy.ps1 -PublisherEmail you@contoso.com
```

APIM **Consumption** tier provisions in a few minutes (vs ~30–45 min for Developer/Premium),
which keeps this demo fast and cheap. The deploy prints outputs including
`trafficManagerFqdn` and both APIM hostnames.

---

## Run the demo

```bash
./scripts/demo.sh
```
```powershell
.\scripts\demo.ps1
```

Expected output (abridged) — note `X-Served-Region`:

```
 Traffic Manager hostname : adfdr-xxxx.trafficmanager.net
 Active APIM gateway      : apim-adfdr-pri-xxxx.azure-api.net
POST https://apim-adfdr-pri-xxxx.azure-api.net/adf/trigger/DemoPipeline
HTTP/1.1 200 OK
X-Served-Region: eastus2
X-Served-Factory: adf-adfdr-pri-xxxx
{"runId":"e1f2...."}
```

## Demonstrate failover

```bash
./scripts/failover.sh fail     # disable the primary Traffic Manager endpoint
./scripts/demo.sh              # now served by the SECONDARY region
./scripts/failover.sh restore  # bring primary back
```
```powershell
.\scripts\failover.ps1 -Action fail
.\scripts\demo.ps1
.\scripts\failover.ps1 -Action restore
```

After failover, `X-Served-Region` flips to `westus2` and the pipeline runs in the
secondary factory — same client, same hostname, zero Autosys changes.

> The scripts disable the Traffic Manager **endpoint** to make failover instant and
> scripted. In a real outage, the **HTTPS `/adf/health` probe** fails on its own and
> Traffic Manager withdraws the endpoint after `toleratedNumberOfFailures` (default 3).

---

## Pattern 2 — APIM-only active-region routing (no Traffic Manager)

Sometimes the requirement is: **don't change the application at all, and have APIM send the
request to the ADF region that is currently active.** This variant uses a **single APIM
endpoint** and moves the region choice *inside* APIM — no Traffic Manager.

```
Autosys ─▶ APIM   POST /adf-ha/trigger/{pipeline}
             │  reads named value  active-region = primary | secondary
             ├─ active  ─▶ Data Factory (active region)  → returns runId
             └─ on failure, auto-fallback ─▶ Data Factory (standby region)
```

- The app always calls the **same URL**: `https://<apim-host>/adf-ha/trigger/<pipeline>`.
- APIM reads an `active-region` **named value** and triggers that region's factory. If the
  call fails, the policy **automatically falls back** to the other region.
- Responses carry `X-Served-Region` (`primary`/`secondary`) and `X-Failover` (`true`/`false`).
- The primary APIM's managed identity holds **Data Factory Contributor on both factories**.

**Fail over with a single operator action — no app change:**
```bash
./scripts/demo-ha.sh                  # served by primary
./scripts/switch-region.sh secondary  # flip the active-region flag (APIM-side)
./scripts/demo-ha.sh                  # same URL, now served by secondary
./scripts/switch-region.sh primary    # flip back
```
```powershell
.\scripts\demo-ha.ps1
.\scripts\switch-region.ps1 -Region secondary
.\scripts\demo-ha.ps1
.\scripts\switch-region.ps1 -Region primary
```

The `active-region` flag is meant to be flipped by an **operator** during a declared failover,
or by an **automated health runbook** that watches real data-plane / integration-runtime
health. (Remember: `createRun` returning `200` only means ARM *accepted* the run — a true
health signal should reflect IR/data health, not just trigger acceptance. The built-in
auto-fallback covers a hard `createRun` failure; the flag covers a *declared* failover.)

### Pattern 1 vs Pattern 2

| | Pattern 1 — Traffic Manager | Pattern 2 — APIM-only |
|---|---|---|
| Regional **ingress** failover | ✅ Two APIMs, DNS failover | ⚠️ No — the single APIM is a one-region ingress point |
| ADF **backend** selection | Each APIM hits its own factory | One APIM picks the active factory + auto-fallback |
| App change on failover | None (same TM hostname) | None (same APIM hostname) |
| External router | Traffic Manager (or Front Door) | None |
| Best when | You must survive losing a whole region end-to-end | You want APIM to steer to the active ADF and can accept a single-region APIM (or add Premium multi-region) |

> **Combine them for full DR:** run Pattern 2's active-region routing on an APIM that is itself
> multi-region — either **APIM Premium multi-region** (one hostname, gateways in N regions, no
> Traffic Manager to manage) or the two-APIM + Traffic Manager ingress from Pattern 1 — for
> resilient ingress **and** active-region backend selection.

---

## From demo to production

This repo keeps the demo **cheap, fast, and credential-free**. For a production rollout,
tighten these (see [`docs/architecture.md`](docs/architecture.md) for detail):

| Area | Demo | Production |
|---|---|---|
| **Stable hostname / TLS** | Clients resolve the TM CNAME to the active `*.azure-api.net` host | Put a **customer-owned custom domain** (e.g. `adf.contoso.com`) on **both** APIM instances with the **same TLS cert**, then CNAME it to the Traffic Manager FQDN. Clients use one name with a valid cert. |
| **APIM tier** | Consumption (fast/cheap) | **Premium** (multi-region, VNet integration, SLA) or Developer for non-prod |
| **Auth to APIM** | `subscriptionRequired: false` (open) | Require a **subscription key**, client cert (mTLS), or OAuth; restrict source IPs to the Autosys hosts |
| **L7 vs DNS failover** | Traffic Manager (DNS) | Traffic Manager is ideal for API/non-HTTP-content failover. If you want **L7 host-header rewrite + managed TLS + faster failover**, consider **Azure Front Door** in front of the two APIM gateways instead. |
| **Data-tier DR** | Not included (pipeline has no data deps) | The real DR boundary is your **data + integration runtimes**: geo-redundant storage (GRS/RA-GRS), SQL failover groups, Key Vault replication, and **Self-hosted IR in HA (2+ nodes)**. ADF itself is redeployable code — keep it in Git/CD. |

---

## Security notes

- The demo API is **unauthenticated** for simplicity. **Do not** leave `subscriptionRequired: false`
  in production — require a key/cert/OAuth and lock down source IPs.
- APIM uses a **system-assigned managed identity** scoped to **Data Factory Contributor** on
  **only** its regional factory — least privilege, no secrets in Autosys.
- No credentials are stored in this repo.

## Cost

Consumption APIM is pay-per-call (first 1M calls/month free), ADF has no standing cost for an
idle factory, and Traffic Manager is a few cents per million DNS queries plus a small
per-profile fee. A full demo run costs **pennies**. Run `teardown` when done:

```bash
./scripts/teardown.sh
```
```powershell
.\scripts\teardown.ps1
```

---

## License

MIT — see [LICENSE](LICENSE).
