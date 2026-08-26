#!/usr/bin/env bash
# Collects evidence from an ALREADY-failed AKS deployment and turns it into an answer.
#
# A failed AKS provisioning attempt reports almost nothing useful at the ARM layer: the deployment
# says the agent pool failed, and that is it. The actual cause is in the custom script extension
# exit code on the node, and the reason for that exit code is in the effective route table, the
# effective NSG rules and the private DNS zone links. This script gathers all of it in one pass.
#
#   ./diagnose.sh -g rg-aks-prod-wus3
#   ./diagnose.sh -g rg-aks-prod-wus3 --deployment-name aks-architectures-aks-private-link-20260820
#
# Read-only. It creates nothing and deletes nothing.

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

RESOURCE_GROUP=''; CLUSTER_NAME=''; DEPLOYMENT_NAME=''; JSON_OUT=''; SUBSCRIPTION_ID=''
CSE_CODES_FILE="${script_dir}/lib/cse-exit-codes.json"

usage() {
  cat <<'EOF'
Usage: diagnose.sh --resource-group <name> [options]

Required:
  -g, --resource-group <name>   Resource group containing the failed deployment.

Options:
  -n, --cluster-name <name>     Cluster to inspect. Default: the only cluster in the group.
  --deployment-name <name>      ARM deployment to read operations from. Default: most recent failed.
  --subscription <id>           Subscription. Default: current az context.
  --json-out <path>             Machine-readable output. Default ./diagnose-<rg>.json
  -h, --help                    This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -n|--cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --deployment-name) DEPLOYMENT_NAME="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

EVIDENCE_FILE="$(mktemp)"; echo '{}' > "$EVIDENCE_FILE"
evidence_set() {
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$EVIDENCE_FILE" > "$tmp" && mv "$tmp" "$EVIDENCE_FILE"
}
trap 'rm -f "$RESULTS_FILE" "$EVIDENCE_FILE" 2>/dev/null || true' EXIT INT TERM

echo
echo 'AKS ARCHITECTURES - POST-FAILURE DIAGNOSTICS'
echo "Subscription: $(aztsv account show --query 'join(" ", [name, id])')"
echo "Resource group: ${RESOURCE_GROUP}"
echo

# ================================================================================================
# 1. Deployment operations
#
# The top-level deployment only says "a nested deployment failed", so the useful message is always
# one or more levels down. This walks the nested deployments to find the operations that actually
# carry a status message.
# ================================================================================================

if [ -z "$DEPLOYMENT_NAME" ]; then
  # Filter with jq, not --query. A JMESPath expression containing '&' or '[?' is mangled by the
  # az.cmd shim on Windows and silently returns nothing.
  DEPLOYMENT_NAME="$(az deployment group list -g "$RESOURCE_GROUP" -o json 2>/dev/null |
    jq -r '[ .[] | select(.properties.provisioningState=="Failed") ]
           | sort_by(.properties.timestamp) | last | .name // ""')"
fi

if [ -z "$DEPLOYMENT_NAME" ]; then
  add_result 'deployment.failed' 'deployment' 'skip' \
    'No failed deployment found in this resource group. Diagnosing the live cluster state instead.'
else
  echo "Reading deployment operations for '${DEPLOYMENT_NAME}'..."
  evidence_set 'deploymentName' "$DEPLOYMENT_NAME"

  collect_failed_operations() {
    local dep="$1" depth="${2:-0}"
    [ "$depth" -gt 4 ] && return 0
    while IFS=$'\t' read -r target status_code message; do
      [ -n "$target$message" ] || continue
      local short="${target##*/}"
      [ -n "$short" ] || short='(deployment)'
      add_result "deployment.${short}" 'deployment' 'fail' \
        "$(printf '%s: %s' "${status_code:-Failed}" "${message:0:400}")"
    done < <(az deployment operation group list -g "$RESOURCE_GROUP" -n "$dep" -o json 2>/dev/null |
      jq -r '.[] | select(.properties.provisioningState=="Failed")
             | [ (.properties.targetResource.id // ""),
                 (.properties.statusCode // ""),
                 ((.properties.statusMessage.error.message // .properties.statusMessage.Message
                   // (.properties.statusMessage | tostring)) | gsub("[\n\t]"; " "))
               ] | @tsv')

    while read -r nested; do
      [ -n "$nested" ] && collect_failed_operations "$nested" $((depth + 1))
    done < <(az deployment operation group list -g "$RESOURCE_GROUP" -n "$dep" -o json 2>/dev/null |
      jq -r '.[] | select(.properties.provisioningState=="Failed")
             | .properties.targetResource.id // ""
             | select(test("/Microsoft.Resources/deployments/"))
             | split("/") | last')
  }
  collect_failed_operations "$DEPLOYMENT_NAME"
fi

# ================================================================================================
# 2. Cluster state
# ================================================================================================

if [ -z "$CLUSTER_NAME" ]; then
  CLUSTER_NAME="$(aztsv aks list -g "$RESOURCE_GROUP" --query '[0].name')"
fi

NODE_RG=''; NODE_SUBNET_ID=''; OUTBOUND_TYPE=''; PRIVATE_FQDN=''
if [ -z "$CLUSTER_NAME" ]; then
  add_result 'cluster.exists' 'cluster' 'fail' \
    "No AKS cluster exists in ${RESOURCE_GROUP}. The deployment failed before the cluster resource was created." \
    'Read the deployment findings above; the cause is upstream of the cluster.'
else
  echo "Inspecting cluster '${CLUSTER_NAME}'..."
  CLUSTER_JSON="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json 2>/dev/null | tr -d '\r')"
  if [ -z "$CLUSTER_JSON" ]; then
    add_result 'cluster.read' 'cluster' 'fail' "Could not read cluster ${CLUSTER_NAME}."
  else
    cget() { echo "$CLUSTER_JSON" | jq -r "$1 // \"\""; }
    PROV="$(cget '.provisioningState')"
    POWER="$(cget '.powerState.code')"
    NODE_RG="$(cget '.nodeResourceGroup')"
    OUTBOUND_TYPE="$(cget '.networkProfile.outboundType')"
    PRIVATE_FQDN="$(cget '.privateFqdn')"
    NODE_SUBNET_ID="$(cget '.agentPoolProfiles[0].vnetSubnetId')"
    evidence_set 'clusterName' "$CLUSTER_NAME"
    evidence_set 'nodeResourceGroup' "$NODE_RG"
    evidence_set 'outboundType' "$OUTBOUND_TYPE"

    if [ "$PROV" = 'Succeeded' ]; then
      add_result 'cluster.provisioningState' 'cluster' 'pass' "Cluster provisioningState is Succeeded, powerState ${POWER}."
    else
      add_result 'cluster.provisioningState' 'cluster' 'fail' \
        "Cluster provisioningState is ${PROV} (powerState ${POWER})." \
        'A cluster stuck in Creating or Failed almost always means the node pool never registered. Check the CSE findings below.'
    fi

    while IFS=$'\t' read -r pname pstate pcount pmode; do
      [ -n "$pname" ] || continue
      if [ "$pstate" = 'Succeeded' ]; then
        add_result "cluster.pool.${pname}" 'cluster' 'pass' "Node pool ${pname} (${pmode}, ${pcount} nodes) is Succeeded."
      else
        add_result "cluster.pool.${pname}" 'cluster' 'fail' \
          "Node pool ${pname} (${pmode}) is ${pstate}." \
          'The node pool is where network failures surface. Continue to the CSE and route findings.'
      fi
    done < <(echo "$CLUSTER_JSON" | jq -r '.agentPoolProfiles[]? | [.name, .provisioningState, (.count|tostring), .mode] | @tsv')

    add_result 'cluster.networkConfig' 'cluster' 'pass' \
      "plugin=$(cget '.networkProfile.networkPlugin') mode=$(cget '.networkProfile.networkPluginMode') dataplane=$(cget '.networkProfile.networkDataplane') outboundType=${OUTBOUND_TYPE} privateCluster=$(cget '.apiServerAccessProfile.enablePrivateCluster')"
  fi
fi

# ================================================================================================
# 3. The custom script extension exit code
#
# This is the single most valuable number in an AKS provisioning failure and it is buried three
# levels inside the VMSS instance view.
# ================================================================================================

NODE_NIC_ID=''
if [ -n "$NODE_RG" ]; then
  echo "Reading VMSS instance views in '${NODE_RG}'..."
  mapfile -t VMSS_LIST < <(aztsv vmss list -g "$NODE_RG" --query '[].name')

  if [ "${#VMSS_LIST[@]}" -eq 0 ] || [ -z "${VMSS_LIST[0]}" ]; then
    add_result 'cse.vmss' 'cse' 'fail' \
      "No VMSS exists in the node resource group ${NODE_RG}." \
      'The control plane never got as far as creating node infrastructure. This is a quota, policy or subnet permission failure, not an egress failure.'
  fi

  for vmss in "${VMSS_LIST[@]+"${VMSS_LIST[@]}"}"; do
    [ -n "$vmss" ] || continue
    mapfile -t INSTANCE_IDS < <(aztsv vmss list-instances -g "$NODE_RG" -n "$vmss" --query '[].instanceId')
    if [ "${#INSTANCE_IDS[@]}" -eq 0 ] || [ -z "${INSTANCE_IDS[0]}" ]; then
      add_result "cse.${vmss}.instances" 'cse' 'fail' \
        "VMSS ${vmss} has no instances." \
        'Check regional vCPU quota and any Azure Policy denying VM creation in this subscription.'
      continue
    fi

    for iid in "${INSTANCE_IDS[@]}"; do
      IV="$(az vmss get-instance-view -g "$NODE_RG" -n "$vmss" --instance-id "$iid" -o json 2>/dev/null | tr -d '\r')"
      [ -n "$IV" ] || continue

      CSE_MSG="$(echo "$IV" | jq -r '
        [ .extensions[]? | select(.name | test("CSE|CustomScript"; "i"))
          | (.substatuses[]?, .statuses[]?) | (.message // "") ] | join(" ") | gsub("[\n\t]"; " ")')"
      CSE_STATUS="$(echo "$IV" | jq -r '
        [ .extensions[]? | select(.name | test("CSE|CustomScript"; "i"))
          | (.statuses[]? | .displayStatus // "") ] | join(", ")')"

      if [ -z "$CSE_MSG" ] && [ -z "$CSE_STATUS" ]; then
        add_result "cse.${vmss}.${iid}" 'cse' 'skip' \
          "Instance ${iid} has no custom script extension status yet. The node is still early in provisioning."
        continue
      fi

      # "command terminated with exit status=50" is the canonical form; older agents emit
      # "Enable failed: ... exit status 50" without the '='.
      EXIT_CODE="$(echo "$CSE_MSG" | grep -oE 'exit status[ =]+[0-9]+' | grep -oE '[0-9]+' | tail -n1)"

      if [ -z "$EXIT_CODE" ]; then
        if echo "$CSE_STATUS" | grep -qi 'succe'; then
          add_result "cse.${vmss}.${iid}" 'cse' 'pass' "Instance ${iid} custom script extension succeeded."
        else
          add_result "cse.${vmss}.${iid}" 'cse' 'warn' \
            "Instance ${iid} extension status '${CSE_STATUS}' with no parseable exit code: ${CSE_MSG:0:300}"
        fi
        continue
      fi

      evidence_set "cseExitCode.${vmss}.${iid}" "$EXIT_CODE"
      MEANING="$(jq -r --arg c "$EXIT_CODE" '.codes[$c].meaning // ""' "$CSE_CODES_FILE")"
      CODE_NAME="$(jq -r --arg c "$EXIT_CODE" '.codes[$c].name // "UNKNOWN"' "$CSE_CODES_FILE")"
      IS_NETWORK="$(jq -r --arg c "$EXIT_CODE" '.codes[$c].network // false' "$CSE_CODES_FILE")"
      [ -n "$MEANING" ] || MEANING='Exit code not present in the known table. Read the full extension message.'

      if [ "$EXIT_CODE" = '0' ]; then
        add_result "cse.${vmss}.${iid}" 'cse' 'pass' "Instance ${iid} custom script extension exit code 0."
      elif [ "$IS_NETWORK" = 'true' ]; then
        add_result "cse.${vmss}.${iid}" 'cse' 'fail' \
          "Instance ${iid} exit ${EXIT_CODE} ${CODE_NAME}: ${MEANING}" \
          'This is a network-path failure. The route, NSG and DNS findings below tell you which hop is at fault.'
      else
        add_result "cse.${vmss}.${iid}" 'cse' 'fail' \
          "Instance ${iid} exit ${EXIT_CODE} ${CODE_NAME}: ${MEANING}" \
          'Not primarily a network failure. Collect /var/log/azure/cluster-provision.log from the node.'
      fi

      if [ -z "$NODE_NIC_ID" ]; then
        NODE_NIC_ID="$(aztsv vmss nic list-vm-nics -g "$NODE_RG" --vmss-name "$vmss" --instance-id "$iid" --query '[0].id')"
      fi
    done
  done
fi

# ================================================================================================
# 4. Effective routes on a real node NIC
#
# The route table attached to the subnet is not what the node uses; the effective table is the merge
# of system routes, the attached UDR and any BGP routes learned over a gateway. Reading the
# effective table is the only way to see what the node will actually do with a packet.
# ================================================================================================

if [ -z "$NODE_NIC_ID" ]; then
  add_result 'routes.effective' 'routes' 'skip' \
    'No node NIC exists yet, so Network Watcher cannot report effective routes. Run scripts/preflight.sh against the intended subnet instead - it deploys a probe VM to answer the same question.'
else
  echo 'Querying effective routes...'
  ROUTES="$(az network nic show-effective-route-table --ids "$NODE_NIC_ID" -o json 2>/dev/null | tr -d '\r')"
  if [ -z "$ROUTES" ]; then
    add_result 'routes.effective' 'routes' 'warn' \
      'Network Watcher did not return an effective route table. The NIC may be detached or the VM deallocated.'
  else
    DEFAULT_HOP="$(echo "$ROUTES" | jq -r '[.value[]? | select(.addressPrefix[]? == "0.0.0.0/0")][0] | "\(.nextHopType) \(.nextHopIpAddress[0] // "")"')"
    DEFAULT_SRC="$(echo "$ROUTES" | jq -r '[.value[]? | select(.addressPrefix[]? == "0.0.0.0/0")][0].source // "unknown"')"
    evidence_set 'defaultRouteNextHop' "$DEFAULT_HOP"

    case "$OUTBOUND_TYPE" in
      userDefinedRouting)
        if echo "$DEFAULT_HOP" | grep -q '^VirtualAppliance'; then
          add_result 'routes.defaultRoute' 'routes' 'pass' \
            "outboundType is userDefinedRouting and 0.0.0.0/0 points at ${DEFAULT_HOP} (source ${DEFAULT_SRC})."
        else
          add_result 'routes.defaultRoute' 'routes' 'fail' \
            "outboundType is userDefinedRouting but the effective 0.0.0.0/0 next hop is '${DEFAULT_HOP}' (source ${DEFAULT_SRC})." \
            'The route table is missing, not associated with the node subnet, or its next hop is wrong. With userDefinedRouting there is no AKS-managed outbound path to fall back on, so the node has no egress at all.'
        fi
        ;;
      *)
        if echo "$DEFAULT_HOP" | grep -q '^VirtualAppliance'; then
          add_result 'routes.defaultRoute' 'routes' 'warn' \
            "outboundType is ${OUTBOUND_TYPE} but 0.0.0.0/0 is forced to ${DEFAULT_HOP} (source ${DEFAULT_SRC})." \
            'A UDR is overriding the managed outbound path. Return traffic to the load balancer will be asymmetric and dropped unless the appliance SNATs. This is the most common cause of a cluster that provisions and then goes unreachable.'
        else
          add_result 'routes.defaultRoute' 'routes' 'pass' \
            "0.0.0.0/0 next hop is ${DEFAULT_HOP} (source ${DEFAULT_SRC}), consistent with outboundType ${OUTBOUND_TYPE}."
        fi
        ;;
    esac

    INVALID="$(echo "$ROUTES" | jq -r '[.value[]? | select(.state != "Active")] | length')"
    if [ "${INVALID:-0}" -gt 0 ]; then
      add_result 'routes.invalid' 'routes' 'warn' "${INVALID} effective route(s) are not in the Active state." \
        'An Invalid route usually points at a virtual appliance IP that no longer exists.'
    else
      add_result 'routes.invalid' 'routes' 'pass' 'All effective routes are Active.'
    fi
  fi
fi

# ================================================================================================
# 5. NSG evaluation on the real node NIC
# ================================================================================================

if [ -z "$NODE_NIC_ID" ]; then
  add_result 'nsg.flowVerify' 'nsg' 'skip' 'No node NIC to evaluate. Use scripts/preflight.sh against the intended subnet.'
else
  echo 'Running IP flow verify...'
  NIC_JSON="$(az network nic show --ids "$NODE_NIC_ID" -o json 2>/dev/null | tr -d '\r')"
  NODE_IP="$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].privateIPAddress // ""')"
  VM_ID="$(echo "$NIC_JSON" | jq -r '.virtualMachine.id // ""')"
  NIC_LOCATION="$(echo "$NIC_JSON" | jq -r '.location // ""')"

  if [ -z "$NODE_IP" ] || [ -z "$VM_ID" ]; then
    add_result 'nsg.flowVerify' 'nsg' 'skip' 'Could not resolve the node private IP or VM ID for IP flow verify.'
  else
    for target in '20.10.0.10:443:api-server-range' '13.107.42.14:443:mcr-range' '168.63.129.16:53:azure-dns'; do
      IFS=':' read -r dst port label <<<"$target"
      proto='TCP'; [ "$port" = '53' ] && proto='UDP'
      ACCESS="$(aztsv network watcher test-ip-flow --direction Outbound --protocol "$proto" \
        --local "${NODE_IP}:10000" --remote "${dst}:${port}" --vm "$VM_ID" --nic "$NODE_NIC_ID" \
        -l "$NIC_LOCATION" --query 'access')"
      RULE="$(aztsv network watcher test-ip-flow --direction Outbound --protocol "$proto" \
        --local "${NODE_IP}:10000" --remote "${dst}:${port}" --vm "$VM_ID" --nic "$NODE_NIC_ID" \
        -l "$NIC_LOCATION" --query 'ruleName')"
      if [ -z "$ACCESS" ]; then
        add_result "nsg.flow.${label}" 'nsg' 'skip' "Network Watcher could not evaluate the flow to ${dst}:${port}."
      elif [ "$ACCESS" = 'Allow' ]; then
        add_result "nsg.flow.${label}" 'nsg' 'pass' "Outbound ${proto} to ${dst}:${port} is allowed by rule ${RULE}."
      else
        add_result "nsg.flow.${label}" 'nsg' 'fail' \
          "Outbound ${proto} to ${dst}:${port} is DENIED by rule ${RULE}." \
          "Remove or reorder that NSG rule. Nodes cannot provision without outbound 443 and DNS."
      fi
    done
  fi
fi

# ================================================================================================
# 6. Private DNS for a private cluster
# ================================================================================================

if [ -z "$PRIVATE_FQDN" ]; then
  add_result 'dns.privateZone' 'dns' 'skip' 'Not a private cluster, or the cluster was never created; no private DNS zone to validate.'
else
  ZONE="${PRIVATE_FQDN#*.}"
  echo "Checking private DNS zone '${ZONE}'..."
  ZONE_ID="$(az network private-dns zone list -o json 2>/dev/null |
    jq -r --arg z "$ZONE" '[ .[] | select(.name==$z) ] | first | .id // ""')"
  if [ -z "$ZONE_ID" ]; then
    add_result 'dns.privateZone' 'dns' 'fail' \
      "No private DNS zone named ${ZONE} is visible in this subscription." \
      'A private cluster whose zone was deleted or lives in another subscription cannot be resolved by its own nodes.'
  else
    ZONE_RG="$(echo "$ZONE_ID" | awk -F/ '{print $5}')"
    LINK_COUNT="$(aztsv network private-dns link vnet list -g "$ZONE_RG" -z "$ZONE" --query 'length(@)')"
    if [ "${LINK_COUNT:-0}" -eq 0 ]; then
      add_result 'dns.zoneLinks' 'dns' 'fail' \
        "Private DNS zone ${ZONE} has no virtual network links." \
        'Nodes cannot resolve the API server. This produces CSE exit 52. Link the node VNet to the zone.'
    else
      NODE_VNET_ID="${NODE_SUBNET_ID%/subnets/*}"
      if [ -n "$NODE_VNET_ID" ] && aztsv network private-dns link vnet list -g "$ZONE_RG" -z "$ZONE" --query '[].virtualNetwork.id' | grep -qiF "$NODE_VNET_ID"; then
        add_result 'dns.zoneLinks' 'dns' 'pass' "Private DNS zone ${ZONE} is linked to the node VNet (${LINK_COUNT} link(s) total)."
      else
        add_result 'dns.zoneLinks' 'dns' 'fail' \
          "Private DNS zone ${ZONE} has ${LINK_COUNT} link(s) but none of them is the node VNet." \
          'Nodes cannot resolve the API server. This produces CSE exit 52.'
      fi
    fi
  fi
fi

# ================================================================================================
# 7. Report
# ================================================================================================

print_results_table "DIAGNOSTIC RESULTS - ${RESOURCE_GROUP}${CLUSTER_NAME:+ / $CLUSTER_NAME}"

[ -n "$JSON_OUT" ] || JSON_OUT="./diagnose-${RESOURCE_GROUP}.json"
jq -n --arg rg "$RESOURCE_GROUP" --arg cluster "$CLUSTER_NAME" --arg deployment "$DEPLOYMENT_NAME" \
  --argjson pass "$COUNT_PASS" --argjson warn "$COUNT_WARN" --argjson skip "$COUNT_SKIP" --argjson fail "$COUNT_FAIL" \
  --slurpfile results "$RESULTS_FILE" --slurpfile evidence "$EVIDENCE_FILE" \
  '{resourceGroup:$rg, cluster:$cluster, deployment:$deployment,
    summary:{pass:$pass, warn:$warn, skip:$skip, fail:$fail},
    results:$results[0], evidence:$evidence[0]}' > "$JSON_OUT"
echo "Machine-readable result: ${JSON_OUT}"

if [ "$COUNT_FAIL" -gt 0 ]; then
  echo 'Findings above are ordered from the deployment inwards. The first FAIL in the cse, routes or dns'
  echo 'categories is the one to fix; the rest are usually consequences of it.'
  exit 1
fi
echo 'No failures detected. If the cluster is still unhealthy the cause is above the network layer.'
exit 0
