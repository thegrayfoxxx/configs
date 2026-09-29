#!/bin/bash
# shellcheck shell=bash
# UI: проверка конфигов haproxy -c (бывший инлайн п.11 haproxy.sh).
# Зависимости: common.sh (load_sites/validate_cfg), ui/menu.sh (menu_pause).

# cmd_validate — проверить stream/haproxy.cfg и web/haproxy.cfg.
cmd_validate() {
  clear_screen
  print_header "ПРОВЕРКА КОНФИГОВ" "✅"
  load_sites 2>/dev/null || true
  local rc=0
  validate_cfg "${HAPROXY_DIR}/stream/haproxy.cfg" || rc=1
  validate_cfg "${HAPROXY_DIR}/web/haproxy.cfg" || rc=1
  if [ "$rc" -eq 0 ]; then
    log_info "✅ Оба конфига в порядке (или haproxy нет для проверки)"
  fi
  menu_pause
}
