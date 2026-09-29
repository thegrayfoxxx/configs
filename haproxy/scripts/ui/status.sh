#!/bin/bash
# shellcheck shell=bash
# UI: статус и рестарт сервисов (бывшие инлайн п.4/п.5 haproxy.sh).
# Зависимости: common.sh (docker/safe_docker_compose/log_*), ui/menu.sh (menu_pause).

# cmd_status — таблица docker ps по haproxy/acme.
cmd_status() {
  clear_screen
  print_header "СТАТУС СЕРВИСОВ" "📊"
  if ! docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=haproxy" --filter "name=acme" 2>/dev/null; then
    log_error "❌ Не удалось получить статус. Проверь Docker."
  fi
  printf "\n"
  menu_pause
}

# cmd_restart_all — рестарт включённых сервисов через dc-профили.
cmd_restart_all() {
  clear_screen
  print_header "ПЕРЕЗАПУСК СЕРВИСОВ" "🔄"
  if safe_docker_compose restart; then
    log_info "✅ Сервисы перезапущены"
  else
    log_error "❌ Ошибка перезапуска сервисов"
  fi
  printf "\n"
  menu_pause
}
