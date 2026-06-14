#!/bin/bash
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

show_header() {
  tput clear
  echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│              🧰  LAPI MANAGER               │${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
  echo ""
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    show_header
    echo -e "  ${GREEN}1.${NC} 🔄 Обновить конфиги (скачать из репозитория)"
    echo -e "  ${GREEN}2.${NC} 🖥️  Зарегистрировать удалённую ноду"
    echo -e "  ${GREEN}3.${NC} 🛡️  Traffic Guard (блоклисты)"
    echo -e "  ${RED}0.${NC} ❌ Выход"
    echo ""
    echo -ne "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        show_header
        echo -e "${YELLOW}═══ ОБНОВЛЕНИЕ КОНФИГОВ ═══${NC}"
        echo ""
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh"
          echo ""
          if [ -f "${SCRIPT_DIR}/compose-example.yml" ]; then
            echo -e "  Не забудь скопировать шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}"
          fi
        else
          echo -e "  ${RED}❌ update.sh не найден${NC}"
        fi
        ;;
      2)
        show_header
        echo -e "${YELLOW}═══ РЕГИСТРАЦИЯ НОДЫ ═══${NC}"
        echo ""
        if [ -f "${SCRIPTS_DIR}/setup-node.sh" ]; then
          bash "${SCRIPTS_DIR}/setup-node.sh"
        else
          echo -e "  ${RED}❌ setup-node.sh не найден${NC}"
        fi
        ;;
      3)
        if [ -f "${SCRIPTS_DIR}/traffic-guard.sh" ]; then
          bash "${SCRIPTS_DIR}/traffic-guard.sh"
        else
          tput clear
          echo -e "${RED}❌ traffic-guard.sh не найден${NC}"
          echo ""
          read -p "[Enter] в меню..." < /dev/tty
        fi
        ;;
      0) exit 0 ;;
      *) echo -e "${RED}❌ Неверный пункт${NC}"; sleep 1; continue ;;
    esac

    if [ "$choice" != "3" ]; then
      echo ""
      read -p "[Enter] в меню..." < /dev/tty
    fi
  done
}

show_menu
