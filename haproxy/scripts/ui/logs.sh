#!/bin/bash
# shellcheck shell=bash
# UI: подменю логов (бывший инлайн п.6 haproxy.sh).
# Зависимости: common.sh (log_*), ui/menu.sh (TTY_IN/menu_read).

# _logs_follow <container> — tail -f с проверкой что контейнер запущен.
_logs_follow() {
  local cname="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}\$"; then
    log_error "❌ Контейнер ${cname} не запущен"
  else
    docker logs "$cname" --tail 50 -f
  fi
}

# cmd_logs — интерактивное подменю: stream / web / acme / назад.
cmd_logs() {
  clear_screen
  print_header "ЛОГИ" "📋"
  printf "  ${GREEN}1.${NC} haproxy-stream\n"
  printf "  ${GREEN}2.${NC} haproxy-web\n"
  printf "  ${GREEN}3.${NC} acme\n"
  printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
  printf "  ${RED}0.${NC} Назад\n"
  printf "\n"
  printf "${CYAN}👉 Пункт:${NC} "
  local log_choice
  read -r log_choice < "$TTY_IN"
  case "$log_choice" in
    1) _logs_follow 'haproxy-stream' ;;
    2) _logs_follow 'haproxy-web' ;;
    3) _logs_follow 'acme' ;;
    0) return 0 ;;
    ?) print_cheatsheet || true ;;
    *) menu_invalid ;;
  esac
}
