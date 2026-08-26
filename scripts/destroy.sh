#!/usr/bin/env bash
# Removes everything an architecture deployment created, including the artefacts that outlive the resource
# group: role assignments scoped outside it, private DNS zone links into other VNets, the
# subscription-scope policy definition, soft-deleted key vaults, and Arc agents on the cluster.
#
# Deleting the resource group on its own is not a clean teardown. It leaves behind:
#   - role assignments whose scope is an existing VNet in another resource group
#   - private DNS zone links pointing at VNets outside the group
#   - the subscription-scope deny-public-IP policy definition, which is not a group resource
#   - soft-deleted key vaults, which keep their names reserved for 90 days
#   - connectedk8s agents running inside a non-Azure cluster, still pointed at a dead ARM resource
#
#   ./destroy.sh -g rg-aks-prod-wus3
#   ./destroy.sh -g rg-aks-dev --force --purge-key-vaults

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

RESOURCE_GROUP=''
SUBSCRIPTION_ID=''
ARCHITECTURE=''
FORCE=0
PURGE_KEY_VAULTS=0
KEEP_POLICY_DEFINITION=0
KEEP_RESOURCE_GROUP=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: destroy.sh --resource-group <name> [options]

Required:
  -g, --resource-group <name>   Resource group to tear down.

Options:
  --subscription <id>           Subscription. Default: current az context.
  --architecture <name>               Narrows the policy-definition search to one architecture.
  --force                       Skip the confirmation prompt.
  --purge-key-vaults            Purge soft-deleted key vaults so their names are released.
  --keep-policy-definition      Leave the subscription-scope policy definition in place.
  --keep-resource-group         Do everything except delete the resource group.
  --dry-run                     Print what would be deleted and exit.
  -h, --help                    This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --architecture) ARCHITECTURE="$2"; shift 2 ;;
    --force|-y|--yes) FORCE=1; shift ;;
    --purge-key-vaults) PURGE_KEY_VAULTS=1; shift ;;
    --keep-policy-definition) KEEP_POLICY_DEFINITION=1; shift ;;
    --keep-resource-group) KEEP_RESOURCE_GROUP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

SUB_ID="$(aztsv account show --query id)"
RG_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}"
ACTION_COUNT=0

act() {
  local description="$1"; shift
  ACTION_COUNT=$((ACTION_COUNT + 1))
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] ${description}"; return 0; fi
  echo "  ${description}"
  "$@"
}

echo
echo 'AKS ARCHITECTURES - DESTROY'
echo "Subscription:   ${SUB_ID}"
echo "Resource group: ${RESOURCE_GROUP}"
echo

RG_LOCATION="$(aztsv group show -n "$RESOURCE_GROUP" --query location)"
if [ -z "$RG_LOCATION" ]; then
  echo "Resource group '${RESOURCE_GROUP}' does not exist. Continuing with subscription-scope cleanup only."
fi

# ------------------------------------------------------------------------------------------------
# 1. Inventory, taken before anything is deleted
# ------------------------------------------------------------------------------------------------

echo 'Taking inventory...'

CLUSTERS=(); CONNECTED=(); DNS_ZONES=(); PRINCIPALS=(); KEY_VAULTS=()
if [ -n "$RG_LOCATION" ]; then
  mapfile -t CLUSTERS   < <(aztsv aks list -g "$RESOURCE_GROUP" --query '[].name')
  mapfile -t CONNECTED  < <(aztsv resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Kubernetes/connectedClusters --query '[].name')
  mapfile -t DNS_ZONES  < <(aztsv network private-dns zone list -g "$RESOURCE_GROUP" --query '[].name')
  mapfile -t KEY_VAULTS < <(aztsv keyvault list -g "$RESOURCE_GROUP" --query '[].name')
  mapfile -t PRINCIPALS < <(aztsv identity list -g "$RESOURCE_GROUP" --query '[].principalId')

  # AKS control plane and kubelet identities are the ones that get assignments outside the group.
  for c in "${CLUSTERS[@]+"${CLUSTERS[@]}"}"; do
    [ -n "$c" ] || continue
    while read -r p; do [ -n "$p" ] && [ "$p" != 'null' ] && PRINCIPALS+=("$p"); done < <(
      aztsv aks show -g "$RESOURCE_GROUP" -n "$c" --query '[identity.principalId,identityProfile.kubeletidentity.objectId]'
    )
  done
fi
mapfile -t PRINCIPALS < <(printf '%s\n' "${PRINCIPALS[@]+"${PRINCIPALS[@]}"}" | grep -v '^$' | sort -u)

count() { local -n _a=$1; echo "${#_a[@]}"; }
printf '  %-34s %s\n' 'AKS clusters:' "$(count CLUSTERS)"
printf '  %-34s %s\n' 'Connected clusters:' "$(count CONNECTED)"
printf '  %-34s %s\n' 'Private DNS zones:' "$(count DNS_ZONES)"
printf '  %-34s %s\n' 'Managed identities:' "$(count PRINCIPALS)"
printf '  %-34s %s\n' 'Key vaults:' "$(count KEY_VAULTS)"

# Role assignments held by those identities anywhere in the subscription. Anything scoped inside
# the group disappears with it; anything outside has to be deleted by hand or it becomes an
# orphaned assignment with an unresolvable principal.
EXTERNAL_ASSIGNMENTS=()
for p in "${PRINCIPALS[@]+"${PRINCIPALS[@]}"}"; do
  [ -n "$p" ] || continue
  while IFS='|' read -r aid ascope arole; do
    [ -n "$aid" ] || continue
    case "$ascope" in
      "$RG_SCOPE"*) ;;
      *) EXTERNAL_ASSIGNMENTS+=("${aid}|${ascope}|${arole}") ;;
    esac
  done < <(aztsv role assignment list --assignee-object-id "$p" --all --query "[].join('|',[id,scope,roleDefinitionName])")
done
printf '  %-34s %s\n' 'Role assignments outside group:' "${#EXTERNAL_ASSIGNMENTS[@]}"

# Private DNS zone links whose target VNet lives outside this group. The link object is a child of
# the zone, so it dies with the group, but listing them here makes the blast radius explicit and
# lets --dry-run show exactly which foreign networks are about to lose name resolution.
EXTERNAL_LINKS=()
for z in "${DNS_ZONES[@]+"${DNS_ZONES[@]}"}"; do
  [ -n "$z" ] || continue
  while IFS='|' read -r lname lvnet; do
    [ -n "$lname" ] || continue
    case "$lvnet" in
      "$RG_SCOPE"/*) ;;
      *) EXTERNAL_LINKS+=("${z}|${lname}|${lvnet}") ;;
    esac
  done < <(aztsv network private-dns link vnet list -g "$RESOURCE_GROUP" -z "$z" --query "[].join('|',[name,virtualNetwork.id])")
done
printf '  %-34s %s\n' 'DNS links into foreign VNets:' "${#EXTERNAL_LINKS[@]}"

POLICY_ASSIGNMENTS=()
if [ -n "$RG_LOCATION" ]; then
  mapfile -t POLICY_ASSIGNMENTS < <(aztsv policy assignment list --scope "$RG_SCOPE" --query '[].name')
fi
printf '  %-34s %s\n' 'Policy assignments at group scope:' "$(count POLICY_ASSIGNMENTS)"

POLICY_DEFINITIONS=()
if [ "$KEEP_POLICY_DEFINITION" -eq 0 ]; then
  if [ -n "$ARCHITECTURE" ]; then
    candidate_architectures=("$ARCHITECTURE")
  else
    mapfile -t candidate_architectures < <(matrix '.architectures | keys[]')
  fi
  for f in "${candidate_architectures[@]}"; do
    name="$(aztsv policy definition show -n "${f}-deny-public-ip" --query name)"
    [ -n "$name" ] && POLICY_DEFINITIONS+=("$name")
  done
fi
printf '  %-34s %s\n' 'Custom policy definitions:' "${#POLICY_DEFINITIONS[@]}"

# ------------------------------------------------------------------------------------------------
# 2. Confirmation
# ------------------------------------------------------------------------------------------------

if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo
  echo "This permanently deletes resource group '${RESOURCE_GROUP}' and everything above."
  read -r -p 'Type the resource group name to confirm: ' answer
  if [ "$answer" != "$RESOURCE_GROUP" ]; then echo 'Aborted.'; exit 1; fi
fi

echo
echo 'Tearing down...'

# ------------------------------------------------------------------------------------------------
# 3. Arc agents, before the ARM resource disappears
#
# `az connectedk8s delete` also removes the agents from the cluster itself. Deleting only the ARM
# resource leaves azure-arc pods running and retrying against a resource that no longer exists.
# ------------------------------------------------------------------------------------------------

disconnect_arc() {
  local name="$1"
  if ! az connectedk8s delete -g "$RESOURCE_GROUP" -n "$name" --yes --force >/dev/null 2>&1; then
    echo "    WARNING: connectedk8s delete failed. If your kubeconfig no longer points at that cluster, run 'az connectedk8s delete --force' from a host that can reach it, or uninstall the azure-arc Helm release manually."
    az resource delete --ids "${RG_SCOPE}/providers/Microsoft.Kubernetes/connectedClusters/${name}" >/dev/null 2>&1
  fi
}
for cc in "${CONNECTED[@]+"${CONNECTED[@]}"}"; do
  [ -n "$cc" ] && act "Disconnecting Arc cluster ${cc} (removes in-cluster agents)" disconnect_arc "$cc"
done

# ------------------------------------------------------------------------------------------------
# 4. AKS clusters, before the VNet
#
# The cluster owns NICs, load balancer rules and private link services that live in the node
# resource group but attach to subnets in this one. Deleting the group with the cluster still in it
# usually works but can strand the VNet in a Deleting state for a long time; removing the cluster
# first is consistently faster.
# ------------------------------------------------------------------------------------------------

delete_cluster() { az aks delete -g "$RESOURCE_GROUP" -n "$1" --yes >/dev/null 2>&1; }
for c in "${CLUSTERS[@]+"${CLUSTERS[@]}"}"; do
  [ -n "$c" ] && act "Deleting AKS cluster ${c}" delete_cluster "$c"
done

# ------------------------------------------------------------------------------------------------
# 5. Private DNS links into foreign VNets
# ------------------------------------------------------------------------------------------------

delete_link() { az network private-dns link vnet delete -g "$RESOURCE_GROUP" -z "$1" -n "$2" --yes >/dev/null 2>&1; }
for entry in "${EXTERNAL_LINKS[@]+"${EXTERNAL_LINKS[@]}"}"; do
  IFS='|' read -r z lname lvnet <<<"$entry"
  act "Unlinking ${z} from ${lvnet##*/}" delete_link "$z" "$lname"
done

# ------------------------------------------------------------------------------------------------
# 6. Role assignments outside the group
# ------------------------------------------------------------------------------------------------

delete_assignment() { az role assignment delete --ids "$1" >/dev/null 2>&1; }
for entry in "${EXTERNAL_ASSIGNMENTS[@]+"${EXTERNAL_ASSIGNMENTS[@]}"}"; do
  IFS='|' read -r aid ascope arole <<<"$entry"
  act "Removing '${arole}' at ${ascope}" delete_assignment "$aid"
done

# ------------------------------------------------------------------------------------------------
# 7. Policy assignments, then the group, then the definition
#
# A policy definition cannot be deleted while an assignment still references it, and the
# assignments live at group scope, so the ordering here is not optional.
# ------------------------------------------------------------------------------------------------

delete_policy_assignment() { az policy assignment delete --name "$1" --scope "$RG_SCOPE" >/dev/null 2>&1; }
for p in "${POLICY_ASSIGNMENTS[@]+"${POLICY_ASSIGNMENTS[@]}"}"; do
  [ -n "$p" ] && act "Removing policy assignment ${p}" delete_policy_assignment "$p"
done

delete_group() {
  if ! az group delete -n "$RESOURCE_GROUP" --yes >/dev/null 2>&1; then
    echo '    WARNING: resource group deletion reported a failure. Re-run this script; deletion is idempotent.'
  fi
}
if [ -n "$RG_LOCATION" ] && [ "$KEEP_RESOURCE_GROUP" -eq 0 ]; then
  act "Deleting resource group ${RESOURCE_GROUP} (this blocks until it is gone)" delete_group
fi

delete_policy_definition() {
  if ! az policy definition delete -n "$1" >/dev/null 2>&1; then
    echo "    WARNING: could not delete $1. It may still be assigned at another scope, or the caller lacks Resource Policy Contributor."
  fi
}
for d in "${POLICY_DEFINITIONS[@]+"${POLICY_DEFINITIONS[@]}"}"; do
  act "Deleting policy definition ${d}" delete_policy_definition "$d"
done

# ------------------------------------------------------------------------------------------------
# 8. Soft-deleted key vaults
#
# Purge protection is off by default in these templates so this is possible; a soft-deleted vault
# otherwise holds its name for 90 days and a redeploy into the same names fails.
# ------------------------------------------------------------------------------------------------

purge_vault() {
  if ! az keyvault purge -n "$1" --location "$RG_LOCATION" >/dev/null 2>&1; then
    echo "    WARNING: purge failed for $1. If purge protection is enabled it cannot be purged and the name stays reserved until retention expires."
  fi
}
if [ "$PURGE_KEY_VAULTS" -eq 1 ]; then
  for kv in "${KEY_VAULTS[@]+"${KEY_VAULTS[@]}"}"; do
    [ -n "$kv" ] && act "Purging soft-deleted key vault ${kv}" purge_vault "$kv"
  done
elif [ "${#KEY_VAULTS[@]}" -gt 0 ] && [ -n "${KEY_VAULTS[0]}" ]; then
  echo
  echo "  NOTE: ${#KEY_VAULTS[@]} key vault(s) are now soft-deleted and keep their names reserved."
  echo '  Re-run with --purge-key-vaults to remove them completely.'
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN - ${ACTION_COUNT} action(s) would have been taken. Nothing was deleted."
else
  echo "TEARDOWN COMPLETE - ${ACTION_COUNT} action(s)."
fi
echo
