#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=${BASH_SOURCE[0]}
while [[ -L $SCRIPT_PATH ]]; do
  SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
  SCRIPT_PATH=$(readlink -- "$SCRIPT_PATH")
  [[ $SCRIPT_PATH == /* ]] || SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
for module in common detect config render actions; do
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/lib/$module.sh"
done

VERSION=$(cat "$SCRIPT_DIR/version" 2>/dev/null || printf 'dev')

usage() {
  cat <<EOF
AWG Home $VERSION — AmneziaWG gateway manager

Usage: awghome [command]
  menu          interactive management menu (default)
  install       initial setup or full reconfiguration
  config        show redacted effective configuration
  change        change gateway settings
  status        services, tunnel, routes and listeners
  check         run readiness and safety checks
  stats         tunnel and firewall counters
  report        save a redacted support/statistics report
  diagnose      collect read-only diagnostics
  restart       restart managed services
  backup        create a configuration/routing backup
  reboot        safely request a server reboot
  version       print version
EOF
}

initial_install() {
  require_root
  if [[ -e $AWGHOME_CONFIG ]]; then
    change_configuration
    return
  fi
  configure_wizard
  install_packages
  apply_configuration
}

change_configuration() {
  require_root
  local backup
  backup=$(create_backup)
  info "pre-change backup: $backup"
  configure_wizard
  apply_configuration "$backup"
}

safe_reboot() {
  require_root
  validate_installation || die "readiness checks failed; reboot is blocked"
  confirm "Do you have working console or out-of-band access?" || die "reboot cancelled"
  confirm "Reboot the server now?" || die "reboot cancelled"
  systemctl reboot
}

menu() {
  while true; do
    clear 2>/dev/null || true
    printf 'AWG Home %s\n\n' "$VERSION"
    printf '  1) Status\n  2) Run checks\n  3) Statistics\n  4) Show configuration\n'
    printf '  5) Change configuration\n  6) Restart services\n  7) Diagnostics\n  8) Create backup\n'
    printf '  9) Save support report\n 10) Reboot server\n  0) Exit\n\n'
    read -r -p 'Select: ' choice
    case $choice in
      1) show_status; pause ;;
      2) validate_installation; pause ;;
      3) show_stats; pause ;;
      4) print_config_redacted; pause ;;
      5) change_configuration; pause ;;
      6) restart_services; pause ;;
      7) show_readonly_diagnostics; pause ;;
      8) printf 'Backup: %s\n' "$(create_backup)"; pause ;;
      9) collect_report; pause ;;
      10) safe_reboot; return ;;
      0) return ;;
      *) warn "unknown choice"; pause ;;
    esac
  done
}

case ${1:-menu} in
  menu) menu ;;
  install) initial_install ;;
  config) print_config_redacted ;;
  change) change_configuration ;;
  status) show_status ;;
  check) validate_installation ;;
  stats) show_stats ;;
  report) collect_report ;;
  diagnose) show_readonly_diagnostics ;;
  restart) restart_services ;;
  backup) require_root; create_backup; printf '\n' ;;
  reboot) safe_reboot ;;
  version|--version|-v) printf '%s\n' "$VERSION" ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
