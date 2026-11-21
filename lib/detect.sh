#!/usr/bin/env bash

detect_network() {
  local route
  route=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1) || return 1
  DETECT_LAN_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<< "$route")
  DETECT_LAN_IP=$(awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' <<< "$route")
  DETECT_LAN_GW=$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<< "$route")
  [[ -n $DETECT_LAN_IF && -n $DETECT_LAN_IP && -n $DETECT_LAN_GW ]] || return 1
  DETECT_LAN_PREFIX=$(ip -4 route show dev "$DETECT_LAN_IF" proto kernel scope link | awk 'NR==1 {print $1}')
  [[ -n $DETECT_LAN_PREFIX ]] || return 1
}

show_readonly_diagnostics() {
  printf '\n--- addresses ---\n'; ip -br addr || true
  printf '\n--- main routes ---\n'; ip -4 route show table main || true
  printf '\n--- rules ---\n'; ip rule || true
  printf '\n--- listeners ---\n'; ss -lntup || true
  printf '\n--- relevant services ---\n'
  systemctl --no-pager --full status systemd-networkd nftables awg-quick@awg0 danted unbound 2>/dev/null || true
}

endpoint_from_config() {
  awk -F= '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$1"
}

resolve_endpoint_ipv4() {
  local endpoint=$1 host
  host=${endpoint%:*}; host=${host#[}; host=${host%]}
  if is_ipv4 "$host"; then printf '%s' "$host"; return; fi
  getent ahostsv4 "$host" | awk 'NR==1 {print $1}'
}
