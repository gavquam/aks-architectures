#!/usr/bin/env bash
#
# Pre-flight network validation for an AKS deployment. Fails fast, with a specific reason.
# Functional mirror of scripts/preflight.ps1 - same checks, same result IDs, same JSON schema.
#
# Usage:
#   ./preflight.sh --param-file ../infra/params/aks-private-link.bicepparam --resource-group rg-aks-prod
#   ./preflight.sh --architecture aks-private-link --network-profile cni-overlay --egress udr-firewall \
#                  --resource-group rg-hub --node-subnet-id /subscriptions/.../subnets/snet-nodes
#
# Options:
#   --param-file <path>        .bicepparam file from infra/params (compiled with the current env)
#   --architecture <name>            override or replace the param file
#   --network-profile <name>   cni-overlay | cni-podsubnet | cni-overlay-cilium
#   --egress <name>            loadbalancer | natgateway | udr-firewall
#   --resource-group <name>    required for anything that touches Azure
#   --location <region>        defaults to the resource group's region, then westus3
#   --node-subnet-id <id>      validate a bring-your-own subnet BEFORE any deployment exists
#   --api-server-fqdn <fqdn>   probe a real API server on 443 instead of a DNS-only test
#   --additional-fqdn <fqdn>   extra endpoint to probe on 443 (repeatable)
#   --on-premises-cidr <cidr>  extra range to check for overlap (repeatable)
#   --probe-vm-size <size>     default Standard_D2ds_v5
#   --json-out <path>          default ./preflight-<architecture>.json
#   --skip-live-probe          static checks only; no VM is created and the real path is NOT tested
#   --keep-probe-vm            leave the probe VM in place for manual investigation

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PARAM_FILE=''; ARCHITECTURE=''; NETWORK_PROFILE=''; EGRESS=''; RESOURCE_GROUP=''; LOCATION=''
NODE_SUBNET_ID=''; API_SERVER_FQDN=''; PROBE_VM_SIZE='Standard_D2ds_v5'; JSON_OUT=''
PROBE_VM_IMAGE='Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest'
SKIP_LIVE_PROBE=0; KEEP_PROBE_VM=0
ADDITIONAL_FQDNS=(); ONPREM_CIDRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --param-file) PARAM_FILE="$2"; shift 2 ;;
    --architecture) ARCHITECTURE="$2"; shift 2 ;;
    --network-profile) NETWORK_PROFILE="$2"; shift 2 ;;
    --egress) EGRESS="$2"; shift 2 ;;
    --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
    --location|-l) LOCATION="$2"; shift 2 ;;
    --node-subnet-id) NODE_SUBNET_ID="$2"; shift 2 ;;
    --api-server-fqdn) API_SERVER_FQDN="$2"; shift 2 ;;
    --additional-fqdn) ADDITIONAL_FQDNS+=("$2"); shift 2 ;;
    --on-premises-cidr) ONPREM_CIDRS+=("$2"); shift 2 ;;
    --probe-vm-size) PROBE_VM_SIZE="$2"; shift 2 ;;
    --probe-vm-image) PROBE_VM_IMAGE="$2"; shift 2 ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    --skip-live-probe) SKIP_LIVE_PROBE=1; shift ;;
    --keep-probe-vm) KEEP_PROBE_VM=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

assert_azure_cli

ACCOUNT="$(az account show -o json)"
SUB_ID="$(echo "$ACCOUNT" | jq -r '.id')"
SUB_NAME="$(echo "$ACCOUNT" | jq -r '.name')"

echo ''
echo 'AKS ARCHITECTURES - PRE-FLIGHT NETWORK VALIDATION'
echo "Subscription: ${SUB_NAME} (${SUB_ID})"
echo ''

PROBE_VM_NAME=''
PROBE_VM_CREATED=0
EVIDENCE_FILE="$(mktemp)"
echo '{}' > "$EVIDENCE_FILE"

evidence_set() {
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$EVIDENCE_FILE" > "$tmp" && mv "$tmp" "$EVIDENCE_FILE"
}

cleanup() {
  rm -f "$RESULTS_FILE" "$EVIDENCE_FILE" 2>/dev/null || true
  if [ "$PROBE_VM_CREATED" = '1' ] && [ -n "$PROBE_VM_NAME" ]; then
    if [ "$KEEP_PROBE_VM" = '1' ]; then
      echo "Leaving probe VM '$PROBE_VM_NAME' in place (--keep-probe-vm). Delete it with:" >&2
      echo "  az vm delete -g $RESOURCE_GROUP -n $PROBE_VM_NAME --yes --force-deletion true" >&2
    else
      echo "Deleting probe VM '$PROBE_VM_NAME'..." >&2
      az vm delete -g "$RESOURCE_GROUP" -n "$PROBE_VM_NAME" --yes --force-deletion true >/dev/null 2>&1 || true
      az network nic delete -g "$RESOURCE_GROUP" -n "${PROBE_VM_NAME}-nic" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM

# ================================================================================================
# 1. Resolve the intended configuration
# ================================================================================================

PARAMS='{}'
if [ -n "$PARAM_FILE" ]; then
  echo "Compiling $(basename "$PARAM_FILE")..."
  PARAMS="$(resolve_bicepparam "$PARAM_FILE")"
  evidence_set paramFile "$PARAM_FILE"
fi

pick() { # pick <explicit> <param path> <fallback>
  if [ -n "$1" ]; then echo "$1"; else param_get "$PARAMS" "$2" "$3"; fi
}

ARCHITECTURE="$(pick "$ARCHITECTURE" architecture '')"
NETWORK_PROFILE="$(pick "$NETWORK_PROFILE" networkProfile 'cni-overlay')"
EGRESS="$(pick "$EGRESS" egress 'natgateway')"
LOCATION="$(pick "$LOCATION" location '')"

[ -n "$ARCHITECTURE" ] || { echo 'ERROR: no architecture specified. Pass --architecture or --param-file.' >&2; exit 2; }
if [ "$(matrix ".architectures | has(\"$ARCHITECTURE\")")" != 'true' ]; then
  echo "ERROR: unknown architecture '$ARCHITECTURE'. Valid values: $(matrix '.architectures | keys | join(", ")')" >&2
  exit 2
fi

ARCHITECTURE_AZURE_REGION="$(matrix ".architectures[\"$ARCHITECTURE\"].azureRegion")"
ARCHITECTURE_CREATES_CLUSTER="$(matrix ".architectures[\"$ARCHITECTURE\"].createsCluster")"
ARCHITECTURE_API_ACCESS="$(matrix ".architectures[\"$ARCHITECTURE\"].apiServerAccess")"

# An architecture that never touches an Azure VNet has no Azure network path to validate.
if [ "$ARCHITECTURE_AZURE_REGION" != 'true' ]; then NETWORK_PROFILE='none'; EGRESS='none'; fi

if [ -n "$RESOURCE_GROUP" ] && [ -z "$LOCATION" ]; then
  LOCATION="$(aztsv group show -n "$RESOURCE_GROUP" --query location || true)"
fi
[ -n "$LOCATION" ] || LOCATION='westus3'

evidence_set subscriptionId "$SUB_ID"
evidence_set architecture "$ARCHITECTURE"
evidence_set networkProfile "$NETWORK_PROFILE"
evidence_set egress "$EGRESS"
evidence_set location "$LOCATION"
evidence_set resourceGroup "$RESOURCE_GROUP"

echo "Architecture: $ARCHITECTURE   Network: $NETWORK_PROFILE   Egress: $EGRESS   Region: $LOCATION"

# ================================================================================================
# 2. Static: matrix combination and required parameters
# ================================================================================================

CAT='configuration'

if [ "$(matrix ".architectures[\"$ARCHITECTURE\"].networkProfiles | index(\"$NETWORK_PROFILE\") != null")" = 'true' ]; then
  add_result 'architecture.networkProfile' "$CAT" pass "'$NETWORK_PROFILE' is supported by architecture '$ARCHITECTURE'."
else
  add_result 'architecture.networkProfile' "$CAT" fail \
    "Architecture '$ARCHITECTURE' does not support network profile '$NETWORK_PROFILE'." \
    "Choose one of: $(matrix ".architectures[\"$ARCHITECTURE\"].networkProfiles | join(\", \")")"
fi

if [ "$(matrix ".architectures[\"$ARCHITECTURE\"].egress | index(\"$EGRESS\") != null")" = 'true' ]; then
  add_result 'architecture.egress' "$CAT" pass "Egress mode '$EGRESS' is supported by architecture '$ARCHITECTURE'."
else
  add_result 'architecture.egress' "$CAT" fail \
    "Architecture '$ARCHITECTURE' does not support egress mode '$EGRESS'." \
    "Choose one of: $(matrix ".architectures[\"$ARCHITECTURE\"].egress | join(\", \")")"
fi

required_path() {
  case "$1" in
    authorizedIpRanges) echo 'authorizedIpRanges' ;;
    apiServerSubnetPrefix|podSubnetPrefix|podCidr|firewallSubnetPrefix) echo "addressing.$1" ;;
    customLocationId|logicalNetworkId|existingConnectedClusterId|arcLocalSshPublicKey) echo "externals.$1" ;;
    *) echo "$1" ;;
  esac
}
required_hint() {
  case "$1" in
    customLocationId) echo 'az customlocation list -o table   then set AKS_CUSTOM_LOCATION_ID' ;;
    logicalNetworkId) echo 'az stack-hci-vm network lnet list -o table   then set AKS_LOGICAL_NETWORK_ID' ;;
    existingConnectedClusterId) echo 'Run scripts/arc-onboard.sh first, then set AKS_EXISTING_CONNECTED_CLUSTER_ID' ;;
    arcLocalSshPublicKey) echo 'ssh-keygen -t rsa -b 4096   then set AKS_ARC_SSH_PUBLIC_KEY to the contents of the .pub file' ;;
    authorizedIpRanges) echo 'Set AKS_AUTHORIZED_IP_RANGES to a comma-separated list of CIDRs, e.g. 203.0.113.0/24' ;;
    *) echo "Set this parameter in $(basename "${PARAM_FILE:-the parameter file}")." ;;
  esac
}

while read -r req; do
  [ -n "$req" ] || continue
  if [ -z "$PARAM_FILE" ]; then
    add_result "required.$req" "$CAT" skip "Cannot verify required parameter '$req' without --param-file."
    continue
  fi
  val="$(param_get "$PARAMS" "$(required_path "$req")" '')"
  if [ -z "$val" ]; then
    add_result "required.$req" "$CAT" fail "Architecture '$ARCHITECTURE' requires '$req' but it is empty." "$(required_hint "$req")"
  else
    add_result "required.$req" "$CAT" pass "Required parameter '$req' is present."
  fi
done < <(matrix ".architectures[\"$ARCHITECTURE\"].requiredParams[]?")

# The API server subnet is a consequence of the architecture, not a free choice.
if [ "$ARCHITECTURE_API_ACCESS" = 'vnetIntegration' ] && [ -n "$PARAM_FILE" ]; then
  if [ -z "$(param_get "$PARAMS" addressing.apiServerSubnetPrefix '')" ]; then
    add_result 'required.apiServerSubnetPrefix' "$CAT" fail \
      'API Server VNet Integration needs a dedicated, delegated API server subnet.' \
      'Set addressing.apiServerSubnetPrefix to a /28 or larger that is inside the VNet address space.'
  fi
fi

# The Automatic SKU validates the system pool against its own recommended values and rejects the
# cluster with a single opaque AKSAutomaticSKUFeatureValidationError listing everything at once,
# 10+ minutes in. These are cheap to check up front.
if [ "$(matrix ".architectures[\"$ARCHITECTURE\"].skuName // empty")" = 'Automatic' ] && [ -n "$PARAM_FILE" ]; then
  auto_zones="$(param_get "$PARAMS" systemNodePool.zones '' | tr -d '[]" ' | tr ',' ' ')"
  missing=''
  for z in 1 2 3; do
    case " $auto_zones " in *" $z "*) ;; *) missing="$missing $z" ;; esac
  done
  if [ -n "$missing" ]; then
    add_result 'automatic.zones' "$CAT" fail \
      "The Automatic SKU requires availability zones 1, 2 and 3 on the system pool; missing:$missing." \
      'Set systemNodePool.zones to [1, 2, 3]. Automatic is only supported in regions offering three zones, so this is not a free choice.'
  else
    add_result 'automatic.zones' "$CAT" pass 'System pool requests all three availability zones, as the Automatic SKU requires.'
  fi

  auto_disk="$(param_get "$PARAMS" systemNodePool.osDiskType '')"
  if [ "$auto_disk" != 'Ephemeral' ]; then
    add_result 'automatic.ephemeralOsDisk' "$CAT" fail \
      "The Automatic SKU requires ephemeral OS disks on the system pool; osDiskType is '$auto_disk'." \
      'Set systemNodePool.osDiskType to Ephemeral, and make sure the VM size has a cache or NVMe disk at least as large as osDiskSizeGB.'
  else
    add_result 'automatic.ephemeralOsDisk' "$CAT" pass 'System pool uses ephemeral OS disks, as the Automatic SKU requires.'
  fi

  if [ -z "$(param_get "$PARAMS" addressing.systemNodeSubnetPrefix '')" ]; then
    add_result 'automatic.systemNodeSubnet' "$CAT" fail \
      'The Automatic SKU always runs a managed system node pool, and without a subnet of its own it is created in an AKS-managed VNet.' \
      'Set addressing.systemNodeSubnetPrefix to a /26 or larger inside the VNet. Otherwise AKS rejects every egress mode except the managed load balancer.'
  else
    add_result 'automatic.systemNodeSubnet' "$CAT" pass 'A subnet is reserved for the Automatic managed system node pool.'
  fi
fi

add_result 'config.immutable' "$CAT" warn \
  "Immutable after creation: $(matrix '.immutable | keys | join(", ")')." \
  'Confirm these are correct now. Changing any of them later requires a new cluster.'

# ================================================================================================
# 3. Static: address plan
# ================================================================================================

CAT='addressing'
if [ "$ARCHITECTURE_AZURE_REGION" = 'true' ] && [ -n "$PARAM_FILE" ]; then
  VNET_SPACE="$(param_get "$PARAMS" addressing.vnetAddressSpace '')"
  SERVICE_CIDR="$(param_get "$PARAMS" addressing.serviceCidr '')"
  POD_CIDR="$(param_get "$PARAMS" addressing.podCidr '')"
  DNS_SERVICE_IP="$(param_get "$PARAMS" addressing.dnsServiceIp '')"

  SUBNET_NAMES=(); SUBNET_VALUES=()
  for n in nodeSubnetPrefix systemNodeSubnetPrefix podSubnetPrefix apiServerSubnetPrefix firewallSubnetPrefix \
           bastionSubnetPrefix privateEndpointSubnetPrefix dnsResolverInboundPrefix dnsResolverOutboundPrefix; do
    v="$(param_get "$PARAMS" "addressing.$n" '')"
    if [ -n "$v" ]; then SUBNET_NAMES+=("$n"); SUBNET_VALUES+=("$v"); fi
  done

  # 3a. Every declared CIDR must parse.
  MALFORMED=''
  for pair in "vnetAddressSpace=$VNET_SPACE" "serviceCidr=$SERVICE_CIDR" "podCidr=$POD_CIDR"; do
    k="${pair%%=*}"; v="${pair#*=}"
    [ -n "$v" ] || continue
    cidr_valid "$v" || MALFORMED="$MALFORMED $k='$v'"
  done
  for i in "${!SUBNET_NAMES[@]}"; do
    cidr_valid "${SUBNET_VALUES[$i]}" || MALFORMED="$MALFORMED ${SUBNET_NAMES[$i]}='${SUBNET_VALUES[$i]}'"
  done

  if [ -n "$MALFORMED" ]; then
    add_result 'cidr.parse' "$CAT" fail "Malformed CIDR values:$MALFORMED" 'Use a.b.c.d/nn IPv4 notation.'
  else
    add_result 'cidr.parse' "$CAT" pass 'All declared address ranges parse as valid IPv4 CIDRs.'

    # 3b. Subnets inside the VNet, and disjoint from each other.
    OUTSIDE=''
    for i in "${!SUBNET_NAMES[@]}"; do
      cidr_contains "$VNET_SPACE" "${SUBNET_VALUES[$i]}" || OUTSIDE="$OUTSIDE ${SUBNET_NAMES[$i]}=${SUBNET_VALUES[$i]}"
    done
    if [ -n "$OUTSIDE" ]; then
      add_result 'cidr.subnetsInVnet' "$CAT" fail \
        "Subnets fall outside the VNet address space ${VNET_SPACE}:$OUTSIDE" \
        'Re-plan the subnets so each is a strict subset of vnetAddressSpace, or widen the VNet.'
    else
      add_result 'cidr.subnetsInVnet' "$CAT" pass "All ${#SUBNET_NAMES[@]} subnets are inside $VNET_SPACE."
    fi

    COLLISIONS=''
    for ((i = 0; i < ${#SUBNET_NAMES[@]}; i++)); do
      for ((j = i + 1; j < ${#SUBNET_NAMES[@]}; j++)); do
        if cidr_overlap "${SUBNET_VALUES[$i]}" "${SUBNET_VALUES[$j]}"; then
          COLLISIONS="$COLLISIONS ${SUBNET_NAMES[$i]}(${SUBNET_VALUES[$i]})<->${SUBNET_NAMES[$j]}(${SUBNET_VALUES[$j]})"
        fi
      done
    done
    if [ -n "$COLLISIONS" ]; then
      add_result 'cidr.subnetOverlap' "$CAT" fail "Subnets overlap each other:$COLLISIONS" 'Give every subnet a disjoint range.'
    else
      add_result 'cidr.subnetOverlap' "$CAT" pass 'No subnet-to-subnet overlaps.'
    fi

    # 3c. Cluster CIDRs against the VNet, its peers, and on-premises ranges.
    CONFLICT_RANGES=("$VNET_SPACE|VNet address space")
    if [ ${#ONPREM_CIDRS[@]} -eq 0 ]; then
      while IFS= read -r c; do [ -n "$c" ] && ONPREM_CIDRS+=("$c"); done < <(echo "$PARAMS" | jq -r '.addressing.onPremisesCidrs[]? // empty')
    fi
    for c in ${ONPREM_CIDRS[@]+"${ONPREM_CIDRS[@]}"}; do CONFLICT_RANGES+=("$c|on-premises range"); done

    # Peered VNets are discovered live: an address plan that looks fine on paper routinely collides
    # with a hub that someone else owns.
    if [ -n "$RESOURCE_GROUP" ]; then
      while IFS= read -r vnet_name; do
        [ -n "$vnet_name" ] || continue
        while IFS= read -r pfx; do
          [ -n "$pfx" ] && CONFLICT_RANGES+=("$pfx|peered VNet range")
        done < <(aztsv network vnet peering list -g "$RESOURCE_GROUP" --vnet-name "$vnet_name" \
                   --query '[].remoteAddressSpace.addressPrefixes[]' || true)
      done < <(aztsv network vnet list -g "$RESOURCE_GROUP" --query '[].name' || true)
    fi

    for pair in "serviceCidr=$SERVICE_CIDR" "podCidr=$POD_CIDR"; do
      name="${pair%%=*}"; value="${pair#*=}"
      [ -n "$value" ] || continue
      HITS=''
      for entry in "${CONFLICT_RANGES[@]}"; do
        range="${entry%%|*}"; label="${entry#*|}"
        [ -n "$range" ] || continue
        cidr_valid "$range" || continue
        cidr_overlap "$value" "$range" && HITS="$HITS $range($label)"
      done
      if [ -n "$HITS" ]; then
        add_result "cidr.$name" "$CAT" fail "$name $value overlaps:$HITS" \
          "Move $name to a range used nowhere else in the routed estate. serviceCidr is immutable after cluster creation."
      else
        add_result "cidr.$name" "$CAT" pass "$name $value does not overlap the VNet, its peers, or on-premises ranges."
      fi
    done

    if [ -n "$SERVICE_CIDR" ] && [ -n "$POD_CIDR" ] && cidr_overlap "$SERVICE_CIDR" "$POD_CIDR"; then
      add_result 'cidr.serviceVsPod' "$CAT" fail "serviceCidr $SERVICE_CIDR overlaps podCidr $POD_CIDR." \
        'These are two independent routing domains inside the cluster and must be disjoint.'
    fi

    # 3d. dnsServiceIp inside the service CIDR, and not the network address.
    if [ -n "$SERVICE_CIDR" ] && [ -n "$DNS_SERVICE_IP" ]; then
      SVC_START="$(cidr_start "$SERVICE_CIDR")"
      SUGGESTED="$(int_to_ip $((SVC_START + 10)))"
      if ! ip_in_cidr "$DNS_SERVICE_IP" "$SERVICE_CIDR"; then
        add_result 'cidr.dnsServiceIp' "$CAT" fail "dnsServiceIp $DNS_SERVICE_IP is not inside serviceCidr $SERVICE_CIDR." "Use an address within $SERVICE_CIDR, conventionally $SUGGESTED."
      elif [ "$(ip_to_int "$DNS_SERVICE_IP")" = "$SVC_START" ]; then
        add_result 'cidr.dnsServiceIp' "$CAT" fail "dnsServiceIp $DNS_SERVICE_IP is the network address of $SERVICE_CIDR." "Use $SUGGESTED instead."
      else
        add_result 'cidr.dnsServiceIp' "$CAT" pass "dnsServiceIp $DNS_SERVICE_IP is a valid address inside $SERVICE_CIDR."
      fi
    fi

    # 3e. Fixed minimum sizes Azure enforces on named subnets.
    TOO_SMALL=''
    for i in "${!SUBNET_NAMES[@]}"; do
      case "${SUBNET_NAMES[$i]}" in
        firewallSubnetPrefix|bastionSubnetPrefix|systemNodeSubnetPrefix) min=26 ;;
        apiServerSubnetPrefix|dnsResolverInboundPrefix|dnsResolverOutboundPrefix) min=28 ;;
        *) continue ;;
      esac
      p="$(cidr_prefix "${SUBNET_VALUES[$i]}")"
      [ "$p" -gt "$min" ] && TOO_SMALL="$TOO_SMALL ${SUBNET_NAMES[$i]}=${SUBNET_VALUES[$i]} needs at least a /$min;"
    done
    if [ -n "$TOO_SMALL" ]; then
      add_result 'cidr.minimumSizes' "$CAT" fail "$TOO_SMALL" 'Azure rejects these subnets outright at create time; widen them now.'
    else
      add_result 'cidr.minimumSizes' "$CAT" pass 'AzureFirewallSubnet, AzureBastionSubnet, API server and DNS resolver subnets all meet their minimum sizes.'
    fi

    # 3f. Capacity: nodes, and - on a pod subnet - pods.
    SYS_MAX="$(param_get "$PARAMS" systemNodePool.maxCount 3)"
    USR_MAX=0
    [ "$(param_get "$PARAMS" deployUserNodePool false)" = 'true' ] && USR_MAX="$(param_get "$PARAMS" userNodePool.maxCount 3)"
    TOTAL_MAX_NODES=$((SYS_MAX + USR_MAX))
    DEFAULT_MAX_PODS=250
    [ "$NETWORK_PROFILE" = 'cni-podsubnet' ] && DEFAULT_MAX_PODS=110
    MAX_PODS="$(param_get "$PARAMS" maxPodsPerNode "$DEFAULT_MAX_PODS")"

    for i in "${!SUBNET_NAMES[@]}"; do
      [ "${SUBNET_NAMES[$i]}" = 'nodeSubnetPrefix' ] || continue
      NODE_USABLE=$(( $(cidr_size "${SUBNET_VALUES[$i]}") - 5 ))   # Azure reserves 5 per subnet
      NEEDED=$(( (TOTAL_MAX_NODES * 134 + 99) / 100 + 1 ))          # 33% upgrade surge, rounded up
      if [ "$NODE_USABLE" -lt "$NEEDED" ]; then
        add_result 'capacity.nodeSubnet' "$CAT" fail \
          "Node subnet ${SUBNET_VALUES[$i]} has $NODE_USABLE usable IPs but needs about $NEEDED for $TOTAL_MAX_NODES nodes plus 33% upgrade surge." \
          'Widen nodeSubnetPrefix. Subnet size is immutable once resources are attached.'
      else
        add_result 'capacity.nodeSubnet' "$CAT" pass "Node subnet has $NODE_USABLE usable IPs for a maximum of $TOTAL_MAX_NODES nodes plus upgrade surge."
      fi
    done

    if [ "$NETWORK_PROFILE" = 'cni-podsubnet' ]; then
      for i in "${!SUBNET_NAMES[@]}"; do
        [ "${SUBNET_NAMES[$i]}" = 'podSubnetPrefix' ] || continue
        POD_USABLE=$(( $(cidr_size "${SUBNET_VALUES[$i]}") - 5 ))
        POD_NEEDED=$((TOTAL_MAX_NODES * MAX_PODS))
        if [ "$POD_USABLE" -lt "$POD_NEEDED" ]; then
          add_result 'capacity.podSubnet' "$CAT" fail \
            "Pod subnet ${SUBNET_VALUES[$i]} has $POD_USABLE usable IPs but $TOTAL_MAX_NODES nodes x $MAX_PODS pods needs $POD_NEEDED." \
            'Widen podSubnetPrefix, lower maxPodsPerNode, or switch networkProfile to cni-overlay which does not consume VNet addresses for pods.'
        else
          add_result 'capacity.podSubnet' "$CAT" pass "Pod subnet has $POD_USABLE usable IPs for $POD_NEEDED pod addresses."
        fi
      done
    elif [ -n "$POD_CIDR" ]; then
      OVERLAY_SIZE="$(cidr_size "$POD_CIDR")"
      OVERLAY_NEEDED=$((TOTAL_MAX_NODES * MAX_PODS))
      if [ "$OVERLAY_SIZE" -lt "$OVERLAY_NEEDED" ]; then
        add_result 'capacity.podCidr' "$CAT" fail "podCidr $POD_CIDR holds $OVERLAY_SIZE addresses but $TOTAL_MAX_NODES nodes x $MAX_PODS pods needs $OVERLAY_NEEDED." \
          'Widen podCidr. It is overlay space and does not consume VNet addresses, so /16 is a safe default.'
      else
        add_result 'capacity.podCidr' "$CAT" pass "Overlay podCidr $POD_CIDR holds $OVERLAY_SIZE addresses for $OVERLAY_NEEDED pods."
      fi
    fi
  fi
else
  # Two different reasons land here and they are not interchangeable. Saying "no VNet" when the
  # real reason is "you did not tell me the address plan" reads as reassurance when it is a gap.
  if [ "$ARCHITECTURE_AZURE_REGION" != 'true' ]; then
    add_result 'cidr.parse' "$CAT" skip "Architecture '$ARCHITECTURE' does not create an Azure VNet, so there is no Azure address plan to validate."
  else
    add_result 'cidr.parse' "$CAT" skip \
      'No --param-file was supplied, so the address plan was never read and NOTHING about it was validated.' \
      "Re-run with --param-file infra/params/${ARCHITECTURE}.bicepparam to check CIDR parsing, overlap, subnet sizing and Service CIDR conflicts."
  fi
fi

# ================================================================================================
# 4. Quota
# ================================================================================================

CAT='quota'

# Provider registration is a property of the subscription, not of the parameter file, so it is
# checked whenever a cluster is in scope. It used to sit inside the vCPU branch below, which meant
# running without --param-file silently skipped it - and an unregistered provider fails every
# deployment regardless of how the address plan is written.
if [ "$ARCHITECTURE_CREATES_CLUSTER" = 'true' ]; then
  if [ "$(aztsv provider show -n Microsoft.ContainerService --query registrationState)" = 'Registered' ]; then
    add_result 'quota.provider' "$CAT" pass 'Microsoft.ContainerService is registered on this subscription.'
  else
    add_result 'quota.provider' "$CAT" fail 'Microsoft.ContainerService is not registered.' 'az provider register -n Microsoft.ContainerService --wait'
  fi
fi

if [ "$ARCHITECTURE_CREATES_CLUSTER" = 'true' ] && [ "$ARCHITECTURE_AZURE_REGION" = 'true' ] && [ -n "$PARAM_FILE" ]; then
  SYS_SKU="$(param_get "$PARAMS" systemNodePool.vmSize '')"
  USR_SKU=''
  [ "$(param_get "$PARAMS" deployUserNodePool false)" = 'true' ] && USR_SKU="$(param_get "$PARAMS" userNodePool.vmSize '')"
  REQUESTED_ZONES="$(param_get "$PARAMS" systemNodePool.zones '')"

  USAGE_JSON="$(az vm list-usage -l "$LOCATION" -o json 2>/dev/null || echo '[]')"

  for SKU in $(printf '%s\n%s\n' "$SYS_SKU" "$USR_SKU" | grep -v '^$' | grep -v '^n/a$' | sort -u); do
    # The Resource SKUs API is not self-consistent: the same query omits the restrictions array on
    # a minority of calls, so a single call makes the zone-availability verdict flap between warn
    # and silent. --all plus a union over up to three samples makes it stable, and a preflight that
    # sometimes stays quiet about a real capacity constraint is worse than no preflight at all.
    MATCH=''
    RESTRICTIONS='[]'
    for _attempt in 1 2 3; do
      SKU_JSON="$(az vm list-skus -l "$LOCATION" --size "$SKU" --resource-type virtualMachines --all -o json 2>/dev/null || echo '[]')"
      HIT="$(echo "$SKU_JSON" | jq -c --arg n "$SKU" '[.[] | select(.name == $n)] | first // empty')"
      [ -n "$HIT" ] || continue
      MATCH="$HIT"
      RESTRICTIONS="$(jq -n --argjson a "$RESTRICTIONS" --argjson b "$(echo "$HIT" | jq -c '.restrictions // []')" '($a + $b) | unique')"
      [ "$(echo "$RESTRICTIONS" | jq 'length')" -gt 0 ] && break
    done
    if [ -z "$MATCH" ]; then
      add_result "quota.sku.$SKU" "$CAT" fail "VM size $SKU is not offered in $LOCATION." \
        "az vm list-skus -l $LOCATION --resource-type virtualMachines --all -o table"
      continue
    fi

    # Restrictions come in two architectures: a Location restriction means the SKU is unusable here at
    # all, a Zone restriction only rules out some zones - and that matters only if the node pool
    # actually asks for those zones.
    while IFS=$'\t' read -r rtype rreason rzones; do
      [ -n "$rtype" ] || continue
      if [ "$rtype" = 'Zone' ] && [ -n "$rzones" ]; then
        BLOCKED=''; TOTAL_REQ=0
        IFS=',' read -ra _rz <<< "$REQUESTED_ZONES"
        for z in ${_rz[@]+"${_rz[@]}"}; do
          [ -n "$z" ] || continue
          TOTAL_REQ=$((TOTAL_REQ + 1))
          case ",$rzones," in *",$z,"*) BLOCKED="$BLOCKED $z" ;; esac
        done
        BLOCKED_COUNT="$(echo "$BLOCKED" | wc -w | tr -d ' ')"
        if [ "$BLOCKED_COUNT" -gt 0 ] && [ "$BLOCKED_COUNT" -ge "$TOTAL_REQ" ]; then
          add_result "quota.restriction.$SKU" "$CAT" fail \
            "$SKU is unavailable ($rreason) in every zone the node pool requests ($REQUESTED_ZONES) in $LOCATION." \
            "Pick another SKU, another region, or change the requested zones."
        elif [ "$BLOCKED_COUNT" -gt 0 ]; then
          add_result "quota.restriction.$SKU" "$CAT" warn \
            "$SKU is unavailable ($rreason) in zone(s)$BLOCKED of $LOCATION; the remaining requested zones are usable." \
            'Zone-imbalanced node pools scale unevenly. Consider dropping the restricted zone from the node pool definition.'
        else
          add_result "quota.restriction.$SKU" "$CAT" pass "$SKU has a zone restriction in $LOCATION ($rzones) but the node pool does not request those zones."
        fi
      else
        add_result "quota.restriction.$SKU" "$CAT" fail "$SKU is not available to this subscription in ${LOCATION}: $rreason." \
          "Choose another SKU or region, or raise a support request to lift the restriction."
      fi
    done < <(echo "$RESTRICTIONS" | jq -r '.[] | [(.type // "Location"), (.reasonCode // "Restricted"), ((.restrictionInfo.zones // []) | join(","))] | @tsv')

    VCPU_PER_NODE="$(echo "$MATCH" | jq -r '.capabilities[]? | select(.name=="vCPUs") | .value' | head -1)"
    [ -n "$VCPU_PER_NODE" ] || VCPU_PER_NODE=0
    FAMILY="$(echo "$MATCH" | jq -r '.family')"

    NODES=0
    [ "$SYS_SKU" = "$SKU" ] && NODES=$((NODES + $(param_get "$PARAMS" systemNodePool.maxCount 3)))
    [ "$USR_SKU" = "$SKU" ] && NODES=$((NODES + $(param_get "$PARAMS" userNodePool.maxCount 3)))
    REQUIRED=$((VCPU_PER_NODE * NODES))
    REQUIRED_SURGE=$(( (REQUIRED * 134 + 99) / 100 ))

    for QN in "$FAMILY" 'cores'; do
      LIMIT="$(echo "$USAGE_JSON" | jq -r --arg n "$QN" '[.[] | select(.name.value == $n)] | first | .limit // empty')"
      CURRENT="$(echo "$USAGE_JSON" | jq -r --arg n "$QN" '[.[] | select(.name.value == $n)] | first | .currentValue // empty')"
      [ -n "$LIMIT" ] || continue
      HEADROOM=$((LIMIT - CURRENT))
      LABEL="family $QN"; [ "$QN" = 'cores' ] && LABEL='regional total cores'
      ID="quota.$(echo "$LABEL" | tr -c 'a-zA-Z0-9' '_' | sed 's/_*$//')"
      if [ "$HEADROOM" -lt "$REQUIRED" ]; then
        add_result "$ID" "$CAT" fail "$LABEL: only $HEADROOM vCPUs available, but $SKU x $NODES nodes needs $REQUIRED." \
          "Lower maxCount, choose a smaller SKU, or request an increase. Portal: Subscription > Usage + quotas > $LABEL."
      elif [ "$HEADROOM" -lt "$REQUIRED_SURGE" ]; then
        add_result "$ID" "$CAT" warn "$LABEL: $HEADROOM vCPUs available. The cluster fits at $REQUIRED vCPUs but a 33% upgrade surge needs $REQUIRED_SURGE, so upgrades will stall at maximum scale." \
          "Raise the quota to at least $REQUIRED_SURGE vCPUs, or lower maxCount."
      else
        add_result "$ID" "$CAT" pass "$LABEL: $HEADROOM vCPUs available, $REQUIRED required ($REQUIRED_SURGE including upgrade surge)."
      fi
    done
  done
else
  if [ "$ARCHITECTURE_CREATES_CLUSTER" != 'true' ]; then
    add_result 'quota.vcpu' "$CAT" skip "Architecture '$ARCHITECTURE' does not create Azure compute."
  else
    add_result 'quota.vcpu' "$CAT" skip 'No node SKU available to check (supply --param-file).' \
      "Re-run with --param-file infra/params/${ARCHITECTURE}.bicepparam to check vCPU headroom, SKU availability and zone restrictions before deploying."
  fi
fi

# ================================================================================================
# 5-8. Live path validation from inside the node subnet
# ================================================================================================

CAT='network-path'
LIVE_SUBNET_ID="$NODE_SUBNET_ID"

if [ "$ARCHITECTURE_AZURE_REGION" = 'true' ] && [ "$SKIP_LIVE_PROBE" = '0' ] && [ -z "$LIVE_SUBNET_ID" ] && [ -n "$RESOURCE_GROUP" ] && [ -n "$PARAM_FILE" ]; then
  GEO="$(geo_code "$LOCATION")"
  VNET_NAME="vnet-$(param_get "$PARAMS" customer contoso)-$(param_get "$PARAMS" environment dev)-${GEO}-$(param_get "$PARAMS" instance 01)"
  VNET_NAME="$(echo "$VNET_NAME" | tr '[:upper:]' '[:lower:]')"
  LIVE_SUBNET_ID="$(aztsv network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n snet-nodes --query id || true)"
  [ -n "$LIVE_SUBNET_ID" ] && echo "Discovered node subnet from a previous deployment: $VNET_NAME/snet-nodes"
fi

PROBE_OUTPUT=''
if [ "$ARCHITECTURE_AZURE_REGION" != 'true' ]; then
  add_result 'path.probe' "$CAT" skip "Architecture '$ARCHITECTURE' has no Azure node subnet. Validate the site network with the Arc connectivity checklist in docs/networking.md."
elif [ "$SKIP_LIVE_PROBE" = '1' ]; then
  add_result 'path.probe' "$CAT" skip '--skip-live-probe was set; no VM was deployed and the real network path was NOT tested.'
elif [ -z "$RESOURCE_GROUP" ]; then
  add_result 'path.probe' "$CAT" skip 'No --resource-group supplied, so no probe VM could be created.'
elif [ -z "$LIVE_SUBNET_ID" ]; then
  add_result 'path.probe' "$CAT" skip \
    'The node subnet does not exist yet, so the live network path could not be tested.' \
    'For a bring-your-own network, pass --node-subnet-id <subnet resource id>. For a greenfield build, re-run preflight after the first deployment.'
else
  PROBE_VM_NAME="vm-preflight-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  evidence_set probeVmName "$PROBE_VM_NAME"
  evidence_set probeSubnetId "$LIVE_SUBNET_ID"

  echo "Creating probe VM $PROBE_VM_NAME in the node subnet (this takes about a minute)..."
  if VM_JSON="$(az vm create -g "$RESOURCE_GROUP" -n "$PROBE_VM_NAME" \
      --image "$PROBE_VM_IMAGE" --size "$PROBE_VM_SIZE" --subnet "$LIVE_SUBNET_ID" \
      --public-ip-address '' --nsg '' --admin-username azureuser --generate-ssh-keys \
      --os-disk-delete-option Delete --nic-delete-option Delete \
      --tags purpose=aks-preflight managedBy=aks-architectures -o json 2>&1)"; then
    PROBE_VM_CREATED=1
    PRIVATE_IP="$(echo "$VM_JSON" | jq -r '.privateIpAddress')"
    NIC_NAME="${PROBE_VM_NAME}-nic"

    # ---- 5/6. Endpoint reachability from inside the subnet -----------------------------------
    EXTRA_CSV="$(IFS=,; echo "${ADDITIONAL_FQDNS[*]-}")"
    TMP_SCRIPT="$(mktemp)"
    {
      echo '#!/usr/bin/env bash'
      printf "set -- '%s' '%s' '%s'\n" "$LOCATION" "$API_SERVER_FQDN" "$EXTRA_CSV"
      cat "${SCRIPT_DIR}/lib/probe.sh"
    } > "$TMP_SCRIPT"

    echo 'Running endpoint probes from inside the subnet...'
    if RUN_JSON="$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$PROBE_VM_NAME" \
        --command-id RunShellScript --scripts "@$TMP_SCRIPT" -o json 2>&1)"; then
      PROBE_OUTPUT="$(echo "$RUN_JSON" | jq -r '.value[0].message // ""')"
      evidence_set probeRawOutput "$PROBE_OUTPUT"

      while IFS='|' read -r _ pid pstatus pmsg; do
        [ -n "$pid" ] || continue
        REM=''
        if [ "$pstatus" = 'fail' ] || [ "$pstatus" = 'warn' ]; then
          case "$pid" in
            ntp) REM='Allow UDP 123 outbound, or configure the nodes against an internal NTP server. Clock skew breaks TLS and AAD token validation on every node.' ;;
            wireserver) REM='Allow outbound to 168.63.129.16 and ensure no UDR sends 168.63.129.16/32 to a firewall.' ;;
            imds) REM='Allow outbound to 169.254.169.254. Kubelet and workload identity both depend on IMDS.' ;;
            *) if [ "$EGRESS" = 'udr-firewall' ]; then
                 REM='Add the FQDN to the Azure Firewall application rule collection, or use the AzureKubernetesService FQDN tag which covers the AKS-required set.'
               else
                 REM='Check the subnet NSG outbound rules and any UDR forcing 0.0.0.0/0 to an appliance.'
               fi ;;
          esac
        fi
        add_result "path.$pid" "$CAT" "$pstatus" "$pmsg" "$REM"
      done < <(echo "$PROBE_OUTPUT" | grep '^PREFLIGHT|' || true)

      while IFS='|' read -r _ ckey cval; do
        [ -n "$ckey" ] && evidence_set "probe_$ckey" "$cval"
      done < <(echo "$PROBE_OUTPUT" | grep '^CONTEXT|' || true)

      OBSERVED_EGRESS="$(echo "$PROBE_OUTPUT" | sed -n 's/^CONTEXT|observed_egress_ip|//p' | tr -d '\r')"
      if [[ "$OBSERVED_EGRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [ "$ARCHITECTURE_API_ACCESS" = 'authorizedIpRanges' ]; then
          DECLARED="$(param_get "$PARAMS" authorizedIpRanges '')"
          COVERED=0
          IFS=',' read -ra _ranges <<< "$DECLARED"
          for r in ${_ranges[@]+"${_ranges[@]}"}; do
            [ -n "$r" ] && cidr_valid "$r" && ip_in_cidr "$OBSERVED_EGRESS" "$r" && COVERED=1
          done
          if [ "$COVERED" = '1' ]; then
            add_result 'path.egressIpCovered' "$CAT" pass "Observed egress IP $OBSERVED_EGRESS is covered by the declared authorized IP ranges."
          else
            add_result 'path.egressIpCovered' "$CAT" warn \
              "Nodes egress as $OBSERVED_EGRESS, which is not in the declared authorized IP ranges ($DECLARED)." \
              "main.bicep appends the NAT Gateway or Firewall public IP automatically, so this is usually fine. If you manage the list by hand, add ${OBSERVED_EGRESS}/32."
          fi
        else
          add_result 'path.egressIp' "$CAT" pass "Nodes egress from this subnet as $OBSERVED_EGRESS."
        fi
      fi
    else
      add_result 'path.runCommand' "$CAT" fail \
        'Could not run commands on the probe VM. The guest agent could not reach Azure.' \
        'Check that the NSG allows outbound to 168.63.129.16 and that no UDR overrides 168.63.129.16/32.'
    fi
    rm -f "$TMP_SCRIPT"

    # ---- 3. Effective routes -----------------------------------------------------------------
    echo 'Reading Network Watcher effective routes...'
    ROUTES="$(az network nic show-effective-route-table -g "$RESOURCE_GROUP" -n "$NIC_NAME" -o json 2>/dev/null || echo '')"
    if [ -z "$ROUTES" ]; then
      add_result 'path.effectiveRoutes' "$CAT" warn 'Effective route table could not be read.' \
        "az network nic show-effective-route-table -g $RESOURCE_GROUP -n $NIC_NAME -o table"
    else
      DEFAULT_ROUTE="$(echo "$ROUTES" | jq -r '[.value[] | select(.state=="Active") | select(.addressPrefix | index("0.0.0.0/0"))] | first // empty')"
      if [ -z "$DEFAULT_ROUTE" ]; then
        add_result 'path.defaultRoute' "$CAT" fail 'No active 0.0.0.0/0 route on the node NIC.' \
          'Nodes cannot reach the internet or a firewall. Restore the default route.'
      else
        HOP="$(echo "$DEFAULT_ROUTE" | jq -r '.nextHopType')"
        HOP_IP="$(echo "$DEFAULT_ROUTE" | jq -r '(.nextHopIpAddress // []) | join(",")')"
        case "$EGRESS" in
          udr-firewall) EXPECTED='VirtualAppliance' ;;
          natgateway|loadbalancer) EXPECTED='Internet' ;;
          *) EXPECTED="$HOP" ;;
        esac
        if [ "$HOP" = "$EXPECTED" ]; then
          add_result 'path.defaultRoute' "$CAT" pass "0.0.0.0/0 next hop is $HOP ($HOP_IP), which matches egress mode '$EGRESS'."
        else
          if [ "$EGRESS" = 'udr-firewall' ]; then
            REM='The route table is not associated with the node subnet, or its next hop IP does not match the firewall private IP. Compare the expectedFirewallPrivateIp and actualFirewallPrivateIp deployment outputs.'
          else
            REM="Remove the user-defined route sending 0.0.0.0/0 to $HOP, or switch egress to udr-firewall."
          fi
          add_result 'path.defaultRoute' "$CAT" fail "0.0.0.0/0 next hop is $HOP ($HOP_IP) but egress mode '$EGRESS' expects $EXPECTED." "$REM"
        fi

        # A UDR pointing at a firewall that does not exist yet is the classic silent failure: the
        # deployment validates, the nodes never register, and the error surfaces 40 minutes later.
        if [ "$HOP" = 'VirtualAppliance' ] && [ -n "$HOP_IP" ]; then
          if ! echo "$PROBE_OUTPUT" | grep -qE '^PREFLIGHT\|(arm|mcr)\|pass'; then
            add_result 'path.applianceReachable' "$CAT" fail \
              "All traffic is forced to the virtual appliance at $HOP_IP, and endpoint probes through it failed." \
              "Confirm an appliance is actually listening on $HOP_IP and that its rules allow the AKS-required FQDNs. Azure Firewall: add the AzureKubernetesService FQDN tag."
          fi
        fi
      fi

      BLACKHOLE="$(echo "$ROUTES" | jq -r '[.value[] | select(.state=="Active") | select(.nextHopType=="None") | select((.addressPrefix | index("0.0.0.0/0")) | not) | (.addressPrefix | join(","))] | join("; ")')"
      if [ -n "$BLACKHOLE" ]; then
        add_result 'path.blackholeRoutes' "$CAT" warn "Route(s) with next hop 'None' will black-hole traffic: $BLACKHOLE" \
          'Confirm each of these is intentional. A None next hop silently drops packets with no ICMP response.'
      fi
    fi

    # ---- 4. IP flow verify -------------------------------------------------------------------
    echo 'Running Network Watcher IP flow verify...'
    az network watcher configure -l "$LOCATION" --enabled true >/dev/null 2>&1 || true

    FLOW_TARGETS=''
    for pid in arm mcr aad; do
      tip="$(echo "$PROBE_OUTPUT" | grep "^PREFLIGHT|$pid|" | grep -oE '(via|resolved to) [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [ -n "$tip" ] && FLOW_TARGETS="$FLOW_TARGETS $pid=$tip"
    done
    [ -n "$FLOW_TARGETS" ] || FLOW_TARGETS=' generic-internet=1.1.1.1'

    for entry in $FLOW_TARGETS; do
      tname="${entry%%=*}"; tip="${entry#*=}"
      FLOW="$(az network watcher test-ip-flow --vm "$PROBE_VM_NAME" -g "$RESOURCE_GROUP" --nic "$NIC_NAME" \
        --direction Outbound --protocol TCP --local "${PRIVATE_IP}:33000" --remote "${tip}:443" -o json 2>/dev/null || echo '')"
      if [ -z "$FLOW" ]; then
        add_result "path.ipFlow.$tname" "$CAT" warn "IP flow verify to ${tip}:443 could not be evaluated." \
          'Network Watcher may be disabled in this region, or the caller lacks Network Contributor.'
      elif [ "$(echo "$FLOW" | jq -r '.access')" = 'Allow' ]; then
        add_result "path.ipFlow.$tname" "$CAT" pass "Outbound TCP 443 to $tip is allowed by NSG rule '$(echo "$FLOW" | jq -r '.ruleName')'."
      else
        RULE="$(echo "$FLOW" | jq -r '.ruleName')"
        add_result "path.ipFlow.$tname" "$CAT" fail "Outbound TCP 443 to $tip is DENIED by NSG rule '$RULE'." \
          "Amend or remove NSG rule '$RULE'. AKS nodes require outbound 443 to the Azure control plane, MCR and AAD."
      fi
    done
  else
    add_result 'path.probe' "$CAT" fail \
      "Could not create the probe VM: ${VM_JSON}" \
      'This is itself a finding - the subnet may be full, policy-blocked or delegated.'
  fi
fi

# ================================================================================================
# 9. Private DNS reachability for aks-private-link
# ================================================================================================

CAT='private-dns'
if [ "$ARCHITECTURE" = 'aks-private-link' ]; then
  ZONE_JSON="$(az network private-dns zone list -o json 2>/dev/null | jq --arg l "$LOCATION" '[.[] | select(.name | endswith(".\($l).azmk8s.io"))] | first // empty' || echo '')"
  if [ -z "$ZONE_JSON" ]; then
    add_result 'dns.zoneExists' "$CAT" skip "No privatelink.${LOCATION}.azmk8s.io private DNS zone found yet." \
      'AKS creates it in the node resource group on first deployment. Re-run preflight afterwards to confirm the operator network can resolve it.'
  else
    ZONE_NAME="$(echo "$ZONE_JSON" | jq -r '.name')"
    ZONE_RG="$(echo "$ZONE_JSON" | jq -r '.id' | cut -d/ -f5)"
    add_result 'dns.zoneExists' "$CAT" pass "Found private DNS zone $ZONE_NAME."

    LINK_COUNT="$(aztsv network private-dns link vnet list -g "$ZONE_RG" -z "$ZONE_NAME" --query 'length(@)' || echo 0)"
    if [ "$LINK_COUNT" = '0' ]; then
      add_result 'dns.zoneLinked' "$CAT" fail "Private DNS zone $ZONE_NAME has no virtual network links." \
        "kubectl will fail to resolve the API server. Link the operator's VNet: az network private-dns link vnet create -g $ZONE_RG -z $ZONE_NAME -n operator-link -v <vnetId> -e false"
    else
      add_result 'dns.zoneLinked' "$CAT" pass "Private DNS zone is linked to $LINK_COUNT VNet(s)."
      INBOUND=''
      while IFS=$'\t' read -r rname rrg; do
        [ -n "$rname" ] || continue
        ips="$(aztsv dns-resolver inbound-endpoint list --resolver-name "$rname" -g "$rrg" \
                --query '[].ipConfigurations[].privateIpAddress' | tr '\n' ' ')"
        INBOUND="$INBOUND $ips"
      done < <(az dns-resolver list -o json 2>/dev/null | jq -r '.[] | [.name, (.id | split("/")[4])] | @tsv' || true)

      if [ -n "$(echo "$INBOUND" | tr -d ' ')" ]; then
        add_result 'dns.resolverInbound' "$CAT" pass "DNS Private Resolver inbound endpoint(s) at$INBOUND can serve on-premises conditional forwarders."
      else
        add_result 'dns.resolverInbound' "$CAT" warn \
          'No DNS Private Resolver found. Operators outside a linked VNet will not resolve the API server.' \
          'Set features.privateDnsResolver to true and point the on-premises conditional forwarder for the azmk8s.io zone at the inbound endpoint IP.'
      fi
    fi
  fi
else
  add_result 'dns.zoneExists' "$CAT" skip 'Private DNS zone validation applies to the aks-private-link architecture only.'
fi

# ================================================================================================
# 10. Identity: can this caller create the role assignments the deployment depends on
#
# AKS validates the control plane identity's rights on the VNet, the route table and the registry
# WHILE it provisions. Granting them afterwards produces a cluster that came up and then cannot
# attach a load balancer or pull an image. The deployment therefore creates those assignments
# itself, which means the person running it needs Microsoft.Authorization/roleAssignments/write.
# Contributor does not include it. This is the most common way a deployment gets three quarters
# of the way through and then fails on something that looks unrelated.
# ================================================================================================

CAT='identity'
if [ "$ARCHITECTURE_AZURE_REGION" != 'true' ]; then
  add_result 'identity.roleAssignmentWrite' "$CAT" skip \
    "Architecture '$ARCHITECTURE' creates no Azure resources that need role assignments."
else
  # Scope the question as narrowly as the deployment will actually run. Permissions inherit
  # downward, so asking at the resource group is the honest test when we know the group.
  if [ -n "$RESOURCE_GROUP" ]; then
    PERM_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}"
    PERM_LABEL="resource group '$RESOURCE_GROUP'"
  else
    PERM_SCOPE="/subscriptions/${SUB_ID}"
    PERM_LABEL="subscription '$SUB_NAME'"
  fi

  # This endpoint returns the effective permissions of the CALLER at the scope, already collapsed
  # across every assignment they hold. It is the only way to answer the question without being
  # able to read role assignments, which is itself a privilege the caller may not have.
  PERMS="$(az rest --method get \
    --url "https://management.azure.com${PERM_SCOPE}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
    -o json 2>/dev/null | jq -c '.value // []' || echo '[]')"

  if [ "$PERMS" = '[]' ]; then
    add_result 'identity.roleAssignmentWrite' "$CAT" warn \
      "Effective permissions at $PERM_LABEL could not be read, so role assignment rights are unverified." \
      'Deployment will still be attempted. If it fails with AuthorizationFailed on Microsoft.Authorization/roleAssignments/write, ask for User Access Administrator or RBAC Administrator on the resource group.'
  else
    # An action grants the target only if some assignment matches it AND that same assignment does
    # not claw it back through a notAction. The wildcard can appear anywhere, not just at the end:
    # Contributor holds actions ["*"] but notActions ["Microsoft.Authorization/*/Write"], which is
    # exactly the case a naive prefix match gets wrong and reports as a pass.
    CAN_ASSIGN="$(echo "$PERMS" | jq -r '
      def grants($pattern; $action):
        ($pattern | gsub("\\."; "\\.") | gsub("\\*"; ".*")) as $re
        | ($action | test("^\($re)$"; "i"));
      "Microsoft.Authorization/roleAssignments/write" as $target
      | [ .[] | select(
            ([ .actions[]?    | select(grants(.; $target)) ] | length) > 0 and
            ([ .notActions[]? | select(grants(.; $target)) ] | length) == 0
          ) ] | length > 0' 2>/dev/null || echo 'unknown')"

    case "$CAN_ASSIGN" in
      true)
        add_result 'identity.roleAssignmentWrite' "$CAT" pass \
          "Caller can create role assignments at $PERM_LABEL."
        ;;
      false)
        add_result 'identity.roleAssignmentWrite' "$CAT" fail \
          "Caller cannot create role assignments at $PERM_LABEL (Microsoft.Authorization/roleAssignments/write is not granted)." \
          "Contributor is not enough - it holds actions [*] but explicitly excludes Microsoft.Authorization/*/Write. Ask for Owner, User Access Administrator, or Role Based Access Control Administrator on that scope: az role assignment create --assignee <you> --role 'Role Based Access Control Administrator' --scope $PERM_SCOPE"
        ;;
      *)
        # Never turn a tooling problem into a false failure. Say so and move on.
        add_result 'identity.roleAssignmentWrite' "$CAT" warn \
          'Effective permissions were returned but could not be evaluated.' \
          'This needs a jq built with regular expression support. Verify manually: az role assignment list --assignee <you> --scope '"$PERM_SCOPE"' --include-inherited'
        ;;
    esac
  fi

  # Spell out what the deployment is about to grant. A reviewer who can see the list can approve
  # it; one who cannot is approving a black box.
  GRANTS='Network Contributor on the VNet; Managed Identity Operator on the kubelet identity'
  [ "$EGRESS" = 'udr-firewall' ] && GRANTS="$GRANTS; Network Contributor on the route table (required for userDefinedRouting)"
  [ "$ARCHITECTURE_API_ACCESS" = 'privateLink' ] && GRANTS="$GRANTS; Private DNS Zone Contributor on the API server zone"
  GRANTS="$GRANTS; AcrPull on the registry; Key Vault Secrets User for the CSI driver"
  add_result 'identity.grantsPlanned' "$CAT" pass \
    "The deployment will create these role assignments: ${GRANTS}." \
    'Each one is scoped to a single resource, never to the subscription. Review infra/modules/rbac/pre-cluster.bicep.'
fi

# ================================================================================================
# Report
# ================================================================================================

print_results_table "PRE-FLIGHT RESULTS - $ARCHITECTURE / $NETWORK_PROFILE / $EGRESS"

[ -n "$JSON_OUT" ] || JSON_OUT="./preflight-${ARCHITECTURE}.json"
OUTCOME=pass; [ "$COUNT_FAIL" -gt 0 ] && OUTCOME=fail

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg architecture "$ARCHITECTURE" --arg np "$NETWORK_PROFILE" --arg eg "$EGRESS" \
  --arg loc "$LOCATION" --arg rg "$RESOURCE_GROUP" --arg outcome "$OUTCOME" \
  --argjson pass "$COUNT_PASS" --argjson warn "$COUNT_WARN" --argjson skip "$COUNT_SKIP" --argjson fail "$COUNT_FAIL" \
  --slurpfile results "$RESULTS_FILE" --slurpfile evidence "$EVIDENCE_FILE" \
  '{schemaVersion:"2.0.0", tool:"aks-architectures/preflight", timestampUtc:$ts, architecture:$architecture,
    networkProfile:$np, egress:$eg, location:$loc, resourceGroup:$rg, outcome:$outcome,
    summary:{pass:$pass, warn:$warn, skip:$skip, fail:$fail},
    results:$results[0], evidence:$evidence[0]}' > "$JSON_OUT"

echo "Machine-readable result: $JSON_OUT"

if [ "$COUNT_FAIL" -gt 0 ]; then
  echo 'PRE-FLIGHT FAILED. Fix the items above before deploying.' >&2
  exit 1
fi
if [ "$COUNT_SKIP" -gt 0 ]; then
  echo "PRE-FLIGHT PASSED, with $COUNT_SKIP check(s) skipped. Read the SKIP lines - a skipped network-path check means the real path was never tested."
else
  echo 'PRE-FLIGHT PASSED.'
fi
exit 0
