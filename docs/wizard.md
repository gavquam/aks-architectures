# The guided wizard

```bash
make wizard
# or
./scripts/wizard.sh          # ./scripts/wizard.ps1 on Windows
```

The wizard asks about ten questions, explains the trade-off behind each one, writes a parameter
file you can keep, shows you what it will cost, and then deploys it through exactly the same path a
pipeline would use.

## Why it exists

The settings that matter most in AKS are the ones that cannot be changed afterwards. The egress
model, the network profile, the Service CIDR, whether the API server is public — none of these can
be altered on a running cluster. All of them are chosen in the first ten minutes, usually by
someone who has not yet been told which ones are permanent.

Documentation does not solve this, because the person making the decision is not reading the
documentation at the moment they make it. The wizard puts the guidance at the point of decision
instead.

For every question you get three things:

| | |
|---|---|
| **Minimum** | what will technically work |
| **Microsoft** | what the platform guidance recommends |
| **Recommended** | what this repository recommends for your situation, and where that differs from Microsoft, why |

Pressing Enter always takes the recommendation. Someone who wants to be led can hold Enter down and
still end up with a defensible cluster.

## What it asks

| # | Question | What it actually decides |
|---|---|---|
| 1 | What is this cluster for? | Cost tier. Named explicitly, including which security controls a cheaper answer switches off |
| 2 | What does your situation look like? | Architecture — and therefore the API server access model |
| 3 | Which region? | Zone availability, and which regions your data may live in |
| 4 | How should the cluster reach the internet? | `outboundType`. **Immutable** |
| 5 | How should pods get addresses? | Network profile. **Immutable** |
| 6 | What address space may it use? | The whole subnet plan, derived from one range |
| 7 | Service CIDR | **Immutable.** Validated against the VNet and pod ranges |
| 8 | On-premises ranges | Fed into pre-flight's overlap checks |
| 9 | Node count and VM size | Capacity, and the pod-subnet node ceiling where one applies |
| 10 | Entra admin group, authorized IPs, alert email | Whether cluster access is auditable or a shared credential |
| 11 | Naming and resource group | Every resource name in the portal and on the bill |

Questions that do not apply are not asked. The authorized-IP question only appears for
`aks-public-authorized-ip`; the network profile is skipped entirely for `aks-automatic`, which
accepts exactly one and says so rather than presenting a menu of one option.

The two Arc architectures exit early with their prerequisite list, because they build nothing in an Azure
region and so have no address plan, sizing or egress model to choose.

## Addressing

The wizard asks for one range — the VNet — and derives the rest, then shows you the result before
anything is deployed. For the default `10.63.0.0/16`:

| Subnet | Derived | Why that size |
|---|---|---|
| Nodes | `10.63.0.0/22` | 1019 usable, plus upgrade surge |
| Pods (podsubnet profiles only) | `10.63.8.0/21` | 110 pods per node is a hard ceiling set here |
| API server | `10.63.16.0/28` | /28 is the delegated minimum |
| Azure Firewall | `10.63.17.0/26` | /26 is the platform minimum |
| Bastion | `10.63.17.64/26` | /26 is the platform minimum |
| Private endpoints | `10.63.18.0/24` | |
| DNS resolver inbound | `10.63.19.0/28` | |
| DNS resolver outbound | `10.63.19.16/28` | |

Asking for nine subnets one at a time would be honest, but nobody would finish. Showing the
derivation afterwards keeps it inspectable, which is the part that matters.

## What you get

A real `.bicepparam` file in `infra/params/<architecture>.local.bicepparam`.

That file is the whole plan. It is the artifact — not a transcript of an interview, not an
environment file that only works in the shell you happened to run it in. You can read it, diff it,
put it in a change ticket, hand it to someone else, or deploy it six weeks later and get the same
cluster.

`*.local.bicepparam` is gitignored, so your answers do not accidentally become someone else's
defaults.

The wizard compiles the file before it asks you to approve anything, so a malformed answer surfaces
immediately rather than sixty seconds into an ARM deployment.

## What it does not do

It does not deploy anything itself. It hands the plan to `deploy.sh` / `deploy.ps1` with
`--param-file`, which means the pre-flight gate, the cost gate, the firewall next-hop assertion and
the governance proof all apply exactly as they would to a curated architecture. There is no second,
less-checked code path for the thing most people will actually run.

Nothing is created until you type `deploy` at the confirmation. Everything before that point is
reversible by pressing Ctrl-C.

## Options

| Flag | PowerShell | Effect |
|---|---|---|
| `-g <rg>` | `-ResourceGroup` | Skip the resource group question |
| `--plan-only` | `-PlanOnly` | Write and validate the plan, deploy nothing |
| `--out-file <name>` | `-OutFile` | Write somewhere other than the default name |

`--plan-only` is the useful one for review: it produces the file, compiles it, prices it, and
prints the exact `deploy` command to run later. Good for getting a plan approved before spending
anything.

`--out-file` accepts a bare filename only. The plan must live in `infra/params/`, because a
`.bicepparam` resolves its `using` target and its `loadJsonContent()` paths relative to its own
directory — the wizard refuses anything else with that explanation rather than letting Bicep emit a
wall of file-not-found errors.

## After it finishes

The wizard prints four next steps, in order, because each proves something different:

1. **Get credentials and list nodes.** On a private architecture this is the moment you find out whether
   you actually have a network path — which is the point of the architecture.
2. **`verify-policy` with `--wait-minutes 20`.** Assignment is not enforcement. This attempts to
   create a public LoadBalancer and confirms the cluster refuses it. The Azure Policy add-on polls
   roughly every fifteen minutes, so a freshly built cluster needs the wait.
3. **`pause`.** Stops most of the cost without destroying anything.
4. **`destroy`.** Removes the cluster, its role assignments and its policy definitions.

## Where the guidance lives

All of the advice text is in [`infra/params/guidance.json`](../infra/params/guidance.json), not in
either script. Two reasons: the bash and PowerShell wizards cannot drift apart, and the guidance can
be reviewed and corrected by someone who does not read shell.

If you disagree with a recommendation, change it there and both wizards change together.
