#!/usr/bin/env bash

readonly GEOIP_ROUTE_PROTO=242
readonly GEOIP_ROUTE_STATE=/run/awgproxy-geoip.routes
readonly GEOIP_TUNNEL_RULE_PRIORITY=10500
readonly GEOIP_TUNNEL_RULE_STATE=/run/awgproxy-geoip-tunnel.rules

normalize_geoip_countries() {
  local countries=${1//[[:space:]]/}
  countries=${countries^^}
  if [[ -z $countries || $countries == '-' ]]; then return 0; fi
  [[ $countries =~ ^[A-Z]{2}(,[A-Z]{2})*$ ]] || return 1
  tr ',' '\n' <<< "$countries" | LC_ALL=C sort -u | paste -sd, -
}

geoip_download() (
  set -Eeuo pipefail
  local work country hash
  local -a countries zones=()
  [[ -n $GEOIP_COUNTRIES ]] || return 0
  have python3 || die "python3 is required for GeoIP routing"
  IFS=, read -r -a countries <<< "${GEOIP_COUNTRIES,,}"
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  for country in "${countries[@]}"; do
    [[ $country =~ ^[a-z]{2}$ ]] || die "invalid GeoIP country code: $country"
    if (( ${#zones[@]} )); then sleep 1; fi
    info "Downloading IPv4 ranges for ${country^^} from IPdeny" >&2
    curl -q -4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 30 --max-filesize 2097152 \
      "https://www.ipdeny.com/ipblocks/data/aggregated/$country-aggregated.zone" -o "$work/$country.zone" ||
      return 1
    zones+=("$work/$country.zone")
  done

  python3 - "${zones[@]}" > "$work/prefixes" <<'PY' || return 1
import ipaddress
import sys
from pathlib import Path

excluded = tuple(map(ipaddress.IPv4Network, (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "198.18.0.0/15",
    "224.0.0.0/4", "240.0.0.0/4",
)))
networks = set()
for name in sys.argv[1:]:
    found = False
    for line in Path(name).read_text(encoding="ascii").splitlines():
        if not line.strip():
            continue
        network = ipaddress.IPv4Network(line.strip())
        if not network.is_global or any(network.overlaps(block) for block in excluded):
            raise SystemExit(f"Non-public IPv4 range in {Path(name).name}: {network}")
        networks.add(network)
        found = True
        if len(networks) > 150_000:
            raise SystemExit("Too many GeoIP prefixes; select fewer countries")
    if not found:
        raise SystemExit(f"Empty GeoIP country data: {Path(name).name}")
for network in ipaddress.collapse_addresses(networks):
    print(network)
PY
  hash=$(sha256sum "$work/prefixes")
  hash=${hash%% *}
  install -d -m 0700 "$STATE_DIR/geoip"
  atomic_install "$work/prefixes" "$STATE_DIR/geoip/$hash.cidr" 0600
  printf '%s' "$hash"
)

geoip_cache() {
  [[ -n ${GEOIP_COUNTRIES:-} ]] || return 1
  [[ ${GEOIP_DATA:-} =~ ^[0-9a-f]{64}$ ]] || die "invalid GeoIP cache identifier"
  local file="$STATE_DIR/geoip/$GEOIP_DATA.cidr" hash
  [[ -s $file ]] || die "GeoIP cache is missing; refresh it in the GeoIP menu"
  hash=$(sha256sum "$file") || return 1
  [[ ${hash%% *} == "$GEOIP_DATA" ]] || die "GeoIP cache checksum does not match"
  printf '%s' "$file"
}

geoip_routes_down() {
  if [[ -f $GEOIP_ROUTE_STATE ]]; then
    ip -4 route flush table main proto "$GEOIP_ROUTE_PROTO"
    rm -f -- "$GEOIP_ROUTE_STATE"
  fi
}

geoip_routes_up() {
  local cache existing
  geoip_routes_down
  [[ -n ${GEOIP_COUNTRIES:-} ]] || return 0
  cache=$(geoip_cache) || return 1
  existing=$(ip -4 route show table main proto "$GEOIP_ROUTE_PROTO")
  [[ -z $existing ]] || die "route protocol $GEOIP_ROUTE_PROTO is already in use"
  touch "$GEOIP_ROUTE_STATE"
  if ! awk -v gw="$LAN_GW" -v iface="$LAN_IF" -v proto="$GEOIP_ROUTE_PROTO" '
      { print "route add " $1 " via " gw " dev " iface " table main proto " proto " metric 24500" }
    ' "$cache" | ip -4 -batch -; then
    geoip_routes_down
    return 1
  fi
}

geoip_tunnel_addresses() {
  ip -o -4 addr show dev awg0 scope global |
    awk '{ split($4, address, "/"); print address[1] }'
}

geoip_tunnel_policy_down() {
  [[ -f $GEOIP_TUNNEL_RULE_STATE ]] || return 0
  local address table
  while read -r address table; do
    ip -4 rule del priority "$GEOIP_TUNNEL_RULE_PRIORITY" iif lo from "$address/32" table "$table" ||
      return 1
  done < "$GEOIP_TUNNEL_RULE_STATE"
  rm -f -- "$GEOIP_TUNNEL_RULE_STATE"
}

geoip_tunnel_policy_up() {
  geoip_tunnel_policy_down || return 1
  [[ -n ${GEOIP_COUNTRIES:-} && ${ENABLE_SOCKS:-0} == 1 &&
     ${SOCKS_ROUTING_MODE:-tunnel} == tunnel ]] || return 0
  local table addresses address existing
  table=$(ip -4 -N -o route show table all default dev awg0 | awk '
    $1 == "default" {
      id = 254
      for (i = 2; i < NF; i++) if ($i == "table") id = $(i + 1)
      print id
    }
  ' | sort -u) || return 1
  [[ $table =~ ^[0-9]+$ && $table != 254 ]] ||
    die "cannot identify a separate IPv4 routing table for awg0"
  addresses=$(geoip_tunnel_addresses) || return 1
  [[ -n $addresses ]] || die "awg0 has no IPv4 address for SOCKS5"
  existing=$(ip -4 rule show pref "$GEOIP_TUNNEL_RULE_PRIORITY") || return 1
  [[ -z $existing ]] || die "routing rule priority $GEOIP_TUNNEL_RULE_PRIORITY is already in use"

  (umask 077; : > "$GEOIP_TUNNEL_RULE_STATE") || return 1
  while IFS= read -r address; do
    if ! ip -4 rule add priority "$GEOIP_TUNNEL_RULE_PRIORITY" iif lo from "$address/32" table "$table"; then
      geoip_tunnel_policy_down
      return 1
    fi
    printf '%s %s\n' "$address" "$table" >> "$GEOIP_TUNNEL_RULE_STATE"
  done <<< "$addresses"
}

geoip_routes_are_active() {
  local cache ip route installed address addresses
  cache=$(geoip_cache) || return 1
  installed=$(ip -4 route show table main proto "$GEOIP_ROUTE_PROTO") || return 1
  [[ $(wc -l <<< "$installed") -eq $(wc -l < "$cache") && -n $installed ]] || return 1
  IFS=/ read -r ip _ < "$cache" || return 1
  route=$(ip -4 route get "$ip" 2>/dev/null) || return 1
  [[ " $route " == *" via $LAN_GW dev $LAN_IF "* ]] || return 1
  if (( ENABLE_SOCKS )) && [[ ${SOCKS_ROUTING_MODE:-tunnel} == tunnel ]]; then
    addresses=$(geoip_tunnel_addresses) || return 1
    [[ -n $addresses ]] || return 1
    while IFS= read -r address; do
      route=$(ip -4 route get "$ip" from "$address" 2>/dev/null) || return 1
      [[ " $route " == *" dev awg0 "* ]] || return 1
    done <<< "$addresses"
  fi
  nft list set inet awgproxy_filter geoip_lan >/dev/null 2>&1 &&
    nft list set ip awgproxy_nat geoip_lan >/dev/null 2>&1
}

tunnel_default_is_available() {
  local destination route matched
  for destination in 1.1.1.1 8.8.8.8 9.9.9.9 185.228.168.9 101.101.101.101; do
    route=$(ip -4 route get "$destination" 2>/dev/null) || return 1
    if [[ " $route " == *" dev awg0 "* ]]; then return 0; fi
    [[ -n ${GEOIP_COUNTRIES:-} ]] || return 1
    matched=$(ip -4 route get fibmatch "$destination" 2>/dev/null) || return 1
    [[ " $matched " == *" proto $GEOIP_ROUTE_PROTO "* ]] || return 1
  done
  # All probe addresses were explicitly selected for LAN routing.
  route=$(ip -4 route show table all default dev awg0) || return 1
  [[ -n $route ]]
}
