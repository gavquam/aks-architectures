#!/usr/bin/env bash
# Proves that the governance controls this repo assigns are actually being ENFORCED, by asking the
# cluster to do the exact thing they exist to prevent.
#
# Assignment and enforcement are different facts. The Azure Policy compliance blade reports the
# first. Only an admission attempt reports the second, and the gap between them is where governance
# quietly stops being real: an assignment scoped to the wrong resource group, an add-on that was
# never enabled, or a constraint that failed to sync all look identical from the portal.
#
# Runs entirely through `az aks command invoke`, so it works against private clusters from any
# network and needs no local kubectl and no kubeconfig.
#
#   ./verify-policy.sh -g rg-aks-prod-wus3 -n aks-contoso-prod-wus3-01
#   ./verify-policy.sh -g rg-aks-prod-wus3 -n aks-contoso-prod-wus3-01 --wait-minutes 20
#
# Exit codes: 0 enforced or pending, 1 assigned but NOT enforced, 2 usage or could not run.

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

RESOURCE_GROUP=''
CLUSTER_NAME=''
SUBSCRIPTION_ID=''
# The Azure Policy add-on polls for assignments roughly every fifteen minutes, so a proof run
# immediately after a deployment will normally find nothing. Waiting is the honest default; zero is
# available for CI, where a PENDING result is fine and twenty minutes of billed runner time is not.
WAIT_MINUTES=15

usage() {
  cat <<'EOF'
Usage: verify-policy.sh -g <resource-group> -n <cluster-name> [options]

Options:
  --subscription <id>       Subscription. Default: current az context.
  --wait-minutes <n>        How long to wait for the Azure Policy add-on to sync its constraints.
                            Default 15, matching the add-on's own poll interval. 0 checks once.
  -h, --help                This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -n|--name|--cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --wait-minutes) WAIT_MINUTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }
[ -n "$CLUSTER_NAME" ] || { echo 'ERROR: --name is required.' >&2; usage >&2; exit 2; }
case "$WAIT_MINUTES" in
  ''|*[!0-9]*) echo 'ERROR: --wait-minutes must be a whole number.' >&2; exit 2 ;;
esac

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

PROOF_SCRIPT="${script_dir}/lib/policy-proof.sh"
[ -f "$PROOF_SCRIPT" ] || { echo "ERROR: missing ${PROOF_SCRIPT}" >&2; exit 2; }

echo
echo 'GOVERNANCE PROOF - internal load balancer Deny'
echo "Cluster: ${CLUSTER_NAME}  (resource group ${RESOURCE_GROUP})"
echo

# `command invoke` schedules a pod on the cluster and streams its output back through the Azure
# control plane, so this reaches a private API server without any network path from here.
#
# The file must be in the CURRENT WORKING DIRECTORY and referenced by bare name - an absolute path
# in --file is not honoured. Hence the subshell cd rather than passing "$PROOF_SCRIPT" directly.
run_proof() {
  ( cd "${script_dir}/lib" && az aks command invoke -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
      --command 'bash policy-proof.sh' --file policy-proof.sh -o json 2>/dev/null )
}

DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))
ATTEMPT=0

while :; do
  ATTEMPT=$((ATTEMPT + 1))
  INVOKE_JSON="$(run_proof)"

  if [ -z "$INVOKE_JSON" ]; then
    echo 'Could not run the proof on this cluster.' >&2
    echo 'The command needs Microsoft.ContainerService/managedClusters/runcommand/action, and the' >&2
    echo 'cluster must be Running. Verify with:' >&2
    echo "  az aks command invoke -g ${RESOURCE_GROUP} -n ${CLUSTER_NAME} --command 'kubectl get nodes'" >&2
    exit 2
  fi

  LOGS="$(echo "$INVOKE_JSON" | jq -r '.logs // .text // ""')"
  RESULT="$(echo "$LOGS" | sed -n 's/^RESULT=//p' | tail -1)"
  DETAIL="$(echo "$LOGS" | sed -n 's/^DETAIL=//p' | tail -1)"

  if [ "$RESULT" != 'pending' ]; then break; fi

  NOW="$(date +%s)"
  if [ "$NOW" -ge "$DEADLINE" ]; then break; fi

  REMAINING=$(( (DEADLINE - NOW) / 60 ))
  echo "  Constraints have not synced yet (attempt ${ATTEMPT}). The Azure Policy add-on polls about"
  echo "  every 15 minutes; waiting up to ${REMAINING} more minute(s)."
  sleep 60
done

echo
case "$RESULT" in
  enforced)
    echo 'ENFORCED. A Service of type LoadBalancer with no internal annotation was REFUSED by the'
    echo 'admission controller, which is the behaviour the assigned policy promises.'
    echo "  ${DETAIL}"
    exit 0
    ;;
  notenforced)
    echo '########################################################################' >&2
    echo '  GOVERNANCE NOT ENFORCED' >&2
    echo "  ${DETAIL}" >&2
    echo '  The compliance blade will still show the assignment. Check that the' >&2
    echo '  Azure Policy add-on is enabled (features.azurePolicyAddon) and that the' >&2
    echo '  assignment scope covers this cluster:' >&2
    echo "    az aks show -g ${RESOURCE_GROUP} -n ${CLUSTER_NAME} --query addonProfiles.azurepolicy" >&2
    echo "    az policy assignment list --disable-scope-strict-match -g ${RESOURCE_GROUP} -o table" >&2
    echo '########################################################################' >&2
    exit 1
    ;;
  pending)
    echo 'PENDING. Gatekeeper has not yet received the constraint, so nothing was proven either way.'
    echo "  ${DETAIL}"
    echo
    echo 'This is normal shortly after a deployment. Re-run when the add-on has polled:'
    echo "  ./verify-policy.sh -g ${RESOURCE_GROUP} -n ${CLUSTER_NAME} --wait-minutes 20"
    exit 0
    ;;
  *)
    echo 'INCONCLUSIVE. The proof ran but did not return a result this script understands.' >&2
    echo "  ${DETAIL:-$LOGS}" >&2
    exit 2
    ;;
esac
