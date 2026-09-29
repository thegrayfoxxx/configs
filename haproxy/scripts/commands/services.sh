#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

svc_menu() {
  local svc="$1"
  local cname
  cname=$(svc_container "$svc")
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "СЕРВИС: ${svc} (${cname})" "🧩"
    local st="${RED}остановлен${NC}"
    if svc_running "$svc"; then st="${GREEN}запущен${NC}"; fi
    local en="${RED}выкл${NC}"
    if svc_is_enabled "$svc"; then en="${GREEN}вкл${NC}"; fi
    printf "  Статус: %b   В автозапуске: %b\n\n" "$st" "$en"
    printf "  ${GREEN}1.${NC} ✅ Включить (в набор для up)\n"
    printf "  ${GREEN}2.${NC} 🚫 Выключить (остановить и убрать из набора)\n"
    printf "  ${GREEN}3.${NC} 🔄 Рестарт\n"
    printf "  ${GREEN}4.${NC} 📋 Логи\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        svc_enable "$svc"
        log_info "✅ ${svc} включён. Применится при следующем up."
        printf "\n"
        printf "  ${CYAN}👉 Поднять сейчас? [Y/n]:${NC} "
        read -r ans < /dev/tty
        if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
          safe_docker_compose up -d || log_error "❌ Не удалось поднять ${svc}"
        fi
        ;;
      2)
        svc_disable "$svc"
        log_info "✅ ${svc} выключен (убран из набора)."
        if svc_running "$svc"; then
          printf "  ${CYAN}👉 Остановить запущенный контейнер? [Y/n]:${NC} "
          read -r ans < /dev/tty
          if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
            docker stop "$cname" 2>/dev/null || log_error "❌ Не удалось остановить ${cname}"
          fi
        fi
        ;;
      3)
        if safe_docker_compose restart "$cname"; then
          log_info "✅ ${cname} перезапущен"
        else
          log_error "❌ Ошибка рестарта (подсказка: сервис должен быть включён и запущен)"
        fi
        ;;
      4)
        if ! svc_running "$svc"; then
          log_error "❌ Контейнер ${cname} не запущен"
        else
          docker logs "$cname" --tail 50 -f
        fi
        ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
    printf "\n"
    menu_pause
  done
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "СЕРВИСЫ" "🧩"
    printf "  Включены: ${GREEN}%s${NC} (файл .enabled_services)\n\n" "$(svc_load_enabled)"
    printf "  ${GREEN}1.${NC} haproxy-stream (L4, :443)\n"
    printf "  ${GREEN}2.${NC} haproxy-web (L7, :8443)\n"
    printf "  ${GREEN}3.${NC} acme (сертификаты)\n"
    printf "  ${GREEN}4.${NC} 🆕 Init с нуля (сервисы → конфиг → up)\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1) bash "${SCRIPT_DIR}/services.sh" __svc stream < /dev/tty  || true ;;
      2) bash "${SCRIPT_DIR}/services.sh" __svc web < /dev/tty  || true ;;
      3) bash "${SCRIPT_DIR}/services.sh" __svc acme < /dev/tty  || true ;;
      4)
        if [ -f "${SCRIPT_DIR}/init.sh" ]; then
          bash "${SCRIPT_DIR}/init.sh" < /dev/tty
        else
          log_error "❌ init.sh не найден"
          menu_pause
        fi
        ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

# Внутренний вызов подменю сервиса: services.sh __svc <name>
if [ "${1:-}" = "__svc" ]; then
  svc_menu "${2:?нужно имя сервиса}"
else
  show_menu
fi
