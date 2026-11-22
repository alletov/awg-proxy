#!/usr/bin/env bash

install_packages() {
  require_root
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) [[ ${AWGPROXY_UNSUPPORTED_OS:-0} == 1 ]] || die "supported Ubuntu releases: 22.04 and 24.04 (set AWGPROXY_UNSUPPORTED_OS=1 to test another release)" ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl dnsutils nftables unbound dante-server \
    software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
  if ! apt-cache show amneziawg >/dev/null 2>&1; then
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update
  fi
  apt-get install -y amneziawg
  modprobe amneziawg
  have awg && have awg-quick || die "AmneziaWG tools were not installed"
}

create_backup() {
  require_root
  local stamp dir
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dir="$BACKUP_DIR/$stamp"
  install -d -m 0700 "$dir"
  ip -4 route show table all > "$dir/routes.txt"
  ip rule > "$dir/rules.txt"
  nft list ruleset > "$dir/nftables.rules"
  [[ -f $AWGPROXY_CONFIG ]] && cp -a "$AWGPROXY_CONFIG" "$dir/awgproxy.conf"
  [[ -f $AWG_CONFIG ]] && cp -a "$AWG_CONFIG" "$dir/awg0.conf"
  printf '%s' "$dir"
}

arm_rollback() {
  local backup=$1 unit
  touch "$backup/ARMED"
  unit="awgproxy-rollback-$(date +%s)"
  printf '%s' "$unit" > "$backup/ROLLBACK_UNIT"
  systemd-run --unit="$unit" --on-active=5m \
    /usr/local/lib/awgproxy/rollback.sh "$backup" >/dev/null
  info "automatic rollback armed for 5 minutes"
}

disarm_rollback() {
  local backup=$1 unit=''
  rm -f -- "$backup/ARMED"
  [[ -r $backup/ROLLBACK_UNIT ]] && unit=$(<"$backup/ROLLBACK_UNIT")
  [[ -z $unit ]] || systemctl stop "$unit.timer" 2>/dev/null || true
  ok "automatic rollback disarmed; backup kept at $backup"
}

apply_configuration() {
  require_root
  local backup=${1:-}
  [[ -n $backup ]] || backup=$(create_backup)
  render_runtime_files
  nft -c -f "$AWGPROXY_DIR/nftables.conf"
  systemctl daemon-reload
  arm_rollback "$backup"
  sysctl --system >/dev/null
  systemctl enable awgproxy-routes awgproxy-firewall awg-quick@awg0
  systemctl stop awg-quick@awg0 2>/dev/null || true
  systemctl restart awgproxy-routes awgproxy-firewall
  systemctl start awg-quick@awg0
  if (( ENABLE_DNS )); then systemctl enable unbound; systemctl restart unbound; else systemctl disable --now unbound 2>/dev/null || true; fi
  if (( ENABLE_SOCKS )); then systemctl enable danted; systemctl restart danted; else systemctl disable --now danted 2>/dev/null || true; fi
  if validate_installation; then
    if [[ -n ${SSH_CONNECTION:-} ]] && ! confirm "Have you opened and verified a second SSH session?"; then
      warn "rollback remains armed until a second SSH session is confirmed"
      return 1
    fi
    disarm_rollback "$backup"
    ok "gateway configuration applied"
  else
    warn "validation failed; rollback remains armed"
    return 1
  fi
}

handshake_age() {
  local latest now
  latest=$(awg show awg0 latest-handshakes 2>/dev/null | awk '$2>max {max=$2} END {print max+0}')
  [[ ${latest:-0} -gt 0 ]] || return 1
  now=$(date +%s); printf '%s' "$((now-latest))"
}

lan_gateway_is_on_link() {
  ip -4 route get "$LAN_GW" from "$LAN_IP" 2>/dev/null |
    awk -v iface="$LAN_IF" '
      NR == 1 {
        for (i = 1; i < NF; i++) {
          if ($i == "dev" && $(i+1) == iface) correct_device = 1
          if ($i == "via") next_hop = 1
        }
      }
      END { exit !(correct_device && !next_hop) }
    '
}

wait_for_socks_listener() {
  local attempt sockets
  for ((attempt=0; attempt<10; attempt++)); do
    if service_active danted &&
       sockets=$(ss -H -4 -lnt 'sport = :1080') &&
       awk -v address="$LAN_IP:1080" '$4 == address { found = 1 } END { exit !found }' <<< "$sockets"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

validate_installation() {
  load_config
  local failures=0 age route internet_route egress
  service_active awg-quick@awg0 && ok "awg0 service is active" || { warn "awg0 service is inactive"; failures=$((failures+1)); }
  age=$(handshake_age) && [[ $age -le 180 ]] && ok "AWG handshake age: ${age}s" || { warn "AWG handshake is missing or stale"; failures=$((failures+1)); }
  route=$(ip -4 route get "$AWG_ENDPOINT_IP" 2>/dev/null || true)
  [[ $route == *"via $LAN_GW"* && $route == *"dev $LAN_IF"* ]] && ok "endpoint route is protected" || { warn "incorrect endpoint route: $route"; failures=$((failures+1)); }
  lan_gateway_is_on_link && ok "LAN gateway is on-link via $LAN_IF" || { warn "LAN gateway $LAN_GW has no direct route via $LAN_IF"; failures=$((failures+1)); }
  internet_route=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
  [[ $internet_route == *"dev awg0"* ]] && ok "server Internet route uses awg0" || { warn "server Internet route does not use awg0: $internet_route"; failures=$((failures+1)); }
  [[ $(cat /proc/sys/net/ipv4/ip_forward) == 1 ]] && ok "IPv4 forwarding is enabled" || { warn "IPv4 forwarding is disabled"; failures=$((failures+1)); }
  nft list table inet awgproxy_filter >/dev/null 2>&1 && nft list table ip awgproxy_nat >/dev/null 2>&1 && ok "nftables policy is loaded" || { warn "nftables policy missing"; failures=$((failures+1)); }
  if [[ -n $AWG_EXPECTED_EGRESS ]]; then
    egress=$(curl --interface awg0 --max-time 10 -fsS https://api.ipify.org 2>/dev/null || true)
    [[ $egress == "$AWG_EXPECTED_EGRESS" ]] && ok "VPN egress matches $AWG_EXPECTED_EGRESS" || { warn "unexpected VPN egress: ${egress:-unavailable}"; failures=$((failures+1)); }
  fi
  if (( ENABLE_DNS )); then
    if service_active unbound && ss -lnut | grep -qE "${LAN_IP//./\\.}:53[[:space:]]"; then ok "DNS is listening on the LAN address"; else warn "DNS validation failed"; failures=$((failures+1)); fi
  fi
  if (( ENABLE_SOCKS )); then
    if wait_for_socks_listener; then
      ok "SOCKS is listening on $LAN_IP:1080"
    else
      warn "Dante is $(systemctl is-active danted || true), or has no listener on $LAN_IP:1080. See journalctl -u danted."
      failures=$((failures+1))
    fi
  fi
  (( failures == 0 ))
}

show_status() {
  load_config
  printf 'AWG Proxy status\n\n'
  systemctl --no-pager --full status awg-quick@awg0 awgproxy-routes awgproxy-firewall 2>/dev/null || true
  (( ENABLE_DNS )) && systemctl --no-pager --full status unbound 2>/dev/null || true
  (( ENABLE_SOCKS )) && systemctl --no-pager --full status danted 2>/dev/null || true
  printf '\nTunnel:\n'; awg show awg0 2>/dev/null || true
  printf '\nManaged routes:\n'; ip -4 route show proto 186 || true
  printf '\nSockets:\n'; ss -lntup | grep -E "(${LAN_IP//./\\.}:(53|1080)|Local Address)" || true
}

show_stats() {
  load_config
  printf '%-28s %s\n' 'Uptime:' "$(uptime -p)"
  local age; age=$(handshake_age 2>/dev/null) && printf '%-28s %s seconds\n' 'AWG handshake age:' "$age" || printf '%-28s %s\n' 'AWG handshake age:' 'none'
  printf '\nAWG transfer counters:\n'; awg show awg0 transfer 2>/dev/null || true
  printf '\nFirewall/NAT counters:\n'; nft list table inet awgproxy_filter 2>/dev/null || true; nft list table ip awgproxy_nat 2>/dev/null || true
}

collect_report() {
  require_root; load_config
  local report_dir="$STATE_DIR/reports" report
  install -d -m 0700 "$report_dir"
  report="$report_dir/report-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    printf 'AWG Proxy redacted report\nGenerated: %s\n\n' "$(date -u --iso-8601=seconds)"
    print_config_redacted
    printf '\nService state:\n'
    systemctl is-active awg-quick@awg0 awgproxy-routes awgproxy-firewall unbound danted 2>&1 || true
    printf '\nAWG state (private key hidden by awg):\n'; awg show awg0 2>&1 || true
    printf '\nIP rules:\n'; ip rule 2>&1 || true
    printf '\nRoutes:\n'; ip -4 route show table all 2>&1 || true
    printf '\nListeners:\n'; ss -lntup 2>&1 || true
    printf '\nAWG Proxy firewall counters:\n'; nft list table inet awgproxy_filter 2>&1 || true; nft list table ip awgproxy_nat 2>&1 || true
  } > "$report"
  chmod 0600 "$report"
  ok "redacted report saved: $report"
}

restart_services() {
  require_root; load_config
  systemctl restart awgproxy-routes awgproxy-firewall awg-quick@awg0
  (( ENABLE_DNS )) && systemctl restart unbound
  (( ENABLE_SOCKS )) && systemctl restart danted
  validate_installation
}

print_config_redacted() {
  load_config
  printf 'LAN_IF=%s\nLAN_IP=%s\nLAN_PREFIX=%s\nLAN_GW=%s\n' "$LAN_IF" "$LAN_IP" "$LAN_PREFIX" "$LAN_GW"
  printf 'AWG_ENDPOINT=%s\nAWG_MTU=%s\nTCP_MSS=%s\n' "$AWG_ENDPOINT_RAW" "$AWG_MTU" "$TCP_MSS"
  printf 'PRIVATE_ROUTES=%s\nVPN_CLIENT_NETWORKS=%s\nSERVICE_CLIENT_NETWORKS=%s\n' "$PRIVATE_ROUTES" "$VPN_CLIENT_NETWORKS" "$SERVICE_CLIENT_NETWORKS"
  printf 'DNS=%s SOCKS=%s\n' "$ENABLE_DNS" "$ENABLE_SOCKS"
  printf 'Tunnel secrets: [REDACTED]\n'
}
