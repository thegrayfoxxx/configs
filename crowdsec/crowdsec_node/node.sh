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

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "NODE MANAGER" "🖥️"
    printf "  ${GREEN}1.${NC} 🔄 Обновить конфиги\n"
    printf "  ${GREEN}2.${NC} 📊 Статус\n"
    printf "  ${GREEN}3.${NC} 🐳 Перезапустить контейнеры\n"
    printf "  ${RED}0.${NC} ❌ Выход\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh"
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
        printf "${YELLOW}═══ ПЕРЕЗАПУСК ═══${NC}\n"
        printf "\n"
        printf "  ${CYAN}🐳 Перезапускаю контейнеры...${NC}\n"
        if [ -f "${SCRIPT_DIR}/compose.yml" ]; then
          cd "${SCRIPT_DIR}" || { log_error "❌ Ошибка перехода в директорию"; return; }
          if docker compose restart; then
            printf "\n"
            log_info "  ✅ Контейнеры перезапущены"
          else
            printf "\n"
            log_error "  ❌ Ошибка перезапуска контейнеров"
          fi
        else
          log_error "❌ compose.yml не найден"
          printf "  Сначала скопируй шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}\n"
        fi
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac

    printf "\n"
    read -p "[Enter] в меню..." < /dev/tty
  done
}

show_menu
