# Architectures

An architecture is a complete cluster shape: where the API server lives, how operators reach it, and which
Azure constructs are valid around it. `infra/architecture-matrix.json` is the machine-readable version of
this document; `main.bicep`, the deploy scripts and the CI workflow all read it, so the two cannot
drift.

Valid combinations are enforced at compile time. Asking for `aks-automatic` with `cni-podsubnet`
fails the build with a message, not at minute 18 of a deployment.

---

## aks-public

Public API server endpoint, no restriction.

| | |
| --- | --- |
| Creates a cluster | Yes |
| API server | Public IP, open to the internet |
| SKU | Base |
| Network profiles | `cni-overlay`, `cni-podsubnet`, `cni-overlay-cilium` |
| Egress | `loadbalancer`, `natgateway`, `udr-firewall` |
| Extra required params | none |

Anyone on the internet holding a valid Entra token for your tenant can reach the API server. Entra
authentication and Azure RBAC still apply, so this is not "unauthenticated", but the endpoint is
reachable and therefore attackable. **Use it for sandboxes and learning only.**

Choose it when you want the fewest moving parts and the environment holds nothing worth stealing.

---

## aks-public-authorized-ip

Public API server endpoint restricted to an explicit CIDR allowlist.

| | |
| --- | --- |
| Creates a cluster | Yes |
| API server | Public IP, filtered by `authorizedIpRanges` |
| SKU | Base |
| Network profiles | all three |
| Egress | all three |
| Extra required params | `authorizedIpRanges` |

The trap: nodes talk to their own API server through the cluster's *egress* IP. If you set an
allowlist and forget that IP, the nodes lock themselves out of the control plane and the cluster
never finishes provisioning. This template appends the egress IP automatically whenever egress is
`natgateway` or `udr-firewall`, and pre-flight fails if `authorizedIpRanges` is empty.

Note that the allowlist governs the *management* path only. Anyone can still open a TCP connection
to the endpoint; they are simply refused. Be clear about what this control is: **it bounds exposure
rather than providing privacy, and the endpoint remains on the internet.** For an OT or plant
platform that last point is usually the deciding factor — use a private architecture instead.

The other way it fails is drift. An administrator's address changes and they are locked out, or a
NAT address changes and automation breaks with no obvious cause. Keep the range list in source
control alongside the cluster definition so a change to it is reviewable.

Choose it for internet-facing SaaS, or for dev/test where operators and CI connect from a small,
stable set of ranges you can enumerate.

---

## aks-private-link

Private cluster. The API server is published through a Private Endpoint plus a private DNS zone
(`privatelink.<region>.azmk8s.io`).

| | |
| --- | --- |
| Creates a cluster | Yes |
| API server | Private Endpoint in your VNet, no public IP |
| SKU | Base |
| Network profiles | all three |
| Egress | all three |
| Extra required params | none |

`kubectl` needs two things, and people reliably provide only the first:

1. **IP reachability** to the private endpoint — same VNet, a peering, ExpressRoute, or VPN.
2. **DNS resolution** of the private FQDN. The private DNS zone must be linked to the VNet you
   resolve from, or a resolver in a linked VNet must be the forward target for that suffix.

Miss the second and `kubectl` returns a name-resolution error while the network path is perfectly
fine. Pre-flight checks `dns.zoneExists`, `dns.zoneLinked` and `dns.resolverInbound` verify the zone
is linked or forwarded before the cluster is built, and `deployBastion` plus the Azure DNS Private
Resolver deployed by this repo give you a working path out of the box.

Choose it when a written policy says the API server may not have a public endpoint and you are
extending an existing hub-and-spoke topology that already does DNS forwarding. For a new build with
no such precedent, choose `aks-private-vnet-integration` instead — it gives the same privacy without
the DNS dependency.

---

## aks-private-vnet-integration

Private cluster using **API Server VNet Integration**. The API server is projected into a delegated
subnet in your VNet. There is no Private Endpoint, no private DNS zone for the API server, and no
tunnel component on the nodes.

| | |
| --- | --- |
| Creates a cluster | Yes |
| API server | Injected into a delegated subnet in your VNet |
| SKU | Base |
| Network profiles | all three |
| Egress | all three |
| Extra required params | `addressing.apiServerSubnetPrefix` (minimum /28) |

The API server subnet must be delegated to `Microsoft.ContainerService/managedClusters` and must not
be shared with nodes or anything else. This template creates and delegates it for you.

Compared with `aks-private-link` this removes the DNS class of failure entirely and lowers API
latency, at the cost of one more subnet. A cluster can also be converted between public and private
without a rebuild, which Private Link does not allow.

**This is the model to adopt as the new enterprise standard**, particularly in hub-and-spoke with
on-premises administrative access, and it is the right default for an OT or plant platform where the
API server must not be on the internet. **Prefer it over `aks-private-link` for new private
clusters.** The main reason to pick Private Link instead is an existing standard that already
assumes the private endpoint and zone.

---

## aks-automatic

The AKS Automatic SKU. Azure manages node pools, scaling, upgrades, ingress and deployment
safeguards.

| | |
| --- | --- |
| Creates a cluster | Yes |
| API server | VNet integration |
| SKU | Automatic |
| Network profiles | `cni-overlay-cilium` **only** |
| Egress | all three, but all require a bring-your-own VNet |
| Extra required params | none |

Automatic hard-wires Azure CNI Overlay powered by Cilium and API Server VNet Integration. No other
network profile is accepted, which is why the matrix lists exactly one.

Two consequences worth knowing before you commit:

- **Node resource group lockdown** blocks VNet links on the platform-managed private DNS zone, so a
  private Automatic cluster also needs a bring-your-own private DNS zone.
- **Migration between Base and Automatic is not supported in either direction.** Choosing Automatic
  is a one-way decision for the life of that cluster.

Choose it when the team's Kubernetes expertise is thin and you would rather have opinionated
defaults that stay healthy than knobs nobody has time to tune.

---

## aks-arc-local

AKS on Azure Local, for plant floors and edge sites.

| | |
| --- | --- |
| Creates a cluster | Yes, on Azure Local hardware |
| API server | On-premises, static IP from the logical network's reserved range |
| Network profiles | `none` |
| Egress | `none` |
| Extra required params | `externals.customLocationId`, `externals.logicalNetworkId`, `externals.arcLocalSshPublicKey`, `arcLocalControlPlaneHostIp` |

The cluster runs on hardware in the building. Azure provides management and projection, not the data
path — which is why `networkProfile` and `egress` are forced to `none`. VNets, NAT Gateways, Azure
Firewall and Azure CNI modes are Azure-region constructs and simply do not exist here.

### Prerequisites this repository cannot create for you

Nothing running in an Azure region can bootstrap an Azure Local instance. Before deploying this
architecture you must already have:

1. A registered and Arc-enabled **Azure Local** instance.
2. An **Arc Resource Bridge** deployed on it.
3. A **custom location** pointing at that bridge → `AKS_CUSTOM_LOCATION_ID`.
4. A **logical network** with a reserved IP range for control plane and load balancer addresses →
   `AKS_LOGICAL_NETWORK_ID`.
5. An **SSH public key** to authorize on the nodes → `AKS_ARC_SSH_PUBLIC_KEY`.

If any are missing, `main.bicep` fails at compile time with the parameter name, and pre-flight fails
with the same message. Neither will let you get halfway through a deployment before finding out.

Choose it when workloads must keep running while the WAN is down.

---

## arc-attach-existing

Creates no cluster. Onboards a Kubernetes cluster you already run and layers Azure management on it.

| | |
| --- | --- |
| Creates a cluster | **No** |
| API server | Wherever it already is; outside Azure's control |
| Network profiles | `none` |
| Egress | `none` |
| Extra required params | `externals.existingConnectedClusterId` |

Onboarding is a **client-side** operation: `az connectedk8s connect` installs agents with Helm using
your kubeconfig. Azure Resource Manager has no path to your kubeconfig, so this cannot be done from
Bicep. The split is therefore:

```bash
# 1. Client side: onboard. Requires kubectl context on the target cluster.
./scripts/arc-onboard.sh --cluster-name plant-3-k8s -g rg-arc-plant3 -l westus3

# 2. The script prints this. Export it.
export AKS_EXISTING_CONNECTED_CLUSTER_ID='/subscriptions/.../connectedClusters/plant-3-k8s'

# 3. Resource Manager side: layer Azure Monitor, Defender, Azure Policy and Flux on top.
./scripts/deploy.sh --architecture arc-attach-existing -g rg-arc-plant3
```

Works with any CNCF-conformant distribution — on-premises, another cloud, k3s, OpenShift, EKS, GKE.

Choose it when the cluster exists, works, and you want one management plane across the estate rather
than a migration project.

---

## What each architecture costs

At the default `lean` cost tier, with the default two-node system pool and no user pool. USD list
prices for `westus3`; log ingestion counted at its cap, so these are upper bounds. Full breakdown in
**[costs.md](costs.md)**.

| Architecture | `lean` | `standard` | `full` | What drives the difference |
| --- | --- | --- | --- | --- |
| `aks-public` | ~$410 | ~$860 | ~$1,271 | No egress resource at all — `loadbalancer` is free. Neither Bastion nor the DNS resolver applies. |
| `aks-public-authorized-ip` | ~$447 | ~$897 | ~$1,447 | NAT Gateway. `full` adds Bastion but not the DNS resolver. |
| `aks-private-link` | ~$447 | ~$897 | ~$1,807 | Same, plus the DNS resolver at `full` — $360 of that gap. |
| `aks-private-vnet-integration` | ~$447 | ~$897 | ~$1,807 | Same. |
| `aks-automatic` | ~$849 | ~$1,254 | ~$1,665 | Three mandatory `Standard_D4ds_v6` nodes plus the hosted control plane and its SLA. |
| `aks-arc-local` | $0 in Azure | $0 in Azure | $0 in Azure | The hardware is yours. Arc management of the cluster itself is free. |
| `arc-attach-existing` | $0 in Azure | $0 in Azure | $0 in Azure | Same. Defender, if enabled, bills per vCore. |

**Adding `AKS_EGRESS=udr-firewall` adds roughly $917/month to any of the first five.** That is more
than everything else in this repo combined, and it bills from creation whether traffic flows or not.
The three private architectures default to `natgateway` precisely so you can evaluate the private API
server pattern without it. Choose the firewall only when the thing you are evaluating *is*
inspected, allowlist-only egress.

---

## Immutable settings

These cannot be changed after creation. Getting one wrong means rebuilding the cluster, so pre-flight
validates them before anything is deployed.

| Setting | Rule |
| --- | --- |
| `networkProfile` | Network plugin, plugin mode and dataplane are fixed. Switching requires a new cluster. |
| `addressing.serviceCidr` | Fixed at creation. |
| `addressing.dnsServiceIp` | Fixed at creation, must sit inside `serviceCidr`. |
| `addressing.podCidr` | Overlay pod CIDR is fixed at creation. |
| Pod subnet assignment | Fixed at creation. |
| Private cluster mode | `enablePrivateCluster` and the API server access mode cannot be toggled. |
| API server subnet | The VNet-integration subnet cannot be changed. |
| SKU (`Base` ↔ `Automatic`) | Not supported in either direction. |
| `egress` / `outboundType` | **Partially** mutable. `loadBalancer` → `userAssignedNATGateway` and `loadBalancer` → `userDefinedRouting` are supported. The reverse directions are not. |

The practical consequence: if you are unsure whether you will eventually need firewall-inspected
egress, start with `loadbalancer` — it is the only starting point that can migrate to either of the
other two. Everything else on this list, decide once.

`clusterSkuTier` is **not** on this list. Free and Standard can be switched on a running cluster, so
starting an evaluation on Free and moving to Standard when it becomes production is a supported
path, not a rebuild.

### Re-deploying an environment built before the cost defaults changed

`outboundType` is on the immutable list, and `aks-private-link` used to default to `udr-firewall`.
If you have a cluster from that era, re-running `deploy` with the current defaults will fail: it will
try to move an existing cluster from `userDefinedRouting` to `userAssignedNATGateway`, which AKS does
not allow. Either keep the old shape:

```bash
export AKS_EGRESS=udr-firewall
```

or destroy the resource group and redeploy on the cheaper path.
