#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Проверяем sites.conf при запуске
ensure_sites_conf

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "HAPROXY MANAGER" "🔧"
    print_status_box
    printf "  ${GREEN}1.${NC} 🌐 Управление сайтами\n"
    printf "  ${GREEN}2.${NC} 🔐 Управление Reality\n"
    printf "  ${GREEN}3.${NC} 📜 Управление сертификатами\n"
    printf "  ${GREEN}4.${NC} 📊 Статус сервисов\n"
    printf "  ${GREEN}5.${NC} 🔄 Перезапустить все сервисы\n"
    printf "  ${GREEN}6.${NC} 📋 Логи\n"
    printf "  ${GREEN}7.${NC} ⬇️  Обновить конфиги из репозитория\n"
    printf "  ${RED}0.${NC} ❌ Выход\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        if [ -f "${SCRIPTS_DIR}/site.sh" ]; then
          bash "${SCRIPTS_DIR}/site.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ site.sh не найден"
          read -p "[Enter]..." < /dev/tty
        fi
        ;;
      2)
        if [ -f "${SCRIPTS_DIR}/reality.sh" ]; then
          bash "${SCRIPTS_DIR}/reality.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ reality.sh не найден"
          read -p "[Enter]..." < /dev/tty
        fi
        ;;
      3)
        if [ -f "${SCRIPTS_DIR}/cert.sh" ]; then
          bash "${SCRIPTS_DIR}/cert.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ cert.sh не найден"
          read -p "[Enter]..." < /dev/tty
        fi
        ;;
      4)
        clear_screen
        print_header "СТАТУС СЕРВИСОВ" "📊"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=haproxy" --filter "name=acme" 2>/dev/null
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      5)
        clear_screen
        print_header "ПЕРЕЗАПУСК СЕРВИСОВ" "🔄"
        docker compose restart
        log_info "✅ Сервисы перезапущены"
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      6)
        clear_screen
        print_header "ЛОГИ" "📋"
        printf "  ${GREEN}1.${NC} haproxy-stream\n"
        printf "  ${GREEN}2.${NC} haproxy-web\n"
        printf "  ${GREEN}3.${NC} acme\n"
        printf "  ${RED}0.${NC} Назад\n"
        printf "\n"
        printf "${CYAN}👉 Пункт:${NC} "
        read -r log_choice < /dev/tty
        case "$log_choice" in
          1) docker logs haproxy-stream --tail 50 -f ;;
          2) docker logs haproxy-web --tail 50 -f ;;
          3) docker logs acme --tail 50 -f ;;
          0) continue ;;
        esac
        ;;
      7)
        if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
          bash "${SCRIPTS_DIR}/update.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ update.sh не найден"
        fi
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac
  done
}

show_menu
