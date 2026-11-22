#!/usr/bin/env bash

configure_wizard() {
  require_root
  local section=${1:-all}
  if [[ $section == all ]]; then
    detect_network || die "failed to detect the current default route"
    LAN_IF=$DETECT_LAN_IF
    LAN_IP=$DETECT_LAN_IP
    LAN_PREFIX=$DETECT_LAN_PREFIX
    LAN_GW=$DETECT_LAN_GW
    LAN_ADDRESS_MODE=auto
  fi

  printf '\nAWG Proxy setup\n'
  if [[ $section == all || $section == lan ]]; then
    prompt_lan_settings
  elif [[ ${LAN_ADDRESS_MODE:-static} == auto ]]; then
    LAN_IP=$(current_lan_ipv4 "$LAN_IF") || die "cannot determine a unique primary IPv4 on $LAN_IF"
  fi
  if [[ $section == all || $section == networks ]]; then prompt_network_settings; fi
  if [[ $section == all || $section == awg ]]; then prompt_awg_settings "$section"; fi
  if [[ $section == all || $section == services ]]; then prompt_service_settings; fi
  if [[ $section == geoip ]]; then
    local countries
    countries=$(prompt_default "Страны через LAN (например RU,KZ; '-' выключает GeoIP)" "${GEOIP_COUNTRIES:-}") ||
      die "input ended"
    GEOIP_COUNTRIES=$(normalize_geoip_countries "$countries") || die "invalid GeoIP country codes"
  fi

  printf '\nPlanned configuration:\n'
  if [[ $section == all || $section == lan ]]; then
    printf '  LAN: %s %s (%s), gateway %s, IPv4 mode %s\n' \
      "$LAN_IF" "$LAN_IP" "$LAN_PREFIX" "$LAN_GW" "$LAN_ADDRESS_MODE"
  fi
  if [[ $section == all || $section == awg ]]; then
    printf '  AWG: endpoint %s, MTU %s, MSS %s\n' "$AWG_ENDPOINT_IP" "$AWG_MTU" "$TCP_MSS"
  fi
  if [[ $section == all || $section == networks ]]; then
    printf '  VPN clients:     %s\n  DNS/SOCKS clients: %s\n  Private routes:  %s\n' \
      "$VPN_CLIENT_NETWORKS" "$SERVICE_CLIENT_NETWORKS" "$PRIVATE_ROUTES"
  fi
  if [[ $section == all || $section == services ]]; then
    printf '  Services on %s: DNS=%s, SOCKS=%s\n' "$LAN_IP" "$ENABLE_DNS" "$ENABLE_SOCKS"
  fi
  if [[ $section == geoip ]]; then
    printf '  GeoIP via %s: %s\n' "$LAN_GW" "${GEOIP_COUNTRIES:-disabled}"
  fi
  if [[ $section != services ]]; then
    warn "Changing routing or firewall can interrupt SSH. Console or out-of-band access is strongly recommended."
  fi
  printf '  Rollback: automatic in 5 minutes until validation succeeds\n\n'
  confirm "Apply this configuration?"
}

prompt_lan_settings() {
  local previous_if=$LAN_IF address_default=$LAN_IP auto_default=n
  if [[ ${LAN_ADDRESS_MODE:-static} == auto ]]; then auto_default=y; fi
  LAN_IF=$(prompt_default "LAN interface" "$LAN_IF") || die "input ended"
  [[ -d /sys/class/net/$LAN_IF ]] || die "interface does not exist: $LAN_IF"
  if [[ $LAN_IF != "$previous_if" || -z $address_default ]]; then
    address_default=$(current_lan_ipv4 "$LAN_IF") || address_default=''
  fi
  LAN_ADDRESS_MODE=static
  if confirm "Detect LAN IPv4 automatically at startup?" "$auto_default"; then
    LAN_ADDRESS_MODE=auto
    LAN_IP=$(current_lan_ipv4 "$LAN_IF") || die "cannot determine a unique primary IPv4 on $LAN_IF"
  else
    LAN_IP=$(prompt_default "Server LAN IPv4" "$address_default") || die "input ended"
  fi
  LAN_PREFIX=$(prompt_default "Directly connected LAN prefix" "$LAN_PREFIX") || die "input ended"
  LAN_GW=$(prompt_default "LAN gateway" "$LAN_GW") || die "input ended"

  is_ipv4 "$LAN_IP" || die "invalid LAN IP"
  is_ipv4 "$LAN_GW" || die "invalid LAN gateway"
  is_cidr "$LAN_PREFIX" || die "invalid LAN prefix"
  ip -4 route get "$LAN_GW" oif "$LAN_IF" >/dev/null || die "LAN gateway is not reachable through $LAN_IF"
}

prompt_network_settings() {
  local private_defaults=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
  VPN_CLIENT_NETWORKS=$(prompt_default "Networks allowed through VPN (comma-separated)" "${VPN_CLIENT_NETWORKS:-$private_defaults}") || die "input ended"
  SERVICE_CLIENT_NETWORKS=$(prompt_default "Networks allowed to DNS/SOCKS (comma-separated)" "${SERVICE_CLIENT_NETWORKS:-$VPN_CLIENT_NETWORKS}") || die "input ended"
  PRIVATE_ROUTES=$(prompt_default "Private destinations kept on LAN gateway" "${PRIVATE_ROUTES:-$private_defaults}") || die "input ended"
  validate_cidr_list "$VPN_CLIENT_NETWORKS" || die "invalid VPN client networks"
  validate_cidr_list "$SERVICE_CLIENT_NETWORKS" || die "invalid service client networks"
  validate_cidr_list "$PRIVATE_ROUTES" || die "invalid private routes"
}

prompt_awg_settings() {
  local source_default=$AWG_CONFIG
  if [[ $1 == all ]]; then source_default=/root/awg0.conf; fi
  AWG_MTU=$(prompt_default "AWG MTU" "${AWG_MTU:-1280}") || die "input ended"
  TCP_MSS=$(prompt_default "TCP MSS clamp" "${TCP_MSS:-1240}") || die "input ended"
  [[ $AWG_MTU =~ ^[0-9]+$ && $AWG_MTU -ge 576 && $AWG_MTU -le 9000 ]] || die "invalid MTU"
  [[ $TCP_MSS =~ ^[0-9]+$ && $TCP_MSS -ge 536 && $TCP_MSS -lt $AWG_MTU ]] || die "invalid TCP MSS"

  AWG_SOURCE_CONFIG=$(prompt_default "Path to the existing AmneziaWG client config" "$source_default") || die "input ended"
  [[ -r $AWG_SOURCE_CONFIG ]] || die "cannot read AWG config: $AWG_SOURCE_CONFIG"
  grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "$AWG_SOURCE_CONFIG" || die "AWG config has no PrivateKey"
  grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0\.0\.0\.0/0([[:space:],#]|$)' "$AWG_SOURCE_CONFIG" ||
    die "full gateway mode requires 0.0.0.0/0 in AllowedIPs"
  AWG_ENDPOINT_RAW=$(endpoint_from_config "$AWG_SOURCE_CONFIG")
  [[ -n $AWG_ENDPOINT_RAW ]] || die "AWG config has no Endpoint"
  AWG_ENDPOINT_IP=$(resolve_endpoint_ipv4 "$AWG_ENDPOINT_RAW")
  is_ipv4 "$AWG_ENDPOINT_IP" || die "the endpoint must resolve to IPv4"

}

prompt_service_settings() {
  local dns_default=n socks_default=n
  if (( ${ENABLE_DNS:-0} )); then dns_default=y; fi
  if (( ${ENABLE_SOCKS:-0} )); then socks_default=y; fi
  ENABLE_DNS=1; ENABLE_SOCKS=1
  confirm "Enable local Unbound DNS on ${LAN_IP}:53?" "$dns_default" || ENABLE_DNS=0
  confirm "Enable Dante SOCKS5 on ${LAN_IP}:1080?" "$socks_default" || ENABLE_SOCKS=0
  if (( ENABLE_DNS )); then check_service_port 53 unbound; fi
  if (( ENABLE_SOCKS )); then check_service_port 1080 danted; fi
}

check_service_port() {
  local port=$1 process=$2 listeners
  listeners=$(ss -H -lntup "sport = :$port") || die "cannot inspect port $port"
  if awk -v ip="$LAN_IP" -v port="$port" -v process="$process" '
      ($5 == ip ":" port || $5 == "0.0.0.0:" port || $5 == "*:" port ||
       $5 == "[::]:" port) && !index($0, "(\"" process "\",") { found = 1 }
      END { exit !found }
    ' <<< "$listeners"; then
    die "port $port is already occupied on the requested address"
  fi
}

save_nonsecret_config() {
  local tmp
  install -d -m 0700 "$AWGPROXY_DIR"
  tmp=$(mktemp)
  {
    printf '# Generated by AWG Proxy. No tunnel private key is stored here.\n'
    printf 'LAN_IF=%q\nLAN_ADDRESS_MODE=%q\n' "$LAN_IF" "$LAN_ADDRESS_MODE"
    if [[ $LAN_ADDRESS_MODE == auto ]]; then
      printf 'LAN_IP=%q\n' ''
    else
      printf 'LAN_IP=%q\n' "$LAN_IP"
    fi
    printf 'LAN_PREFIX=%q\n' "$LAN_PREFIX"
    printf 'LAN_GW=%q\n' "$LAN_GW"; printf 'AWG_IF=%q\n' 'awg0'; printf 'AWG_ENDPOINT_RAW=%q\n' "$AWG_ENDPOINT_RAW"
    printf 'AWG_ENDPOINT_IP=%q\n' "$AWG_ENDPOINT_IP"
    printf 'AWG_MTU=%q\n' "$AWG_MTU"; printf 'TCP_MSS=%q\n' "$TCP_MSS"
    printf 'PRIVATE_ROUTES=%q\n' "$PRIVATE_ROUTES"; printf 'VPN_CLIENT_NETWORKS=%q\n' "$VPN_CLIENT_NETWORKS"
    printf 'SERVICE_CLIENT_NETWORKS=%q\n' "$SERVICE_CLIENT_NETWORKS"
    printf 'ENABLE_DNS=%q\n' "$ENABLE_DNS"; printf 'ENABLE_SOCKS=%q\n' "$ENABLE_SOCKS"
    printf 'GEOIP_COUNTRIES=%q\nGEOIP_DATA=%q\n' "${GEOIP_COUNTRIES:-}" "${GEOIP_DATA:-}"
  } > "$tmp"
  atomic_install "$tmp" "$AWGPROXY_CONFIG" 0600
  rm -f -- "$tmp"
}

prepare_awg_config() {
  local source=$1 tmp
  install -d -m 0700 "$AWG_CONFIG_DIR"
  tmp=$(mktemp)
  awk -v mtu="$AWG_MTU" '
    /^[[:space:]]*I[2-5][[:space:]]*=[[:space:]]*$/ {next}
    /^[[:space:]]*DNS[[:space:]]*=/ {next}
    /^[[:space:]]*MTU[[:space:]]*=/ {if (!mtu_done) {print "MTU = " mtu; mtu_done=1}; next}
    /^\[Peer\]/ && !mtu_done {print "MTU = " mtu; mtu_done=1}
    {print}
    END {if (!mtu_done) print "MTU = " mtu}
  ' "$source" > "$tmp"
  atomic_install "$tmp" "$AWG_CONFIG" 0600
  rm -f -- "$tmp"
}
