#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

show_status() {
  printf "\n"
  log_warn "═══ СТАТУС ═══"

  # Docker контейнеры
  printf "\n"
  printf "  ${CYAN}🐳 Контейнеры:${NC}\n"
  if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q 'crowdsec'; then
    docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null | grep crowdsec
  else
    log_error "❌ Контейнеры не запущены"
  fi

  # Хостовые логи (только чтение, ничего не ставит)
  printf "\n"
  printf "  ${CYAN}📋 Хостовые логи:${NC}\n"
  if command -v host_logs_status >/dev/null 2>&1; then
    host_logs_status
  else
    log_warn "  ⚠️  host_logs_status недоступна (обнови common.sh)"
  fi

  # ipset
  printf "\n"
  printf "  ${CYAN}🛡️  Блокировки (ipset):${NC}\n"
  if command -v ipset >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      if ! sudo -n true 2>/dev/null; then
        log_warn "  ⚠️  Нет прав sudo для ipset (требуется NOPASSWD)"
      else
        local entries
        entries=$(sudo -n ipset list crowdsec-blacklists-0 -t 2>/dev/null \
          | grep "Number of entries" \
          | awk '{print $4}')
        if [ -n "$entries" ]; then
          log_info "  ✅ IP в блоке: $entries"
        else
          log_warn "  ⚠️  Список crowdsec-blacklists-0 не найден"
          printf "  Возможно, баунсер ещё не создал его\n"
        fi
      fi
    else
      log_warn "  ⚠️  sudo не установлен"
    fi
  else
    log_warn "  ⚠️  ipset не установлен"
  fi
}

start_with_preflight() {
  require_cmd docker "Установи Docker: https://docs.docker.com/engine/install/"
  if [ ! -f "${SCRIPT_DIR}/compose.yml" ] && [ ! -f "${SCRIPT_DIR}/compose.yaml" ]; then
    log_error "❌ compose.yml не найден"
    printf "  Сначала скопируй шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}\n"
    return 1
  fi
  if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    log_warn "  ⚠️  .env не найден, проверь: cp .env.example .env"
  fi
  printf "\n"
  log_warn "═══ PREFLIGHT ═══"
  printf "\n"
  ensure_host_logs "${SCRIPT_DIR}"
  printf "\n"
  printf "  ${CYAN}🐳 Запускаю контейнеры...${NC}\n"
  cd "${SCRIPT_DIR}" || { log_error "❌ Ошибка перехода в директорию"; return 1; }
  if docker compose up -d; then
    printf "\n"
    log_info "  ✅ Нода запущена"
  else
    printf "\n"
    log_error "  ❌ Ошибка запуска контейнеров"
    return 1
  fi
}

restart_with_preflight() {
  require_cmd docker "Установи Docker: https://docs.docker.com/engine/install/"
  if [ ! -f "${SCRIPT_DIR}/compose.yml" ] && [ ! -f "${SCRIPT_DIR}/compose.yaml" ]; then
    log_error "❌ compose.yml не найден"
    printf "  Сначала скопируй шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}\n"
    return 1
  fi
  ensure_host_logs "${SCRIPT_DIR}"
  printf "\n"
  printf "  ${CYAN}🐳 Перезапускаю контейнеры...${NC}\n"
  cd "${SCRIPT_DIR}" || { log_error "❌ Ошибка перехода в директорию"; return 1; }
  if docker compose restart; then
    printf "\n"
    log_info "  ✅ Контейнеры перезапущены"
  else
    printf "\n"
    log_error "  ❌ Ошибка перезапуска контейнеров"
    return 1
  fi
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "NODE MANAGER" "🖥️"
    printf "  ${GREEN}1.${NC} 🔄 Обновить конфиги\n"
    printf "  ${GREEN}2.${NC} 📊 Статус\n"
    printf "  ${GREEN}3.${NC} 🐳 Перезапустить контейнеры (с preflight)\n"
    printf "  ${GREEN}4.${NC} 🚀 Запустить (preflight + up -d)\n"
    printf "  ${RED}0.${NC} ❌ Выход\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ update.sh не найден"
        fi
        ;;
      2)
        clear_screen
        print_header "СТАТУС"
        show_status
        ;;
      3)
        clear_screen
        print_header "ПЕРЕЗАПУСК"
        restart_with_preflight
        ;;
      4)
        clear_screen
        print_header "ЗАПУСК НОДЫ" "🚀"
        start_with_preflight
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac

    printf "\n"
    read -p "[Enter] в меню..." < /dev/tty
  done
}

# CLI для setup-node.sh и автоматизации: ./node.sh start|status|restart
case "${1:-}" in
  start|up)
    print_header "ЗАПУСК НОДЫ" "🚀"
    start_with_preflight
    ;;
  status)
    print_header "СТАТУС"
    show_status
    ;;
  restart)
    print_header "ПЕРЕЗАПУСК"
    restart_with_preflight
    ;;
  "")
    show_menu
    ;;
  *)
    log_error "❌ Неизвестная команда: ${1:-} (start|status|restart)"
    exit 1
    ;;
esac
