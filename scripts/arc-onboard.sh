#!/usr/bin/env bash
# Onboards an existing Kubernetes cluster to Azure Arc and prints the resource ID the
# arc-attach-existing architecture needs.
#
# The connectedCluster resource cannot be created by Resource Manager, because onboarding installs
# agents into the target cluster and Resource Manager has no kubeconfig. So the sequence is:
#
#   1. this script          -> creates Microsoft.Kubernetes/connectedClusters and installs the agents
#   2. export AKS_EXISTING_CONNECTED_CLUSTER_ID=<printed id>
#   3. ./deploy.sh --architecture arc-attach-existing   -> layers monitoring, Defender and policy extensions
#
# Re-running is safe. If the cluster is already Connected the onboarding step is skipped.

set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

CLUSTER_NAME=''; RESOURCE_GROUP=''; LOCATION='westus3'; SUBSCRIPTION_ID=''
KUBE_CONTEXT=''; PROXY_HTTPS=''; PROXY_HTTP=''; PROXY_SKIP_RANGE=''
DISTRIBUTION=''; INFRASTRUCTURE=''; FORCE=0

usage() {
  cat <<'EOF'
Usage: arc-onboard.sh --cluster-name <name> --resource-group <name> [options]

Required:
  -n, --cluster-name <name>      Name for the Azure Arc connectedCluster resource.
  -g, --resource-group <name>    Resource group to create it in.

Options:
  -l, --location <region>        Default westus3.
  --subscription <id>            Default: current az context.
  --kube-context <name>          kubeconfig context to onboard. Default: current context.
  --proxy-https <url>            Outbound HTTPS proxy for the Arc agents.
  --proxy-http <url>             Outbound HTTP proxy for the Arc agents.
  --proxy-skip-range <csv>       CIDRs and suffixes that bypass the proxy.
  --distribution <name>          e.g. k3s, rke2, openshift, generic.
  --infrastructure <name>        e.g. onpremises, azure_stack_hci, vsphere.
  -y, --force                    Skip the confirmation prompt.
  -h, --help                     This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -l|--location) LOCATION="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --kube-context) KUBE_CONTEXT="$2"; shift 2 ;;
    --proxy-https) PROXY_HTTPS="$2"; shift 2 ;;
    --proxy-http) PROXY_HTTP="$2"; shift 2 ;;
    --proxy-skip-range) PROXY_SKIP_RANGE="$2"; shift 2 ;;
    --distribution) DISTRIBUTION="$2"; shift 2 ;;
    --infrastructure) INFRASTRUCTURE="$2"; shift 2 ;;
    -y|--force|--yes) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$CLUSTER_NAME" ] || { echo 'ERROR: --cluster-name is required.' >&2; usage >&2; exit 2; }
[ -n "$RESOURCE_GROUP" ] || { echo 'ERROR: --resource-group is required.' >&2; usage >&2; exit 2; }

assert_azure_cli
[ -n "$SUBSCRIPTION_ID" ] && az account set --subscription "$SUBSCRIPTION_ID" -o none

echo
echo 'AKS ARCHITECTURES - AZURE ARC ONBOARDING'
echo

# ------------------------------------------------------------------------------------------------
# 1. Tooling
# ------------------------------------------------------------------------------------------------

if ! type -P kubectl >/dev/null 2>&1; then
  echo 'ERROR: kubectl is not on PATH. Arc onboarding runs against the cluster, not against Azure, so kubectl is required.' >&2
  exit 1
fi

if ! az extension show --name connectedk8s -o none >/dev/null 2>&1; then
  echo 'Installing the connectedk8s CLI extension...'
  az extension add --name connectedk8s --only-show-errors -o none
else
  az extension update --name connectedk8s --only-show-errors -o none >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------------------------
# 2. Confirm the target cluster
#
# This writes agents into whatever kubeconfig context is active. Onboarding the wrong cluster is an
# unpleasant thing to undo on a plant floor, so the context is always shown and confirmed.
# ------------------------------------------------------------------------------------------------

CURRENT_CONTEXT="$KUBE_CONTEXT"
[ -n "$CURRENT_CONTEXT" ] || CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null | tr -d '\r')"
if [ -z "$CURRENT_CONTEXT" ]; then
  echo 'ERROR: No kubectl context is selected and --kube-context was not supplied.' >&2
  echo '       Run kubectl config use-context <name> first.' >&2
  exit 1
fi

SERVER_URL="$(kubectl config view --minify -o "jsonpath={.clusters[0].cluster.server}" --context "$CURRENT_CONTEXT" 2>/dev/null | tr -d '\r')"
NODE_COUNT="$(kubectl get nodes -o name --context "$CURRENT_CONTEXT" 2>/dev/null | grep -c . || true)"
if [ "${NODE_COUNT:-0}" -eq 0 ]; then
  echo "ERROR: kubectl could not reach the cluster behind context '${CURRENT_CONTEXT}'." >&2
  echo '       Fix connectivity before onboarding.' >&2
  exit 1
fi

echo "  kube context : ${CURRENT_CONTEXT}"
echo "  api server   : ${SERVER_URL}"
echo "  nodes        : ${NODE_COUNT}"
echo "  arc resource : ${RESOURCE_GROUP}/${CLUSTER_NAME} in ${LOCATION}"
echo

if [ "$FORCE" != '1' ]; then
  read -r -p "Onboard this cluster to Azure Arc? Type the cluster name '${CLUSTER_NAME}' to continue: " ANSWER
  if [ "$ANSWER" != "$CLUSTER_NAME" ]; then echo 'Aborted.'; exit 1; fi
fi

# ------------------------------------------------------------------------------------------------
# 3. Providers and resource group
# ------------------------------------------------------------------------------------------------

for ns in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
  STATE="$(aztsv provider show -n "$ns" --query registrationState)"
  if [ "$STATE" != 'Registered' ]; then
    echo "Registering resource provider ${ns}..."
    az provider register -n "$ns" --wait -o none
  fi
done

if [ "$(aztsv group exists -n "$RESOURCE_GROUP")" != 'true' ]; then
  echo "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}..."
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
fi

# ------------------------------------------------------------------------------------------------
# 4. Onboard
# ------------------------------------------------------------------------------------------------

EXISTING_STATUS="$(aztsv connectedk8s show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query connectivityStatus)"
if [ "$EXISTING_STATUS" = 'Connected' ]; then
  echo "Cluster '${CLUSTER_NAME}' is already Connected. Skipping onboarding."
else
  [ -n "$EXISTING_STATUS" ] && \
    echo "Cluster '${CLUSTER_NAME}' exists with connectivityStatus '${EXISTING_STATUS}'. Re-running connect to repair the agents."

  CONNECT_ARGS=(connectedk8s connect -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION"
    --kube-context "$CURRENT_CONTEXT" --only-show-errors)
  [ -n "$PROXY_HTTPS" ] && CONNECT_ARGS+=(--proxy-https "$PROXY_HTTPS")
  [ -n "$PROXY_HTTP" ] && CONNECT_ARGS+=(--proxy-http "$PROXY_HTTP")
  [ -n "$PROXY_SKIP_RANGE" ] && CONNECT_ARGS+=(--proxy-skip-range "$PROXY_SKIP_RANGE")
  [ -n "$DISTRIBUTION" ] && CONNECT_ARGS+=(--distribution "$DISTRIBUTION")
  [ -n "$INFRASTRUCTURE" ] && CONNECT_ARGS+=(--infrastructure "$INFRASTRUCTURE")

  echo 'Running az connectedk8s connect. This installs the Arc agents and usually takes 5-10 minutes...'
  if ! az "${CONNECT_ARGS[@]}" -o none; then
    echo
    echo 'Onboarding failed. The agents pull images from mcr.microsoft.com and call' >&2
    echo 'management.azure.com and login.microsoftonline.com on 443. If this site egresses through a' >&2
    echo 'proxy, re-run with --proxy-https / --proxy-skip-range. See docs/networking.md for the full list.' >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------------------------------------
# 5. Verify and hand off
# ------------------------------------------------------------------------------------------------

CLUSTER_JSON="$(az connectedk8s show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" -o json 2>/dev/null | tr -d '\r')"
if [ -z "$CLUSTER_JSON" ]; then
  echo 'ERROR: Onboarding reported success but the connectedCluster resource could not be read.' >&2
  exit 1
fi

CLUSTER_ID="$(echo "$CLUSTER_JSON" | jq -r '.id')"
STATUS="$(echo "$CLUSTER_JSON" | jq -r '.connectivityStatus // ""')"

echo
echo "  connectivityStatus : ${STATUS}"
echo "  kubernetesVersion  : $(echo "$CLUSTER_JSON" | jq -r '.kubernetesVersion // ""')"
echo "  agentVersion       : $(echo "$CLUSTER_JSON" | jq -r '.agentVersion // ""')"
echo "  totalNodeCount     : $(echo "$CLUSTER_JSON" | jq -r '.totalNodeCount // ""')"
echo

if [ "$STATUS" != 'Connected' ]; then
  echo "Cluster is '${STATUS}', not yet 'Connected'. The agents may still be starting."
  echo 'Check with: kubectl get pods -n azure-arc'
fi

echo 'Set this before deploying the arc-attach-existing architecture:'
echo
echo "  export AKS_EXISTING_CONNECTED_CLUSTER_ID='${CLUSTER_ID}'"
echo
echo 'Then:'
echo "  ./deploy.sh --architecture arc-attach-existing --resource-group ${RESOURCE_GROUP} --location ${LOCATION}"
echo
