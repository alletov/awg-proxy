#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=${BASH_SOURCE[0]}
while [[ -L $SCRIPT_PATH ]]; do
  SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
  SCRIPT_PATH=$(readlink -- "$SCRIPT_PATH")
  [[ $SCRIPT_PATH == /* ]] || SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
for module in common detect geoip config render actions update; do
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/lib/$module.sh"
done

VERSION=$(cat "$SCRIPT_DIR/version" 2>/dev/null || printf 'dev')

usage() {
  cat <<EOF
AWG Proxy $VERSION — AmneziaWG gateway manager

Usage: awgproxy [command]
  menu          interactive management menu (default)
  install       initial setup or open configuration menu
  config        show redacted effective configuration
  change [lan|awg|networks|dns|socks|geoip]
                open configuration menu or edit one section
  status        services, tunnel, routes and listeners
  check         run readiness and safety checks
  stats         tunnel and firewall counters
  report        save a redacted support/statistics report
  diagnose      collect read-only diagnostics
  restart       restart managed services
  backup        create a configuration/routing backup
  update        update installed scripts from GitHub
  reboot        safely request a server reboot
  version       print version
EOF
}

initial_install() {
  require_root
  if [[ -e $AWGPROXY_CONFIG ]]; then
    change_configuration
    return
  fi
  configure_wizard
  save_nonsecret_config
  prepare_awg_config "$AWG_SOURCE_CONFIG"
  install_packages
  apply_configuration
}

show_configuration_summary() {
  if [[ ! -r $AWGPROXY_CONFIG ]]; then
    printf 'Текущая конфигурация: не задана\n'
    return
  fi

  load_config saved
  local address=$LAN_IP mode='вручную' dns='выкл.' socks='выкл.'
  if [[ $LAN_ADDRESS_MODE == auto ]]; then
    mode='авто'
    address=$(current_lan_ipv4 "$LAN_IF") || address='IPv4 недоступен'
  fi
  if (( ENABLE_DNS )); then dns='вкл.'; fi
  if (( ENABLE_SOCKS )); then socks=$(socks_routing_label); fi

  printf 'LAN:       %s · %s (%s) · подсеть %s · шлюз %s\n' \
    "$LAN_IF" "$address" "$mode" "$LAN_PREFIX" "$LAN_GW"
  printf 'AmneziaWG: %s · MTU %s · MSS %s\n' "$AWG_ENDPOINT_RAW" "$AWG_MTU" "$TCP_MSS"
  printf 'Доступ к VPN: %s\n' "$VPN_CLIENT_NETWORKS"
  printf 'Доступ к DNS и SOCKS5: %s\n' "$SERVICE_CLIENT_NETWORKS"
  printf 'Частные маршруты: %s\n' "$PRIVATE_ROUTES"
  printf 'GeoIP через LAN: %s\n' "${GEOIP_COUNTRIES:-выкл.}"
  printf 'DNS: %s · SOCKS5: %s\n' "$dns" "$socks"
}

change_configuration() {
  require_root
  local choice section
  while true; do
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    printf '\nНастройки AWG Proxy\n\n'
    show_configuration_summary
    printf '\n  1) Настройки LAN\n  2) Настройки AmneziaWG\n  3) Сети доступа и маршруты\n'
    printf '  4) Настройки DNS\n  5) Настройки SOCKS5\n  6) GeoIP через LAN\n  0) Назад\n\n'
    read -r -p 'Выбор [0]: ' choice || return 0
    case ${choice:-0} in
      1) section=lan ;;
      2) section=awg ;;
      3) section=networks ;;
      4) section=dns ;;
      5) section=socks ;;
      6) section=geoip ;;
      0) return 0 ;;
      *) warn "unknown choice"; pause; continue ;;
    esac
    "$BASH" "$SCRIPT_DIR/awgproxy.sh" change "$section" || true
    pause
  done
}

change_configuration_section() {
  require_root
  local section=$1 backup
  case $section in
    lan|awg|networks|dns|socks|services|geoip) ;;
    *) die "unknown configuration section: $section" ;;
  esac
  load_config saved
  if ! configure_wizard "$section"; then
    info "configuration unchanged"
    return 0
  fi
  if [[ $section == geoip ]]; then GEOIP_DATA=$(geoip_download); fi
  backup=$(create_backup)
  info "pre-change backup: $backup"
  case $section in
    geoip|dns|socks|services)
      render_rollback_script
      arm_rollback "$backup" "$section"
      ;;
  esac
  save_nonsecret_config
  if [[ $section == awg ]]; then prepare_awg_config "$AWG_SOURCE_CONFIG"; fi
  apply_configuration "$backup" "$section"
}

safe_reboot() {
  require_root
  validate_installation || die "readiness checks failed; reboot is blocked"
  confirm "Do you have working console or out-of-band access?" || die "reboot cancelled"
  confirm "Reboot the server now?" || die "reboot cancelled"
  systemctl reboot
}

backup_and_update_menu() {
  require_root
  local choice
  while true; do
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    printf '\nРезервные копии и обновление\n\n'
    printf '  1) Создать резервную копию\n  2) Обновить с GitHub\n  0) Назад\n\n'
    read -r -p 'Выбор [0]: ' choice || return 0
    case ${choice:-0} in
      1) "$BASH" "$SCRIPT_DIR/awgproxy.sh" backup || true ;;
      2)
        if "$BASH" "$SCRIPT_DIR/awgproxy.sh" update; then
          pause
          exec "$BASH" "$SCRIPT_DIR/awgproxy.sh" menu
        fi
        ;;
      0) return 0 ;;
      *) warn "unknown choice" ;;
    esac
    pause
  done
}

menu() {
  while true; do
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    if [[ -r $AWGPROXY_CONFIG ]]; then
      show_status
    else
      printf 'AWG Proxy %s\n\n' "$VERSION"
      if (( EUID == 0 )); then
        printf 'Статус:     НЕ НАСТРОЕН\n'
      else
        printf 'Статус:     для просмотра запустите sudo awgproxy\n'
      fi
    fi
    printf '\n  1) Run checks\n  2) Statistics\n  3) Show configuration\n'
    printf '  4) Change configuration\n  5) Restart services\n  6) Diagnostics\n  7) Update and Backup\n'
    printf '  8) Save support report\n  9) Reboot server\n  0) Exit\n\n'
    read -r -p 'Select [0]: ' choice || return 0
    case ${choice:-0} in
      1) validate_installation; pause ;;
      2) show_stats; pause ;;
      3) print_config_redacted; pause ;;
      4) change_configuration ;;
      5) restart_services; pause ;;
      6) show_readonly_diagnostics; pause ;;
      7) backup_and_update_menu ;;
      8) collect_report; pause ;;
      9) safe_reboot; return ;;
      0) return ;;
      *) warn "unknown choice"; pause ;;
    esac
  done
}

case ${1:-menu} in
  menu) menu ;;
  install) initial_install ;;
  config) print_config_redacted ;;
  change)
    if [[ -n ${2:-} ]]; then change_configuration_section "$2"; else change_configuration; fi
    ;;
  status) show_status ;;
  check) validate_installation ;;
  stats) show_stats ;;
  report) collect_report ;;
  diagnose) show_readonly_diagnostics ;;
  restart) restart_services ;;
  backup) require_root; backup=$(create_backup); printf 'Backup: %s\n' "$backup" ;;
  update) update_project ;;
  reboot) safe_reboot ;;
  version|--version|-v) printf '%s\n' "$VERSION" ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
