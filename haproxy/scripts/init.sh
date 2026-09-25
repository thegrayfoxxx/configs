#!/bin/bash
# Init с нуля: сервисы -> sites.conf -> generate+validate -> up.
# Скелет волны 1; в волне 4 сюда встанет визард пресетов.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

clear_screen
print_header "INIT С НУЛЯ" "🆕"

# Шаг 1: выбор сервисов
printf "  ${CYAN}Какие сервисы поднимать? (по умолчанию: все)${NC}\n"
for svc in stream web acme; do
  local_on="Y"
  svc_is_enabled "$svc" || local_on="n"
  printf "  ${CYAN}👉 Включить %s? [Y/n] (сейчас: %s):${NC} " "$svc" "$local_on"
  read -r ans < /dev/tty
  if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
    svc_enable "$svc"
  else
    svc_disable "$svc"
  fi
done
log_info "  ✓ Набор: $(svc_load_enabled)"
printf "\n"

# Шаг 2: sites.conf — пресет или ручной интерактив
if [ -f "${SCRIPT_DIR}/preset.sh" ]; then
  printf "  ${CYAN}👉 Начать с готового пресета? [y/N]:${NC} "
  read -r ans < /dev/tty
  if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    bash "${SCRIPT_DIR}/preset.sh" < /dev/tty
    printf "\n"
    read -p "[Enter]..." < /dev/tty
    exit 0
  fi
fi
ensure_sites_conf

# Шаг 3: генерация + валидация
load_sites
if ! generate_configs; then
  die "❌ Генерация не удалась — чиним sites.conf и повторяем"
fi

# Шаг 4: up
printf "\n"
printf "  ${CYAN}👉 Поднять включённые сервисы сейчас? [Y/n]:${NC} "
read -r ans < /dev/tty
if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
  require_docker
  if safe_docker_compose up -d; then
    log_info "✅ Готово: $(svc_load_enabled)"
  else
    log_error "❌ up завершился с ошибкой — смотри логи (п.6 главного меню)"
  fi
else
  log_info "Ок, конфиги готовы. Поднять позже: п.5 главного меню или services.sh"
fi
printf "\n"
read -p "[Enter]..." < /dev/tty
