#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${AWGHOME_REPO:-OWNER/awg-proxy}"
BRANCH="${AWGHOME_BRANCH:-main}"
INSTALL_DIR="/opt/awghome"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || die "cannot detect the operating system"
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "currently only Ubuntu is supported"

tmp_dir="$(mktemp -d /tmp/awghome-install.XXXXXX)"
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/awghome.sh" && -d "$script_dir/lib" ]]; then
  source_dir="$script_dir"
else
  [[ $REPO != OWNER/* ]] || die "set AWGHOME_REPO=github-user/repository before publishing"
  command -v curl >/dev/null || { apt-get update; apt-get install -y curl ca-certificates; }
  archive="$tmp_dir/source.tar.gz"
  curl --fail --location --silent --show-error \
    "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"
  source_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n $source_dir && -f "$source_dir/awghome.sh" ]] || die "invalid repository archive"
fi

install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/lib"
install -m 0755 "$source_dir/awghome.sh" "$INSTALL_DIR/awghome.sh"
install -m 0644 "$source_dir"/lib/*.sh "$INSTALL_DIR/lib/"
install -m 0644 "$source_dir/version" "$INSTALL_DIR/version"
ln -sfn "$INSTALL_DIR/awghome.sh" /usr/local/sbin/awghome

printf 'AWG Home installed. Starting the setup wizard...\n'
exec /usr/local/sbin/awghome install
