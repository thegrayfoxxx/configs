#!/bin/bash
# Глобальные опции sites.conf (GLOBAL_OPTS): таймауты, бинды, PROXY-пара,
# blackhole, проверки и логи. Правка с валидацией до записи.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

# g_get <ключ> <дефолт> — текущее значение из GLOBAL_OPTS.
g_get() { cfg_opt "$1" "$2"; }

# g_set <ключ> <значение> — заменить или добавить запись key=value в GLOBAL_OPTS.
g_set() {
  local key="$1" val="$2" i found=false
  for ((i = 0; i < ${#GLOBAL_OPTS[@]}; i++)); do
    if [[ "${GLOBAL_OPTS[$i]}" == "${key}="* ]]; then
      GLOBAL_OPTS[$i]="${key}=${val}"
      found=true
    fi
  done
  if [ "$found" = false ]; then
    GLOBAL_OPTS+=("${key}=${val}")
  fi
}

# g_del <ключ> — убрать запись (для опциональных ключей: tunnel и т.п.).
g_del() {
  local key="$1" kept=() g
  for g in ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"}; do
    [[ "$g" == "${key}="* ]] || kept+=("$g")
  done
  GLOBAL_OPTS=(${kept[@]+"${kept[@]}"})
}

g_save() {
  # g_save [--no-validate] — в интерактиве (без флага) спрашивает про проверку.
  local _flag="${1:-}"
  if [ -z "$_flag" ]; then
    _flag=$(ask_validate)
  elif [ "$_flag" != "--no-validate" ]; then
    die "❌ g_save: жди --no-validate"
  fi
  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут (детали выше)"
    menu_pause
    return 1
  fi
  save_sites
  log_info "✅ GLOBAL_OPTS записаны"
  if [ -z "$_flag" ]; then
    if ! generate_configs; then
      log_error "❌ Ошибка генерации конфигов"
      return 1
    fi
  # shellcheck disable=SC2086
  elif ! generate_configs $_flag; then
    log_error "❌ Ошибка генерации конфигов"
    return 1
  fi
}

edit_timeouts() {
  load_sites
  printf "\n  ${CYAN}Профиль одной строкой (Enter — править по полям):${NC}\n"
  printf "  ${GREEN}1.${NC} sites-50s (обычные сайты: 50s/50s без tunnel)\n"
  printf "  ${GREEN}2.${NC} xhttp-1h (долгие сессии: 1h/1h+tunnel)\n"
  printf "  ${GREEN}3.${NC} Вручную по полям\n"
  printf "  ${RED}0.${NC} Назад\n"
  printf "  ${CYAN}👉 Пункт:${NC} "
  local sel
  tread -r sel || return
  case "$sel" in
    1)
      g_set timeout_connect "5s"
      g_set timeout_client "50s"
      g_set timeout_server "50s"
      g_del timeout_tunnel
      g_save || return
      ;;
    2)
      g_set timeout_connect "5s"
      g_set timeout_client "1h"
      g_set timeout_server "1h"
      g_set timeout_tunnel "1h"
      g_save || return
      ;;
    3)
      local v
      v=$(ask_default "timeout connect" "$(g_get timeout_connect 5s)")
      [[ "$v" =~ ^[0-9]+(s|m|h|d)$ ]] || { log_error "❌ Жди длительность (50s/1h)"; return; }
      g_set timeout_connect "$v"
      v=$(ask_default "timeout client" "$(g_get timeout_client 50s)")
      [[ "$v" =~ ^[0-9]+(s|m|h|d)$ ]] || { log_error "❌ Жди длительность"; return; }
      g_set timeout_client "$v"
      v=$(ask_default "timeout server" "$(g_get timeout_server 50s)")
      [[ "$v" =~ ^[0-9]+(s|m|h|d)$ ]] || { log_error "❌ Жди длительность"; return; }
      g_set timeout_server "$v"
      v=$(ask_default "timeout tunnel (пусто/- = убрать)" "$(g_get timeout_tunnel "")")
      if [ "$v" = "-" ] || [ -z "$v" ]; then
        g_del timeout_tunnel
      else
        [[ "$v" =~ ^[0-9]+(s|m|h|d)$ ]] || { log_error "❌ Жди длительность"; return; }
        g_set timeout_tunnel "$v"
      fi
      g_save || return
      ;;
    0|"") return ;;
    *) log_error "❌ Неверный пункт"; return ;;
  esac
  confirm_restart
}

edit_binds() {
  load_sites
  local v
  v=$(ask_default "bind stream (SNI-вход; например, *:443 — host обязателен)" "$(g_get bind_stream "*:443")")
  [[ "$v" =~ ^[^:]+:[0-9]+$ ]] || { log_error "❌ Жди host:порт"; return; }
  validate_port "${v##*:}" "порт" || return
  g_set bind_stream "$v"
  v=$(ask_default "bind web (терминация; например, 127.0.0.1:8443 или *:443 — host обязателен)" "$(g_get bind_web "*:8443")")
  [[ "$v" =~ ^[^:]+:[0-9]+$ ]] || { log_error "❌ Жди host:порт"; return; }
  validate_port "${v##*:}" "порт" || return
  g_set bind_web "$v"
  g_save || return
  confirm_restart
}

edit_proxy() {
  load_sites
  local v
  v=$(ask_default "stream_web_proxy (слать PROXY в web: off/v1/v2)" "$(g_get stream_web_proxy off)")
  case "$v" in off|v1|v2) ;; *) log_error "❌ Жди off/v1/v2"; return ;; esac
  g_set stream_web_proxy "$v"
  v=$(ask_default "web_accept_proxy (читать PROXY на web: off/on)" "$(g_get web_accept_proxy off)")
  case "$v" in off|on) ;; *) log_error "❌ Жди off/on"; return ;; esac
  g_set web_accept_proxy "$v"
  v=$(ask_default "xray_xver (Xray шлет PROXY в web-таргет, realitySettings.xver: off/v2)" "$(g_get xray_xver off)")
  case "$v" in off|v2) ;; *) log_error "❌ Жди off/v2"; return ;; esac
  g_set xray_xver "$v"
  g_save || return
  confirm_restart
}

edit_blackhole() {
  load_sites
  local v
  v=$(ask_default "blackhole (deny/tarpit)" "$(g_get blackhole deny)")
  case "$v" in deny|tarpit) ;; *) log_error "❌ Жди deny/tarpit"; return ;; esac
  g_set blackhole "$v"
  v=$(ask_default "blackhole_deny_status (100-599, 403)" "$(g_get blackhole_deny_status 403)")
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 100 ] && [ "$v" -le 599 ] || { log_error "❌ Жди код 100-599"; return; }
  if [ "$v" = "403" ]; then
    g_del blackhole_deny_status
  else
    g_set blackhole_deny_status "$v"
  fi
  g_save || return
  confirm_restart
}

edit_checks_logs() {
  load_sites
  local v
  v=$(ask_default "backend_check (off/tcp; tcp шумит в логах Xray)" "$(g_get backend_check off)")
  case "$v" in off|tcp) ;; *) log_error "❌ Жди off/tcp"; return ;; esac
  g_set backend_check "$v"
  v=$(ask_default "stream_log_sni (off/on)" "$(g_get stream_log_sni off)")
  case "$v" in off|on) ;; *) log_error "❌ Жди off/on"; return ;; esac
  g_set stream_log_sni "$v"
  v=$(ask_default "web_capture_headers (off/on)" "$(g_get web_capture_headers off)")
  case "$v" in off|on) ;; *) log_error "❌ Жди off/on"; return ;; esac
  g_set web_capture_headers "$v"
  v=$(ask_default "forwardfor_backends (через запятую bk_*, пусто/- = убрать)" "$(g_get forwardfor_backends "")")
  if [ "$v" = "-" ] || [ -z "$v" ]; then
    g_del forwardfor_backends
  else
    g_set forwardfor_backends "$v"
  fi
  g_save || return
  confirm_restart
}

show_opts() {
  load_sites
  printf "  ${CYAN}Текущие GLOBAL_OPTS:${NC}\n"
  local g
  for g in ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"}; do
    printf "    %s\n" "$g"
  done
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "ГЛОБАЛЬНЫЕ ОПЦИИ" "⚙️"
    show_opts
    printf "\n"
    printf "  ${GREEN}1.${NC} ⏱️  Таймауты\n"
    printf "  ${GREEN}2.${NC} 🔌 Бинды (bind_stream/bind_web)\n"
    printf "  ${GREEN}3.${NC} 🔀 PROXY-пара stream→web\n"
    printf "  ${GREEN}4.${NC} 🕳️  Blackhole\n"
    printf "  ${GREEN}5.${NC} 🩺 Проверки и логи\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    local choice
    tread -r choice || exit 0
    case "$choice" in
      1) edit_timeouts; printf "\n"; menu_pause ;;
      2) edit_binds; printf "\n"; menu_pause ;;
      3) edit_proxy; printf "\n"; menu_pause ;;
      4) edit_blackhole; printf "\n"; menu_pause ;;
      5) edit_checks_logs; printf "\n"; menu_pause ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

# Неинтерактивно: --show | --set K=V [--set ...] [--no-validate] (для скриптов/тестов).
if [ "${1:-}" = "--show" ]; then
  show_opts
  exit 0
elif [ "${1:-}" = "--set" ]; then
  shift
  load_sites
  g_novalidate=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) shift; continue ;;
      --no-validate) g_novalidate="--no-validate"; shift; continue ;;
      *=*) g_set "${1%%=*}" "${1#*=}"; shift ;;
      *) die "❌ Жди --set K=V [--no-validate]" ;;
    esac
  done
  # shellcheck disable=SC2086
  g_save $g_novalidate
  exit 0
elif [ $# -eq 0 ]; then
  show_menu
else
  die "❌ Неизвестные флаги (жди без флагов / --show / --set K=V [--no-validate])"
fi
