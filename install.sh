#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${AWGPROXY_REPO:-alletov/awg-proxy}"
BRANCH="${AWGPROXY_BRANCH:-main}"
INSTALL_DIR="/opt/awgproxy"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || die "cannot detect the operating system"
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "currently only Ubuntu is supported"

tmp_dir="$(mktemp -d /tmp/awgproxy-install.XXXXXX)"
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/awgproxy.sh" && -d "$script_dir/lib" ]]; then
  source_dir="$script_dir"
else
  command -v curl >/dev/null || { apt-get update; apt-get install -y curl ca-certificates; }
  archive="$tmp_dir/source.tar.gz"
  curl --fail --location --silent --show-error \
    "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"
  source_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n $source_dir && -f "$source_dir/awgproxy.sh" ]] || die "invalid repository archive"
fi

install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/lib"
install -m 0755 "$source_dir/awgproxy.sh" "$INSTALL_DIR/awgproxy.sh"
install -m 0644 "$source_dir"/lib/*.sh "$INSTALL_DIR/lib/"
install -m 0644 "$source_dir/version" "$INSTALL_DIR/version"
ln -sfn "$INSTALL_DIR/awgproxy.sh" /usr/local/sbin/awgproxy

printf 'AWG Proxy installed. Starting the setup wizard...\n'
exec /usr/local/sbin/awgproxy install
