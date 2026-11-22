#!/usr/bin/env bash

render_runtime_files() {
  load_config
  install -d -m 0755 /usr/local/lib/awgproxy /etc/systemd/system
  render_routes_script
  render_firewall
  render_rollback_script
  render_lan_bindings_script
  render_systemd_units
  (( ENABLE_DNS )) && render_unbound
  (( ENABLE_SOCKS )) && render_dante
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-awgproxy-forwarding.conf
}

render_lan_bindings_script() {
  cat > /usr/local/lib/awgproxy/lan-bindings.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/awgproxy/lib/common.sh
source /opt/awgproxy/lib/geoip.sh
source /opt/awgproxy/lib/render.sh
load_config saved
[[ ${LAN_ADDRESS_MODE:-static} == auto ]] || exit 0

for ((attempt=0; attempt<30; attempt++)); do
  if LAN_IP=$(current_lan_ipv4 "$LAN_IF"); then
    render_firewall
    if (( ENABLE_DNS )); then render_unbound; fi
    if (( ENABLE_SOCKS )); then render_dante; fi
    exit 0
  fi
  sleep 1
done
die "no unique primary IPv4 on $LAN_IF after 30 seconds"
EOF
  chmod 0755 /usr/local/lib/awgproxy/lan-bindings.sh
}

render_routes_script() {
  cat > /usr/local/lib/awgproxy/routes.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/awgproxy/lib/common.sh
source /opt/awgproxy/lib/geoip.sh
load_config saved
metric=50
route_proto=186
case "${1:-up}" in
  up)
    endpoint_host=${AWG_ENDPOINT_RAW%:*}; endpoint_host=${endpoint_host#[}; endpoint_host=${endpoint_host%]}
    if [[ $endpoint_host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      endpoint_ip=$endpoint_host
    else
      endpoint_ip=$(getent ahostsv4 "$endpoint_host" | awk 'NR==1 {print $1}')
    fi
    [[ -n ${endpoint_ip:-} ]] || { echo "Cannot resolve AWG endpoint" >&2; exit 1; }
    ip -4 route flush proto "$route_proto"
    ip -4 route replace "$endpoint_ip/32" via "$LAN_GW" dev "$LAN_IF" proto "$route_proto" metric "$metric"
    IFS=, read -r -a routes <<< "$PRIVATE_ROUTES"
    for route in "${routes[@]}"; do
      ip -4 route replace "$route" via "$LAN_GW" dev "$LAN_IF" proto "$route_proto" metric "$metric"
    done
    geoip_routes_up
    ;;
  down)
    geoip_routes_down
    ip -4 route flush proto "$route_proto"
    ;;
  *) echo "Usage: $0 {up|down}" >&2; exit 2 ;;
esac
EOF
  chmod 0755 /usr/local/lib/awgproxy/routes.sh
}

render_firewall() {
  local vpn_nft service_nft
  local geoip_set='' geoip_forward='' geoip_nat='' geoip_output='' cache prefixes
  vpn_nft=$(csv_to_nft "$VPN_CLIENT_NETWORKS")
  service_nft=$(csv_to_nft "$SERVICE_CLIENT_NETWORKS")
  if [[ -n ${GEOIP_COUNTRIES:-} ]]; then
    cache=$(geoip_cache) || return 1
    prefixes=$(paste -sd, "$cache") || return 1
    geoip_set="set geoip_lan { type ipv4_addr; flags interval; elements = { $prefixes } }"
    geoip_forward="iifname \"$LAN_IF\" oifname \"$LAN_IF\" ip daddr @geoip_lan ip saddr @vpn_clients counter accept
    iifname \"$LAN_IF\" oifname \"$LAN_IF\" ip daddr @geoip_lan counter drop"
    geoip_nat="iifname \"$LAN_IF\" oifname \"$LAN_IF\" ip daddr @geoip_lan ip saddr @vpn_clients counter masquerade"
    geoip_output="chain geoip_output {
    type filter hook output priority filter; policy accept;
    oifname \"$LAN_IF\" icmp type redirect drop
  }"
  fi
  cat > "$AWGPROXY_DIR/nftables.conf" <<EOF
table inet awgproxy_filter {
  set vpn_clients { type ipv4_addr; flags interval; elements = { $vpn_nft } }
  set service_clients { type ipv4_addr; flags interval; elements = { $service_nft } }
  $geoip_set
  $geoip_output

  chain input {
    type filter hook input priority filter; policy accept;
    ct state established,related counter accept
    iifname "$LAN_IF" ip daddr $LAN_IP ip saddr @service_clients tcp dport { 53, 1080 } counter accept
    iifname "$LAN_IF" ip daddr $LAN_IP ip saddr @service_clients udp dport 53 counter accept
    ip daddr $LAN_IP tcp dport { 53, 1080 } counter drop
    ip daddr $LAN_IP udp dport 53 counter drop
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related counter accept
    $geoip_forward
    iifname "$LAN_IF" oifname "awg0" ip saddr @vpn_clients counter accept
    iifname "$LAN_IF" oifname "awg0" counter drop
    iifname "awg0" oifname "$LAN_IF" counter drop
  }

  chain mangle_forward {
    type filter hook forward priority mangle; policy accept;
    oifname "awg0" tcp flags syn tcp option maxseg size set $TCP_MSS
    iifname "awg0" tcp flags syn tcp option maxseg size set $TCP_MSS
  }
}

table ip awgproxy_nat {
  set vpn_clients { type ipv4_addr; flags interval; elements = { $vpn_nft } }
  $geoip_set
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "awg0" ip saddr @vpn_clients counter masquerade
    $geoip_nat
  }
}
EOF

  cat > /usr/local/lib/awgproxy/firewall-apply.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
config=/etc/awgproxy/nftables.conf
batch=$(mktemp)
trap 'rm -f -- "$batch"' EXIT
{
  if nft list table inet awgproxy_filter >/dev/null 2>&1; then echo 'delete table inet awgproxy_filter'; fi
  if nft list table ip awgproxy_nat >/dev/null 2>&1; then echo 'delete table ip awgproxy_nat'; fi
  cat "$config"
} > "$batch"
if [[ ${1:-} == check ]]; then nft -c -f "$batch"; else nft -f "$batch"; fi
EOF
  chmod 0755 /usr/local/lib/awgproxy/firewall-apply.sh
}

render_unbound() {
  local acl_lines='' item
  IFS=, read -r -a networks <<< "$SERVICE_CLIENT_NETWORKS"
  for item in "${networks[@]}"; do acl_lines+="  access-control: $item allow"$'\n'; done
  cat > /etc/unbound/unbound.conf.d/awgproxy.conf <<EOF
server:
  interface: 127.0.0.1
  interface: $LAN_IP
  port: 53
  do-ip4: yes
  do-ip6: no
  hide-identity: yes
  hide-version: yes
  access-control: 127.0.0.0/8 allow
$acl_lines
EOF
}

render_dante() {
  local client_rules='' socks_rules='' item
  IFS=, read -r -a networks <<< "$SERVICE_CLIENT_NETWORKS"
  for item in "${networks[@]}"; do
    client_rules+="client pass { from: $item to: 0.0.0.0/0 }"$'\n'
    socks_rules+="socks pass { from: $item to: 0.0.0.0/0 command: connect }"$'\n'
  done
  cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: $LAN_IP port = 1080
external: awg0
clientmethod: none
socksmethod: none
user.privileged: proxy
user.notprivileged: nobody
$client_rules
$socks_rules
EOF
  {
    cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EOF
    printf 'LAN_IF=%q\nLAN_IP=%q\n' "$LAN_IF" "$LAN_IP"
    cat <<'EOF'
for ((i=0; i<60; i++)); do
  ip -4 addr show dev "$LAN_IF" | grep -Fq "inet $LAN_IP/" || { sleep 1; continue; }
  ip link show dev awg0 2>/dev/null | grep -q 'state UNKNOWN\|state UP' || { sleep 1; continue; }
  latest=$(awg show awg0 latest-handshakes 2>/dev/null | awk '$2>max {max=$2} END {print max+0}')
  now=$(date +%s)
  [[ ${latest:-0} -gt 0 && $((now-latest)) -le 180 ]] && exit 0
  sleep 1
done
echo "awg0 did not become ready within 60 seconds" >&2
exit 1
EOF
  } > /usr/local/lib/awgproxy/dante-ready.sh
  chmod 0755 /usr/local/lib/awgproxy/dante-ready.sh
}

render_rollback_script() {
  cat > /usr/local/lib/awgproxy/rollback.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
backup=${1:?backup directory required}
[[ -e "$backup/ARMED" ]] || exit 0
logger -t awgproxy "automatic network rollback started"
if [[ ${2:-all} == geoip ]]; then
  source /opt/awgproxy/lib/common.sh
  source /opt/awgproxy/lib/geoip.sh
  source /opt/awgproxy/lib/render.sh
  cp -a "$backup/awgproxy.conf" "$AWGPROXY_CONFIG"
  load_config
  geoip_routes_down
  render_firewall
  /usr/local/lib/awgproxy/firewall-apply.sh
  geoip_routes_up
  logger -t awgproxy "GeoIP rollback completed"
  exit 0
fi
systemctl stop awg-quick@awg0.service 2>/dev/null || true
if [[ -s "$backup/nftables.rules" ]]; then
  nft flush ruleset
  nft -f "$backup/nftables.rules"
fi
cp -a "$backup/awgproxy.conf" /etc/awgproxy/awgproxy.conf 2>/dev/null || true
cp -a "$backup/awg0.conf" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
/usr/local/lib/awgproxy/routes.sh down 2>/dev/null || true
/usr/local/lib/awgproxy/routes.sh up 2>/dev/null || true
logger -t awgproxy "automatic network rollback completed"
EOF
  chmod 0755 /usr/local/lib/awgproxy/rollback.sh
}

render_systemd_units() {
  cat > /etc/systemd/system/awgproxy-lan-bindings.service <<'EOF'
[Unit]
Description=AWG Proxy LAN address and service bindings
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/awgproxy/lan-bindings.sh
RemainAfterExit=yes
EOF
  cat > /etc/systemd/system/awgproxy-routes.service <<'EOF'
[Unit]
Description=AWG Proxy protected routes
Before=awg-quick@awg0.service
After=network-online.target awgproxy-firewall.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/awgproxy/routes.sh up
ExecStop=/usr/local/lib/awgproxy/routes.sh down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/awgproxy-firewall.service <<'EOF'
[Unit]
Description=AWG Proxy nftables policy
Before=awg-quick@awg0.service
Requires=awgproxy-lan-bindings.service
After=awgproxy-lan-bindings.service nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/awgproxy/firewall-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 0755 /etc/systemd/system/awg-quick@awg0.service.d
  cat > /etc/systemd/system/awg-quick@awg0.service.d/awgproxy.conf <<'EOF'
[Unit]
Requires=awgproxy-routes.service awgproxy-firewall.service
After=awgproxy-routes.service awgproxy-firewall.service systemd-networkd.service
PartOf=systemd-networkd.service
EOF
  if (( ENABLE_DNS )); then
    install -d -m 0755 /etc/systemd/system/unbound.service.d
    cat > /etc/systemd/system/unbound.service.d/awgproxy.conf <<'EOF'
[Unit]
Requires=awgproxy-firewall.service
After=awgproxy-firewall.service
EOF
  fi
  if (( ENABLE_SOCKS )); then
    install -d -m 0755 /etc/systemd/system/danted.service.d
    cat > /etc/systemd/system/danted.service.d/awgproxy.conf <<'EOF'
[Unit]
Requires=awg-quick@awg0.service
After=awg-quick@awg0.service

[Service]
ExecStartPre=/usr/local/lib/awgproxy/dante-ready.sh
EOF
  fi
}
