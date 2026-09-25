#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Проверяем sites.conf при запуске
ensure_sites_conf

# Проверяем конфиги HAProxy
ensure_configs

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
    printf "  ${GREEN}8.${NC} 📝 Перегенерировать конфиги\n"
    printf "  ${GREEN}9.${NC} 🧩 Сервисы (вкл/выкл/рестарт/init)\n"
    printf "  ${GREEN}10.${NC} 💾 Бэкапы и откат\n"
    printf "  ${GREEN}11.${NC} ✅ Проверить конфиги (haproxy -c)\n"
    printf "  ${GREEN}12.${NC} 🔀 Миграция sites.conf v1 → v2\n"
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
        if ! docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=haproxy" --filter "name=acme" 2>/dev/null; then
          log_error "❌ Не удалось получить статус. Проверь Docker."
        fi
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      5)
        clear_screen
        print_header "ПЕРЕЗАПУСК СЕРВИСОВ" "🔄"
        if safe_docker_compose restart; then
          log_info "✅ Сервисы перезапущены"
        else
          log_error "❌ Ошибка перезапуска сервисов"
        fi
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
          1)
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-stream'; then
              log_error "❌ Контейнер haproxy-stream не запущен"
            else
              docker logs haproxy-stream --tail 50 -f
            fi
            ;;
          2)
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-web'; then
              log_error "❌ Контейнер haproxy-web не запущен"
            else
              docker logs haproxy-web --tail 50 -f
            fi
            ;;
          3)
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'acme'; then
              log_error "❌ Контейнер acme не запущен"
            else
              docker logs acme --tail 50 -f
            fi
            ;;
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
      8)
        if [ -f "$SITES_CONF" ]; then
          load_sites
          printf "\n"
          if preview_configs; then
            log_info "✅ Перегенерировать нечего — живые конфиги совпадают"
          else
            printf "\n"
            printf "  ${CYAN}👉 Применить показанный diff? [y/N]:${NC} "
            read -r ans < /dev/tty
            if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
              generate_configs
            else
              log_info "Отмена (живые файлы не тронуты)"
            fi
          fi
        else
          log_error "❌ sites.conf не найден"
        fi
        read -p "[Enter]..." < /dev/tty
        ;;
      9)
        if [ -f "${SCRIPTS_DIR}/services.sh" ]; then
          bash "${SCRIPTS_DIR}/services.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ services.sh не найден"
          read -p "[Enter]..." < /dev/tty
        fi
        ;;
      10)
        if [ -f "${SCRIPTS_DIR}/backups.sh" ]; then
          bash "${SCRIPTS_DIR}/backups.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ backups.sh не найден"
          read -p "[Enter]..." < /dev/tty
        fi
        ;;
      11)
        clear_screen
        print_header "ПРОВЕРКА КОНФИГОВ" "✅"
        load_sites 2>/dev/null || true
        rc=0
        validate_cfg "${SCRIPT_DIR}/stream/haproxy.cfg" || rc=1
        validate_cfg "${SCRIPT_DIR}/web/haproxy.cfg" || rc=1
        if [ "$rc" -eq 0 ]; then
          log_info "✅ Оба конфига в порядке (или haproxy нет для проверки)"
        fi
        read -p "[Enter]..." < /dev/tty
        ;;
      12)
        if [ -f "${SCRIPTS_DIR}/migrate.sh" ]; then
          bash "${SCRIPTS_DIR}/migrate.sh" < /dev/tty
        else
          clear_screen
          log_error "❌ migrate.sh не найден"
          read -p "[Enter]..." < /dev/tty
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
