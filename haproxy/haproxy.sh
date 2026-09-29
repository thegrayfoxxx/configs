#!/bin/bash
# HAProxy Manager — тонкий диспетчер главного меню.
# Структура: Stream (SNI) + Web (Host) + Сертификаты + Пресеты + Сервисы + Конфиги.
# Конкретика (xray/reality) живет только в presets/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
COMMANDS_DIR="${SCRIPTS_DIR}/commands"

# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/ui/menu.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/ui/status.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/ui/logs.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/ui/regen.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/ui/validate.sh"

# Проверяем sites.conf при запуске
ensure_sites_conf

# Проверяем конфиги HAProxy
ensure_configs

print_main_menu() {
  clear_screen
  print_header "HAPROXY MANAGER" "🔧"
  print_status_box
  printf "  ${GREEN}1.${NC} 🔀 Stream\n"
  printf "  ${GREEN}2.${NC} 🌐 Web\n"
  printf "  ${GREEN}3.${NC} 📜 Сертификаты\n"
  printf "  ${GREEN}4.${NC} 🎛️  Пресеты (готовые сценарии)\n"
  printf "  ${GREEN}5.${NC} 🧩 Сервисы и логи\n"
  printf "  ${GREEN}6.${NC} 💾 Конфиги и бэкапы\n"
  printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
  printf "  ${RED}0.${NC} ❌ Выход\n"
  printf "\n"
  printf "${CYAN}👉 Пункт:${NC} "
}

# run_cmd <имя> — запустить commands/<имя> с TTY-пробросом.
run_cmd() {
  local name="$1"
  local path="${COMMANDS_DIR}/${name}"
  if [ -f "$path" ]; then
    bash "$path" < "$TTY_IN"
  else
    clear_screen
    log_error "❌ ${name} не найден"
    menu_pause
  fi
}

print_services_menu() {
  clear_screen
  print_header "СЕРВИСЫ И ЛОГИ" "🧩"
  printf "  ${GREEN}1.${NC} 📊 Статус сервисов\n"
  printf "  ${GREEN}2.${NC} 🔄 Перезапустить все сервисы\n"
  printf "  ${GREEN}3.${NC} 📋 Логи\n"
  printf "  ${GREEN}4.${NC} 🧩 Сервисы (вкл/выкл/рестарт/init)\n"
  printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
  printf "  ${RED}0.${NC} ⬅️  Назад\n"
  printf "\n"
  printf "${CYAN}👉 Пункт:${NC} "
}

cmd_services_menu() {
  while true; do
    print_services_menu
    local choice
    read -r choice < "$TTY_IN"
    case "$choice" in
      1) cmd_status || true ;;
      2) cmd_restart_all || true ;;
      3) cmd_logs || true ;;
      4) run_cmd "services.sh"  || true ;;
      0) return 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid ;;
    esac
  done
}

print_configs_menu() {
  clear_screen
  print_header "КОНФИГИ И БЭКАПЫ" "💾"
  printf "  ${GREEN}1.${NC} 📝 Перегенерировать конфиги (с diff)\n"
  printf "  ${GREEN}2.${NC} ✅ Проверить конфиги (haproxy -c)\n"
  printf "  ${GREEN}3.${NC} 🔀 Миграция sites.conf → v3\n"
  printf "  ${GREEN}4.${NC} ⬇️  Обновить скрипты из репозитория\n"
  printf "  ${GREEN}5.${NC} 💾 Бэкапы и откат\n"
  printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
  printf "  ${RED}0.${NC} ⬅️  Назад\n"
  printf "\n"
  printf "${CYAN}👉 Пункт:${NC} "
}

cmd_configs_menu() {
  while true; do
    print_configs_menu
    local choice
    read -r choice < "$TTY_IN"
    case "$choice" in
      1) cmd_regen || true ;;
      2) cmd_validate || true ;;
      3)
        run_cmd "migrate.sh"
        printf "\n"
        menu_pause
        ;;
      4)
        run_cmd "update.sh"
        printf "\n"
        menu_pause
        ;;
      5) run_cmd "backups.sh"  || true ;;
      0) return 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid ;;
    esac
  done
}

# dispatch <choice> — один пункт меню. Вынесено из цикла для тестируемости.
dispatch() {
  local choice="$1"
  case "$choice" in
    1) run_cmd "stream.sh"  || true ;;
    2) run_cmd "web.sh"  || true ;;
    3) run_cmd "cert.sh"  || true ;;
    4) run_cmd "preset.sh"  || true ;;
    5) cmd_services_menu || true ;;
    6) cmd_configs_menu || true ;;
    0) exit 0 ;;
    ?) print_cheatsheet || true ;;
    *) menu_invalid ;;
  esac
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    print_main_menu
    local choice
    read -r choice < "$TTY_IN"
    dispatch "$choice"
  done
}

show_menu
