# Troubleshooting

An AKS deployment that fails on networking does not fail at validation. It provisions for fifteen to
twenty minutes and then returns `VMExtensionProvisioningError`, which tells you nothing about the
cause. This document turns that into a specific answer.

**Start here:**

```bash
./scripts/diagnose.sh -g rg-aks-prod
```

```powershell
./scripts/diagnose.ps1 -ResourceGroup rg-aks-prod
```

It works against a deployment that has already failed. It walks the nested deployment tree, extracts
the node VMSS custom script extension exit code, maps it through
[scripts/lib/cse-exit-codes.json](../scripts/lib/cse-exit-codes.json), then re-runs the route, NSG and
private DNS checks against what actually exists. Output is a pass/fail table plus JSON.

> **Read the findings in order.** They run from the deployment inwards. The first `FAIL` in the
> `cse`, `routes` or `dns` categories is the one to fix; everything after it is usually a
> consequence.

---

## 1. The custom script extension exit code

Every AKS node runs a bootstrap script. When it fails it exits with a specific code, and that code
names the failure precisely. `diagnose.*` extracts it for you; to get it by hand:

```bash
NODE_RG=$(az aks show -g rg-aks-prod -n aks-contoso-prod-wus3-01 --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "$NODE_RG" --query "[0].name" -o tsv)
az vmss get-instance-view --ids "$(az vmss list-instances -g "$NODE_RG" -n "$VMSS" --query "[0].id" -o tsv)"
```

Look for the `vmssCSE` extension status message; it contains `exit status <n>`.

The full table of 94 codes is
[scripts/lib/cse-exit-codes.json](../scripts/lib/cse-exit-codes.json) — it is the single source of
truth, read by both diagnose scripts, and deliberately not duplicated here. These are the ones you
will actually see:

| Code | Name | What it really means | Fix |
| --- | --- | --- | --- |
| **50** | `ERR_OUTBOUND_CONN_FAIL` | No outbound connectivity at all. The classic UDR, firewall or NSG misconfiguration. | Check the `0.0.0.0/0` route's next hop, that the firewall exists and has the AKS rules, and that no NSG denies outbound 443. |
| **51** | `ERR_K8S_API_SERVER_CONN_FAIL` | Name resolved, TCP 443 refused or dropped. | Firewall rule, private endpoint state, or NSG. On `aks-public-authorized-ip`, the egress IP is not in the allowlist. |
| **52** | `ERR_K8S_API_SERVER_DNS_LOOKUP_FAIL` | Could not resolve the API server name. On a private cluster the private DNS zone is not linked to the node VNet. | Link `privatelink.<region>.azmk8s.io` to the node VNet. |
| **53** | `ERR_K8S_API_SERVER_AZURE_DNS_LOOKUP_FAIL` | Azure DNS itself was unreachable. | Custom DNS servers on the VNet that cannot forward to `168.63.129.16`. Add the forwarder or remove the custom DNS. |
| **42** | `ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT` | Timed out on `packages.microsoft.com`. | Allowlist it. |
| **41** | `ERR_CNI_DOWNLOAD_TIMEOUT` | Timed out downloading CNI plugins. | Allowlist `packages.aks.azure.com` **and** `acs-mirror.azureedge.net`. |
| **31** | `ERR_K8S_DOWNLOAD_TIMEOUT` | Timed out downloading Kubernetes binaries. | Same two endpoints. |
| **33, 35, 36, 37** | image pull timeouts | Almost always MCR is unreachable. | Allowlist `mcr.microsoft.com` and `*.data.mcr.microsoft.com`. Note the wildcard — allowing only `mcr.microsoft.com` fails on the data plane. |
| **99** | `ERR_APT_UPDATE_TIMEOUT` | Cannot reach the distro archive. | Allowlist the endpoints for your `osSku`. |
| **9** | `ERR_APT_INSTALL_TIMEOUT` | Same cause, later stage. | Same. |
| **124** | `CSE_GLOBAL_TIMEOUT` | The whole script hit its 15-minute limit. | **Partial** block or slow egress: everything succeeds eventually but not fast enough. See below. |
| **173, 210, 234** | IMDS failures | Something is blocking `169.254.169.254`. | Remove the NSG rule, route or proxy config that intercepts link-local. IMDS must never be routed through a firewall. |
| **215** | `ERR_DNS_HEALTH_FAIL` | Node DNS health check failed. | Resolver cannot answer for the root domain or the target domain. |

### About 124 specifically

`timeout -k5s 15m /bin/bash /opt/azure/containers/provision.sh` wraps the whole bootstrap, with an
internal soft budget around 780 seconds. Exit 124 means the path is not *blocked* but is slow enough
that the sum of downloads exceeded the budget. Causes, in the order they turn up:

- A firewall with per-connection inspection (Premium tier with TLS inspection) on a path sized for
  far less traffic.
- SNAT port exhaustion on `loadbalancer` egress. Switch to `natgateway`.
- A partially correct allowlist where one endpoint retries to its own timeout before falling back.

### Logs on the node

If you have SSH or `az vm run-command` access:

| Path | Contents |
| --- | --- |
| `/var/log/azure/cluster-provision.log` | The main bootstrap log. Start here. |
| `/var/log/azure/<service>-status.log` | Per-service status. |
| `/var/log/azure/Microsoft.Azure.Extensions.CustomScript/events/` | Structured extension events. |

```bash
az vm run-command invoke -g <node-rg> -n <vm> --command-id RunShellScript \
  --scripts "tail -n 200 /var/log/azure/cluster-provision.log"
```

---

## 2. Failure modes that are not a CSE exit code

### The deployment succeeded but `kubectl` cannot connect

On `aks-private-link`, this is almost always DNS rather than routing. The private endpoint is
reachable; the name does not resolve from where you are.

```bash
# Does the name resolve to a private address?
nslookup <cluster>.privatelink.<region>.azmk8s.io

# Is the zone linked to the VNet you are resolving from?
az network private-dns link vnet list -g <rg> -z privatelink.<region>.azmk8s.io -o table
```

Fix with `additionalVnetIdsToLink` (link the zone to your VNet) or `dnsForwardingRules` (forward the
suffix to the resolver). Pre-flight check `dns.zoneLinked` tests this before you deploy.

### Nodes lock themselves out of their own API server

Symptom: `aks-public-authorized-ip` never finishes; CSE exit 51.

Nodes reach the API server through the cluster **egress** IP, not from inside the VNet. If that IP is
not in `authorizedIpRanges`, the control plane refuses them. This template appends it automatically
for `natgateway` and `udr-firewall`. With `loadbalancer` the egress IP is not knowable in advance,
which is why that combination is discouraged for this architecture.

### Traffic disappears with no error

Check `firewallBypassCidrs`. Those ranges are routed to a virtual network gateway. If the VNet does
not have one, the route is a black hole — no rejection, no log, packets simply gone. Only set them
when an ExpressRoute or VPN gateway genuinely exists in that VNet.

The other cause is a deallocated or moved Azure Firewall. `outboundType=userDefinedRouting` sends
`0.0.0.0/0` to the firewall's **private** IP, and that address is not reserved across a
deallocate/allocate cycle — Azure may hand back a different one. A firewall that is paused, or that
came back on a new address, leaves the route pointing at nothing: image pulls hang, token refresh
fails, nodes drift to `NotReady`, and no resource reports an error.

```bash
# What the route says, versus where the firewall actually is
az network route-table route list -g "$RG" --route-table-name "$RT" \
  --query "[?addressPrefix=='0.0.0.0/0'].{prefix:addressPrefix,nextHop:nextHopIpAddress}" -o table
az network firewall show -g "$RG" -n "$FW" \
  --query "{state:provisioningState,privateIp:ipConfigurations[0].privateIPAddress}" -o table
```

An empty `ipConfigurations` array means the firewall is deallocated. `scripts/pause.sh --resume`
(or `pause.ps1 -Resume`) reattaches it and rewrites any route still pointing at the old address;
re-running `deploy.sh` for the architecture converges the same way, because the template derives the next
hop from the firewall resource itself.

### Asymmetric routing

Adding a route for the API server's public IP that bypasses the firewall, while return traffic comes
back through the firewall, causes silent drops. Do not add per-endpoint routes; let the default route
carry everything.

### Quota

Failures at minute 12 with `QuotaExceeded` or `SkuNotAvailable`. Pre-flight checks `quota.*` test regional
vCPU headroom for the chosen SKU and count.

A subtler variant: the SKU is available in the region but **restricted in one zone**. A pool
requesting `['1','2','3']` then fails. Pre-flight reports this, but note that `az vm list-skus` is
not self-consistent — the same query intermittently returns an empty `restrictions` array and hides a
real restriction. Pre-flight samples it repeatedly with `--all` for that reason. If you check by
hand, run it more than once.

To work around a restricted zone without editing the node pool blocks, set `AKS_NODE_ZONES` to the
zones that are actually usable — for example `export AKS_NODE_ZONES=2,3`. This is a per-subscription
entitlement, not a regional capability, so the parameter files keep `1,2,3` as the default.

### `RoleDefinitionDoesNotExist`

Managed and CSP tenants do not use the published built-in role GUIDs for every role. Hardcoding them
fails. `deploy.*` resolves all nine by display name at run time and passes them as parameters —
never put a role GUID in a template.

### Policy assignment fails during deploy

`deploy.*` creates the custom deny-public-IP definition at subscription scope. If the caller lacks
Resource Policy Contributor it **warns and continues** rather than failing, so a restricted operator
can still deploy the cluster. The assignment is simply skipped. Re-run with sufficient rights, or
pass `--skip-policy-definition` to make the intent explicit.

### `UserAssignedNATGatewayWithManagedVNetNotAllowed` on `aks-automatic`

Full message: *"Outbound type is userAssignedNATGateway but agent pool `hostedpool` is not using
custom VNet, which is not allowed."*

`hostedpool` is not a pool this repository declares. AKS Automatic **always** runs a managed system
node pool, and you cannot opt out of it. Unless you give that pool a subnet, AKS places it in an
AKS-managed VNet — at which point the cluster is no longer entirely inside your VNet, and every
outbound type except the managed load balancer is rejected.

The fix is `addressing.systemNodeSubnetPrefix` (minimum /26), which this repository wires into
`properties.hostedSystemProfile` — the ARM equivalent of `az aks create --system-node-subnet-id`.
Give that subnet the same NSG, route table and NAT gateway as the node subnet; it carries real
nodes, so its egress must follow the architecture's egress mode.

Note that `what-if` does **not** catch this. The conflict is evaluated by the AKS resource provider
at create time, not by ARM template validation.

Also note that `az aks show` does **not** render `hostedSystemProfile` — the CLI's object model is
older than the field, so it is silently dropped from the output and looks unset even when it is
applied. Verify against ARM directly:

```bash
az rest --method get --url "https://management.azure.com<cluster-resource-id>?api-version=2026-05-01" --query properties.hostedSystemProfile
```

### `... virtualNetworkLinks/link-<hash> is defined multiple times in a template`

A private DNS zone link or DNS forwarding ruleset link is named from `uniqueString(<vnet id>)`, so
listing the same VNet twice produces two resources with the same name and ARM rejects the **entire**
nested deployment with `InvalidTemplate`.

The usual cause is passing the cluster VNet in `AKS_ADDITIONAL_VNET_IDS` when the module already
links it. Both DNS modules now dedupe with `union()`, so this should not recur — but if you add a
link loop of your own, key it on a deduplicated list.

This failure is easy to misread. It is raised when the nested deployment is submitted, which happens
*after* the cluster has been created, so the resource group looks half-built: `az aks show` reports
`Succeeded` while the top-level deployment reports `Failed`. See below.

### A resource group looks deployed but the deployment failed

`az deployment group list` returns **nested** deployments alongside the top-level one. Sorting by
timestamp and taking the most recent will happily report `Succeeded` for a deployment that failed.
Filter to the top-level name:

```bash
az deployment group list -g <rg> -o json | jq -r '.[] | select(.name | startswith("aks-architectures-")) | "\(.name) \(.properties.provisioningState)"'
```

### `SubnetMissingRequiredDelegation` on a **re-deployment**

Full message: *"Subnet .../snet-pods requires any of the following delegation(s)
[Microsoft.ContainerService/managedClusters] to reference service association link
.../serviceAssociationLinks/AzureKubernetesService."*

This never happens on a first deployment, only on a re-run. When AKS attaches to a pod subnet it
adds a `Microsoft.ContainerService/managedClusters` delegation and a service association link to
that subnet. If the template does not declare the delegation, the next deployment submits the subnet
without it, Azure tries to remove a delegation the link still depends on, and the VNet update fails.

The template therefore declares the delegation explicitly. If you add subnets of your own that AKS
attaches to, declare their delegations too, or your templates will only be deployable once.

Confirm what the platform actually put on a subnet with:

```bash
az network vnet subnet show -g <rg> --vnet-name <vnet> -n <subnet> --query "{delegations:delegations[].serviceName, links:serviceAssociationLinks[].name}"
```

### Flux reconciles cleanly but every pod is `ImagePullBackOff`

Not a workload bug — a firewall rule. The registries the manifests reference are not on the
allowlist. See the FQDN table in [networking.md](networking.md#3-required-outbound-endpoints), and
prefer mirroring images into the ACR this repo deploys.

### `deploy` appears to hang after printing the cost estimate

It is waiting for an answer. When the estimate contains a line marked `!!`, the script asks for
confirmation before creating anything. In a pipeline, a cron job or any other context with no
terminal attached, that prompt has nobody to answer it.

Pass `--yes` (`-Yes` in PowerShell) to accept the estimate non-interactively. The estimate is still
printed, so the numbers remain on the record in the log.

### `AKS_COST_TIER is 'x'. Valid values: lean, standard, full`

The tier is validated before the parameters are resolved, so a typo stops the run immediately
rather than deploying something unintended. Tier names come from
[infra/params/cost-tiers.json](../infra/params/cost-tiers.json). Adding a tier there means adding it
to the validation list in both `scripts/deploy.ps1` and `scripts/deploy.sh` — CI checks that the two
agree.

### Re-deploying an old environment fails on `outboundType`

`aks-private-link` used to default to `udr-firewall` and now defaults to `natgateway`.
`outboundType` is immutable, so re-running against a cluster built under the old default is
rejected. Either pin the old shape with `export AKS_EGRESS=udr-firewall` or destroy and redeploy.
See [architectures.md](architectures.md#immutable-settings).

### Redeploy fails because the Key Vault name is still reserved

Symptom, after a successful `destroy`:

```
VaultAlreadyExists: The vault name 'kv-<...>' is already in use.
```

The vault name is derived from the resource group ID, so redeploying into a group of the same name
regenerates the same vault name — and Key Vault always soft-deletes, keeping that name reserved.

Check what is holding it:

```bash
az keyvault list-deleted --query "[].{name:name, purgeProtection:properties.purgeProtectionEnabled, purgeOn:properties.scheduledPurgeDate}" -o table
```

If `purgeProtection` is **false**, free the name:

```bash
az keyvault purge -n <vault-name> -l <region>
```

If it is **true** the name cannot be freed by anyone until `purgeOn` passes. Deploy into a
differently named resource group — the suffix is derived from the group ID, so a new group name
yields a new vault name. This is why `keyVaultPurgeProtection` defaults to off; see
[parameters.md](parameters.md#key-vault-purge-protection-and-redeploying).

---

## 3. Reproducing a failure deliberately

To test the diagnostic path itself, you need a deployment that fails **after** validation. Errors
caught at validation, such as a taken storage account name, create no deployment record at all and
there is nothing for `diagnose.*` to read.

What works: a subnet whose prefix falls outside its VNet address space, e.g. `10.200.0.0/24` in a
`10.99.0.0/24` VNet. It passes validation and fails at the network resource provider with
`NetcfgSubnetRangeOutsideVnet`, leaving real nested deployment records for the recursive walk to
find.

---

## 4. Interpreting pre-flight output

| Status | Meaning |
| --- | --- |
| `pass` | Verified. |
| `warn` | Worth reading. Often a degraded check — for example an API server FQDN that cannot be probed because the cluster does not exist yet. |
| `skip` | **The check never ran**, usually because a required parameter was absent. The failure mode it covers is still live. A run with skips is not a clean run. |
| `fail` | Blocks deployment. Exit code is non-zero. |

Machine-readable output is written to `./preflight-<architecture>.json` (override with `--json-out`), with
`results[]` entries carrying `id`, `category`, `status`, `message` and `remediation`. CI publishes it
as an artifact and renders the table into the job summary.

---

## 5. Escape hatches

| Flag | Effect |
| --- | --- |
| `--skip-preflight` | Deploys without the gate. Prints a prominent warning. In CI it also writes a warning annotation and a job summary explaining what was not verified. |
| `--skip-live-probe` | Runs pre-flight's static checks only, no throwaway VM. Appropriate for `--preview`. |
| `--skip-policy-definition` | Does not attempt to create the subscription-scope policy definition. |
| `--keep-probe-vm` | Leaves the pre-flight VM running so you can log in and investigate by hand. **Remember to delete it.** |

Skipping the gate is occasionally the right call. Doing it without knowing which checks you gave up
is not, which is why every escape hatch says so loudly.
