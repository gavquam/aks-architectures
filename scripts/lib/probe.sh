#!/usr/bin/env bash
# Runs INSIDE the throwaway probe VM, in the intended AKS node subnet.
#
# Emits one machine-readable line per check:
#     PREFLIGHT|<id>|<pass|warn|fail>|<human readable detail>
# plus free-form context lines prefixed with CONTEXT| that the caller folds into the JSON evidence.
#
# Constraints this script must respect, because it runs on a node that may have NO internet egress:
#   * no package installs, no downloads - only what a stock Ubuntu server image already has
#   * every network operation is bounded by a timeout, so a black-holing UDR cannot hang the run
#   * exit code is always 0; the caller decides pass/fail from the PREFLIGHT lines
#
# Usage: probe.sh <azure-region> [api-server-fqdn] [extra-fqdn,extra-fqdn,...]

set -u

REGION="${1:-}"
API_FQDN="${2:-}"
EXTRA_FQDNS="${3:-}"
CONNECT_TIMEOUT=6

emit() { printf 'PREFLIGHT|%s|%s|%s\n' "$1" "$2" "$3"; }
context() { printf 'CONTEXT|%s|%s\n' "$1" "$2"; }

# --------------------------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------------------------

resolve_host() {
  # Echoes the first A record, or nothing. Never blocks longer than the timeout.
  timeout "$CONNECT_TIMEOUT" getent ahostsv4 "$1" 2>/dev/null | awk '/STREAM|RAW/ {print $1; exit}'
}

dns_detail() {
  # Best-effort classification of WHY a name did not resolve. SERVFAIL / timeout means the resolver
  # itself is unreachable or a firewall is eating DNS; NXDOMAIN means DNS works and the name is
  # genuinely absent. Those two demand completely different fixes, so the distinction matters.
  if command -v resolvectl >/dev/null 2>&1; then
    timeout "$CONNECT_TIMEOUT" resolvectl query "$1" 2>&1 | tr '\n' ' ' | cut -c1-220
  elif command -v dig >/dev/null 2>&1; then
    timeout "$CONNECT_TIMEOUT" dig +short +time=3 +tries=1 "$1" 2>&1 | tr '\n' ' ' | cut -c1-220
  else
    echo 'no resolver diagnostic tool available'
  fi
}

tcp_connect() {
  # /dev/tcp is a bash builtin - no nc, no curl, nothing to install.
  timeout "$CONNECT_TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# --------------------------------------------------------------------------------------------
# Check: DNS + TCP for one endpoint
# --------------------------------------------------------------------------------------------

check_tcp() {
  local id="$1" host="$2" port="$3" severity="$4"   # severity: fail | warn
  local ip elapsed_start elapsed

  if [ -z "$host" ]; then
    emit "$id" warn "no hostname supplied for this check"
    return
  fi

  ip="$(resolve_host "$host")"
  if [ -z "$ip" ]; then
    emit "$id" "$severity" "DNS resolution FAILED for ${host} - $(dns_detail "$host")"
    return
  fi

  elapsed_start=$(date +%s%3N 2>/dev/null || echo 0)
  if tcp_connect "$ip" "$port"; then
    elapsed=$(( $(date +%s%3N 2>/dev/null || echo 0) - elapsed_start ))
    emit "$id" pass "${host}:${port} reachable via ${ip} (${elapsed}ms)"
  else
    emit "$id" "$severity" "${host}:${port} resolved to ${ip} but TCP connect was refused or timed out after ${CONNECT_TIMEOUT}s"
  fi
}

check_dns_only() {
  # Used for wildcard endpoint families where no single concrete host exists to connect to.
  local id="$1" host="$2"
  local ip
  ip="$(resolve_host "$host")"
  if [ -n "$ip" ]; then
    emit "$id" pass "${host} resolves to ${ip}"
  else
    local detail
    detail="$(dns_detail "$host")"
    case "$detail" in
      *NXDOMAIN*|*"not found"*|*"no such"*)
        emit "$id" pass "resolver answered authoritatively for ${host} (NXDOMAIN is expected for a synthetic name); DNS path is healthy" ;;
      *)
        emit "$id" warn "${host} did not resolve - ${detail}" ;;
    esac
  fi
}

# --------------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------------

# Platform endpoints. These use the Azure platform route (next hop VirtualNetwork/168.63.129.16) and
# survive a 0.0.0.0/0 UDR, so a failure here means something far more fundamental than egress.
if tcp_connect 169.254.169.254 80; then
  emit imds pass 'Instance Metadata Service 169.254.169.254:80 reachable'
else
  emit imds fail 'Instance Metadata Service unreachable - the NSG is blocking 169.254.169.254 or the image has a broken route table'
fi

if tcp_connect 168.63.129.16 80; then
  emit wireserver pass 'Azure platform endpoint 168.63.129.16:80 reachable'
else
  emit wireserver fail 'Azure platform endpoint 168.63.129.16 unreachable - AKS node bootstrap and the guest agent both depend on it; check for an NSG deny or a UDR overriding 168.63.129.16/32'
fi

# Control-plane and identity: without these the node cannot register and kubelet cannot authenticate.
check_tcp arm            management.azure.com            443 fail
check_tcp aad            login.microsoftonline.com       443 fail

# Container images.
check_tcp mcr            mcr.microsoft.com               443 fail
# MCR regional data endpoints do not exist for every region - westus3, for example, has no A record
# at all while eastus does. Treat this as a warning: a missing record is a property of the region,
# not evidence of a firewall deny, and failing on it produces a false alarm on every deployment in
# such a region. The firewall still needs *.data.mcr.microsoft.com allowed for image layer pulls.
check_tcp mcr_data       "${REGION}.data.mcr.microsoft.com" 443 warn

# Node bootstrap binaries. packages.aks.azure.com is the current endpoint; acs-mirror is the legacy
# one still referenced by older node images, so its absence is a warning rather than a failure.
check_tcp aks_packages   packages.aks.azure.com          443 fail
check_tcp acs_mirror     acs-mirror.azureedge.net        443 warn

# Distro security updates. Both Ubuntu and Azure Linux node pools pull from packages.microsoft.com;
# Ubuntu additionally uses the Canonical mirrors.
check_tcp ms_packages    packages.microsoft.com          443 fail
check_tcp ubuntu_security security.ubuntu.com            443 warn
check_tcp ubuntu_archive azure.archive.ubuntu.com        443 warn

# API server. A wildcard cannot be probed, so a real FQDN is used when one is available and a
# synthetic name under the regional zone is used otherwise to at least exercise the DNS path.
if [ -n "$API_FQDN" ]; then
  check_tcp api_server "$API_FQDN" 443 fail
else
  check_dns_only api_server_zone "preflight-probe.hcp.${REGION}.azmk8s.io"
fi

# Caller-supplied extras: private ACR data endpoints, an on-premises historian, a licence server.
if [ -n "$EXTRA_FQDNS" ]; then
  i=0
  IFS=',' read -ra _extras <<< "$EXTRA_FQDNS"
  for fqdn in "${_extras[@]}"; do
    fqdn="$(echo "$fqdn" | xargs)"
    [ -z "$fqdn" ] && continue
    i=$((i + 1))
    check_tcp "extra_${i}_$(echo "$fqdn" | tr -c 'a-zA-Z0-9' '_')" "$fqdn" 443 fail
  done
fi

# NTP. Kubelet certificate validation and AAD token validation both fail in confusing ways when the
# node clock drifts, and UDP 123 is the single most commonly forgotten firewall rule.
NTP_HOST="time.windows.com"
if command -v python3 >/dev/null 2>&1; then
  ntp_out="$(timeout "$CONNECT_TIMEOUT" python3 - "$NTP_HOST" <<'PY' 2>&1
import socket, struct, sys
host = sys.argv[1]
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    s.sendto(b'\x1b' + 47 * b'\0', (host, 123))
    data, _ = s.recvfrom(1024)
    secs = struct.unpack('!12I', data[:48])[10] - 2208988800
    print('OK %d' % secs)
except Exception as exc:
    print('ERR %s' % exc)
PY
)"
  case "$ntp_out" in
    OK*) emit ntp pass "NTP UDP 123 to ${NTP_HOST} answered (${ntp_out})" ;;
    *)   emit ntp fail "NTP UDP 123 to ${NTP_HOST} failed - ${ntp_out}. Open UDP 123 outbound or point the nodes at an internal time source." ;;
  esac
else
  emit ntp warn 'python3 not present on the probe image; UDP 123 could not be tested'
fi

# Clock sanity, independent of whether the NTP probe itself succeeded.
if command -v timedatectl >/dev/null 2>&1; then
  sync_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  if [ "$sync_state" = "yes" ]; then
    emit clock pass "system clock is NTP-synchronised ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
  else
    emit clock warn "system clock is NOT NTP-synchronised (currently $(date -u '+%Y-%m-%dT%H:%M:%SZ')) - expect TLS and token validation failures on the nodes"
  fi
fi

# --------------------------------------------------------------------------------------------
# Context for the JSON evidence blob
# --------------------------------------------------------------------------------------------

context default_route "$(ip route show default 2>/dev/null | head -1 | tr '\n' ' ')"
context nameservers   "$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
context private_ip    "$(hostname -I 2>/dev/null | awk '{print $1}')"

# The observed egress IP is what AKS API server authorized-IP-range rules must contain, and it is
# almost never the address people assume when a NAT Gateway or Azure Firewall is in the path.
egress_ip=''
if command -v curl >/dev/null 2>&1; then
  egress_ip="$(timeout "$CONNECT_TIMEOUT" curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
fi
context observed_egress_ip "${egress_ip:-unavailable (no egress, or curl absent)}"

exit 0
