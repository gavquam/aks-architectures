# Parameter reference

Every parameter accepted by [infra/main.bicep](../infra/main.bicep), with its default, allowed
values, and what changing it does to you. Types are defined in
[infra/types.bicep](../infra/types.bicep).

**Immutable** means the value is fixed for the life of the cluster. Changing it in a parameter file
and re-deploying does not migrate anything — it either errors or is silently ignored. Getting one
wrong means rebuilding.

## Where values come from

By default `deploy.*` uses `infra/params/<architecture>.bicepparam`, the curated file for that architecture.
Most values in it read from the environment — `readEnvironmentVariable('AKS_NODE_COUNT', '2')` and
so on — which is why the quick start is a handful of `export` lines.

The `addressing` block is the exception: it is written out literally rather than read from the
environment, because an address plan is a set of nine interdependent ranges and expressing that as
nine environment variables produces overlaps nobody notices until pre-flight fails.

To use a different address plan, supply your own parameter file:

```bash
./scripts/deploy.sh --architecture aks-private-link -g rg-aks-prod --param-file infra/params/my-plan.bicepparam
```
```powershell
./scripts/deploy.ps1 -Architecture aks-private-link -ResourceGroup rg-aks-prod -ParamFile infra/params/my-plan.bicepparam
```

The file must live in `infra/params/`, because a `.bicepparam` resolves its `using` target and its
`loadJsonContent()` paths relative to its own directory.

A supplied file is deployed exactly like a curated one — same cost gate, same pre-flight gate, same
post-deployment assertions — so there is no second, less-checked code path.

The [guided wizard](wizard.md) generates one of these for you and is the easiest way to get a
correct plan: `make wizard`.

---

## Identity and naming

| Parameter | Type | Default | Allowed | Consequence of changing |
| --- | --- | --- | --- | --- |
| `customer` | string | *required* | 2-8 lowercase letters or digits | Appears in every resource name. Capped at eight because a storage account name is capped at 24 and the other five segments spend 16 of them. Changing it renames everything, which means a new set of resources and an orphaned old set. |
| `environment` | `environmentType` | *required* | `dev`, `test`, `prod` | Part of every name, and drives environment tags. Same rename consequence. |
| `location` | string | `resourceGroup().location` | any region | For `aks-arc-local` this is where the Arc *projection* lives, not where the cluster runs. |
| `instance` | string | `'01'` | any short string | Lets a second environment sit beside the first without collisions. |
| `tags` | object | `{}` | any | Merged with the tags the template sets (`customer`, `environment`, `architecture`, `networkProfile`, `egress`, `managedBy`). |

Names are produced by [infra/modules/naming/naming.bicep](../infra/modules/naming/naming.bicep) as
`<abbreviation>-<customer>-<environment>-<geocode>-<instance>`, for example
`aks-contoso-prod-wus3-01`. Globally-unique names (registry, vault, storage) get a deterministic
suffix derived from the resource group ID. **Nothing is named by hand anywhere in this repository.**

---

## Shape

| Parameter | Type | Default | Allowed | Consequence of changing |
| --- | --- | --- | --- | --- |
| `architecture` | `architectureType` | *required* | the 7 architectures | **Immutable.** Determines API server placement and SKU. See [architectures.md](architectures.md). |
| `networkProfile` | `networkProfileType` | `cni-overlay` | `cni-overlay`, `cni-podsubnet`, `cni-overlay-cilium` | **Immutable.** Plugin, plugin mode and dataplane are fixed at creation. Ignored by the two Arc architectures. |
| `egress` | `egressType` | per architecture (`AKS_EGRESS`) | `loadbalancer`, `natgateway`, `udr-firewall` | **Partially immutable.** `loadbalancer` → `natgateway` and `loadbalancer` → `udr-firewall` are supported migrations. The reverse is not. `aks-public` defaults to `loadbalancer`, every other Azure architecture to `natgateway`; `udr-firewall` is never a default because it adds ~$917/month. Ignored by the two Arc architectures. |

Invalid combinations fail the **build**, not the deployment. `architecture-matrix.json` is the authority.

---

## Addressing

All fields of the `addressing` object are required. See
[networking.md](networking.md#2-address-plan) for sizing.

| Field | Immutable | Consequence |
| --- | --- | --- |
| `vnetAddressSpace` | no | Additional space can be added later; existing space cannot be removed while in use. |
| `nodeSubnetPrefix` | no | Undersize it and you cannot scale or surge during upgrade. Size for max nodes **plus** surge. |
| `systemNodeSubnetPrefix` | **yes** | Minimum /26. **Required by `aks-automatic`.** AKS Automatic always runs a managed system node pool; without this subnet that pool is created in an AKS-managed VNet and AKS then rejects every egress mode except the managed load balancer. Leave empty for all other architectures. |
| `podSubnetPrefix` | **yes** | Pod subnet assignment is fixed at creation. Only used by `cni-podsubnet`. |
| `apiServerSubnetPrefix` | **yes** | Minimum /28, delegated, not shared. Cannot be changed after creation. |
| `firewallSubnetPrefix` | no | Must be /26 or larger or Azure rejects the firewall. |
| `bastionSubnetPrefix` | no | Must be /26 or larger. |
| `privateEndpointSubnetPrefix` | no | One address per private endpoint. |
| `dnsResolverInboundPrefix` | no | Minimum /28, delegated to `Microsoft.Network/dnsResolvers`. |
| `dnsResolverOutboundPrefix` | no | Same. |
| `serviceCidr` | **yes** | Overlap with the VNet, a peered VNet or on-premises silently black-holes that range for every pod. Unfixable after creation. |
| `dnsServiceIp` | **yes** | Must be inside `serviceCidr` and must not be the network address. |
| `podCidr` | **yes** | Overlay only. Same overlap rule. |
| `onPremisesCidrs` | no | Not deployed anywhere — it is the list pre-flight checks `serviceCidr` and `podCidr` against. **Leaving it empty does not make the overlap safe, it makes it undetected.** |

---

## Node pools

`systemNodePool` and `userNodePool` share the `nodePoolType` shape.

| Field | Default in params | Consequence |
| --- | --- | --- |
| `vmSize` | `Standard_D4ds_v5` (`AKS_NODE_VM_SIZE`) | Avoid B-series for anything real. Production wants 4 vCPU or more. Check zone restrictions — SKUs are frequently unavailable in *some* zones of a region. |
| `count` | 2 (`AKS_NODE_COUNT`) | Initial count. With autoscaling on, only the starting point. Two nodes at `Standard_D4ds_v5` is roughly $336/month and is usually the largest line on the bill. |
| `minCount` / `maxCount` | `count` / `count` + 2 or 3 | Only meaningful when `enableAutoScaling` is true. `maxCount` must fit the node subnet and your vCPU quota. |
| `zones` | `['1','2','3']` (`AKS_NODE_ZONES`) | Empty pins the pool to a single regional placement. **Verify the SKU is available in every zone you list** — one restricted zone fails the pool. |
| `osSku` | `AzureLinux` | Determines which distro update endpoints the firewall opens. Changing it later replaces nodes. |
| `osDiskType` | `Ephemeral` (`AKS_OS_DISK_TYPE`) | Ephemeral is free but requires the VM SKU's cache disk to be at least `osDiskSizeGB`. If it is not, creation fails. `Managed` always works, is slower, and bills for the disk. |
| `osDiskSizeGB` | 128 | See above. |
| `enableAutoScaling` | `true` | — |

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `deployUserNodePool` | bool | `false` (`AKS_DEPLOY_USER_POOL`) | False puts workloads on the system pool alongside control-plane add-ons. Fine for an evaluation or sandbox, wrong for production — but a second pool roughly doubles the compute line, so it is opt-in. |
| `userNodePoolName` | string | `'user'` | — |
| `maxPodsPerNode` | int? (10–250) | unset | Unset lets the template pick: 110 for pod-subnet, 250 for overlay. **Immutable per pool.** With `cni-podsubnet` this multiplies your pod subnet requirement. |

---

## Cluster settings

| Parameter | Type | Default | Allowed | Consequence |
| --- | --- | --- | --- | --- |
| `kubernetesVersion` | string | `''` | any supported version | Empty lets AKS pick the current default — the safest choice for a first deployment. Pinning means you own the upgrade cadence. |
| `autoUpgradeChannel` | string | `stable` | `rapid`, `stable`, `patch`, `node-image`, `none` | `none` means you will eventually fall out of support. `rapid` means you get new minors quickly, including their regressions. |
| `nodeOsUpgradeChannel` | string | `NodeImage` | `None`, `Unmanaged`, `NodeImage`, `SecurityPatch` | `None` leaves nodes unpatched. `SecurityPatch` applies CVE fixes without a full image roll. |
| `maintenance` | `maintenanceType` | Sunday 02:00, 4h, UTC | `durationHours` 4–24 | The window auto-upgrades run in. `utcOffset` is an offset such as `-05:00`, not a time zone name. |
| `enableEncryptionAtHost` | bool | `false` | | Encrypts the temp disk and OS disk cache on the node host. **Requires the `EncryptionAtHost` subscription feature to be registered first**, otherwise deployment fails. |
| `nodeSshAccess` | string | `Disabled` | `LocalUser`, `Disabled` | `Disabled` is correct once Bastion or `az vm run-command` is available. Turning it off removes an entire lateral-movement path. |
| `clusterSkuTier` | string | `Free` | `Free`, `Standard` | Free and Standard are the same cluster up to 1,000 nodes; Standard adds a financially backed 99.95% API server SLA and bills ~$73/month for it. Production runs Standard. The Automatic SKU forces Standard regardless. |

---

## Cost controls

Set by the cost tier in [../infra/params/cost-tiers.json](../infra/params/cost-tiers.json) unless
overridden. Full detail in **[costs.md](costs.md)**.

| Parameter | Type | Default (`lean`) | Allowed | Consequence |
| --- | --- | --- | --- | --- |
| `containerRegistrySku` | string | `Basic` | `Basic`, `Standard`, `Premium` | Basic is the evaluation tier: Entra-authenticated but on the public endpoint. **Premium is required for the private endpoint and `publicNetworkAccess=Disabled`**, and costs roughly ten times as much. Below Premium the ACR private endpoint, zone redundancy and retention policy are all skipped automatically. |
| `grafanaSku` | string | `Essential` | `Standard`, `Essential` | Only read when `features.managedGrafana` is on. Essential is materially cheaper but carries no availability SLA and no per-user included quota. |
| `logAnalyticsRetentionDays` | int | `30` | 30–730 | 30 days is the free floor for most tables; longer bills per GB per month. |
| `logAnalyticsDailyQuotaGb` | int | `1` | ≥1, or `-1` | A hard ingestion cap and the backstop against a runaway log bill. **Once the cap is hit, telemetry is dropped silently until the next UTC day.** `-1` removes the cap — correct for production, dangerous for an evaluation. |
| `firewallSkuTier` | string | `Standard` | `Standard`, `Premium` | Only read when `egress` is `udr-firewall`. Premium adds TLS inspection and IDPS for about 40% more. |

---

## Access

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `adminGroupObjectIds` | string[] | `[]` | Entra group object IDs granted cluster-admin. Empty is only correct if you manage access entirely through separate role assignments — otherwise nobody can administer the cluster. |
| `authorizedIpRanges` | string[] | `[]` | **Required by `aks-public-authorized-ip`**; pre-flight fails if empty. The cluster egress IP is appended automatically when egress is `natgateway` or `udr-firewall`. Omitting that IP locks the nodes out of their own API server. |
| `deploymentPrincipalId` | string | `''` | Object ID of whoever is deploying. Granted cluster admin and Grafana admin so the result is usable immediately. `deploy.*` fills it in. |
| `deploymentPrincipalType` | string | `User` | `User`, `Group`, `ServicePrincipal`. Wrong value produces a role assignment that appears to succeed and grants nothing. |
| `roleIds` | `roleIdsType` | *required* | Role definition GUIDs. **Never hardcode these** — managed and CSP tenants do not use the published built-in GUIDs for every role, and a wrong GUID fails with `RoleDefinitionDoesNotExist`. `deploy.*` resolves all nine by display name at run time. |

---

## Features

Every field of `features` is a bool. **The defaults come from the cost tier**, not from the Bicep
type — the `.bicepparam` files build the object from
[../infra/params/cost-tiers.json](../infra/params/cost-tiers.json) and then override the entries a
particular architecture cannot support. The column below is the `lean` tier, which is what you get if you
set nothing. See [costs.md](costs.md) for the `standard` and `full` columns.

| Field | `lean` | Turning it on costs | Turning it off means |
| --- | --- | --- | --- |
| `defenderForContainers` | off | ~$7/vCore/month | No runtime threat detection. |
| `containerInsights` | off | log ingestion | No container logs or metrics in Log Analytics. |
| `managedPrometheus` | off | $0.16 per 10M samples | No metrics store. |
| `managedGrafana` | off | $6/user/mo or ~$66/mo | No dashboards. |
| `diagnosticSettings` | **on** | log ingestion, capped | No control-plane audit logs. Usually a compliance problem. |
| `azurePolicyAddon` | **on** | nothing | No in-cluster policy enforcement. See [governance.md](governance.md). |
| `workloadIdentity` | **on** | nothing | Pods cannot federate to Entra; you fall back to secrets. |
| `keyVaultSecretsProvider` | **on** | nothing | No CSI driver for mounting secrets. |
| `imageCleaner` | **on** | nothing | Vulnerable unused images accumulate on nodes. |
| `containerRegistry` | **on** | ~$5/mo at Basic | No ACR is created and `AcrPull` is not assigned. |
| `keyVault` | **on** | per-operation only | No vault is created. |
| `storage` | off | per-GB only | No storage account is created. |
| `privateDnsResolver` | off | **~$360/month** | No inbound/outbound DNS endpoints — on-premises cannot resolve Azure private zones and vice versa. Only needed if you are demonstrating hybrid DNS. |
| `policyAssignments` | **on** | nothing | The Azure Policy initiative is not assigned. |
| `bastion` | off | **~$139/month** | No browser-based access to nodes. `az aks command invoke` reaches a private API server for free. |
| `flux` | off | nothing | No GitOps. Requires `fluxGitRepositoryUrl`. On by default only for `arc-attach-existing`. |

---

## Network controls

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `firewallSkuTier` | string | `Standard` | `Premium` adds IDPS and TLS inspection and costs materially more. `Standard` is sufficient for the AKS egress allowlist. |
| `managementSourceRanges` | string[] | `[]` | Source ranges permitted to reach management ports through the NSGs, e.g. an on-premises jumpbox range. Empty means no management access is opened. |
| `additionalAllowedFqdns` | string[] | `[]` | Extra outbound FQDNs on 443 for workload dependencies. **Only applied when egress is `udr-firewall`** — with other egress modes there is no firewall to configure. |
| `firewallBypassCidrs` | string[] | `[]` | Ranges routed to a virtual network gateway instead of the firewall. **Only set these when the VNet actually holds an ExpressRoute or VPN gateway** — otherwise the route is a black hole and the traffic disappears with no error. |
| `additionalVnetIdsToLink` | string[] | `[]` | Extra VNets linked to the private DNS zones, typically a hub. Without this, `kubectl` from the hub cannot resolve a private cluster. |
| `dnsForwardingRules` | array | `[]` | Conditional forwarders for the DNS Private Resolver, in the shape [private-resolver.bicep](../infra/modules/dns/private-resolver.bicep) expects. |

---

## Governance

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `denyPublicIpPolicyDefinitionId` | string | `''` | Resource ID of the custom definition produced by [infra/subscription-policy.bicep](../infra/subscription-policy.bicep). Empty skips that assignment. `deploy.*` creates the definition and passes the ID **only for architectures whose parameter file declares this parameter** — see the architecture table in [governance.md](governance.md#1-policy-baseline). It **warns rather than fails** if the caller lacks Resource Policy Contributor, so a restricted operator can still deploy. |
| `policyEffect` | string | `Deny` | `Audit`, `Deny`, `Disabled`. `Audit` reports violations without blocking — the right setting while onboarding an existing estate. `Deny` blocks. |

---

## GitOps

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `fluxGitRepositoryUrl` | string | `''` | Empty disables Flux regardless of `features.flux`. |
| `fluxGitBranch` | string | `main` | — |
| `fluxGitPath` | string | `clusters/default` | Path within the repo. The Flux module reconciles `<path>/infrastructure` then `<path>/apps` — **both directories must exist** or the kustomizations fail. The sample tree is `clusters/contoso-prod`. |

---

## Externals

Fields of the `externals` object. Each is required only by the architectures that consume it; `main.bicep`
fails at compile time with the specific parameter name if one is missing.

| Field | Required by | Notes |
| --- | --- | --- |
| `existingVnetId` | optional, all Azure architectures | Bring your own VNet. Empty means this deployment creates it. |
| `existingNodeSubnetId` | optional | Bring your own node subnet. |
| `existingConnectedClusterId` | `arc-attach-existing` | Full resource ID of a `Microsoft.Kubernetes/connectedClusters`. Produced by [scripts/arc-onboard.sh](../scripts/arc-onboard.sh) — not a name, the whole ID. |
| `customLocationId` | `aks-arc-local` | Custom location on the Azure Local instance. |
| `logicalNetworkId` | `aks-arc-local` | `Microsoft.AzureStackHCI/logicalNetworks` the cluster attaches to. |
| `arcLocalSshPublicKey` | `aks-arc-local` | SSH public key authorized on control plane and worker nodes. |

| Parameter | Type | Default | Consequence |
| --- | --- | --- | --- |
| `arcLocalControlPlaneHostIp` | string | `''` | `aks-arc-local` only. Static API server address, taken from the logical network's **reserved** range. An address outside the reserve, or one already in use, fails at the Resource Bridge with an unhelpful message. |
| `arcLocalVmSize` | string | `Standard_A4_v2` | `aks-arc-local` only. Must be a size the Arc Resource Bridge offers. |

---

## Environment variables

The parameter files read from the environment so no secrets or tenant-specific IDs live in the repo,
and so making a deployment cheaper or larger never means editing a file.

### Identity and topology

| Variable | Feeds |
| --- | --- |
| `AKS_CUSTOMER` | `customer` |
| `AKS_LOCATION` | `location` |
| `AKS_ADMIN_GROUP_OBJECT_IDS` | `adminGroupObjectIds` (comma-separated) |
| `AKS_NODE_ZONES` | `systemNodePool.zones` and `userNodePool.zones` (comma-separated, default `1,2,3`) |
| `AKS_DEPLOYMENT_PRINCIPAL_ID` / `_TYPE` | `deploymentPrincipalId` / `deploymentPrincipalType` |
| `AKS_AUTHORIZED_IP_RANGES` | `authorizedIpRanges` (comma-separated) |
| `AKS_ADDITIONAL_VNET_IDS` | `additionalVnetIdsToLink` |
| `AKS_DENY_PUBLIC_IP_POLICY_ID` | `denyPublicIpPolicyDefinitionId` |
| `AKS_CUSTOM_LOCATION_ID`, `AKS_LOGICAL_NETWORK_ID`, `AKS_ARC_SSH_PUBLIC_KEY`, `AKS_ARC_VM_SIZE`, `AKS_ARC_CONTROL_PLANE_IP` | `externals` and the `arcLocal*` params |
| `AKS_EXISTING_CONNECTED_CLUSTER_ID` | `externals.existingConnectedClusterId` |
| `AKS_FLUX_GIT_URL`, `AKS_FLUX_GIT_BRANCH`, `AKS_FLUX_GIT_PATH` | the Flux params |
| `AKS_ROLE_*` (nine of them) | `roleIds`. Set automatically by `deploy.*`; you should never set these by hand. |

### Cost and size

Everything here has a working default, so a first deployment needs none of it. See
**[costs.md](costs.md)**.

| Variable | Default | Feeds |
| --- | --- | --- |
| `AKS_COST_TIER` | `lean` | The whole `features` object plus `clusterSkuTier`, `containerRegistrySku`, `grafanaSku` and both Log Analytics settings. `lean` \| `standard` \| `full`. |
| `AKS_EGRESS` | `natgateway`, or `loadbalancer` for `aks-public` | `egress`. **`udr-firewall` is the only thing that creates an Azure Firewall.** |
| `AKS_NODE_COUNT` | `2` | `systemNodePool.count`. The max count is derived from it. |
| `AKS_NODE_VM_SIZE` | `Standard_D4ds_v5` | `systemNodePool.vmSize` and `userNodePool.vmSize`. |
| `AKS_OS_DISK_TYPE` | `Ephemeral` | `systemNodePool.osDiskType`. Free, but needs a VM size with a local temp disk of at least `osDiskSizeGB` — set `Managed` if yours has none. |
| `AKS_DEPLOY_USER_POOL` | `false` | `deployUserNodePool`. A second pool roughly doubles the compute line. |
| `AKS_ACR_SKU` | tier default | `containerRegistrySku`, overriding the tier. |
| `AKS_GRAFANA_SKU` | tier default | `grafanaSku`, overriding the tier. |
| `AKS_FIREWALL_SKU` | `Standard` | `firewallSkuTier`. Only read when `AKS_EGRESS=udr-firewall`. |
| `AKS_KEYVAULT_PURGE_PROTECTION` | `false` | `keyVaultPurgeProtection`. See the warning below before turning it on. |

### Key Vault purge protection and redeploying

`keyVaultPurgeProtection` defaults to **off**, which is not the production-hardened choice, and the
reason is worth understanding.

The vault name is derived from the resource group ID, so tearing an environment down and redeploying
it into a group of the same name regenerates the **same** vault name. Key Vault always soft-deletes,
and a soft-deleted vault keeps its name reserved. Purge protection makes that reservation
**unbreakable** — the name cannot be freed early by anyone, including the subscription owner — so an
evaluation environment torn down on Monday cannot be rebuilt under the same group name until the
retention period expires.

So the repo defaults to:

| | purge protection off (default) | purge protection on |
| --- | --- | --- |
| Soft-delete retention | 7 days | 90 days |
| `destroy.*` can free the name | yes, via `--purge-key-vaults` | **no** |
| Redeploy same group name | immediately | only after retention expires |

Turn it on for anything holding real secrets:

```bash
export AKS_KEYVAULT_PURGE_PROTECTION=true
```

**It cannot be turned off again on an existing vault.** That is an Azure rule, not a repo one.

`aks-automatic` ignores the node variables — the Automatic SKU fixes the system pool at three
`Standard_D4ds_v6` nodes across three zones and manages scaling itself. `logAnalyticsRetentionDays`
and `logAnalyticsDailyQuotaGb` have no environment variable because Bicep's
`readEnvironmentVariable` cannot supply an integer default; edit `cost-tiers.json` instead.
