#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

select_domain() {
  load_sites

  if [ ${#WEB_ROUTES[@]} -gt 0 ]; then
    printf "  ${GREEN}1.${NC} Ввести домен вручную\n" > /dev/tty
    printf "  ${GREEN}2.${NC} Выбрать из списка маршрутов\n" > /dev/tty
    printf "  ${RED}0.${NC} ⬅️  Назад\n\n" > /dev/tty
    printf "${CYAN}👉 Пункт:${NC} " > /dev/tty
    read -r sel < /dev/tty

    if [ "$sel" = "0" ] || [ -z "$sel" ]; then
      return 1
    fi

    if [ "$sel" = "2" ]; then
      printf "\n  ${CYAN}Доступные хосты:${NC}\n" > /dev/tty
      local -a _hosts=()
      local _entry
      for _entry in "${WEB_ROUTES[@]}"; do
        parse_web_route "$_entry" 2>/dev/null || continue
        _hosts+=("$W3_HOST")
      done
      local i
      for i in "${!_hosts[@]}"; do
        printf "  ${GREEN}%d.${NC} %s\n" "$((i+1))" "${_hosts[$i]}" > /dev/tty
      done
      printf "\n  ${CYAN}👉 Номер хоста (0 - отмена):${NC} " > /dev/tty
      read -r num < /dev/tty

      if [ "$num" = "0" ] || [ -z "$num" ]; then
        return 1
      fi

      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#_hosts[@]}" ]; then
        echo "${_hosts[$((num-1))]}"
        return
      else
        log_error "❌ Неверный номер"
        return 1
      fi
    fi
  fi

  printf "  ${CYAN}👉 Домен (Enter = отмена):${NC} " > /dev/tty
  read -r domain < /dev/tty
  [ -z "$domain" ] && return 1
  if ! validate_domain "$domain"; then
    return 1
  fi
  echo "$domain"
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "УПРАВЛЕНИЕ СЕРТИФИКАТАМИ" "📜"
    printf "  ${GREEN}1.${NC} 📜 Выпустить сертификат\n"
    printf "  ${GREEN}2.${NC} 🚀 Деплой сертификата\n"
    printf "  ${GREEN}3.${NC} 🔄 Выпустить + деплой\n"
    printf "  ${GREEN}4.${NC} 📋 Список сертификатов\n"
    printf "  ${GREEN}5.${NC} 🔍 Проверить сертификат\n"
    printf "  ${GREEN}6.${NC} 🗑️  Удалить сертификат\n"
    printf "  ${GREEN}7.${NC} ⚡ Принудительно обновить\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1) issue_cert || true ;;
      2) deploy_cert || true ;;
      3) issue_and_deploy || true ;;
      4) list_certs || true ;;
      5) inspect_cert || true ;;
      6) remove_cert || true ;;
      7) force_renew || true ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

issue_cert() {
  clear_screen
  print_header "ВЫПУСК СЕРТИФИКАТА" "📜"

  local domain
  domain=$(select_domain) || return

  load_sites
  if [ -z "${ACME_EMAIL:-}" ]; then
    printf "  ${CYAN}👉 Email:${NC} "
    read -r ACME_EMAIL < /dev/tty
    [ -z "$ACME_EMAIL" ] && { log_error "❌ Email не может быть пустым"; return; }
  fi

  require_port_free 80 "standalone-выпуск слушает :80" || return

  if ! safe_docker_compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL"; then
    log_error "❌ Ошибка выпуска сертификата"
  else
    log_info "✅ Сертификат выпущен"
  fi

  printf "\n"
  menu_pause
}

deploy_cert() {
  clear_screen
  print_header "ДЕПЛОЙ СЕРТИФИКАТА" "🚀"

  printf "  ${CYAN}👉 Домен (Enter = отмена):${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && return
  if ! validate_domain "$domain"; then
    return
  fi

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
  else
    log_info "✅ Сертификат задеплоен"
  fi

  printf "\n"
  menu_pause
}

issue_and_deploy() {
  clear_screen
  print_header "ВЫПУСК + ДЕПЛОЙ" "🔄"

  local domain
  domain=$(select_domain) || return

  load_sites
  if [ -z "${ACME_EMAIL:-}" ]; then
    printf "  ${CYAN}👉 Email:${NC} "
    read -r ACME_EMAIL < /dev/tty
    [ -z "$ACME_EMAIL" ] && { log_error "❌ Email не может быть пустым"; return; }
  fi

  require_port_free 80 "standalone-выпуск слушает :80" || return

  if ! safe_docker_compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL"; then
    log_error "❌ Ошибка выпуска сертификата"
    printf "\n"
    menu_pause
    return
  fi

  log_info "✅ Сертификат выпущен"

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
  else
    log_info "✅ Сертификат задеплоен"
  fi

  printf "\n"
  menu_pause
}

list_certs() {
  clear_screen
  print_header "СПИСОК СЕРТИФИКАТОВ" "📋"

  printf "  ${CYAN}PEM-файлы в web/certs/:${NC}\n\n"

  if [ ! -d "${HAPROXY_DIR}/web/certs" ]; then
    log_warn "⚠️  Директория web/certs не существует"
    printf "\n"
    menu_pause
    return
  fi

  local count=0
  shopt -s nullglob
  for pem in "${HAPROXY_DIR}/web/certs"/*.pem; do
    local name=$(basename "$pem" .pem)
    local expiry=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    printf "  ${GREEN}•${NC} %-35s до %s\n" "$name" "$expiry"
    count=$((count + 1))
  done
  shopt -u nullglob

  if [ $count -eq 0 ]; then
    log_warn "⚠️  Сертификатов нет"
  fi

  printf "\n"
  menu_pause
}

inspect_cert() {
  clear_screen
  print_header "ПРОВЕРКА СЕРТИФИКАТА" "🔍"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  local pem="${HAPROXY_DIR}/web/certs/${domain}.pem"
  if [ ! -f "$pem" ]; then
    log_error "❌ PEM-файл не найден: ${pem}"
    printf "\n"
    menu_pause
    return
  fi

  printf "\n"
  if ! openssl x509 -in "$pem" -noout -subject -issuer -dates; then
    log_error "❌ Ошибка чтения сертификата"
  fi

  printf "\n"
  menu_pause
}

remove_cert() {
  clear_screen
  print_header "УДАЛЕНИЕ СЕРТИФИКАТА" "🗑️"

  printf "  ${CYAN}👉 Домен (Enter = отмена):${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && return
  if ! validate_domain "$domain"; then
    return
  fi

  printf "  ${YELLOW}⚠️  Удалить сертификат для ${domain}? [y/N]:${NC} "
  read -r confirm < /dev/tty
  [ "$confirm" != "y" ] && return

  safe_docker_compose exec acme acme.sh --remove -d "$domain" || log_warn "⚠️  Не удалось удалить через acme.sh"
  rm -f "${HAPROXY_DIR}/web/certs/${domain}.pem"

  log_info "✅ Сертификат удалён"

  printf "\n"
  menu_pause
}

force_renew() {
  clear_screen
  print_header "ПРИНУДИТЕЛЬНОЕ ОБНОВЛЕНИЕ" "⚡"

  printf "  ${CYAN}👉 Домен (Enter = отмена):${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && return
  if ! validate_domain "$domain"; then
    return
  fi

  if ! safe_docker_compose exec acme acme.sh --renew \
    -d "$domain" \
    --force; then
    log_error "❌ Ошибка обновления сертификата"
    printf "\n"
    menu_pause
    return
  fi

  log_info "✅ Сертификат обновлён"

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
  else
    log_info "✅ Сертификат задеплоен"
  fi

  printf "\n"
  menu_pause
}

# --- Неинтерактивное ядро (для вызовов из web.sh и автоматизации) ---
# Возврат 0 = ок, 1 = ошибка. Без clear_screen и пауз.
cert_issue_domain() {
  local domain="$1"
  validate_domain "$domain" || return 1
  load_sites
  if [ -z "${ACME_EMAIL:-}" ]; then
    log_error "❌ ACME_EMAIL пуст (задай в sites.conf)"
    return 1
  fi
  require_port_free 80 "standalone-выпуск слушает :80" || return 1
  if ! safe_docker_compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL"; then
    log_error "❌ Ошибка выпуска сертификата"
    return 1
  fi
  log_info "✅ Сертификат выпущен"
  cert_deploy_domain "$domain"
}

cert_deploy_domain() {
  local domain="$1"
  validate_domain "$domain" || return 1
  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
    return 1
  fi
  log_info "✅ Сертификат задеплоен"
}

cert_remove_domain() {
  local domain="$1"
  validate_domain "$domain" || return 1
  safe_docker_compose exec acme acme.sh --remove -d "$domain" || log_warn "⚠️  Не удалось удалить через acme.sh"
  rm -f "${HAPROXY_DIR}/web/certs/${domain}.pem"
  log_info "✅ Сертификат удалён"
}

case "${1:-}" in
  --issue) cert_issue_domain "${2:?укажи домен}" ;;
  --deploy) cert_deploy_domain "${2:?укажи домен}" ;;
  --remove) cert_remove_domain "${2:?укажи домен}" ;;
  "" ) show_menu ;;
  *) die "❌ Неизвестный флаг: $1 (жди --issue/--deploy/--remove <домен>)" ;;
esac
