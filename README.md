# aks-architectures

Opinionated Infrastructure-as-Code for Azure Kubernetes Service. You pick a **architecture** and a
**networking model**, set a handful of parameters, run one command, and get a working cluster.

The thing that makes this repo different from a template gallery is the **pre-flight gate**. Before
any cluster is created, a throwaway VM is placed in the intended node subnet and asked to prove it
can actually reach the endpoints AKS node bootstrap depends on. If it cannot, the deployment stops
with a specific message naming the endpoint and the reason, instead of stalling for 20 minutes and
failing with `VMExtensionProvisioningError`.

The second thing is that **it is cheap by default**. Nothing that bills by the hour is created
unless you ask for it — no Azure Firewall, no Bastion, no DNS Private Resolver, no paid control
plane. The deploy scripts itemise the bill before creating anything and stop for confirmation if an
expensive component is in the plan. See **[docs/costs.md](docs/costs.md)**.

---

## 1. Which architecture do I want?

| If your situation is… | Choose | Why |
| --- | --- | --- |
| Learning AKS, a sandbox, a throwaway demo | `aks-public` | Fastest path. No network prerequisites beyond default egress. The API server is on the internet, so **never use this for anything real**. |
| Internet-facing SaaS, or dev/test with a known, small, stable admin IP set | `aks-public-authorized-ip` | Keeps the public endpoint but bounds who can reach it. Be clear about what this buys: it **bounds exposure rather than providing privacy**, and the endpoint remains on the internet. It also fails quietly when the list drifts — an admin's address changes and they are locked out, or a NAT address changes and automation breaks with no obvious cause. Keep the ranges in source control next to the cluster. |
| **New enterprise build, hub-and-spoke, admins reach the cluster from on-premises** | **`aks-private-vnet-integration`** | **The model to adopt as the new enterprise standard.** The API server is injected into a delegated subnet in your VNet — same privacy as Private Link, without the private DNS dependency that causes most private-cluster failures. A cluster can also be converted between public and private without a rebuild. **Prefer this for anything new.** |
| Standard enterprise workload where Private Link is the established, already-understood pattern | `aks-private-link` | No public API endpoint; widely deployed and well understood. Costs you DNS plumbing, which is the part everyone gets wrong; the `dns.*` pre-flight checks verify it for you. Choose `aks-private-vnet-integration` instead unless you have a reason to stay on Private Link. |
| OT / plant network, industrial DMZ, or a written policy forbids a public API server | `aks-private-vnet-integration` | Choose this over authorized-IP ranges when the requirement is documented rather than merely preferred. An authorized-IP endpoint is still *on the internet* — it restricts access without satisfying a control that says the API server must not be reachable from it. Pair it with jump-host access (Bastion or AVD) at Level 3.5 and `--disable-local-accounts`. |
| Kubernetes outcomes without Kubernetes operations | `aks-automatic` | The Automatic SKU manages node pools, scaling, upgrades, ingress and safeguards. You give up knobs in exchange for a cluster that stays healthy without a platform team. |
| Plant floor or edge site that must keep running when the WAN drops | `aks-arc-local` | The cluster runs on Azure Local hardware in the building. Azure provides management, not the data path. |
| Disconnected or intermittently connected site | `aks-arc-local` | Same reasoning. Local control plane survives the link going down; Azure sees it again when connectivity returns. |
| Kubernetes clusters you already run — on-premises, another cloud, or a different distro | `arc-attach-existing` | Creates no cluster. Onboards what you have via Azure Arc and layers Azure Monitor, Defender, Azure Policy and Flux on top. |

Two of these choices are **immutable** and cannot be changed without rebuilding the cluster:
`outboundType` (the egress model) and the network plugin together with the Service CIDR. Get them
right at creation. The `config.immutable` pre-flight warning lists the full set.

Full detail, including what is immutable in each: **[docs/architectures.md](docs/architectures.md)**.

### And which networking model?

| Concern | Choose | Notes |
| --- | --- | --- |
| Default. Conserves VNet address space | `cni-overlay` | Pod IPs come from a private overlay range and are **not** routable from the VNet or on-premises. |
| On-premises systems must reach pod IPs directly (some OT and legacy middleware do) | `cni-podsubnet` | Pods get real VNet IPs. Costs a lot of address space — size the pod subnet for `nodes × maxPods`. |
| You want eBPF, Cilium network policy, and higher throughput | `cni-overlay-cilium` | Required by `aks-automatic`. |

| Egress requirement | Choose | Notes |
| --- | --- | --- |
| Simplest | `loadbalancer` | Shared SNAT ports; the egress IP can change. |
| Predictable egress IP, heavy outbound connection counts | `natgateway` | Far larger SNAT port pool. Usually the right default. |
| Traffic must be inspected and logged, allowlist-only egress | `udr-firewall` | `outboundType=userDefinedRouting` with Azure Firewall as next hop. This is where most provisioning failures come from, and the reason pre-flight exists. **~$917/month** — opt in with `AKS_EGRESS=udr-firewall`, it is never created by default. |

---

## 2. How much will this cost?

The default cost tier, `lean`, deploys the architecture's network pattern and a working cluster and
nothing that bills by the hour on top. Two tiers above it add the observability and security stack.

| Tier | Roughly | What you get |
| --- | --- | --- |
| `lean` (default) | **~$410–850/month** | Free-tier control plane, 2 nodes, NAT Gateway, Basic registry, capped logs |
| `standard` | ~$860–1,250/month | Adds Defender for Containers, Container Insights, Managed Prometheus, Premium registry, the SLA |
| `full` | ~$1,270–1,810/month | Adds Managed Grafana, Bastion, DNS Private Resolver |

Per-architecture figures are in [docs/architectures.md](docs/architectures.md#what-each-architecture-costs).

Add an Azure Firewall to any of them and it becomes the largest line on the invoice by a wide
margin. `deploy.sh` prints an itemised estimate and asks for confirmation before creating anything
expensive:

```
!! Azure Firewall (Standard) + 1 public IP          $917 /mo  AKS_EGRESS=natgateway removes it
!! Azure Bastion (Basic)                            $139 /mo  AKS_COST_TIER=lean removes it
!! DNS Private Resolver (2 endpoints)               $360 /mo  AKS_COST_TIER=lean removes it
```

Every figure, every knob, and how to re-check the prices yourself: **[docs/costs.md](docs/costs.md)**.

---

## 3. Quick start

### Start here: let it walk you through it

```bash
make wizard          # or ./scripts/wizard.sh, or ./scripts/wizard.ps1
```

The wizard asks about ten questions and, for each one, tells you the minimum that works, what
Microsoft recommends, and what this repo recommends for your situation — including why those
sometimes differ. Pressing Enter always takes the recommendation, so you can hold Enter down and
still end up with a defensible cluster.

It writes a real parameter file you can keep and diff, compiles it, prices it, and only then asks
whether to deploy. It does not deploy anything itself: it hands the plan to `deploy.sh` with
`--param-file`, so the pre-flight gate, the cost gate and the governance proof all apply exactly as
they would to a curated architecture.

This is the recommended path for a first deployment, and the reason is not hand-holding. The
settings that matter most in AKS — the egress model, the network profile, the Service CIDR, whether
the API server is public — cannot be changed on a running cluster, and they are chosen in the first
ten minutes by someone who has not yet been told which ones are permanent. The wizard puts the
guidance at the point of decision instead of in a document nobody has open.

Use `--plan-only` to produce and price a plan without deploying it — useful for getting a change
approved before spending anything.

Full detail: **[docs/wizard.md](docs/wizard.md)**.

### Or drive it directly

If you already know what you want:

```bash
# 1. Pick an architecture and set the handful of inputs the params read from the environment.
export AKS_CUSTOMER=contoso
export AKS_LOCATION=westus3
export AKS_ADMIN_GROUP_OBJECT_IDS='<entra-group-object-id>'
export AKS_AUTHORIZED_IP_RANGES='203.0.113.0/24'      # only for aks-public-authorized-ip

# 2. Optional: how much to spend. lean is the default and needs no variable.
export AKS_COST_TIER=lean                             # lean | standard | full
export AKS_NODE_COUNT=1                               # 2 by default

# 3. Deploy. You get a cost estimate, then pre-flight, then the deployment.
./scripts/deploy.sh --architecture aks-private-vnet-integration -g rg-aks-prod -l westus3
```

[demo-env.ps1](demo-env.ps1) is a commented PowerShell template for the same variables. Dot-source
it once per shell (`. ./demo-env.ps1`) instead of exporting them by hand.

PowerShell is a first-class equivalent, not an afterthought — every script ships as a matched pair
and the two are diffed against each other:

```powershell
$env:AKS_CUSTOMER = 'contoso'
./scripts/deploy.ps1 -Architecture aks-private-vnet-integration -ResourceGroup rg-aks-prod
```

Preview without changing anything:

```bash
./scripts/deploy.sh --architecture aks-private-link -g rg-aks-prod --preview
```

Run pre-flight on its own, against a subnet that already exists:

```bash
./scripts/preflight.sh --architecture aks-private-link \
  --node-subnet-id /subscriptions/.../subnets/snet-nodes \
  --on-premises-cidr 10.10.0.0/16
```

Tear everything down, including role assignments, private DNS links and policy definitions:

```bash
./scripts/destroy.sh -g rg-aks-prod --architecture aks-private-link
```

Or stop the meter without losing the environment — stops the cluster and deallocates the firewall,
keeping the VNet, DNS and role assignments intact:

```bash
./scripts/pause.sh -g rg-aks-prod --architecture aks-private-link
./scripts/pause.sh -g rg-aks-prod --architecture aks-private-link --resume
```

`make help` lists the same operations if you prefer Make.

---

## 4. When a deployment fails

Do not read through the portal. Run:

```bash
./scripts/diagnose.sh -g rg-aks-prod
```

It walks the failed deployment tree, pulls the node VMSS custom script extension exit code, maps it
through [scripts/lib/cse-exit-codes.json](scripts/lib/cse-exit-codes.json), then re-runs the
route, NSG and private DNS checks against the cluster that actually exists. Output is a pass/fail
table plus JSON. The first `FAIL` in the `cse`, `routes` or `dns` categories is the one to fix; the
rest are usually consequences of it.

See **[docs/troubleshooting.md](docs/troubleshooting.md)**.

---

## 5. What gets deployed

Always, in every tier: a VNet with purpose-built subnets and NSGs, the egress path you chose, a
container registry, a Key Vault, private endpoints and private DNS zones, a Log Analytics workspace
with a hard daily ingestion cap, the Azure Policy add-on with a Kubernetes baseline, Microsoft Entra
integration with Azure RBAC, workload identity, the Key Vault secrets provider, and image cleaner.

Only when you raise the cost tier: Container Insights, Managed Prometheus, Managed Grafana, Defender
for Containers, a storage account, an Azure DNS Private Resolver, and Bastion. Only when you set
`AKS_EGRESS=udr-firewall`: an Azure Firewall. Flux is available on every architecture and enabled by
default only on `arc-attach-existing`.

Everything is toggleable through the `features` object, and the tiers in
[infra/params/cost-tiers.json](infra/params/cost-tiers.json) are just named sets of those toggles.
Nothing is named by hand — every resource name comes from
[infra/modules/naming/naming.bicep](infra/modules/naming/naming.bicep), so two environments never
collide.

---

## 6. Repository layout

```
infra/
  main.bicep                orchestrator; one architecture switch, no per-architecture copies
  architecture-matrix.json        single source of truth for which combinations are valid
  types.bicep               shared parameter contract
  subscription-policy.bicep custom deny-public-IP definition (subscription scope)
  modules/                  one concern per module
  params/                   one .bicepparam per architecture, plus cost-tiers.json and guidance.json
scripts/
  wizard.{sh,ps1}           guided interview; writes a plan, then deploys it via deploy.*
  preflight.{sh,ps1}        the network gate
  deploy.{sh,ps1}           cost estimate, then pre-flight, then deploy
  verify-policy.{sh,ps1}    proves the assigned Deny rules actually refuse an admission attempt
  destroy.{sh,ps1}          ordered teardown
  pause.{sh,ps1}            stop the meter without losing the environment
  diagnose.{sh,ps1}         post-mortem for a failed deployment
  arc-onboard.{sh,ps1}      client-side Arc onboarding for arc-attach-existing
  lib/                      shared functions, CSE exit code table, price table, wizard template
clusters/
  contoso-prod/            sample GitOps tree reconciled by Flux
docs/
  wizard.md architectures.md networking.md costs.md troubleshooting.md governance.md parameters.md
.github/workflows/
  validate.yml              build + lint, no credentials, safe for forks
  deploy.yml                OIDC deploy with pre-flight as a required gate
```

---

## 7. Deliberate omissions

**There is no Terraform copy of this, on purpose.** A parallel implementation would have to
re-encode `architecture-matrix.json`, the seven parameter files, and the architecture switch in `main.bicep`.
The two copies would drift, and the drift would show up as an architecture that deploys correctly in one
language and subtly wrong in the other — which is exactly the class of failure this repo exists to
prevent. One implementation, tested end to end, beats two that are each half-tested. If Terraform is
a hard requirement, generate the ARM JSON with `az bicep build` and wrap it in
`azurerm_resource_group_template_deployment`; the pre-flight scripts are language-agnostic and work
unchanged.

**Pre-flight is not implemented as an ARM deployment script.** Tenant policy in many managed and CSP
subscriptions forces `allowSharedKeyAccess=false` on storage accounts, which breaks
`Microsoft.Resources/deploymentScripts`. The checks run from the operator's shell and from CI
instead, where they can also be run standalone against an existing subnet.

---

## 8. Documentation

| Document | Contents |
| --- | --- |
| [WALKTHROUGH.md](WALKTHROUGH.md) | A suggested order for working through the repository end to end, from wizard to teardown. Start here if you are evaluating it. |
| [docs/wizard.md](docs/wizard.md) | The guided interview: what it asks, why each question matters, and the plan file it produces. |
| [docs/architectures.md](docs/architectures.md) | Each architecture in detail: what it builds, what it requires, what is immutable, and how to migrate. |
| [docs/costs.md](docs/costs.md) | The cost tiers, an itemised price table, and every knob for making a deployment cheaper. |
| [docs/networking.md](docs/networking.md) | Data-path diagrams per architecture, address planning, the required FQDN set, DNS behaviour. |
| [docs/parameters.md](docs/parameters.md) | Every parameter: default, allowed values, consequence of changing it, and whether it is immutable. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Failure modes, CSE exit codes, and what to do about each. |
| [docs/governance.md](docs/governance.md) | Policy baseline, RBAC model, the public-IP exception path. |
