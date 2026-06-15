#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "LAPI MANAGER" "🧰"
    printf "  ${GREEN}1.${NC} 🔄 Обновить конфиги (скачать из репозитория)\n"
    printf "  ${GREEN}2.${NC} 🖥️  Зарегистрировать удалённую ноду\n"
    printf "  ${GREEN}3.${NC} 🛡️  Traffic Guard (блоклисты)\n"
    printf "  ${RED}0.${NC} ❌ Выход\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        clear_screen
        print_header "ОБНОВЛЕНИЕ КОНФИГОВ"
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh" < /dev/tty
          printf "\n"
          if [ -f "${SCRIPT_DIR}/compose-example.yml" ]; then
            printf "  Не забудь скопировать шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}\n"
          fi
        else
          log_error "❌ update.sh не найден"
        fi
        ;;
      2)
        clear_screen
        print_header "РЕГИСТРАЦИЯ НОДЫ"
        if [ -f "${SCRIPTS_DIR}/setup-node.sh" ]; then
          bash "${SCRIPTS_DIR}/setup-node.sh" < /dev/tty
        else
          log_error "❌ setup-node.sh не найден"
        fi
        ;;
      3)
        if [ -f "${SCRIPTS_DIR}/traffic-guard.sh" ]; then
          bash "${SCRIPTS_DIR}/traffic-guard.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ traffic-guard.sh не найден"
          printf "\n"
          read -p "[Enter] в меню..." < /dev/tty
        fi
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac

    if [ "$choice" != "3" ]; then
      printf "\n"
      read -p "[Enter] в меню..." < /dev/tty
    fi
  done
}

show_menu
