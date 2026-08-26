#!/usr/bin/env bash
# ==================================================================================================
# wizard.sh - interactive planner.
#
# Asks about ten questions, explains the trade-off behind each one, writes a parameter file you can
# keep, and then deploys it.
#
# The point is not to save typing. It is to make the reasoning visible at the moment the decision is
# made, because the settings that matter most in AKS are the ones that cannot be changed afterwards,
# and they are usually chosen in the first ten minutes by someone who has not yet been told which
# ones those are.
#
# For every question you get three things: the minimum that works, what Microsoft recommends, and
# what this repository recommends for your situation - which is not always the same, and where they
# differ the reason is stated.
#
# The guidance text lives in infra/params/guidance.json, not in this script, so this and wizard.ps1
# cannot drift apart, and so the advice can be reviewed by someone who does not read shell.
#
# Nothing is deployed until the whole plan and its monthly cost have been shown and confirmed.
#
# Usage: ./scripts/wizard.sh [-g <resource-group>] [--plan-only] [--out-file <name>]
# ==================================================================================================
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

require_tools az jq

RESOURCE_GROUP=''
PLAN_ONLY=0
OUT_FILE=''

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --plan-only)         PLAN_ONLY=1; shift ;;
    --out-file)          OUT_FILE="$2"; shift 2 ;;
    -h|--help)           sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

GUIDANCE="${REPO_ROOT}/infra/params/guidance.json"
[ -f "$GUIDANCE" ] || { echo "ERROR: guidance.json not found at $GUIDANCE" >&2; exit 2; }

g() { jq -r "$1" "$GUIDANCE"; }

# --------------------------------------------------------------------------------------------------
# Presentation
#
# Guidance is only useful if it is legible under pressure, so the three kinds of statement the
# wizard makes - what is required, what Microsoft says, what this repo says - are visually distinct
# rather than three more lines of grey text. Colour is dropped entirely when output is not a
# terminal, so a piped transcript stays readable.
# --------------------------------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[90m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_DKYEL=$'\033[33m'; C_RED=$'\033[31m'; C_MAGENTA=$'\033[35m'
  C_WHITE=$'\033[97m'; C_DKGRN=$'\033[32m'
else
  C_RESET=''; C_DIM=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_DKYEL=''
  C_RED=''; C_MAGENTA=''; C_WHITE=''; C_DKGRN=''
fi

rule() { printf '%s%*s%s\n' "$C_DIM" 78 '' "$C_RESET" | tr ' ' '-'; }

heading() {
  echo
  rule
  printf '  %s%s%s\n' "$C_CYAN" "$1" "$C_RESET"
  rule
}

# why_lines <jq-path-to-array>
why_lines() {
  jq -r "$1 // [] | .[]" "$GUIDANCE" | while IFS= read -r l; do
    printf '  %s%s%s\n' "$C_DIM" "$l" "$C_RESET"
  done
}

# advice <jq-path-to-decision-object>
advice() {
  local d; d="$(jq -c "$1" "$GUIDANCE")"
  local minimum best rec why immutable
  minimum="$(echo "$d"   | jq -r '.minimum // ""')"
  best="$(echo "$d"      | jq -r '.microsoftBestPractice // ""')"
  rec="$(echo "$d"       | jq -r '.recommended // ""')"
  why="$(echo "$d"       | jq -r '.recommendedWhy // ""')"
  immutable="$(echo "$d" | jq -r '.immutable // false')"

  [ -n "$minimum" ] && printf '  %sMinimum:      %s%s\n' "$C_DKYEL" "$minimum" "$C_RESET"
  [ -n "$best" ]    && printf '  %sMicrosoft:    %s%s\n' "$C_YELLOW" "$best" "$C_RESET"
  [ -n "$rec" ]     && printf '  %sRecommended:  %s%s\n' "$C_GREEN" "$rec" "$C_RESET"
  [ -n "$why" ]     && printf '  %s              %s%s\n' "$C_DKGRN" "$why" "$C_RESET"
  [ "$immutable" = 'true' ] && \
    printf '  %sIMMUTABLE:    changing this later means building a new cluster.%s\n' "$C_MAGENTA" "$C_RESET"
  return 0
}

# Some decisions carry a reference table rather than a single recommendation. Zone support is the
# one that changes the answer most often, so it is shown rather than described.
# regions <jq-path-to-decision-object>
regions() {
  local d; d="$(jq -c "$1" "$GUIDANCE")"
  echo "$d" | jq -e 'has("regions")' >/dev/null 2>&1 || return 0
  printf '\n'
  echo "$d" | jq -r '.regions[] | "\(.name)\t\(.city)\t\(.zones)"' |
    while IFS=$'\t' read -r name city zones; do
      if [ "$zones" -gt 0 ] 2>/dev/null; then
        printf '    %s%-16s %-12s %s zones%s\n' "$C_GREEN" "$name" "$city" "$zones" "$C_RESET"
      else
        printf '    %s%-16s %-12s no zones%s\n' "$C_DKYEL" "$name" "$city" "$C_RESET"
      fi
    done
  if echo "$d" | jq -e 'has("regionsNote")' >/dev/null 2>&1; then
    printf '\n'
    echo "$d" | jq -r '.regionsNote[]' | while IFS= read -r l; do
      printf '  %s%s%s\n' "$C_DIM" "$l" "$C_RESET"
    done
  fi
  return 0
}

# ask <prompt> <default> [validator-function]
# Enter takes the default, which is always the recommendation, so a user who wants to be led can
# hold Enter down and still get a defensible cluster.
ANSWER=''
ask() {
  local prompt="$1" default="${2:-}" validator="${3:-}" raw shown problem
  while true; do
    shown=''; [ -n "$default" ] && shown=" [$default]"
    echo
    printf '  %s%s%s%s ' "$C_WHITE" "$prompt" "$shown" "$C_RESET"
    IFS= read -r raw || raw=''
    ANSWER="${raw:-$default}"
    # Trim.
    ANSWER="${ANSWER#"${ANSWER%%[![:space:]]*}"}"
    ANSWER="${ANSWER%"${ANSWER##*[![:space:]]}"}"
    if [ -n "$validator" ]; then
      problem="$("$validator" "$ANSWER")"
      if [ -n "$problem" ]; then printf '  %s%s%s\n' "$C_RED" "$problem" "$C_RESET"; continue; fi
    fi
    return 0
  done
}

# choose <options-json-array> <recommended-value>
# Sets CHOICE to the selected option object. The recommended option is marked so the default is
# never a mystery.
CHOICE=''
choose() {
  local opts="$1" rec="$2" count i label detail warning value marker colour rec_index=1 raw n
  count="$(echo "$opts" | jq 'length')"
  for (( i=0; i<count; i++ )); do
    value="$(echo "$opts"   | jq -r ".[$i].value")"
    label="$(echo "$opts"   | jq -r ".[$i].label")"
    detail="$(echo "$opts"  | jq -r ".[$i].detail // \"\"")"
    warning="$(echo "$opts" | jq -r ".[$i].warning // \"\"")"
    marker=' '; colour="$C_WHITE"
    if [ "$value" = "$rec" ]; then marker='*'; colour="$C_GREEN"; rec_index=$(( i + 1 )); fi
    echo
    printf '  %s%s%d) %s%s\n' "$colour" "$marker" "$(( i + 1 ))" "$label" "$C_RESET"
    [ -n "$detail" ]  && printf '       %s%s%s\n' "$C_DIM" "$detail" "$C_RESET"
    [ -n "$warning" ] && printf '       %s%s%s\n' "$C_DKYEL" "$warning" "$C_RESET"
  done
  echo
  printf '  %s* = recommended%s\n' "$C_DIM" "$C_RESET"

  while true; do
    echo
    printf '  %sChoose 1-%d [%d]%s ' "$C_WHITE" "$count" "$rec_index" "$C_RESET"
    IFS= read -r raw || raw=''
    [ -z "$raw" ] && n="$rec_index" || n="$raw"
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
      CHOICE="$(echo "$opts" | jq -c ".[$(( n - 1 ))]")"
      return 0
    fi
    printf '  %sEnter a number between 1 and %d.%s\n' "$C_RED" "$count" "$C_RESET"
  done
}

# check_cidr <cidr> <max-prefix> <min-prefix> - echoes a problem, or nothing when acceptable.
check_cidr() {
  local v="$1" maxp="$2" minp="$3" prefix start aligned
  if ! cidr_valid "$v"; then echo "'$v' is not a valid IPv4 CIDR, e.g. 10.63.0.0/16."; return 0; fi
  prefix="$(cidr_prefix "$v")"
  start="$(cidr_start "$v")"
  if [ "$start" -ne "$(ip_to_int "${v%%/*}")" ]; then
    aligned="$(int_to_ip "$start")"
    echo "$v is not aligned to its own prefix. Did you mean $aligned/$prefix?"; return 0
  fi
  if [ "$prefix" -gt "$maxp" ]; then echo "$v is too small. Use /$maxp or larger."; return 0; fi
  if [ "$prefix" -lt "$minp" ]; then echo "$v is larger than /$minp, which is more address space than any cluster needs."; return 0; fi
  echo ''
}

v_region()   { [[ "$1" =~ ^[a-z0-9]+$ ]] && echo '' || echo "'$1' does not look like a region short name, e.g. westus3 or northeurope."; }
v_vnet()     { check_cidr "$1" 19 8; }
v_nodes()    { { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 50 ]; } && echo '' || echo 'Enter a whole number between 1 and 50.'; }
v_vmsize()   { [[ "$1" =~ ^Standard_ ]] && echo '' || echo "'$1' does not look like an Azure VM size, e.g. Standard_D4ds_v5."; }
v_email()    { { [ -z "$1" ] || [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; } && echo '' || echo "'$1' is not an email address."; }
v_customer() { [[ "$1" =~ ^[a-z0-9]{2,8}$ ]] && echo '' || echo 'Use 2 to 8 lowercase letters or digits.'; }
v_env()      { case "$1" in dev|test|prod) echo '' ;; *) echo 'Must be dev, test or prod.' ;; esac; }
v_instance() { [[ "$1" =~ ^[0-9]{2}$ ]] && echo '' || echo 'Two digits, e.g. 01.'; }
v_rg()       { [[ "$1" =~ ^[A-Za-z0-9._()-]{1,90}$ ]] && echo '' || echo 'Not a valid resource group name.'; }

v_service_cidr() {
  local p; p="$(check_cidr "$1" 24 8)"
  if [ -n "$p" ]; then echo "$p"; return 0; fi
  if cidr_overlap "$1" "$VNET"; then
    echo "$1 overlaps the VNet range $VNET. The Service CIDR must not overlap anything routable."; return 0
  fi
  if [ -n "${POD_CIDR:-}" ] && cidr_overlap "$1" "$POD_CIDR"; then
    echo "$1 overlaps the overlay pod range $POD_CIDR."; return 0
  fi
  echo ''
}

v_onprem() {
  local c p
  [ -z "$1" ] && { echo ''; return 0; }
  for c in ${1//,/ }; do
    p="$(check_cidr "$c" 32 8)"
    if [ -n "$p" ]; then echo "$p"; return 0; fi
    if cidr_overlap "$c" "$VNET"; then
      echo "$c overlaps the VNet range $VNET. This is the overlap that is most expensive to discover later - pick a different VNet range."
      return 0
    fi
  done
  echo ''
}

v_authips() {
  local c p
  [ -z "$1" ] && { echo 'At least one range is required for this architecture, or the cluster is unreachable.'; return 0; }
  for c in ${1//,/ }; do
    p="$(check_cidr "$c" 32 0)"
    if [ -n "$p" ]; then echo "$p"; return 0; fi
  done
  echo ''
}

v_groups() {
  local x
  [ -z "$1" ] && { echo ''; return 0; }
  for x in ${1//,/ }; do
    if ! [[ "$x" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      echo "'$x' is not an object ID (a GUID). Find one with: az ad group show -g <name> --query id -o tsv"
      return 0
    fi
  done
  echo ''
}

# Renders a comma-separated list as a Bicep array literal.
bicep_array() {
  local raw="$1" out='' x
  [ -z "$raw" ] && { echo '[]'; return 0; }
  for x in ${raw//,/ }; do
    [ -n "$out" ] && out="$out, "
    out="$out'$x'"
  done
  echo "[$out]"
}

# ==================================================================================================
# Intro
# ==================================================================================================

# Starting from a clean screen makes the guidance readable, but there is no console to clear when
# the wizard is driven from a pipe or a CI log, and failing to clear a screen is never a reason to
# refuse to run.
[ -t 1 ] && printf '\033[2J\033[H' || true

echo
printf '  %s%s%s\n' "$C_CYAN" "$(g '.intro.title')" "$C_RESET"
rule
g '.intro.body[]' | while IFS= read -r l; do echo "  $l"; done
rule

assert_azure_cli
ACCOUNT_NAME="$(aztsv account show --query name)"
ACCOUNT_USER="$(aztsv account show --query user.name)"
echo
printf '  %sSubscription: %s%s\n' "$C_DIM" "$ACCOUNT_NAME" "$C_RESET"
printf '  %sSigned in as: %s%s\n' "$C_DIM" "$ACCOUNT_USER" "$C_RESET"

# ==================================================================================================
# 1. Purpose. This sets the cost tier, and it is where the wizard is most explicit about what a
#    cheaper answer actually costs you, because that is the trade people make without noticing.
# ==================================================================================================

heading "$(g '.decisions.purpose.question')"
why_lines '.decisions.purpose.whyItMatters'
choose "$(jq -c '.decisions.purpose.options' "$GUIDANCE")" "$(g '.decisions.purpose.recommended')"
PURPOSE_VALUE="$(echo "$CHOICE" | jq -r '.value')"
PURPOSE_LABEL="$(echo "$CHOICE" | jq -r '.label')"
COST_TIER="$(echo "$CHOICE" | jq -r '.costTier')"
DISABLES_NOTE="$(echo "$CHOICE" | jq -r '.disablesNote // ""')"

if [ "$(echo "$CHOICE" | jq '.disables // [] | length')" -gt 0 ]; then
  echo
  printf '%s  This choice switches OFF the following. They are named rather than merely omitted,\n' "$C_YELLOW"
  printf '  because a cost tier that silently drops security controls is how a demo becomes a\n'
  printf '  production template:%s\n' "$C_RESET"
  echo "$CHOICE" | jq -r '.disables[]' | while IFS= read -r x; do
    printf '    %s- %s%s\n' "$C_YELLOW" "$x" "$C_RESET"
  done
fi
echo
printf '  %s%s%s\n' "$C_DIM" "$DISABLES_NOTE" "$C_RESET"
printf '  %sCost tier: %s%s\n' "$C_GREEN" "$COST_TIER" "$C_RESET"

# ==================================================================================================
# 2. Architecture. Asked as a situation rather than a product name, because people know their situation
#    and do not yet know which API server access model it implies.
# ==================================================================================================

heading "$(g '.decisions.architecture.question')"
why_lines '.decisions.architecture.whyItMatters'
choose "$(jq -c '.decisions.architecture.options' "$GUIDANCE")" "$(g '.decisions.architecture.recommended')"
ARCHITECTURE_RAW="$(echo "$CHOICE" | jq -r '.value')"

# The OT entry is the same architecture reached by a different route. Keeping it as its own line means
# someone with an OT problem recognises themselves in the list instead of having to translate.
IS_OT=0
case "$ARCHITECTURE_RAW" in *:ot) IS_OT=1 ;; esac
ARCHITECTURE="${ARCHITECTURE_RAW%:ot}"

ARCHITECTURE_JSON="$(jq -c ".architectures.\"$ARCHITECTURE\"" "$MATRIX_FILE")"
API_ACCESS="$(echo "$ARCHITECTURE_JSON" | jq -r '.apiServerAccess')"
AZURE_REGION="$(echo "$ARCHITECTURE_JSON" | jq -r '.azureRegion')"

echo
printf '  %sArchitecture: %s%s\n' "$C_GREEN" "$ARCHITECTURE" "$C_RESET"
printf '  %s%s%s\n' "$C_DIM" "$(echo "$ARCHITECTURE_JSON" | jq -r '.summary')" "$C_RESET"

if [ "$AZURE_REGION" != 'true' ]; then
  echo
  printf '%s  This architecture does not build anything in an Azure region, so there is no address plan,\n' "$C_YELLOW"
  printf '  no node sizing and no egress model for this wizard to ask about.%s\n' "$C_RESET"
  echo
  printf '  %sRequired prerequisites this wizard cannot create: %s%s\n' "$C_YELLOW" \
    "$(echo "$ARCHITECTURE_JSON" | jq -r '.requiredParams // [] | join(", ")')" "$C_RESET"
  echo
  printf '  %sNext step:%s\n' "$C_CYAN" "$C_RESET"
  if [ "$ARCHITECTURE" = 'arc-attach-existing' ]; then
    echo '    ./scripts/arc-onboard.sh -g <rg> -n <cluster-name>'
    echo '    then ./scripts/deploy.sh --architecture arc-attach-existing -g <rg>'
  else
    echo '    Register the Azure Local instance, its Arc Resource Bridge, a custom location and a'
    echo '    logical network first. Then edit infra/params/aks-arc-local.bicepparam and run:'
    echo '    ./scripts/deploy.sh --architecture aks-arc-local -g <rg>'
  fi
  echo
  printf '  %sSee docs/architectures.md for the full prerequisite list.%s\n' "$C_DIM" "$C_RESET"
  echo
  exit 0
fi

if [ "$IS_OT" -eq 1 ]; then
  echo
  printf '%s  Because this is an OT platform, two further things are worth doing and neither is\n' "$C_YELLOW"
  printf '  handled by the address plan:\n'
  printf '    - place administrative access on a jump host at Purdue Level 3.5 rather than\n'
  printf '      giving plant engineers direct routes to the API server subnet, and\n'
  printf '    - disable local Kubernetes accounts entirely, so the shared credential does not\n'
  printf '      exist to be found later.%s\n' "$C_RESET"
  printf '  %sChoosing an Entra admin group below is what makes the second one possible.%s\n' "$C_DIM" "$C_RESET"
fi

# ==================================================================================================
# 3. Region
# ==================================================================================================

heading "$(g '.decisions.location.question')"
why_lines '.decisions.location.whyItMatters'
advice '.decisions.location'
regions '.decisions.location'
ask 'Region' "$(g '.decisions.location.recommended')" v_region
LOCATION="$ANSWER"

# ==================================================================================================
# 4. Egress. Asked before addressing because udr-firewall needs a firewall subnet, and asked early
#    because it is immutable in the direction people care about.
# ==================================================================================================

heading "$(g '.decisions.egress.question')"
why_lines '.decisions.egress.whyItMatters'
advice '.decisions.egress'
ALLOWED_EGRESS="$(echo "$ARCHITECTURE_JSON" | jq -c '.egress')"
EGRESS_OPTS="$(jq -c --argjson allowed "$ALLOWED_EGRESS" \
  '.decisions.egress.options | map(select(.value as $v | $allowed | index($v)))' "$GUIDANCE")"
choose "$EGRESS_OPTS" "$(g '.decisions.egress.recommended')"
EGRESS="$(echo "$CHOICE" | jq -r '.value')"
OUTBOUND_TYPE="$(matrix ".egressModes.\"$EGRESS\".outboundType")"
REQUIRES_FIREWALL="$(matrix ".egressModes.\"$EGRESS\".requiresFirewall")"
echo
printf '  %sEgress: %s  (outboundType = %s)%s\n' "$C_GREEN" "$EGRESS" "$OUTBOUND_TYPE" "$C_RESET"

# ==================================================================================================
# 5. Network profile. Constrained by the architecture - Automatic accepts exactly one - so where there is
#    no choice the wizard says so rather than presenting a menu of one.
# ==================================================================================================

ALLOWED_PROFILES="$(echo "$ARCHITECTURE_JSON" | jq -c '.networkProfiles')"
heading "$(g '.decisions.networkProfile.question')"
if [ "$(echo "$ALLOWED_PROFILES" | jq 'length')" -eq 1 ]; then
  NETWORK_PROFILE="$(echo "$ALLOWED_PROFILES" | jq -r '.[0]')"
  printf '  %sThe %s architecture hard-wires this to %s, so there is nothing to choose.%s\n' \
    "$C_DIM" "$ARCHITECTURE" "$NETWORK_PROFILE" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "$(matrix ".networkProfiles.\"$NETWORK_PROFILE\".summary")" "$C_RESET"
else
  why_lines '.decisions.networkProfile.whyItMatters'
  advice '.decisions.networkProfile'
  PROFILE_OPTS="$(jq -c --argjson allowed "$ALLOWED_PROFILES" \
    '.decisions.networkProfile.options | map(select(.value as $v | $allowed | index($v)))' "$GUIDANCE")"
  choose "$PROFILE_OPTS" "$(g '.decisions.networkProfile.recommended')"
  NETWORK_PROFILE="$(echo "$CHOICE" | jq -r '.value')"
fi
REQUIRES_POD_SUBNET="$(matrix ".networkProfiles.\"$NETWORK_PROFILE\".requiresPodSubnet")"
REQUIRES_POD_CIDR="$(matrix ".networkProfiles.\"$NETWORK_PROFILE\".requiresPodCidr")"
echo
printf '  %sNetwork profile: %s%s\n' "$C_GREEN" "$NETWORK_PROFILE" "$C_RESET"

# ==================================================================================================
# 6. Addressing
#
# The wizard asks for one number - the VNet range - and derives every subnet from it, then shows the
# derived plan. Asking for nine subnets one at a time would be honest but nobody would finish;
# showing the derivation afterwards keeps it inspectable, which is the part that matters.
# ==================================================================================================

heading "$(g '.decisions.vnetAddressSpace.question')"
why_lines '.decisions.vnetAddressSpace.whyItMatters'
advice '.decisions.vnetAddressSpace'
echo
printf '  %sThe wizard derives the node, pod, API server, firewall, Bastion, private endpoint and\n' "$C_DIM"
printf '  DNS resolver subnets from this one range, and shows you the result before deploying.\n'
printf '  It needs at least a /19 of room to lay them all out.%s\n' "$C_RESET"

ask 'VNet address space' "$(g '.decisions.vnetAddressSpace.recommended')" v_vnet
VNET="$ANSWER"

BASE="$(cidr_start "$VNET")"
# sub <256-block offset> <extra addresses> <prefix>
sub() { echo "$(int_to_ip $(( BASE + ($1 * 256) + $2 )))/$3"; }

NODE_SUBNET="$(sub 0 0 22)"
POD_SUBNET=''
[ "$REQUIRES_POD_SUBNET" = 'true' ] && POD_SUBNET="$(sub 8 0 21)"
API_SUBNET=''
[ "$API_ACCESS" = 'vnetIntegration' ] && API_SUBNET="$(sub 16 0 28)"
FIREWALL_SUBNET=''
[ "$REQUIRES_FIREWALL" = 'true' ] && FIREWALL_SUBNET="$(sub 17 0 26)"
BASTION_SUBNET="$(sub 17 64 26)"
PE_SUBNET="$(sub 18 0 24)"
DNS_IN_SUBNET="$(sub 19 0 28)"
DNS_OUT_SUBNET="$(sub 19 16 28)"

# Overlay pod addresses never appear in the VNet, so this range only has to avoid colliding with
# something the pods will genuinely need to reach.
POD_CIDR=''
[ "$REQUIRES_POD_CIDR" = 'true' ] && POD_CIDR='192.168.0.0/16'

heading "$(g '.decisions.serviceCidr.question')"
why_lines '.decisions.serviceCidr.whyItMatters'
advice '.decisions.serviceCidr'
ask 'Service CIDR' "$(g '.decisions.serviceCidr.recommended')" v_service_cidr
SERVICE_CIDR="$ANSWER"
# .10 in the Service CIDR is the convention CoreDNS is configured against everywhere.
DNS_SERVICE_IP="$(int_to_ip $(( $(cidr_start "$SERVICE_CIDR") + 10 )))"

echo
printf '  %sOn-premises or plant ranges this cluster must not collide with.%s\n' "$C_WHITE" "$C_RESET"
printf '  %sPre-flight checks the whole plan against these. Comma separated, or Enter to skip.%s\n' "$C_DIM" "$C_RESET"
ask 'On-premises CIDRs' '' v_onprem
ON_PREM="${ANSWER// /}"

# ==================================================================================================
# 7. Sizing
# ==================================================================================================

heading "$(g '.decisions.nodeCount.question')"
why_lines '.decisions.nodeCount.whyItMatters'
advice '.decisions.nodeCount'
ask 'System node count' "$(g '.decisions.nodeCount.recommended')" v_nodes
NODE_COUNT="$ANSWER"

heading "$(g '.decisions.nodeVmSize.question')"
why_lines '.decisions.nodeVmSize.whyItMatters'
advice '.decisions.nodeVmSize'
ask 'Node VM size' "$(g '.decisions.nodeVmSize.recommended')" v_vmsize
NODE_VM_SIZE="$ANSWER"

if [ -n "$POD_SUBNET" ]; then
  # This is the constraint that surprises people, so it is computed rather than described.
  POD_SIZE="$(cidr_size "$POD_SUBNET")"
  MAX_NODES=$(( (POD_SIZE - 5) / 110 ))
  echo
  printf '%s  Pod subnet %s gives %d addresses. At 110 pods per node that is\n' "$C_DKYEL" "$POD_SUBNET" "$POD_SIZE"
  printf '  a hard ceiling of about %d nodes, and it cannot be raised after creation.%s\n' "$MAX_NODES" "$C_RESET"
fi

# ==================================================================================================
# 8. Access and identity
# ==================================================================================================

AUTHORIZED_IPS=''
if [ "$API_ACCESS" = 'authorizedIpRanges' ]; then
  heading 'Which addresses may reach the API server?'
  printf '  %sThis list is the entire control. Everything not on it is refused, including you.%s\n' "$C_DIM" "$C_RESET"
  printf '  %sIt also fails quietly when it drifts: an address changes and someone is locked out with%s\n' "$C_DIM" "$C_RESET"
  printf '  %sno error that points at this list. Keep it in source control next to the cluster.%s\n' "$C_DIM" "$C_RESET"

  MY_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
  IP_DEFAULT=''
  if [ -n "$MY_IP" ]; then
    IP_DEFAULT="$MY_IP/32"
    echo
    printf '  %sYour current public address appears to be %s.%s\n' "$C_DIM" "$MY_IP" "$C_RESET"
    printf '%s  Behind corporate NAT this rotates across a pool, so a single /32 will lock you out\n' "$C_DKYEL"
    printf '  within hours. Ask your network team for the egress range rather than trusting this.%s\n' "$C_RESET"
  fi
  ask 'Authorized CIDRs (comma separated)' "$IP_DEFAULT" v_authips
  AUTHORIZED_IPS="${ANSWER// /}"
fi

heading "$(g '.decisions.adminGroup.question')"
why_lines '.decisions.adminGroup.whyItMatters'
advice '.decisions.adminGroup'

# Groups the signed-in user belongs to are far more likely to be the right answer than groups they
# happen to own, and this is the difference between a useful suggestion and a confusing one.
MEMBER_OF="$(az rest --method get --url https://graph.microsoft.com/v1.0/me/memberOf -o json 2>/dev/null || echo '{}')"
MY_GROUPS="$(echo "$MEMBER_OF" | jq -r '[.value // [] | .[] | select(."@odata.type" == "#microsoft.graph.group")] | .[0:8] | .[] | "    \(.id)  \(.displayName)"' 2>/dev/null || echo '')"
if [ -n "$MY_GROUPS" ]; then
  echo
  printf '  %sGroups you belong to:%s\n' "$C_DIM" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$MY_GROUPS" "$C_RESET"
fi

ask 'Entra group object IDs (comma separated, Enter to skip)' '' v_groups
ADMIN_GROUPS="${ANSWER// /}"
if [ -z "$ADMIN_GROUPS" ]; then
  echo
  printf '%s  No group supplied, so cluster access will use local Kubernetes accounts. That is a\n' "$C_YELLOW"
  printf '  shared credential which nobody rotates and which survives someone leaving. Acceptable\n'
  printf '  for a sandbox you will delete; not acceptable for anything that outlives this week.%s\n' "$C_RESET"
fi

heading "$(g '.decisions.alertEmail.question')"
why_lines '.decisions.alertEmail.whyItMatters'
advice '.decisions.alertEmail'
ask 'Alert email (Enter to skip)' '' v_email
ALERT_EMAIL="$ANSWER"

# ==================================================================================================
# 9. Naming and target
# ==================================================================================================

heading 'Naming'
printf '  %sEvery resource name is derived from these four values, so they are what you will see in the%s\n' "$C_DIM" "$C_RESET"
printf '  %sportal, in the bill and in every alert. The customer code is capped at eight characters because%s\n' "$C_DIM" "$C_RESET"
printf '  %sa storage account name is capped at 24 and the other five segments already spend 16 of them.%s\n' "$C_DIM" "$C_RESET"

ask 'Customer or project code (2-8 chars)' 'contoso' v_customer
CUSTOMER="$ANSWER"
ENV_DEFAULT='prod'; [ "$PURPOSE_VALUE" = 'learning' ] && ENV_DEFAULT='dev'
ask 'Environment (dev, test, prod)' "$ENV_DEFAULT" v_env
ENVIRONMENT="$ANSWER"
ask 'Instance number' '01' v_instance
INSTANCE="$ANSWER"

if [ -z "$RESOURCE_GROUP" ]; then
  # Soft-deleted, purge-protected Key Vaults hold their names for 90 days, so a repeated resource
  # group name is a common way to make a second deployment fail for a reason nobody enjoys finding.
  ask 'Resource group' "rg-aks-$CUSTOMER-$ENVIRONMENT-$INSTANCE" v_rg
  RESOURCE_GROUP="$ANSWER"
fi

# ==================================================================================================
# 10. Write the plan
# ==================================================================================================

PARAMS_DIR="${REPO_ROOT}/infra/params"
if [ -z "$OUT_FILE" ]; then
  OUT_FILE="${PARAMS_DIR}/${ARCHITECTURE}.local.bicepparam"
elif [ "$OUT_FILE" = "$(basename "$OUT_FILE")" ]; then
  OUT_FILE="${PARAMS_DIR}/${OUT_FILE}"
fi

# A .bicepparam resolves 'using ../main.bicep' and loadJsonContent('cost-tiers.json') relative to
# its own location, so a plan written anywhere else produces a wall of BCP091 file-not-found errors
# that say nothing about the real cause. Refuse early and say what the real cause is.
if [ "$(cd "$(dirname "$OUT_FILE")" && pwd)" != "$(cd "$PARAMS_DIR" && pwd)" ]; then
  echo "ERROR: the plan must be written into infra/params/, because a .bicepparam resolves its" >&2
  echo "       'using' target and its loadJsonContent() paths relative to its own directory." >&2
  echo "       Requested: $OUT_FILE" >&2
  exit 2
fi

TEMPLATE="$(cat "${script_dir}/lib/wizard-template.bicepparam.tmpl")"

subst() {
  local key="$1" val="$2"
  # Values are CIDRs, names and sizes, so a literal replacement is both correct and safer than
  # letting sed interpret anything.
  TEMPLATE="${TEMPLATE//"$key"/"$val"}"
}

subst '__GENERATED_ON__'      "$(date '+%Y-%m-%d %H:%M')"
subst '__PURPOSE_LABEL__'     "$PURPOSE_LABEL"
subst '__COST_TIER__'         "$COST_TIER"
subst '__ARCHITECTURE__'            "$ARCHITECTURE"
subst '__NETWORK_PROFILE__'   "$NETWORK_PROFILE"
subst '__EGRESS__'            "$EGRESS"
subst '__CUSTOMER__'          "$CUSTOMER"
subst '__ENVIRONMENT__'       "$ENVIRONMENT"
subst '__LOCATION__'          "$LOCATION"
subst '__INSTANCE__'          "$INSTANCE"
subst '__NODE_ZONES__'        '1,2,3'
subst '__NODE_COUNT__'        "$NODE_COUNT"
subst '__NODE_VM_SIZE__'      "$NODE_VM_SIZE"
subst '__VNET__'              "$VNET"
subst '__NODE_SUBNET__'       "$NODE_SUBNET"
subst '__POD_SUBNET__'        "$POD_SUBNET"
subst '__API_SUBNET__'        "$API_SUBNET"
subst '__FIREWALL_SUBNET__'   "$FIREWALL_SUBNET"
subst '__BASTION_SUBNET__'    "$BASTION_SUBNET"
subst '__PE_SUBNET__'         "$PE_SUBNET"
subst '__DNS_IN_SUBNET__'     "$DNS_IN_SUBNET"
subst '__DNS_OUT_SUBNET__'    "$DNS_OUT_SUBNET"
subst '__SERVICE_CIDR__'      "$SERVICE_CIDR"
subst '__DNS_SERVICE_IP__'    "$DNS_SERVICE_IP"
subst '__POD_CIDR__'          "$POD_CIDR"
subst '__ON_PREM_CIDRS__'     "$(bicep_array "$ON_PREM")"
subst '__ADMIN_GROUPS__'      "$(bicep_array "$ADMIN_GROUPS")"
subst '__AUTHORIZED_IPS__'    "$(bicep_array "$AUTHORIZED_IPS")"
subst '__MANAGEMENT_RANGES__' "$(bicep_array "$ON_PREM")"
subst '__ALERT_EMAIL__'       "$ALERT_EMAIL"

# A leftover placeholder means the template and this script have drifted. Failing here is far better
# than writing a file that compiles into something nobody intended.
if leftover="$(echo "$TEMPLATE" | grep -o '__[A-Z0-9_]*__' | head -1)" && [ -n "$leftover" ]; then
  echo "ERROR: template placeholder $leftover was not substituted." >&2
  echo "       scripts/lib/wizard-template.bicepparam.tmpl and wizard.sh have drifted." >&2
  exit 2
fi

printf '%s\n' "$TEMPLATE" > "$OUT_FILE"
export AKS_COST_TIER="$COST_TIER"

# ==================================================================================================
# 11. Show the plan, then confirm
# ==================================================================================================

heading 'Your plan'
row() { printf '  %-17s %s\n' "$1" "$2"; }
row 'Purpose'         "$PURPOSE_LABEL  (cost tier $COST_TIER)"
row 'Architecture'          "$ARCHITECTURE"
row 'API server'      "$API_ACCESS"
row 'Region'          "$LOCATION"
row 'Egress'          "$EGRESS  ->  outboundType $OUTBOUND_TYPE"
row 'Network profile' "$NETWORK_PROFILE"
row 'VNet'            "$VNET"
row 'Node subnet'     "$NODE_SUBNET"
if [ -n "$POD_SUBNET" ]; then
  row 'Pod addressing' "pod subnet $POD_SUBNET (VNet-routable)"
else
  row 'Pod addressing' "overlay $POD_CIDR (not VNet-routable)"
fi
row 'API subnet'      "${API_SUBNET:-n/a}"
row 'Firewall subnet' "${FIREWALL_SUBNET:-n/a}"
row 'Service CIDR'    "$SERVICE_CIDR  (DNS $DNS_SERVICE_IP)"
row 'On-premises'     "${ON_PREM:-none declared}"
row 'System pool'     "$NODE_COUNT x $NODE_VM_SIZE across zones 1,2,3"
row 'Entra admins'    "${ADMIN_GROUPS:-NONE - local accounts only}"
row 'Authorized IPs'  "${AUTHORIZED_IPS:-n/a}"
row 'Alert email'     "${ALERT_EMAIL:-none}"
row 'Resource group'  "$RESOURCE_GROUP"

echo
g '.closing.immutableWarning[]' | while IFS= read -r l; do
  printf '  %s%s%s\n' "$C_MAGENTA" "$l" "$C_RESET"
done

echo
printf '  %sPlan written to: %s%s\n' "$C_GREEN" "$OUT_FILE" "$C_RESET"
printf '  %sThat file is the whole plan. Keep it, review it, or re-run this wizard to replace it.%s\n' "$C_DIM" "$C_RESET"

# The plan is compiled before anyone is asked to approve it, so a malformed answer surfaces here
# rather than sixty seconds into an ARM deployment.
echo
printf '  %sCompiling the plan...%s\n' "$C_DIM" "$C_RESET"
if ! az bicep build-params --file "$OUT_FILE" --stdout >/dev/null 2>&1; then
  printf '  %sThe generated plan does not compile. This is a bug in the wizard, not in your answers.%s\n' "$C_RED" "$C_RESET"
  az bicep build-params --file "$OUT_FILE" --stdout
  exit 1
fi
printf '  %sCompiles cleanly.%s\n' "$C_GREEN" "$C_RESET"

RESOLVED="$(resolve_bicepparam "$OUT_FILE")"
show_cost_estimate "$RESOLVED" "$ARCHITECTURE" "$COST_TIER" || true

echo
g '.closing.nextSteps[]' | while IFS= read -r l; do
  printf '  %s%s%s\n' "$C_DIM" "$l" "$C_RESET"
done

DEPLOY_CMD="./scripts/deploy.sh --architecture $ARCHITECTURE -g $RESOURCE_GROUP --location $LOCATION --param-file '$OUT_FILE'"

if [ "$PLAN_ONLY" -eq 1 ]; then
  echo
  printf '  %sPlan only, nothing deployed. When you are ready:%s\n' "$C_CYAN" "$C_RESET"
  echo "    export AKS_COST_TIER=$COST_TIER"
  echo "    $DEPLOY_CMD"
  echo
  exit 0
fi

echo
printf '  %sType deploy to build this, or anything else to stop.%s\n' "$C_WHITE" "$C_RESET"
printf '  %sNothing has been created yet.%s\n' "$C_DIM" "$C_RESET"
echo
printf '  %s> %s' "$C_WHITE" "$C_RESET"
IFS= read -r confirm || confirm=''
if [ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != 'deploy' ]; then
  echo
  printf '  %sStopped. The plan is still on disk, so you can deploy it later with:%s\n' "$C_YELLOW" "$C_RESET"
  echo "    $DEPLOY_CMD"
  echo
  exit 0
fi

# ==================================================================================================
# 12. Deploy, through the ordinary path
#
# The wizard deliberately does not deploy anything itself. It hands the plan to the same script a
# pipeline would use, so the pre-flight gate, the cost gate, the firewall next-hop assertion and the
# governance proof all apply exactly as they would otherwise.
# ==================================================================================================

deploy_args=(--architecture "$ARCHITECTURE" -g "$RESOURCE_GROUP" --location "$LOCATION" --param-file "$OUT_FILE" --yes)
[ -n "$ON_PREM" ] && deploy_args+=(--on-prem-cidrs "$ON_PREM")

deploy_rc=0
"${script_dir}/deploy.sh" "${deploy_args[@]}" || deploy_rc=$?

if [ "$deploy_rc" -ne 0 ]; then
  echo
  printf '%s  The deployment did not complete. Nothing about your plan is lost - it is still at\n' "$C_YELLOW"
  printf '  %s and can be corrected and re-run.%s\n' "$OUT_FILE" "$C_RESET"
  echo
  printf '  %sFor a readable post-mortem of what failed and why:%s\n' "$C_CYAN" "$C_RESET"
  echo "    ./scripts/diagnose.sh -g $RESOURCE_GROUP"
  echo
  exit "$deploy_rc"
fi

heading 'What to try next'
printf '  %sThe cluster exists. These are worth doing in order, because each one proves something%s\n' "$C_DIM" "$C_RESET"
printf '  %sdifferent about the shape you just built:%s\n' "$C_DIM" "$C_RESET"
echo
printf '   %s1. Get credentials and list nodes. On a private architecture this is the moment you find out%s\n' "$C_WHITE" "$C_RESET"
printf '      %swhether you actually have a network path - which is the point of the architecture.%s\n' "$C_DIM" "$C_RESET"
printf '   %s2. Prove the governance is real, not just assigned:%s\n' "$C_WHITE" "$C_RESET"
printf '      %s./scripts/verify-policy.sh -g %s -n <cluster> --wait-minutes 20%s\n' "$C_DIM" "$RESOURCE_GROUP" "$C_RESET"
printf '   %s3. Stop paying for it without destroying it:%s\n' "$C_WHITE" "$C_RESET"
printf '      %s./scripts/pause.sh -g %s%s\n' "$C_DIM" "$RESOURCE_GROUP" "$C_RESET"
printf '   %s4. Remove it completely, including role assignments and policy definitions:%s\n' "$C_WHITE" "$C_RESET"
printf '      %s./scripts/destroy.sh --architecture %s -g %s%s\n' "$C_DIM" "$ARCHITECTURE" "$RESOURCE_GROUP" "$C_RESET"
echo
