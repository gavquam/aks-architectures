#!/usr/bin/env bash
# Shared helpers for the aks-architectures shell scripts: architecture-matrix lookup, CIDR arithmetic,
# .bicepparam resolution, role-ID resolution and the pass/fail result model.
#
# Requires: az, jq. Nothing else - these scripts must run on a stock CI runner.

set -uo pipefail

# --------------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------------

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${lib_dir}/../.." && pwd)"
MATRIX_FILE="${REPO_ROOT}/infra/architecture-matrix.json"

require_tools() {
  local missing=() t kind
  for t in "$@"; do
    kind="$(type -t "$t" 2>/dev/null || true)"
    if [ "$kind" = 'function' ]; then
      # jq is shadowed by a wrapper below, so `command -v` would always succeed. Look for the
      # actual executable instead.
      type -P "$t" >/dev/null 2>&1 || missing+=("$t")
    elif ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: required tool(s) not on PATH: ${missing[*]}" >&2
    echo "  az: https://aka.ms/azcli    jq: https://jqlang.github.io/jq/" >&2
    exit 2
  fi
}

assert_azure_cli() {
  require_tools az jq
  if ! az account show -o json >/dev/null 2>&1; then
    echo 'ERROR: not signed in. Run: az login' >&2
    exit 2
  fi
}

matrix() { jq -r "$1" "$MATRIX_FILE"; }

# On Windows, a native jq build and az.cmd both open stdout in text mode and terminate lines with
# CRLF. A stray CR then rides along inside every value captured by `read` or `$()`, which silently
# corrupts comparisons and result IDs. Shadowing jq strips it once, everywhere; CR is not
# significant in JSON output either, so this is safe for the file-writing call sites too.
jq() { command jq "$@" | tr -d '\r'; }

aztsv() { az "$@" -o tsv 2>/dev/null | tr -d '\r'; }

# --------------------------------------------------------------------------------------------
# CIDR arithmetic, in pure bash integer math
# --------------------------------------------------------------------------------------------

ip_to_int() {
  local IFS=. ; read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local v=$1
  echo "$(( (v >> 24) & 255 )).$(( (v >> 16) & 255 )).$(( (v >> 8) & 255 )).$(( v & 255 ))"
}

cidr_valid() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip="${1%%/*}" len="${1##*/}"
  [ "$len" -ge 0 ] && [ "$len" -le 32 ] || return 1
  local IFS=. ; read -r a b c d <<< "$ip"
  for o in "$a" "$b" "$c" "$d"; do [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1; done
  return 0
}

cidr_start() {
  local ip="${1%%/*}" len="${1##*/}" base size
  base=$(ip_to_int "$ip")
  size=$(( 1 << (32 - len) ))
  echo $(( base - (base % size) ))
}

cidr_size() { local len="${1##*/}"; echo $(( 1 << (32 - len) )); }
cidr_end()  { echo $(( $(cidr_start "$1") + $(cidr_size "$1") - 1 )); }
cidr_prefix() { echo "${1##*/}"; }

# 0 (true) when the two ranges intersect.
cidr_overlap() {
  local as ae bs be
  as=$(cidr_start "$1"); ae=$(cidr_end "$1")
  bs=$(cidr_start "$2"); be=$(cidr_end "$2")
  [ "$as" -le "$be" ] && [ "$bs" -le "$ae" ]
}

# 0 (true) when $2 is entirely inside $1.
cidr_contains() {
  local os oe is ie
  os=$(cidr_start "$1"); oe=$(cidr_end "$1")
  is=$(cidr_start "$2"); ie=$(cidr_end "$2")
  [ "$is" -ge "$os" ] && [ "$ie" -le "$oe" ]
}

ip_in_cidr() { cidr_contains "$2" "$1/32"; }

# --------------------------------------------------------------------------------------------
# .bicepparam resolution
# --------------------------------------------------------------------------------------------

# Compiles a .bicepparam file and echoes the flattened parameters JSON object
# ({"customer": "...", "addressing": {...}, ...}). Environment variables are read at compile time,
# so this must run in the same shell as the deployment.
resolve_bicepparam() {
  local file="$1" out
  out="$(az bicep build-params --file "$file" --stdout 2>&1)" || {
    echo "ERROR: az bicep build-params failed for $file" >&2
    echo "$out" >&2
    exit 2
  }
  echo "$out" | jq -r '.parametersJson' | jq '.parameters | with_entries(.value = .value.value)'
}

# param_get <params-json> <dotted.path> [default]
param_get() {
  local json="$1" path="$2" def="${3:-}" val
  val="$(echo "$json" | jq -r --arg p "$path" '
    ($p | split(".")) as $segs
    | reduce $segs[] as $s (.; if . == null then null else (.[$s] // null) end)
    | if . == null then "" elif type == "array" then (map(tostring) | join(",")) else tostring end' 2>/dev/null)"
  if [ -z "$val" ] || [ "$val" = "null" ]; then echo "$def"; else echo "$val"; fi
}

# --------------------------------------------------------------------------------------------
# Result model - mirrors scripts/lib/common.psm1 so both implementations emit the same JSON
# --------------------------------------------------------------------------------------------

RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT
echo '[]' > "$RESULTS_FILE"

# add_result <id> <category> <pass|warn|skip|fail> <message> [remediation]
add_result() {
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$1" --arg cat "$2" --arg st "$3" --arg msg "$4" --arg rem "${5:-}" \
    '. += [{id:$id, category:$cat, status:$st, message:$msg, remediation:$rem}]' \
    "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
}

print_results_table() {
  local title="$1"
  local reset='\033[0m' green='\033[32m' yellow='\033[33m' red='\033[31m' grey='\033[90m' cyan='\033[36m'
  [ -t 1 ] || { reset=''; green=''; yellow=''; red=''; grey=''; cyan=''; }

  echo ''
  printf '%.0s=' {1..100}; echo ''
  echo "$title"
  printf '%.0s=' {1..100}; echo ''

  local last_cat=''
  while IFS=$'\t' read -r id cat status msg rem; do
    if [ "$cat" != "$last_cat" ]; then
      echo ''
      # The leading '%s' is required: with colors disabled the format would start with '--' and
      # bash printf would treat it as an end-of-options marker.
      printf '%s-- %s ' "$cyan" "$cat"; printf '%.0s-' {1..70}; printf '%s\n' "$reset"
      last_cat="$cat"
    fi
    local color="$grey" label='SKIP'
    case "$status" in
      pass) color="$green"; label='PASS' ;;
      warn) color="$yellow"; label='WARN' ;;
      fail) color="$red"; label='FAIL' ;;
    esac
    printf "  ${color}[%s]${reset} %-34s %s\n" "$label" "$id" "$msg"
    if [ -n "$rem" ] && { [ "$status" = 'fail' ] || [ "$status" = 'warn' ]; }; then
      printf "         ${yellow}-> %s${reset}\n" "$rem"
    fi
  done < <(jq -r '.[] | [.id, .category, .status, .message, .remediation] | @tsv' "$RESULTS_FILE")

  COUNT_PASS=$(jq '[.[] | select(.status=="pass")] | length' "$RESULTS_FILE")
  COUNT_WARN=$(jq '[.[] | select(.status=="warn")] | length' "$RESULTS_FILE")
  COUNT_SKIP=$(jq '[.[] | select(.status=="skip")] | length' "$RESULTS_FILE")
  COUNT_FAIL=$(jq '[.[] | select(.status=="fail")] | length' "$RESULTS_FILE")

  echo ''
  printf '%.0s=' {1..100}; echo ''
  if [ "$COUNT_FAIL" -gt 0 ]; then
    printf "${red}  %s passed   %s warned   %s skipped   %s FAILED${reset}\n" "$COUNT_PASS" "$COUNT_WARN" "$COUNT_SKIP" "$COUNT_FAIL"
  else
    printf "${green}  %s passed   %s warned   %s skipped   %s FAILED${reset}\n" "$COUNT_PASS" "$COUNT_WARN" "$COUNT_SKIP" "$COUNT_FAIL"
  fi
  printf '%.0s=' {1..100}; echo ''
  echo ''
}

# --------------------------------------------------------------------------------------------
# Azure helpers
# --------------------------------------------------------------------------------------------

# Managed and CSP tenants do not always use the published built-in role GUIDs. Hardcoding them
# produces RoleDefinitionDoesNotExist at deploy time, so resolve by display name and fall back.
resolve_role_id() {
  local display="$1" fallback="$2" id
  id="$(aztsv role definition list --name "$display" --query '[0].name')"
  if [ -n "$id" ] && [ "$id" != 'null' ]; then echo "$id"; else
    echo "WARNING: could not resolve role '$display'; using the well-known GUID $fallback" >&2
    echo "$fallback"
  fi
}

geo_code() {
  case "$1" in
    eastus) echo eus ;; eastus2) echo eus2 ;; centralus) echo cus ;; northcentralus) echo ncus ;;
    southcentralus) echo scus ;; westcentralus) echo wcus ;; westus) echo wus ;; westus2) echo wus2 ;;
    westus3) echo wus3 ;; canadacentral) echo cac ;; canadaeast) echo cae ;; brazilsouth) echo brs ;;
    northeurope) echo neu ;; westeurope) echo weu ;; uksouth) echo uks ;; ukwest) echo ukw ;;
    francecentral) echo frc ;; germanywestcentral) echo gwc ;; switzerlandnorth) echo chn ;;
    norwayeast) echo nwe ;; swedencentral) echo sdc ;; polandcentral) echo plc ;; italynorth) echo itn ;;
    spaincentral) echo spc ;; uaenorth) echo uan ;; southafricanorth) echo san ;; australiaeast) echo aue ;;
    australiasoutheast) echo ause ;; southeastasia) echo sea ;; eastasia) echo ea ;; japaneast) echo jpe ;;
    japanwest) echo jpw ;; koreacentral) echo krc ;; centralindia) echo inc ;; southindia) echo ins ;;
    israelcentral) echo ilc ;; mexicocentral) echo mxc ;; newzealandnorth) echo nzn ;;
    *) echo "${1:0:3}" ;;
  esac
}

# --------------------------------------------------------------------------------------------
# Cost estimate - mirrors Get-CostEstimate / Write-CostEstimate in common.psm1
#
# The point of this is not accounting accuracy, it is that nobody should discover an Azure
# Firewall on their invoice. It itemises only the things that bill continuously once created;
# per-request and per-GB charges are named but not totalled, because guessing someone's traffic
# would be dishonest.
# --------------------------------------------------------------------------------------------

COST_FILE="${REPO_ROOT}/scripts/lib/cost-estimates.json"
COST_HAS_EXPENSIVE=0
_COST_LINES=()

# _cost_monthly <item-key> [multiplier] -> whole dollars per month
_cost_monthly() {
  jq -r --arg k "$1" --argjson m "${2:-1}" '
    .hoursPerMonth as $h
    | .items[$k] as $i
    | (if   $i.unit == "hour"  then $i.unitPrice * $h
       elif $i.unit == "day"   then $i.unitPrice * ($h / 24)
       elif $i.unit == "month" then $i.unitPrice
       else 0 end) as $per
    | ($per * ($i.count // 1) * $m) | round' "$COST_FILE"
}

# _cost_add <label> <monthly> <expensive 0|1> <note>
_cost_add() {
  _COST_LINES+=("$1|$2|$3|${4:-}")
  [ "$3" -eq 1 ] && COST_HAS_EXPENSIVE=1
  return 0
}

# _cost_node_key <vm size> -> item key, or empty when the size is not priced here.
# Standard_D4ds_v5 -> nodeD4dsV5
_cost_node_key() {
  local k="node${1#Standard_}"
  k="${k/_v/V}"
  if jq -e --arg k "$k" '.items | has($k)' "$COST_FILE" >/dev/null 2>&1; then echo "$k"; fi
}

# show_cost_estimate <params-json> <architecture> <tier>
show_cost_estimate() {
  local params="$1" architecture="$2" tier="$3"
  _COST_LINES=(); COST_HAS_EXPENSIVE=0

  local azure_region creates_cluster sku_name
  azure_region="$(matrix ".architectures[\"$architecture\"].azureRegion")"
  creates_cluster="$(matrix ".architectures[\"$architecture\"].createsCluster")"
  sku_name="$(matrix ".architectures[\"$architecture\"].skuName")"

  if [ "$azure_region" = 'true' ] && [ "$creates_cluster" = 'true' ]; then
    local count size key
    count="$(param_get "$params" 'systemNodePool.count' 0)"
    size="$(param_get "$params" 'systemNodePool.vmSize' '')"
    key="$(_cost_node_key "$size")"
    if [ -n "$key" ]; then
      _cost_add "System node pool, $count x $size" "$(_cost_monthly "$key" "$count")" 0 ''
    else
      _cost_add "System node pool, $count x $size" 0 0 'size not priced here, see docs/costs.md'
    fi

    if [ "$(param_get "$params" 'deployUserNodePool' 'false')" = 'true' ]; then
      local ucount usize ukey uamount
      ucount="$(param_get "$params" 'userNodePool.count' 0)"
      usize="$(param_get "$params" 'userNodePool.vmSize' '')"
      ukey="$(_cost_node_key "$usize")"
      uamount=0
      [ -n "$ukey" ] && uamount="$(_cost_monthly "$ukey" "$ucount")"
      _cost_add "User node pool, $ucount x $usize" "$uamount" 1 'AKS_DEPLOY_USER_POOL=false removes it'
    fi

    # Automatic pins the cluster to Standard regardless of clusterSkuTier, so the SLA is billed
    # there whatever the cost tier says.
    local is_automatic=0
    [ "$sku_name" = 'Automatic' ] && is_automatic=1
    if [ "$is_automatic" -eq 1 ] || [ "$(param_get "$params" 'clusterSkuTier' 'Free')" = 'Standard' ]; then
      local sla_note='Free tier is the same cluster without the SLA'
      [ "$is_automatic" -eq 1 ] && sla_note='not optional on this architecture'
      _cost_add 'AKS Standard tier (uptime SLA)' "$(_cost_monthly aksUptimeSla)" 0 "$sla_note"
    fi
    if [ "$is_automatic" -eq 1 ]; then
      _cost_add 'AKS Automatic hosted control plane' "$(_cost_monthly aksAutomaticControlPlane)" 0 'not optional on this architecture'
    fi

    local egress fw_sku fw_key
    egress="$(param_get "$params" 'egress' 'none')"
    case "$egress" in
      natgateway)
        _cost_add 'NAT Gateway + 1 public IP' "$(( $(_cost_monthly natGateway) + $(_cost_monthly publicIp) ))" 0 ''
        ;;
      udr-firewall)
        fw_sku="$(param_get "$params" 'firewallSkuTier' 'Standard')"
        fw_key='azureFirewallStandard'
        [ "$fw_sku" = 'Premium' ] && fw_key='azureFirewallPremium'
        _cost_add "Azure Firewall ($fw_sku) + 1 public IP" \
          "$(( $(_cost_monthly "$fw_key") + $(_cost_monthly publicIp) ))" 1 'AKS_EGRESS=natgateway removes it'
        ;;
    esac

    [ "$(param_get "$params" 'features.bastion' 'false')" = 'true' ] &&
      _cost_add 'Azure Bastion (Basic)' "$(_cost_monthly bastionBasic)" 1 'AKS_COST_TIER=lean removes it'
    [ "$(param_get "$params" 'features.privateDnsResolver' 'false')" = 'true' ] &&
      _cost_add 'DNS Private Resolver (2 endpoints)' "$(_cost_monthly dnsResolverEndpoint)" 1 'AKS_COST_TIER=lean removes it'

    if [ "$(param_get "$params" 'features.managedGrafana' 'false')" = 'true' ]; then
      local gsku gkey gexp
      gsku="$(param_get "$params" 'grafanaSku' 'Essential')"
      gkey='grafanaEssential'; gexp=0
      [ "$gsku" = 'Standard' ] && { gkey='grafanaStandard'; gexp=1; }
      _cost_add "Managed Grafana ($gsku)" "$(_cost_monthly "$gkey")" "$gexp" 'AKS_GRAFANA_SKU=Essential is cheaper'
    fi

    if [ "$(param_get "$params" 'features.containerRegistry' 'false')" = 'true' ]; then
      local asku aexp
      asku="$(param_get "$params" 'containerRegistrySku' 'Basic')"
      aexp=0; [ "$asku" = 'Premium' ] && aexp=1
      _cost_add "Container registry ($asku)" "$(_cost_monthly "acr$asku")" "$aexp" 'Premium buys the private endpoint'
    fi

    if [ "$(param_get "$params" 'features.diagnosticSettings' 'false')" = 'true' ]; then
      local cap
      cap="$(param_get "$params" 'logAnalyticsDailyQuotaGb' '-1')"
      if [ "$cap" -gt 0 ] 2>/dev/null; then
        _cost_add "Log Analytics ceiling, $cap GB/day cap" \
          "$(jq -r --argjson c "$cap" '(.items.logAnalyticsPerGb.unitPrice * $c * 30) | round' "$COST_FILE")" \
          0 'a ceiling, not a run rate'
      else
        _cost_add 'Log Analytics ingestion' 0 1 'UNCAPPED - set logAnalyticsDailyQuotaGb'
      fi
    fi

    if [ "$(param_get "$params" 'features.defenderForContainers' 'false')" = 'true' ]; then
      local vcores
      vcores=$(( count * 4 ))
      _cost_add "Defender for Containers, about $vcores vCores" \
        "$(jq -r --argjson v "$vcores" '(.items.defenderPerVcoreHour.unitPrice * .hoursPerMonth * $v) | round' "$COST_FILE")" \
        0 'scales with every node you add'
    fi
  elif [ "$(param_get "$params" 'features.defenderForContainers' 'false')" = 'true' ]; then
    _cost_add 'Defender for Containers on the Arc cluster' 0 0 'about $7 per vCore per month'
  fi

  local currency region captured total=0
  currency="$(jq -r '.currency' "$COST_FILE")"
  region="$(jq -r '.referenceRegion' "$COST_FILE")"
  captured="$(jq -r '.capturedOn' "$COST_FILE")"

  echo ''
  echo "COST ESTIMATE  (cost tier: $tier)"
  echo "$currency list prices for $region, captured $captured. An estimate, not a quote."
  printf '%.0s-' {1..78}; echo ''
  if [ "${#_COST_LINES[@]}" -eq 0 ]; then
    echo '   Nothing in this architecture bills by the hour. Attaching a cluster to Arc is free;'
    echo '   only the Arc features you enable on top of it are chargeable.'
    echo ''
    return 0
  fi
  local line label amount expensive note marker display
  for line in "${_COST_LINES[@]}"; do
    IFS='|' read -r label amount expensive note <<< "$line"
    total=$(( total + amount ))
    marker='  '; [ "$expensive" -eq 1 ] && marker='!!'
    display="usage"; [ "$amount" -gt 0 ] && display="\$$amount"
    printf '%s %-42s %10s /mo  %s\n' "$marker" "$label" "$display" "$note"
  done
  printf '%.0s-' {1..78}; echo ''
  printf '   %-42s %10s /mo\n' 'Estimated standing cost' "\$$total"
  echo '   Log ingestion is counted at its daily cap, so this is an upper bound.'
  echo '   Excludes data processed, egress bandwidth, storage and per-request charges.'
  if [ "$COST_HAS_EXPENSIVE" -eq 1 ]; then
    echo ''
    echo '   Lines marked !! are the ones worth a second look. docs/costs.md explains each.'
  fi
  echo ''
}
