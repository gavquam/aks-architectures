# Governance

Two layers, deliberately separate: **Azure Policy** governs what can be created in the subscription
and resource group, and **Kubernetes RBAC through Entra** governs what can be done inside the
cluster. Neither substitutes for the other.

---

## 1. Policy baseline

Assigned at resource group scope by
[infra/modules/policy/policy-assignments.bicep](../infra/modules/policy/policy-assignments.bicep)
when `features.policyAssignments` is true.

| Assignment | Source | Effect |
| --- | --- | --- |
| Kubernetes clusters should use internal load balancers | Built-in | `policyEffect` |
| Deny public IP addresses outside an approved exception | Custom, this repo | `policyEffect` |

`policyEffect` accepts `Audit`, `Deny` or `Disabled` and defaults to `Deny`.

Not every architecture is governed:

| Architecture | Policy assignments | Why |
| --- | --- | --- |
| `aks-public` | None | A throwaway learning environment. Governing it teaches nothing and gets in the way. |
| `aks-public-authorized-ip` | Both | |
| `aks-private-link` | Both | |
| `aks-private-vnet-integration` | Both | |
| `aks-automatic` | Both | |
| `aks-arc-local` | None | The cluster is not an Azure resource; there are no Azure public IPs or load balancers to govern. |
| `arc-attach-existing` | None | Same, and the cluster already has its own governance. |

> `deploy.*` reads the architecture's parameter file to decide whether to create the subscription-scope
> definition at all. An architecture that does not assign the policy does not get a definition created for
> it — otherwise every run would leave an orphaned definition in the subscription and print a
> reassuring message about a control that was never in force.

### Onboarding an existing estate

Start with `Audit`. It records every violation without blocking anything, so you find out what your
environment actually does before you break it. Move to `Deny` once the noise is understood. Going
straight to `Deny` on a brownfield subscription reliably blocks something nobody knew was there.

### Internal load balancers

Enforced by the Azure Policy add-on, so it only takes effect where the add-on is enabled
(`features.azurePolicyAddon`). System namespaces are excluded by the definition; add more through
the module's exclusion parameter.

The practical effect: a `Service` of type `LoadBalancer` must carry
`service.beta.kubernetes.io/azure-load-balancer-internal: "true"`. This is why the sample ingress
controller in [clusters/contoso-prod](../clusters/contoso-prod) sets that annotation — a public
load balancer would allocate a public IP and trip both this policy and the next one.

### Deny public IP

A custom definition, because no built-in policy expresses "no public IPs except the ones the platform
legitimately needs".

Policy definitions cannot live at resource group scope, so
[infra/subscription-policy.bicep](../infra/subscription-policy.bicep) deploys the definition at
subscription scope separately, and `deploy.*` feeds the resulting ID into the main deployment.

Rule: deny creation of `Microsoft.Network/publicIPAddresses` unless the resource carries a
**non-empty `publicIpException` tag**.

```
IF   type == Microsoft.Network/publicIPAddresses
AND  tags['publicIpException'] is empty or absent
THEN <effect>
```

Parameters: `effect` (`Audit`/`Deny`/`Disabled`) and `exceptionTagName` (default `publicIpException`).

### The exception path

The platform egress addresses this repository creates — NAT Gateway, Azure Firewall, Bastion — are
tagged automatically. Everything else goes through the exception process:

1. Raise a change record justifying why a public IP is required and why the internal load balancer,
   NAT Gateway or Bastion path does not meet the need.
2. On approval, tag the resource with `publicIpException = <change record ID>`. The tag value must be
   non-empty; the policy does not inspect it further.
3. The tag is the audit trail. `az resource list --tag publicIpException` enumerates every exception
   in the subscription, which makes review a query rather than an archaeology project.

The tag mechanism is deliberately simple. Its job is to make an exception a **conscious, attributable
act** rather than an accident, not to be an approval workflow — that lives in your change system.

### If the deployer cannot create policy definitions

Creating a subscription-scope definition needs Resource Policy Contributor. Many operators do not
have it, and blocking the whole deployment on that would be wrong.

`deploy.*` therefore **warns and continues**: the definition is skipped,
`denyPublicIpPolicyDefinitionId` stays empty, and `main.bicep` skips that one assignment. Everything
else deploys. Re-run with sufficient rights to add it later, or pass `--skip-policy-definition` to
make the intent explicit and silence the warning.

### Proving enforcement, not just assignment

Assignment is not enforcement. The compliance blade reports that a `Deny` was assigned; it does not
report that anything is actually being refused. A rule that was assigned without the Azure Policy
add-on to enforce it, and a rule that is working perfectly, look identical there.

`verify-policy.*` closes that gap by attempting the violation:

```bash
./scripts/verify-policy.sh -g rg-aks-prod -n aks-contoso-prod-wus3-01
```
```powershell
./scripts/verify-policy.ps1 -ResourceGroup rg-aks-prod -ClusterName aks-contoso-prod-wus3-01
```

It runs inside the cluster via `az aks command invoke`, creates a throwaway namespace, tries to
create a `Service` of type `LoadBalancer` without the internal annotation, and reports what
happened. The namespace is torn down **before** the result is reported, unconditionally, so an
interrupted run never leaves a public IP behind.

| Outcome | Exit | Meaning |
| --- | --- | --- |
| `enforced` | 0 | Gatekeeper refused the admission. The control is real. |
| `pending` | 0 | The constraint has not synced yet. Not a failure — see below. |
| `notenforced` | **1** | The cluster accepted what its own policy forbids. A genuine finding. |
| `inconclusive` | 0 | The attempt failed for some other reason; the message says which. |

**Pending is expected on a fresh cluster.** The Azure Policy add-on polls roughly every fifteen
minutes, so the Gatekeeper constraint usually does not exist yet when a deployment finishes.
`deploy.*` therefore runs the proof with `--wait-minutes 0`, reports `PENDING`, and prints the
re-run command rather than blocking the deployment for fifteen minutes to learn something it
already expects. Run it again afterwards with a real wait:

```bash
./scripts/verify-policy.sh -g rg-aks-prod -n aks-contoso-prod-wus3-01 --wait-minutes 20
make verify-policy RG=rg-aks-prod CLUSTER=aks-contoso-prod-wus3-01
```

`notenforced` fails the deployment, because a cluster that accepts what its own policy forbids is a
finding worth stopping for. Everything else is reported and does not. Skip the check entirely with
`--skip-policy-proof` / `-SkipPolicyProof`.

The proof only runs when it can mean something: `main.bicep` emits `policyInClusterEnforcement`,
which is true only when the in-cluster policy assignments **and** the add-on that enforces them are
both present. Without that gate, a cluster with no assignments at all would report the same
`pending` as one that is merely still syncing.

---

## 2. Cluster access

Microsoft Entra integration with Azure RBAC is on for every architecture that creates a cluster. Local
accounts are the fallback path that gets abused, so authorization goes through Entra and Azure role
assignments instead.

| Who | Gets | How |
| --- | --- | --- |
| `adminGroupObjectIds` | Cluster admin | Entra group object IDs. Manage membership in Entra, not in the cluster. |
| `deploymentPrincipalId` | Cluster admin + Grafana admin | So the environment is usable the moment deployment finishes rather than requiring a second manual step. |

`deploymentPrincipalType` must match reality — `User`, `Group` or `ServicePrincipal`. A wrong value
produces a role assignment that appears to succeed and grants nothing.

Leaving `adminGroupObjectIds` empty is only correct if you manage access entirely through separate
role assignments. Otherwise nobody can administer the cluster.

### Role definition IDs

Managed and CSP tenants **do not use the published built-in role GUIDs for every role**. Hardcoding
them produces `RoleDefinitionDoesNotExist` at deploy time.

All nine roles this repo assigns are therefore resolved by **display name** at run time by `deploy.*`
and passed in as the `roleIds` parameter. No role GUID appears in any template. If you write a new
module that needs a role, follow the same pattern.

---

## 3. Workload identity

`features.workloadIdentity` enables the OIDC issuer and the workload identity webhook, letting pods
federate to Entra and obtain tokens with no secret anywhere. `features.keyVaultSecretsProvider` adds
the CSI driver for mounting Key Vault material.

Together they remove the need for a secret in a manifest, in a pipeline variable, or in a
`kubectl create secret` someone ran once and never rotated. Turn them off only if you have a
deliberate alternative.

---

## 4. Detection and audit

| Control | Feature flag | What it gives you |
| --- | --- | --- |
| Defender for Containers | `defenderForContainers` | Runtime threat detection, image vulnerability findings. |
| Diagnostic settings | `diagnosticSettings` | Control-plane audit logs to Log Analytics. Turning this off is usually a compliance problem. |
| Container Insights | `containerInsights` | Container logs and metrics. |
| Managed Prometheus + Grafana | `managedPrometheus`, `managedGrafana` | Metrics and dashboards. |
| Image Cleaner | `imageCleaner` | Removes vulnerable unused images from nodes. |

---

## 5. In-cluster guardrails

Azure Policy governs Azure resources; it does not govern what runs inside the cluster. The sample
GitOps tree carries that layer:

- **Pod Security Admission** at `restricted` on the workload namespace. Pods must run non-root, drop
  all capabilities, disallow privilege escalation, and use the `RuntimeDefault` seccomp profile. The
  `ingress` namespace runs at `baseline` and is isolated, rather than weakening the workload
  namespace, because the ingress controller binds low ports.
- **Default-deny NetworkPolicy** on the workload namespace, with explicit allows for DNS egress and
  for ingress from the ingress controller. A pod is unreachable until it is labelled
  `networking/allow-ingress: "true"`.

> Network policy is **silently ignored** if the cluster was created with `networkPolicy=none`. The
> manifests apply, nothing enforces them, and it looks like everything is fine. Verify:
>
> ```bash
> az aks show -g <rg> -n <cluster> --query networkProfile.networkPolicy
> ```
>
> Every network profile in this repository sets it — `azure` for the Azure dataplane, `cilium` for
> the eBPF dataplane.

---

## 6. Teardown

`destroy.*` removes things in an order that actually works, which matters more than it sounds:

1. Disconnect Arc, if the architecture onboarded a cluster.
2. Delete the AKS cluster **before** the VNet, or the VNet delete fails on in-use subnets.
3. Unlink private DNS zones from foreign VNets — links to VNets outside the resource group survive
   the resource group delete and leave orphans.
4. Delete role assignments scoped to resources outside the resource group. Same reason.
5. Delete policy assignments.
6. Delete the resource group.
7. Delete the subscription-scope policy definition. It cannot be deleted while an assignment
   references it, which is why it is last.
8. Optionally purge the Key Vault. Soft-delete otherwise holds the name.

It inventories everything first and requires you to type the resource group name to confirm, unless
`--force`. Nothing about the order is optional — each step exists because skipping it leaves
something behind.
