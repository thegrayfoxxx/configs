#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "УПРАВЛЕНИЕ САЙТАМИ" "🌐"
    printf "  ${GREEN}1.${NC} ➕ Добавить сайт\n"
    printf "  ${GREEN}2.${NC} ➖ Удалить сайт\n"
    printf "  ${GREEN}3.${NC} 📋 Список сайтов\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1) add_site ;;
      2) remove_site ;;
      3) list_sites ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac
  done
}

add_site() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ САЙТА" "➕"

  # Загружаем текущую конфигурацию
  load_sites

  # Домен
  printf "  ${CYAN}👉 Домен (например, example.com):${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }

  # Проверяем, не существует ли уже
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    local existing="${entry%%:*}"
    if [ "$existing" = "$domain" ]; then
      log_error "❌ Сайт $domain уже существует"
      return
    fi
  done

  # Порт бэкенда
  printf "  ${CYAN}👉 Порт бэкенда (например, 8080):${NC} "
  read -r port < /dev/tty
  [ -z "$port" ] && { log_error "❌ Порт не может быть пустым"; return; }

  # Добавляем в массив
  WEB_SITES+=("${domain}:${port}")

  # Сохраняем
  save_sites
  log_info "✅ Сайт ${domain} добавлен в sites.conf"

  # Генерируем конфиги
  generate_configs

  # Выпускаем сертификат
  printf "\n"
  printf "  ${CYAN}👉 Выпустить сертификат для ${domain}? [Y/n]:${NC} "
  read -r issue_cert < /dev/tty
  if [ -z "$issue_cert" ] || [ "$issue_cert" = "Y" ] || [ "$issue_cert" = "y" ]; then
    issue_certificate "$domain"
  fi

  # Перезапускаем сервисы
  printf "\n"
  printf "  ${CYAN}👉 Перезапустить сервисы? [Y/n]:${NC} "
  read -r restart < /dev/tty
  if [ -z "$restart" ] || [ "$restart" = "Y" ] || [ "$restart" = "y" ]; then
    docker compose restart
    log_info "✅ Сервисы перезапущены"
  fi
}

remove_site() {
  clear_screen
  print_header "УДАЛЕНИЕ САЙТА" "➖"

  load_sites

  if [ ${#WEB_SITES[@]} -eq 0 ]; then
    log_warn "⚠️  Нет сайтов для удаления"
    return
  fi

  # Показываем список
  printf "  ${CYAN}Доступные сайты:${NC}\n"
  for i in "${!WEB_SITES[@]}"; do
    local entry="${WEB_SITES[$i]}"
    local domain="${entry%%:*}"
    local port="${entry##*:}"
    printf "  ${GREEN}%d.${NC} %s (порт %s)\n" "$((i+1))" "$domain" "$port"
  done
  printf "\n"

  # Выбор
  printf "  ${CYAN}👉 Номер сайта для удаления (0 - отмена):${NC} "
  read -r num < /dev/tty
  [ "$num" = "0" ] && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#WEB_SITES[@]} ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local idx=$((num-1))
  local domain="${WEB_SITES[$idx]%%:*}"

  # Удаляем из массива
  unset 'WEB_SITES[$idx]'
  WEB_SITES=("${WEB_SITES[@]+"${WEB_SITES[@]}"}")

  # Сохраняем
  save_sites
  log_info "✅ Сайт ${domain} удалён из sites.conf"

  # Генерируем конфиги
  generate_configs

  # Удаляем сертификат
  printf "\n"
  printf "  ${CYAN}👉 Удалить сертификат для ${domain}? [Y/n]:${NC} "
  read -r del_cert < /dev/tty
  if [ -z "$del_cert" ] || [ "$del_cert" = "Y" ] || [ "$del_cert" = "y" ]; then
    remove_certificate "$domain"
  fi

  # Перезапускаем сервисы
  printf "\n"
  printf "  ${CYAN}👉 Перезапустить сервисы? [Y/n]:${NC} "
  read -r restart < /dev/tty
  if [ -z "$restart" ] || [ "$restart" = "Y" ] || [ "$restart" = "y" ]; then
    docker compose restart
    log_info "✅ Сервисы перезапущены"
  fi
}

list_sites() {
  clear_screen
  print_header "СПИСОК САЙТОВ" "📋"

  load_sites

  if [ ${#WEB_SITES[@]} -eq 0 ]; then
    log_warn "⚠️  Сайтов нет"
    return
  fi

  printf "  ${CYAN}%-30s %s${NC}\n" "ДОМЕН" "ПОРТ"
  printf "  ${CYAN}%-30s %s${NC}\n" "──────────────────────────────" "────"

  for entry in "${WEB_SITES[@]}"; do
    local domain="${entry%%:*}"
    local port="${entry##*:}"
    printf "  %-30s %s\n" "$domain" "$port"
  done
}

issue_certificate() {
  local domain="$1"
  printf "  ${CYAN}📜 Выпускаю сертификат для %s...${NC}\n" "$domain"

  if [ -z "$ACME_EMAIL" ]; then
    printf "  ${CYAN}👉 Email для сертификата:${NC} "
    read -r ACME_EMAIL < /dev/tty
  fi

  cd "$HAPROXY_DIR"
  docker compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL" \
    --force

  if [ $? -eq 0 ]; then
    log_info "  ✅ Сертификат выпущен"
    deploy_certificate "$domain"
  else
    log_error "  ❌ Ошибка выпуска сертификата"
  fi
}

deploy_certificate() {
  local domain="$1"
  printf "  ${CYAN}🚀 Деплою сертификат для %s...${NC}\n" "$domain"

  cd "$HAPROXY_DIR"
  docker compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy

  if [ $? -eq 0 ]; then
    log_info "  ✅ Сертификат задеплоен"
  else
    log_error "  ❌ Ошибка деплоя сертификата"
  fi
}

remove_certificate() {
  local domain="$1"
  printf "  ${CYAN}🗑️  Удаляю сертификат для %s...${NC}\n" "$domain"

  cd "$HAPROXY_DIR"
  docker compose exec acme acme.sh --remove \
    -d "$domain"

  # Удаляем PEM файл
  rm -f "${HAPROXY_DIR}/web/certs/${domain}.pem"

  log_info "  ✅ Сертификат удалён"
}

show_menu
