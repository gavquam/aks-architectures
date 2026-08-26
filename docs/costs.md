# Costs

This repo defaults to the cheapest configuration that still demonstrates the architecture honestly. Every
component that bills continuously is opt-in, the deploy scripts itemise the bill before creating
anything, and the components that dominate the bill require a typed confirmation.

If you only read one line: **`AKS_COST_TIER=lean` (the default) never creates an Azure Firewall, a
Bastion host, a DNS Private Resolver, a Premium container registry or a paid control plane.**

---

## 1. The cost tiers

One environment variable, `AKS_COST_TIER`, selects a bundle of feature flags and SKUs from
[infra/params/cost-tiers.json](../infra/params/cost-tiers.json).

| | `lean` (default) | `standard` | `full` |
| --- | --- | --- | --- |
| **Intended for** | Evaluating a network pattern | A realistic pilot | Showing the whole platform |
| **Typical total** | $410–850/month | $860–1,250/month | $1,270–1,810/month |
| AKS control plane | Free tier | Standard (SLA) | Standard (SLA) |
| Container registry | Basic | Premium | Premium |
| Managed Grafana | — | — | Standard |
| Log Analytics cap | 1 GB/day | 5 GB/day | 10 GB/day |
| Container Insights | off | on | on |
| Managed Prometheus | off | on | on |
| Defender for Containers | off | on | on |
| Storage account | off | on | on |
| DNS Private Resolver | off | off | on |
| Bastion | off | off | on |
| Diagnostic settings, Azure Policy add-on, workload identity, Key Vault CSI, image cleaner, Key Vault, policy assignments | on | on | on |

Flux is off in every tier for the Azure-region architectures; it is on for `arc-attach-existing`, which
exists to demonstrate GitOps.

```bash
export AKS_COST_TIER=lean          # default; omit it and you get this
./scripts/deploy.sh --architecture aks-private-vnet-integration -g rg-aks-eval
```

The tiers are data, not code. If you want Defender but not Prometheus, edit `cost-tiers.json` — no
Bicep changes required.

---

## 2. What the deploy script shows you

`deploy.sh` and `deploy.ps1` compile the resolved parameters, itemise everything that bills
continuously, and print it before the pre-flight gate runs:

```
COST ESTIMATE  (cost tier: lean)
USD list prices for westus3, captured 2026-06-01. An estimate, not a quote.
------------------------------------------------------------------------------
   System node pool, 2 x Standard_D4ds_v5           $336 /mo
   NAT Gateway + 1 public IP                         $37 /mo
   Container registry (Basic)                         $5 /mo  Premium buys the private endpoint
   Log Analytics ceiling, 1 GB/day cap               $69 /mo  a ceiling, not a run rate
------------------------------------------------------------------------------
   Estimated standing cost                          $447 /mo
```

Lines prefixed `!!` are the expensive ones. If any are present the script stops and asks for a
confirmation before it creates anything. `--yes` / `-Yes` skips the prompt for CI; `--preview` never
prompts because it creates nothing.

The estimate is deliberately conservative and deliberately incomplete:

- Log ingestion is counted **at its daily cap**, so the total is an upper bound. Real ingestion on an
  idle evaluation cluster is usually a small fraction of it.
- Data processed, egress bandwidth, storage capacity and per-request charges are named but not
  totalled. Guessing your traffic would produce a confident number that is wrong.
- Only the VM sizes this repo defaults to are priced. A size the table does not know is printed as
  `usage` rather than silently valued at zero.

---

## 3. Price table

USD pay-as-you-go list prices for `westus3`, captured 2026-06-01, from the public Azure retail price
API. Monthly figures assume 730 hours. Your agreement, currency, region and any reservations change
these. The machine-readable copy the scripts read is
[scripts/lib/cost-estimates.json](../scripts/lib/cost-estimates.json).

### The ones that dominate a bill

| Component | Unit price | Per month | Notes |
| --- | --- | --- | --- |
| **Azure Firewall (Standard)** | $1.25/hr + $0.02/GB | **~$917** | The single most expensive thing this repo can create. Only `AKS_EGRESS=udr-firewall` creates it. |
| Azure Firewall (Premium) | $1.75/hr + $0.02/GB | ~$1,282 | TLS inspection and IDPS. Rarely needed for an evaluation. |
| **DNS Private Resolver** | $180/endpoint/mo | **~$360** | Inbound and outbound endpoints bill separately, and the repo creates both. `full` tier only. |
| **Azure Bastion (Basic)** | $0.19/hr | **~$139** | `full` tier only. `az aks command invoke` gets you into a private cluster for free. |
| Node, Standard_D4ds_v5 | $0.23/hr | ~$168 each | Two nodes is the default. This is usually the largest line at the `lean` tier. |
| Node, Standard_D4ds_v6 | $0.25/hr | ~$183 each | What `aks-automatic` mandates. |
| Log Analytics ingestion | $2.30/GB | capped | The cap, not the meter, is what protects you. |

### The rest

| Component | Unit price | Per month | Notes |
| --- | --- | --- | --- |
| AKS control plane, Free tier | $0 | $0 | The same cluster as Standard up to 1,000 nodes, without the SLA. |
| AKS control plane, Standard tier | $0.10/hr | ~$73 | Buys a financially backed 99.95% API server SLA. |
| AKS Automatic hosted control plane | $0.16/hr | ~$117 | Not optional on `aks-automatic`. |
| NAT Gateway | $0.045/hr + $0.045/GB | ~$33 | Cheap, and the right default egress for most architectures. |
| Public IP, Standard static | $0.005/hr | ~$4 | One per NAT Gateway or firewall. |
| Container registry, Basic | $0.167/day | ~$5 | Entra-authenticated, public endpoint. |
| Container registry, Standard | $0.667/day | ~$20 | More included storage and throughput. |
| Container registry, Premium | $1.667/day | ~$51 | Required for the private endpoint and `publicNetworkAccess=Disabled`. |
| Managed Grafana, Essential | $6/user/mo | ~$6 | No availability SLA, no included user quota. |
| Managed Grafana, Standard | $0.09/hr | ~$66 | $0.04 node + $0.05 zone redundancy. |
| Private DNS zone | $0.50/mo each | ~$2 | Plus $0.40 per million queries. |
| Defender for Containers | ~$0.0095/vCore/hr | ~$7/vCore | Scales with every node you add. |
| Managed Prometheus | $0.16 per 10M samples | usage | Plus $0.10/million queries. |
| Key Vault, Standard | $0.03 per 10k operations | usage | Effectively free at evaluation volumes. |

### Re-checking these yourself

No authentication is required. Each entry in `cost-estimates.json` records the exact filter:

```bash
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Azure%20Firewall'%20and%20armRegionName%20eq%20'westus3'" | jq '.Items[] | {skuName, meterName, retailPrice, unitOfMeasure}'
```

```powershell
$f = [uri]::EscapeDataString("serviceName eq 'Azure Firewall' and armRegionName eq 'westus3'")
(Invoke-RestMethod "https://prices.azure.com/api/retail/prices?%24filter=$f").Items |
  Select-Object skuName, meterName, retailPrice, unitOfMeasure
```

---

## 4. Turning individual things off

Every knob is an environment variable, so making a deployment cheaper never means editing a
parameter file.

| Variable | Default | Effect |
| --- | --- | --- |
| `AKS_COST_TIER` | `lean` | `lean` \| `standard` \| `full`. See section 1. |
| `AKS_EGRESS` | `natgateway` (`loadbalancer` for `aks-public`) | Set to `udr-firewall` to add an Azure Firewall. **This is the only way to create one.** |
| `AKS_NODE_COUNT` | `2` | System node pool size. `1` works for a pure network-path test. |
| `AKS_NODE_VM_SIZE` | `Standard_D4ds_v5` | Any size with a local temp disk of at least the OS disk size. |
| `AKS_OS_DISK_TYPE` | `Ephemeral` | Free, but requires a VM size with a local temp disk. Set `Managed` if yours has none. |
| `AKS_DEPLOY_USER_POOL` | `false` | A second node pool doubles the compute line. |
| `AKS_ACR_SKU` | tier default | Force `Basic` even at `standard`/`full` if you do not need the private endpoint. |
| `AKS_GRAFANA_SKU` | tier default | `Essential` instead of `Standard`. |
| `AKS_FIREWALL_SKU` | `Standard` | Only relevant when `AKS_EGRESS=udr-firewall`. |

The two Log Analytics controls, `logAnalyticsRetentionDays` and `logAnalyticsDailyQuotaGb`, live in
`cost-tiers.json` rather than in an environment variable, because Bicep's
`readEnvironmentVariable` cannot supply an integer default.

`aks-automatic` ignores the node variables. The Automatic SKU fixes the system pool at three
`Standard_D4ds_v6` nodes across three zones and manages scaling itself — that is the deal you accept
when you choose it. `AKS_COST_TIER` still applies. The two Arc architectures create no Azure compute at
all, so only the Defender line is relevant to them.

A minimum-cost private cluster:

```bash
export AKS_COST_TIER=lean
export AKS_NODE_COUNT=1
export AKS_DEPLOY_USER_POOL=false
./scripts/deploy.sh --architecture aks-private-vnet-integration -g rg-aks-eval
```

---

## 5. Pausing instead of destroying

`scripts/pause.{sh,ps1}` stops the cluster and deallocates the firewall's public IP configuration,
which stops both compute and firewall hourly charges while leaving the VNet, subnets, NSGs, route
tables, DNS zones and role assignments exactly as they are. `resume` puts them back, including
rewriting the `VirtualAppliance` routes to the firewall's new private IP.

```bash
./scripts/pause.sh -g rg-aks-prod --architecture aks-private-link
./scripts/pause.sh -g rg-aks-prod --architecture aks-private-link --resume
```

Use this between demo sessions. Use `destroy` when you are finished — a paused environment still
bills for disks, public IP reservations and Log Analytics retention.

---

## 6. If an architecture is genuinely too expensive to evaluate

`aks-private-link` and `aks-private-vnet-integration` both default to `natgateway` egress, so you can
evaluate the private API server pattern for the price of a two-node cluster. You only need the
firewall when the thing you are evaluating **is** inspected, allowlist-only egress. If that is the
requirement, budget for it: at $917/month the firewall costs more than everything else in this repo
combined, and it bills from the moment it is created whether traffic flows through it or not.
