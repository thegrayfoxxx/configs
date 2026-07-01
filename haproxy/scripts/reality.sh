#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "УПРАВЛЕНИЕ REALITY" "🔐"
    printf "  ${GREEN}1.${NC} ➕ Добавить reality\n"
    printf "  ${GREEN}2.${NC} ➖ Удалить reality\n"
    printf "  ${GREEN}3.${NC} 📋 Список reality\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1) add_reality ;;
      2) remove_reality ;;
      3) list_reality ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac
  done
}

add_reality() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ REALITY" "➕"

  load_sites

  # Домены
  printf "  ${CYAN}👉 Домены через пробел (например, google.com www.google.com):${NC} "
  read -r domains < /dev/tty
  [ -z "$domains" ] && { log_error "❌ Домены не могут быть пустыми"; return; }

  # Проверяем, не существует ли уже
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    local existing="${entry%%:*}"
    if [ "$existing" = "$domains" ]; then
      log_error "❌ Reality для этих доменов уже существует"
      return
    fi
  done

  # Порт xray
  printf "  ${CYAN}👉 Порт xray reality (по умолчанию 10443):${NC} "
  read -r port < /dev/tty
  [ -z "$port" ] && port="10443"

  # Добавляем в массив
  REALITY_SITES+=("${domains}:${port}")

  # Сохраняем
  save_sites
  log_info "✅ Reality добавлен в sites.conf"

  # Генерируем конфиги
  generate_configs

  # Перезапускаем сервисы
  printf "\n"
  printf "  ${CYAN}👉 Перезапустить сервисы? [Y/n]:${NC} "
  read -r restart < /dev/tty
  if [ -z "$restart" ] || [ "$restart" = "Y" ] || [ "$restart" = "y" ]; then
    docker compose restart
    log_info "✅ Сервисы перезапущены"
  fi
}

remove_reality() {
  clear_screen
  print_header "УДАЛЕНИЕ REALITY" "➖"

  load_sites

  if [ ${#REALITY_SITES[@]} -eq 0 ]; then
    log_warn "⚠️  Нет reality для удаления"
    return
  fi

  # Показываем список
  printf "  ${CYAN}Доступные reality:${NC}\n"
  for i in "${!REALITY_SITES[@]}"; do
    local entry="${REALITY_SITES[$i]}"
    local domains="${entry%%:*}"
    local port="${entry##*:}"
    printf "  ${GREEN}%d.${NC} %s (порт %s)\n" "$((i+1))" "$domains" "$port"
  done
  printf "\n"

  # Выбор
  printf "  ${CYAN}👉 Номер reality для удаления (0 - отмена):${NC} "
  read -r num < /dev/tty
  [ "$num" = "0" ] && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#REALITY_SITES[@]} ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local idx=$((num-1))
  local domains="${REALITY_SITES[$idx]%%:*}"

  # Удаляем из массива
  unset 'REALITY_SITES[$idx]'
  REALITY_SITES=("${REALITY_SITES[@]+"${REALITY_SITES[@]}"}")

  # Сохраняем
  save_sites
  log_info "✅ Reality для ${domains} удалён из sites.conf"

  # Генерируем конфиги
  generate_configs

  # Перезапускаем сервисы
  printf "\n"
  printf "  ${CYAN}👉 Перезапустить сервисы? [Y/n]:${NC} "
  read -r restart < /dev/tty
  if [ -z "$restart" ] || [ "$restart" = "Y" ] || [ "$restart" = "y" ]; then
    docker compose restart
    log_info "✅ Сервисы перезапущены"
  fi
}

list_reality() {
  clear_screen
  print_header "СПИСОК REALITY" "📋"

  load_sites

  if [ ${#REALITY_SITES[@]} -eq 0 ]; then
    log_warn "⚠️  Reality нет"
    read -p "[Enter]..." < /dev/tty
    return
  fi

  printf "  ${CYAN}%-40s %s${NC}\n" "ДОМЕНЫ" "ПОРТ"
  printf "  ${CYAN}%-40s %s${NC}\n" "────────────────────────────────────────" "────"

  for entry in "${REALITY_SITES[@]}"; do
    local domains="${entry%%:*}"
    local port="${entry##*:}"
    printf "  %-40s %s\n" "$domains" "$port"
  done

  printf "\n"
  read -p "[Enter]..." < /dev/tty
}

show_menu
