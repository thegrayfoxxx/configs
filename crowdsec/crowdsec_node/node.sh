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
  echo -e "${CYAN}│            🖥️  NODE MANAGER                │${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
  echo ""
}

show_status() {
  echo ""
  echo -e "${YELLOW}═══ СТАТУС ═══${NC}"

  # Docker контейнеры
  echo ""
  echo -e "  ${CYAN}🐳 Контейнеры:${NC}"
  if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q 'crowdsec'; then
    docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null | grep crowdsec
  else
    echo -e "  ${RED}❌ Контейнеры не запущены${NC}"
  fi

  # ipset
  echo ""
  echo -e "  ${CYAN}🛡️  Блокировки (ipset):${NC}"
  if command -v ipset >/dev/null 2>&1; then
    local entries=$(sudo ipset list crowdsec-blacklists-0 -t 2>/dev/null | grep "Number of entries" | awk '{print $4}')
    if [ -n "$entries" ]; then
      echo -e "  ${GREEN}✅${NC} IP в блоке: ${GREEN}$entries${NC}"
    else
      echo -e "  ${YELLOW}⚠️  Список crowdsec-blacklists-0 не найден${NC}"
      echo -e "  Возможно, баунсер ещё не создал его"
    fi
  else
    echo -e "  ${YELLOW}⚠️  ipset не установлен${NC}"
  fi
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    show_header
    echo -e "  ${GREEN}1.${NC} 🔄 Обновить конфиги"
    echo -e "  ${GREEN}2.${NC} 📊 Статус"
    echo -e "  ${GREEN}3.${NC} 🐳 Перезапустить контейнеры"
    echo -e "  ${RED}0.${NC} ❌ Выход"
    echo ""
    echo -ne "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh"
        else
          tput clear
          echo -e "${RED}❌ update.sh не найден${NC}"
        fi
        ;;
      2)
        tput clear
        show_header
        show_status
        ;;
      3)
        tput clear
        echo -e "${YELLOW}═══ ПЕРЕЗАПУСК ═══${NC}"
        echo ""
        echo -e "  ${CYAN}🐳 Перезапускаю контейнеры...${NC}"
        if [ -f "${SCRIPT_DIR}/compose.yml" ]; then
          cd "${SCRIPT_DIR}" && docker compose restart
          echo ""
          echo -e "  ${GREEN}✅ Контейнеры перезапущены${NC}"
        else
          echo -e "  ${RED}❌ compose.yml не найден${NC}"
          echo -e "  Сначала скопируй шаблон: ${CYAN}cp compose-example.yml compose.yml${NC}"
        fi
        ;;
      0) exit 0 ;;
      *) echo -e "${RED}❌ Неверный пункт${NC}"; sleep 1; continue ;;
    esac

    echo ""
    read -p "[Enter] в меню..." < /dev/tty
  done
}

show_menu
