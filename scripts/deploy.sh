#!/usr/bin/env bash
# Deploys one AKS architecture end to end: role resolution, policy definition, pre-flight gate, then the
# main deployment.
#
# Idempotent. Re-running against an existing environment converges rather than erroring.
#
# The pre-flight network validation is a required gate. --skip-preflight exists for the case where
# you have already validated the path and are iterating on something unrelated; it prints a warning
# and is not appropriate for a first deployment into a new network.
#
#   ./deploy.sh --architecture aks-private-link -g rg-aks-prod-wus3
#   ./deploy.sh --architecture aks-public -g rg-aks-dev --preview

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

ARCHITECTURE=''
RESOURCE_GROUP=''
LOCATION='westus3'
SUBSCRIPTION_ID=''
PREVIEW=0
SKIP_PREFLIGHT=0
SKIP_POLICY_DEFINITION=0
SKIP_POLICY_PROOF=0
SKIP_LIVE_PREFLIGHT_PROBE=0
ASSUME_YES=0
DEPLOYMENT_NAME=''
PARAM_FILE=''
ON_PREM_CIDRS=()

usage() {
  cat <<'EOF'
Usage: deploy.sh --architecture <architecture> --resource-group <name> [options]

Required:
  --architecture <name>               aks-public | aks-public-authorized-ip | aks-private-link |
                                aks-private-vnet-integration | aks-automatic | aks-arc-local |
                                arc-attach-existing
  -g, --resource-group <name>   Target resource group. Created if it does not exist.

Options:
  -l, --location <region>       Region for a new resource group. Default westus3.
  --param-file <path>           Deploy this .bicepparam instead of the curated example for the
                                architecture. This is how a wizard-generated plan is deployed.
  --subscription <id>           Subscription to deploy into. Default: current az context.
  --preview                     Run what-if instead of deploying. Requires an existing group.
  --skip-preflight              Skip network validation entirely. Prints a warning.
  --skip-live-preflight-probe   Run pre-flight but without the throwaway probe VM.
  --skip-policy-definition      Do not create the custom deny-public-IP policy definition.
  --skip-policy-proof           Do not attempt the post-deployment admission test that proves the
                                assigned Deny rules are actually being enforced.
  --on-premises-cidr <cidr>     On-premises range to check for overlap. Repeatable.
  --deployment-name <name>      Override the generated ARM deployment name.
  -y, --yes                     Accept the cost estimate without prompting. For CI.
  -h, --help                    This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --architecture) ARCHITECTURE="$2"; shift 2 ;;
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -l|--location) LOCATION="$2"; shift 2 ;;
    --param-file) PARAM_FILE="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --preview|--what-if) PREVIEW=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    --skip-live-preflight-probe) SKIP_LIVE_PREFLIGHT_PROBE=1; shift ;;
    --skip-policy-definition) SKIP_POLICY_DEFINITION=1; shift ;;
    --skip-policy-proof) SKIP_POLICY_PROOF=1; shift ;;
    --on-premises-cidr) ON_PREM_CIDRS+=("$2"); shift 2 ;;
    --deployment-name) DEPLOYMENT_NAME="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$ARCHITECTURE" ] || { echo 'ERROR: --architecture is required.' >&2; usage >&2; exit 2; }
[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

MAIN_BICEP="${REPO_ROOT}/infra/main.bicep"
# A generated plan is deployed exactly like a curated one - same gates, same assertions - so there
# is no second, less-checked code path for the thing most people will actually run.
[ -n "$PARAM_FILE" ] || PARAM_FILE="${REPO_ROOT}/infra/params/${ARCHITECTURE}.bicepparam"
[ -f "$PARAM_FILE" ] || { echo "ERROR: no parameter file for architecture '$ARCHITECTURE' at $PARAM_FILE" >&2; exit 2; }

sub_name="$(aztsv account show --query name)"
sub_id="$(aztsv account show --query id)"
echo
echo 'AKS ARCHITECTURES - DEPLOY'
echo "Subscription:   ${sub_name} (${sub_id})"
echo "Architecture:         ${ARCHITECTURE}"
echo "Resource group: ${RESOURCE_GROUP}"
echo "Region:         ${LOCATION}"
echo

# ------------------------------------------------------------------------------------------------
# 1. Resource group
# ------------------------------------------------------------------------------------------------

existing_location="$(aztsv group show -n "$RESOURCE_GROUP" --query location)"
if [ -n "$existing_location" ]; then
  if [ "$existing_location" != "$LOCATION" ]; then
    echo "NOTE: resource group already exists in ${existing_location}; using that region instead of ${LOCATION}."
    LOCATION="$existing_location"
  fi
elif [ "$PREVIEW" -eq 1 ]; then
  echo "ERROR: resource group '$RESOURCE_GROUP' does not exist. Preview cannot run against a missing group; create it first or run without --preview." >&2
  exit 2
else
  echo "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}..."
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none || exit 1
fi

# ------------------------------------------------------------------------------------------------
# 2. Role definition IDs
#
# Managed and CSP tenants do not use the published built-in role GUIDs for every role. Hardcoding
# them produces RoleDefinitionDoesNotExist at deploy time, so they are resolved by display name here
# and handed to Bicep as parameters.
# ------------------------------------------------------------------------------------------------

echo 'Resolving built-in role definition IDs...'
# Assigned and exported on separate lines on purpose: `export X="$(cmd)"` swallows the exit status
# of cmd, so a broken lookup would sail through unnoticed (shellcheck SC2155).
AKS_ROLE_ACR_PULL="$(resolve_role_id 'AcrPull' '7f951dda-4ed3-4680-a7ca-43fe172d538d')"
AKS_ROLE_NETWORK_CONTRIBUTOR="$(resolve_role_id 'Network Contributor' '4d97b98b-1d4f-4787-a291-c67834d212e7')"
AKS_ROLE_PRIVATE_DNS_ZONE_CONTRIBUTOR="$(resolve_role_id 'Private DNS Zone Contributor' 'b12aa53e-6015-4669-85d0-8515ebb3ae7f')"
AKS_ROLE_MONITORING_METRICS_PUBLISHER="$(resolve_role_id 'Monitoring Metrics Publisher' '3913510d-42f4-4e42-8a64-420c390055eb')"
AKS_ROLE_RBAC_CLUSTER_ADMIN="$(resolve_role_id 'Azure Kubernetes Service RBAC Cluster Admin' 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')"
AKS_ROLE_KEY_VAULT_SECRETS_USER="$(resolve_role_id 'Key Vault Secrets User' '4633458b-17de-408a-b874-0445c86b69e6')"
AKS_ROLE_GRAFANA_ADMIN="$(resolve_role_id 'Grafana Admin' '22926164-76b3-42b3-bc55-97df8dab3e41')"
AKS_ROLE_MONITORING_DATA_READER="$(resolve_role_id 'Monitoring Data Reader' 'b0d8363b-8ddd-447d-831f-62ca05bff136')"
AKS_ROLE_MANAGED_IDENTITY_OPERATOR="$(resolve_role_id 'Managed Identity Operator' 'f1a07417-d97a-45cb-824c-7a7467783830')"
export AKS_ROLE_ACR_PULL AKS_ROLE_NETWORK_CONTRIBUTOR AKS_ROLE_PRIVATE_DNS_ZONE_CONTRIBUTOR
export AKS_ROLE_MONITORING_METRICS_PUBLISHER AKS_ROLE_RBAC_CLUSTER_ADMIN AKS_ROLE_KEY_VAULT_SECRETS_USER
export AKS_ROLE_GRAFANA_ADMIN AKS_ROLE_MONITORING_DATA_READER AKS_ROLE_MANAGED_IDENTITY_OPERATOR

# ------------------------------------------------------------------------------------------------
# 3. Identity of the caller, so the deployment is usable the moment it finishes
# ------------------------------------------------------------------------------------------------

if [ -z "${AKS_DEPLOYMENT_PRINCIPAL_ID:-}" ]; then
  caller_type="$(aztsv account show --query user.type)"
  if [ "$caller_type" = 'servicePrincipal' ]; then
    caller_name="$(aztsv account show --query user.name)"
    principal_id="$(aztsv ad sp show --id "$caller_name" --query id)"
    principal_kind='ServicePrincipal'
  else
    principal_id="$(aztsv ad signed-in-user show --query id)"
    principal_kind='User'
  fi
  if [ -n "$principal_id" ]; then
    export AKS_DEPLOYMENT_PRINCIPAL_ID="$principal_id"
    export AKS_DEPLOYMENT_PRINCIPAL_TYPE="$principal_kind"
  fi
fi
if [ -n "${AKS_DEPLOYMENT_PRINCIPAL_ID:-}" ]; then
  echo "Deployment principal: ${AKS_DEPLOYMENT_PRINCIPAL_ID} (${AKS_DEPLOYMENT_PRINCIPAL_TYPE})"
else
  echo 'WARNING: could not determine the caller object ID. Cluster admin and Grafana admin role assignments will be skipped, and you may not be able to reach the cluster after deployment.'
  echo '  Set AKS_DEPLOYMENT_PRINCIPAL_ID and AKS_DEPLOYMENT_PRINCIPAL_TYPE explicitly to fix this.'
fi

# ------------------------------------------------------------------------------------------------
# 4. Custom deny-public-IP policy definition
#
# Policy definitions cannot live at resource group scope, so this is a separate subscription-scope
# deployment. Lacking Resource Policy Contributor is a governance gap, not a reason to block the
# whole deployment, so it warns rather than failing.
# ------------------------------------------------------------------------------------------------

if [ "$SKIP_POLICY_DEFINITION" -eq 1 ]; then
  echo 'Skipping the custom deny-public-IP policy definition (--skip-policy-definition).'
elif ! grep -q 'denyPublicIpPolicyDefinitionId' "$PARAM_FILE"; then
  # The parameter file is the source of truth for whether this architecture assigns the policy. Creating a
  # subscription-scope definition that nothing consumes leaves an orphan behind and prints a
  # reassuring governance message for a control that is not actually in force.
  echo "Architecture '${ARCHITECTURE}' does not assign the custom deny-public-IP policy; skipping the definition."
elif [ -z "${AKS_DENY_PUBLIC_IP_POLICY_ID:-}" ]; then
  echo 'Deploying the custom deny-public-IP policy definition at subscription scope...'
  policy_id="$(aztsv deployment sub create \
    --name "aks-architectures-policy-$(date +%Y%m%d%H%M%S)" \
    --location "$LOCATION" \
    --template-file "${REPO_ROOT}/infra/subscription-policy.bicep" \
    --parameters "namePrefix=${ARCHITECTURE}" \
    --query properties.outputs.definitionId.value)"
  if [ -n "$policy_id" ]; then
    export AKS_DENY_PUBLIC_IP_POLICY_ID="$policy_id"
    echo "  Definition: ${AKS_DENY_PUBLIC_IP_POLICY_ID}"
  else
    echo 'WARNING: could not create the custom deny-public-IP policy definition.'
    echo '  This usually means the caller lacks Resource Policy Contributor at subscription scope.'
    echo '  Deployment continues. The built-in internal-load-balancer policy is still assigned;'
    echo '  only the custom public-IP denial is missing. See docs/governance.md.'
  fi
fi

# ------------------------------------------------------------------------------------------------
# 5. Cost gate
#
# Nobody should find an Azure Firewall on their invoice. Everything that bills continuously is
# itemised before anything is created, and the components that dominate the bill need an explicit
# yes. --yes skips the prompt for CI.
# ------------------------------------------------------------------------------------------------

COST_TIER="$(echo "${AKS_COST_TIER:-lean}" | tr '[:upper:]' '[:lower:]')"
case "$COST_TIER" in
  lean|standard|full) ;;
  *) echo "ERROR: AKS_COST_TIER is '$COST_TIER'. Valid values: lean, standard, full. See docs/costs.md." >&2; exit 2 ;;
esac

RESOLVED_PARAMS="$(resolve_bicepparam "$PARAM_FILE")"
show_cost_estimate "$RESOLVED_PARAMS" "$ARCHITECTURE" "$COST_TIER"

if [ "$COST_HAS_EXPENSIVE" -eq 1 ] && [ "$PREVIEW" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p 'Deploy these components? [y/N] ' answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo 'Aborted. Re-run with AKS_COST_TIER=lean, or see docs/costs.md to turn off individual items.'; exit 1 ;;
  esac
fi

# ------------------------------------------------------------------------------------------------
# 6. Pre-flight gate
# ------------------------------------------------------------------------------------------------

if [ "$SKIP_PREFLIGHT" -eq 1 ]; then
  echo
  echo '########################################################################'
  echo '  WARNING: pre-flight network validation was SKIPPED (--skip-preflight).'
  echo '  Address overlaps, quota shortfalls, NSG denies and broken egress will'
  echo '  not surface until the node pool fails to register, typically 20-40'
  echo '  minutes into the deployment and with an opaque error.'
  echo '########################################################################'
  echo
else
  echo
  echo 'Running pre-flight network validation...'
  preflight_args=(
    --param-file "$PARAM_FILE"
    --resource-group "$RESOURCE_GROUP"
    --location "$LOCATION"
    --json-out "./preflight-${ARCHITECTURE}.json"
  )
  [ "$SKIP_LIVE_PREFLIGHT_PROBE" -eq 1 ] && preflight_args+=(--skip-live-probe)
  for cidr in "${ON_PREM_CIDRS[@]+"${ON_PREM_CIDRS[@]}"}"; do
    preflight_args+=(--on-premises-cidr "$cidr")
  done

  if ! bash "${script_dir}/preflight.sh" "${preflight_args[@]}"; then
    echo
    echo 'Deployment aborted: pre-flight validation failed.' >&2
    echo 'Fix the items above, or re-run with --skip-preflight if you accept the risk.' >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------------------------------------
# 7. Main deployment
# ------------------------------------------------------------------------------------------------

[ -n "$DEPLOYMENT_NAME" ] || DEPLOYMENT_NAME="aks-architectures-${ARCHITECTURE}-$(date +%Y%m%d%H%M%S)"

if [ "$PREVIEW" -eq 1 ]; then
  echo
  echo 'Previewing changes (what-if)...'
  az deployment group what-if -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --template-file "$MAIN_BICEP" --parameters "$PARAM_FILE"
  exit $?
fi

echo
echo "Deploying ${ARCHITECTURE}. A first private cluster with a firewall takes roughly 25 minutes."
if ! az deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
  --template-file "$MAIN_BICEP" --parameters "$PARAM_FILE" -o none; then
  echo
  echo 'Deployment failed.' >&2
  echo "Collect evidence with:  ./diagnose.sh -g ${RESOURCE_GROUP} --deployment-name ${DEPLOYMENT_NAME}" >&2
  exit 1
fi

OUTPUTS_JSON="$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
  --query properties.outputs -o json 2>/dev/null | tr -d '\r')"
out() { echo "$OUTPUTS_JSON" | jq -r --arg k "$1" '.[$k].value // "" | if type=="array" then join(", ") else tostring end'; }

# ------------------------------------------------------------------------------------------------
# 8. Post-deployment assertions
#
# The route table has to be created before the firewall exists, so its next hop is a computed
# prediction of the firewall private IP. If the prediction is wrong, every node egresses into a
# black hole and the failure looks like a random timeout much later.
# ------------------------------------------------------------------------------------------------

expected_fw="$(out expectedFirewallPrivateIp)"
actual_fw="$(out actualFirewallPrivateIp)"
if [ -n "$expected_fw" ] && [ -n "$actual_fw" ] && [ "$expected_fw" != "$actual_fw" ]; then
  echo
  echo '########################################################################' >&2
  echo '  ROUTE TABLE / FIREWALL MISMATCH' >&2
  echo "  Route table next hop:  ${expected_fw}" >&2
  echo "  Actual firewall IP:    ${actual_fw}" >&2
  echo '  Every node egress packet is being sent to an address the firewall does' >&2
  echo '  not hold. Nodes will fail to register or will hang mid-provisioning.' >&2
  echo '  Fix addressing.firewallSubnetPrefix so the fourth address of the subnet' >&2
  echo '  is the firewall private IP, then redeploy.' >&2
  echo '########################################################################' >&2
  exit 1
fi

echo
echo 'DEPLOYMENT SUCCEEDED'
printf '%.0s=' {1..78}; echo
for name in architectureApplied networkProfileApplied egressApplied outboundTypeApplied \
  clusterName clusterFqdn nodeResourceGroup vnetName nodeSubnetId \
  egressPublicIpAddress dnsResolverInboundIp containerRegistryLoginServer \
  keyVaultUri grafanaEndpoint apiServerAuthorizedIpRanges; do
  value="$(out "$name")"
  [ -n "$value" ] && printf '  %-30s %s\n' "$name" "$value"
done
printf '%.0s=' {1..78}; echo

# ------------------------------------------------------------------------------------------------
# 9. Governance proof
#
# Assignment is not enforcement. The compliance blade reports that a Deny was assigned; only an
# admission attempt reports that it is actually refusing anything. This runs the attempt so the
# proof ships with the deployment rather than living in a runbook nobody opens.
#
# The wait is zero here on purpose. The Azure Policy add-on polls roughly every fifteen minutes, so
# a fresh cluster almost always reports PENDING, and blocking the deploy for fifteen minutes to
# learn that would be a poor trade. The re-run command is printed instead.
# ------------------------------------------------------------------------------------------------

if [ "$SKIP_POLICY_PROOF" -eq 0 ] && [ "$(out policyInClusterEnforcement)" = 'true' ]; then
  cluster_name="$(out clusterName)"
  echo
  "${script_dir}/verify-policy.sh" -g "$RESOURCE_GROUP" -n "$cluster_name" --wait-minutes 0
  proof_rc=$?
  # A cluster that accepts what its own policy forbids is a real finding, so it fails the deploy.
  # Anything else - pending, or the proof could not run - is reported and does not.
  [ "$proof_rc" -eq 1 ] && exit 1
fi

kubectl_cmd="$(out kubectlCredentialCommand)"
if [ -n "$kubectl_cmd" ]; then
  echo
  echo 'Get credentials:'
  echo "  ${kubectl_cmd}"
  if [ "$ARCHITECTURE" = 'aks-private-link' ]; then
    echo
    echo 'This is a private cluster. kubectl only works from a network that can resolve and'
    echo 'reach the API server private endpoint. From outside that network, use:'
    echo "  az aks command invoke -g ${RESOURCE_GROUP} -n $(out clusterName) --command 'kubectl get nodes'"
  fi
fi
echo
