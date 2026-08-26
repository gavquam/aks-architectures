#!/usr/bin/env bash
# Deallocates ("pauses") the Azure Firewall in an architecture deployment and allocates it back, without
# destroying anything. Stops the firewall's hourly meter while keeping the policy, rules, public IP
# and every other resource in place.
#
# Azure Firewall has no portal stop button. The supported way to stop paying for it is to strip its
# IP configuration, which deallocates the running service but preserves the resource and its policy
# association. Reattaching the subnet and public IP starts it again.
#
# Two things make this more than a one-liner in this repo:
#
#   1. The udr-firewall egress model points 0.0.0.0/0 at the firewall's PRIVATE IP. A deallocated
#      firewall means that next hop is gone and every packet leaving the node subnet is black-holed.
#      So by default this also stops the AKS clusters in the group, which is the larger saving.
#
#   2. Azure does not guarantee the same private IP when the firewall is allocated again. If it
#      moves, the route table is silently stale and egress stays broken after resume. This script
#      records the old address, compares it after allocation, and rewrites any matching route.
#
# The configuration needed to allocate again is stored on the firewall's own tags, so resume works
# from a different machine.
#
#   ./pause.sh -g rg-aks-private-link
#   ./pause.sh -g rg-aks-private-link --resume
#   ./pause.sh -g rg-aks-private-link --firewall-only --dry-run

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

API_VERSION='2025-05-01'
TAG_PIP='aksarchitectures-paused-pip'
TAG_SUBNET='aksarchitectures-paused-subnet'
TAG_IPCONFIG='aksarchitectures-paused-ipconfig'
TAG_PRIVATE_IP='aksarchitectures-paused-privateip'
TAG_PAUSED_AT='aksarchitectures-paused-at'

RESOURCE_GROUP=''
SUBSCRIPTION_ID=''
RESUME=0
FIREWALL_ONLY=0
FORCE=0
DRY_RUN=0
TIMEOUT_MINUTES=45

usage() {
  cat <<'EOF'
Usage: pause.sh --resource-group <name> [options]

Required:
  -g, --resource-group <name>   Resource group holding the firewall.

Options:
  --subscription <id>           Subscription. Default: current az context.
  --resume                      Allocate the firewall again instead of deallocating it.
  --firewall-only               Do not stop/start the AKS clusters in the group.
  --force                       Skip the confirmation prompt.
  --dry-run                     Print what would happen and exit.
  --timeout <minutes>           How long to wait for the firewall. Default: 45.
  -h, --help                    This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --firewall-only) FIREWALL_ONLY=1; shift ;;
    --force|-y|--yes) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --timeout) TIMEOUT_MINUTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

SUB_ID="$(aztsv account show --query id)"

arm_get() {
  az rest --method get --url "https://management.azure.com${1}?api-version=${API_VERSION}" -o json 2>/dev/null
}

arm_put() {
  local id="$1" body_file="$2" out
  out="$(az rest --method put --url "https://management.azure.com${id}?api-version=${API_VERSION}" \
    --body "@${body_file}" -o json 2>&1)" || {
    echo "ERROR: ARM PUT failed for ${id}" >&2
    echo "$out" >&2
    return 1
  }
  return 0
}

wait_firewall() {
  local id="$1" verb="$2" deadline state
  deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 20
    state="$(arm_get "$id" | jq -r '.properties.provisioningState // empty')"
    case "$state" in
      Succeeded) echo "    ${verb} complete."; return 0 ;;
      Failed|Canceled) echo "ERROR: firewall ${verb} ended in provisioningState '${state}'." >&2; return 1 ;;
      '') ;;
      *) echo "    still ${state}..." ;;
    esac
  done
  echo "ERROR: timed out after ${TIMEOUT_MINUTES} minutes waiting for the firewall to ${verb}." >&2
  return 1
}

# Round-trips the whole GET response so SKU, zones, policy link and DNS settings survive untouched;
# this mirrors what Set-AzFirewall does. Only the read-only fields are stripped.
build_body() {
  local current="$1" ipconfigs="$2" tags="$3"
  echo "$current" | jq \
    --argjson ipconfigs "$ipconfigs" \
    --argjson tags "$tags" \
    'del(.etag, .id, .name, .type)
     | del(.properties.provisioningState, .properties.hubIPAddresses, .properties.ipGroups)
     | .properties.ipConfigurations = $ipconfigs
     | .tags = $tags'
}

ACTION='PAUSE'
[ "$RESUME" -eq 1 ] && ACTION='RESUME'

echo
echo "AKS ARCHITECTURES - ${ACTION}"
echo "Subscription:   ${SUB_ID}"
echo "Resource group: ${RESOURCE_GROUP}"
echo

FIREWALLS_JSON="$(az network firewall list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
FIREWALL_IDS=()
while IFS= read -r line; do [ -n "$line" ] && FIREWALL_IDS+=("$line"); done < <(echo "$FIREWALLS_JSON" | jq -r '.[].id')

if [ ${#FIREWALL_IDS[@]} -eq 0 ]; then
  echo "No Azure Firewall in '${RESOURCE_GROUP}'. Only the udr-firewall egress model deploys one."
  exit 0
fi

CLUSTERS_JSON="$(az aks list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"

echo 'Plan:'
echo "$FIREWALLS_JSON" | jq -r '.[] | "  firewall \(.name) is currently " + (if ((.ipConfigurations // []) | length) > 0 then "allocated" else "deallocated" end)'
if [ "$FIREWALL_ONLY" -eq 0 ]; then
  echo "$CLUSTERS_JSON" | jq -r '.[] | "  cluster  \(.name) is currently \(.powerState.code // "unknown")"'
fi
echo

if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ "$RESUME" -eq 1 ]; then
    echo 'Allocating the firewall restarts its hourly charge.'
  else
    echo 'While the firewall is deallocated, 0.0.0.0/0 has no next hop and the node subnet has NO egress.'
  fi
  read -r -p "Proceed with ${ACTION} on '${RESOURCE_GROUP}'? (y/N) " answer
  case "$answer" in [Yy]*) ;; *) echo 'Aborted.'; exit 1 ;; esac
  echo
fi

# Pause: stop the clusters first, so nodes are not left running without a route out.
if [ "$RESUME" -eq 0 ] && [ "$FIREWALL_ONLY" -eq 0 ]; then
  while IFS=$'\t' read -r cname cpower; do
    [ -n "$cname" ] || continue
    if [ "$cpower" = 'Stopped' ]; then echo "  cluster ${cname} already stopped"; continue; fi
    if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] stop cluster ${cname}"; continue; fi
    echo "  stopping cluster ${cname}..."
    az aks stop -g "$RESOURCE_GROUP" -n "$cname" -o none \
      || echo "    could not stop ${cname}. Continuing; the firewall pause is independent."
  done < <(echo "$CLUSTERS_JSON" | jq -r '.[] | [.name, (.powerState.code // "unknown")] | @tsv')
fi

for id in "${FIREWALL_IDS[@]}"; do
  fw_name="${id##*/}"
  current="$(arm_get "$id")"
  [ -n "$current" ] || { echo "ERROR: could not read firewall '${fw_name}' over ARM." >&2; exit 1; }

  ipconfig_count="$(echo "$current" | jq -r '(.properties.ipConfigurations // []) | length')"
  tags="$(echo "$current" | jq -c '.tags // {}')"

  if [ "$RESUME" -eq 0 ]; then
    # ------------------------------------------------------------------------------------------
    # Deallocate
    # ------------------------------------------------------------------------------------------
    if [ "$ipconfig_count" -eq 0 ]; then
      echo "  firewall ${fw_name} is already deallocated, nothing to do."
      continue
    fi

    subnet_id="$(echo "$current" | jq -r '.properties.ipConfigurations[0].properties.subnet.id // empty')"
    pip_id="$(echo "$current" | jq -r '.properties.ipConfigurations[0].properties.publicIPAddress.id // empty')"
    private_ip="$(echo "$current" | jq -r '.properties.ipConfigurations[0].properties.privateIPAddress // empty')"
    ipconfig_name="$(echo "$current" | jq -r '.properties.ipConfigurations[0].name // "ipconfig"')"

    if [ -z "$subnet_id" ] || [ -z "$pip_id" ]; then
      echo "ERROR: firewall '${fw_name}' has an IP configuration this script cannot reconstruct." >&2
      exit 1
    fi
    if [ "$ipconfig_count" -gt 1 ]; then
      echo "  firewall ${fw_name} has ${ipconfig_count} IP configurations; only the primary is recorded for resume."
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] deallocate firewall ${fw_name} (private IP ${private_ip})"
      continue
    fi

    new_tags="$(echo "$tags" | jq -c \
      --arg subnet "$subnet_id" --arg pip "$pip_id" --arg ipc "$ipconfig_name" \
      --arg privip "$private_ip" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg kSubnet "$TAG_SUBNET" --arg kPip "$TAG_PIP" --arg kIpc "$TAG_IPCONFIG" \
      --arg kPrivIp "$TAG_PRIVATE_IP" --arg kAt "$TAG_PAUSED_AT" \
      '.[$kSubnet]=$subnet | .[$kPip]=$pip | .[$kIpc]=$ipc | .[$kPrivIp]=$privip | .[$kAt]=$at')"

    body_file="$(mktemp)"
    build_body "$current" '[]' "$new_tags" > "$body_file"
    echo "  deallocating firewall ${fw_name} (was ${private_ip})..."
    arm_put "$id" "$body_file" || { rm -f "$body_file"; exit 1; }
    rm -f "$body_file"
    wait_firewall "$id" 'deallocate' || exit 1

  else
    # ------------------------------------------------------------------------------------------
    # Allocate
    # ------------------------------------------------------------------------------------------
    if [ "$ipconfig_count" -gt 0 ]; then
      echo "  firewall ${fw_name} is already allocated, nothing to do."
      continue
    fi

    subnet_id="$(echo "$tags" | jq -r --arg k "$TAG_SUBNET" '.[$k] // empty')"
    pip_id="$(echo "$tags" | jq -r --arg k "$TAG_PIP" '.[$k] // empty')"
    old_ip="$(echo "$tags" | jq -r --arg k "$TAG_PRIVATE_IP" '.[$k] // empty')"
    ipconfig_name="$(echo "$tags" | jq -r --arg k "$TAG_IPCONFIG" '.[$k] // "ipconfig"')"

    if [ -z "$subnet_id" ] || [ -z "$pip_id" ]; then
      echo "ERROR: firewall '${fw_name}' is deallocated but has no '${TAG_SUBNET}'/'${TAG_PIP}' tags," >&2
      echo "       so this script does not know what to reattach. Re-run scripts/deploy.sh for the" >&2
      echo "       architecture instead - it is idempotent and will allocate the firewall." >&2
      exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] allocate firewall ${fw_name} into ${subnet_id}"
      continue
    fi

    restored="$(jq -nc --arg name "$ipconfig_name" --arg subnet "$subnet_id" --arg pip "$pip_id" \
      '[{name: $name, properties: {subnet: {id: $subnet}, publicIPAddress: {id: $pip}}}]')"

    new_tags="$(echo "$tags" | jq -c \
      --arg kSubnet "$TAG_SUBNET" --arg kPip "$TAG_PIP" --arg kIpc "$TAG_IPCONFIG" \
      --arg kPrivIp "$TAG_PRIVATE_IP" --arg kAt "$TAG_PAUSED_AT" \
      'del(.[$kSubnet], .[$kPip], .[$kIpc], .[$kPrivIp], .[$kAt])')"

    body_file="$(mktemp)"
    build_body "$current" "$restored" "$new_tags" > "$body_file"
    echo "  allocating firewall ${fw_name}... (this takes several minutes)"
    arm_put "$id" "$body_file" || { rm -f "$body_file"; exit 1; }
    rm -f "$body_file"
    wait_firewall "$id" 'allocate' || exit 1

    new_ip="$(arm_get "$id" | jq -r '.properties.ipConfigurations[0].properties.privateIPAddress // empty')"
    echo "  firewall private IP: ${new_ip}"

    # Azure does not promise the same private IP across a deallocate/allocate cycle, and a stale
    # 0.0.0.0/0 next hop black-holes the node subnet with no error anywhere.
    if [ -n "$old_ip" ] && [ -n "$new_ip" ] && [ "$old_ip" != "$new_ip" ]; then
      echo "  private IP moved ${old_ip} -> ${new_ip}, reconciling route tables..."
      fixed=0
      while IFS=$'\t' read -r rt_name route_name; do
        [ -n "$rt_name" ] || continue
        if az network route-table route update -g "$RESOURCE_GROUP" --route-table-name "$rt_name" \
          -n "$route_name" --next-hop-ip-address "$new_ip" -o none; then
          echo "    ${rt_name}/${route_name} -> ${new_ip}"
          fixed=$((fixed + 1))
        else
          echo "    FAILED to update ${rt_name}/${route_name}" >&2
        fi
      done < <(az network route-table list -g "$RESOURCE_GROUP" -o json 2>/dev/null \
        | jq -r --arg old "$old_ip" \
          '.[] as $t | $t.routes[]? | select(.nextHopType=="VirtualAppliance" and .nextHopIpAddress==$old) | [$t.name, .name] | @tsv')
      echo "  updated ${fixed} route(s)."
    elif [ -n "$old_ip" ]; then
      echo '  private IP unchanged, route tables already correct.'
    fi
  fi
done

if [ "$RESUME" -eq 1 ] && [ "$FIREWALL_ONLY" -eq 0 ]; then
  while IFS=$'\t' read -r cname cpower; do
    [ -n "$cname" ] || continue
    if [ "$cpower" = 'Running' ]; then echo "  cluster ${cname} already running"; continue; fi
    if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] start cluster ${cname}"; continue; fi
    echo "  starting cluster ${cname}..."
    az aks start -g "$RESOURCE_GROUP" -n "$cname" -o none || echo "    could not start ${cname}."
  done < <(echo "$CLUSTERS_JSON" | jq -r '.[] | [.name, (.powerState.code // "unknown")] | @tsv')
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo 'Dry run only, nothing was changed.'
elif [ "$RESUME" -eq 1 ]; then
  echo 'Resumed. Firewall billing has restarted.'
else
  echo 'Paused. Firewall compute is no longer billed; its public IP still is (a few dollars a month).'
  echo "Resume with: ./scripts/pause.sh -g ${RESOURCE_GROUP} --resume"
fi
echo
