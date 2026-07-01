#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

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
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1) issue_cert ;;
      2) deploy_cert ;;
      3) issue_and_deploy ;;
      4) list_certs ;;
      5) inspect_cert ;;
      6) remove_cert ;;
      7) force_renew ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac
  done
}

issue_cert() {
  clear_screen
  print_header "ВЫПУСК СЕРТИФИКАТА" "📜"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  load_sites
  if [ -z "${ACME_EMAIL:-}" ]; then
    printf "  ${CYAN}👉 Email:${NC} "
    read -r ACME_EMAIL < /dev/tty
    [ -z "$ACME_EMAIL" ] && { log_error "❌ Email не может быть пустым"; return; }
  fi

  if ! safe_docker_compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL"; then
    log_error "❌ Ошибка выпуска сертификата"
    return 1
  fi

  log_info "✅ Сертификат выпущен"
}

deploy_cert() {
  clear_screen
  print_header "ДЕПЛОЙ СЕРТИФИКАТА" "🚀"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
    return 1
  fi

  log_info "✅ Сертификат задеплоен"
}

issue_and_deploy() {
  clear_screen
  print_header "ВЫПУСК + ДЕПЛОЙ" "🔄"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  load_sites
  if [ -z "${ACME_EMAIL:-}" ]; then
    printf "  ${CYAN}👉 Email:${NC} "
    read -r ACME_EMAIL < /dev/tty
    [ -z "$ACME_EMAIL" ] && { log_error "❌ Email не может быть пустым"; return; }
  fi

  if ! safe_docker_compose exec acme acme.sh --issue \
    -d "$domain" \
    --standalone \
    --httpport 80 \
    --email "$ACME_EMAIL"; then
    log_error "❌ Ошибка выпуска сертификата"
    return 1
  fi

  log_info "✅ Сертификат выпущен"

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
    return 1
  fi

  log_info "✅ Сертификат задеплоен"
}

list_certs() {
  clear_screen
  print_header "СПИСОК СЕРТИФИКАТОВ" "📋"

  printf "  ${CYAN}PEM-файлы в web/certs/:${NC}\n\n"

  if [ ! -d "${HAPROXY_DIR}/web/certs" ]; then
    log_warn "⚠️  Директория web/certs не существует"
    printf "\n"
    read -p "[Enter]..." < /dev/tty
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
  read -p "[Enter]..." < /dev/tty
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
    read -p "[Enter]..." < /dev/tty
    return
  fi

  printf "\n"
  if ! openssl x509 -in "$pem" -noout -subject -issuer -dates; then
    log_error "❌ Ошибка чтения сертификата"
  fi

  printf "\n"
  read -p "[Enter]..." < /dev/tty
}

remove_cert() {
  clear_screen
  print_header "УДАЛЕНИЕ СЕРТИФИКАТА" "🗑️"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  printf "  ${YELLOW}⚠️  Удалить сертификат для ${domain}? [y/N]:${NC} "
  read -r confirm < /dev/tty
  [ "$confirm" != "y" ] && return

  safe_docker_compose exec acme acme.sh --remove -d "$domain" || log_warn "⚠️  Не удалось удалить через acme.sh"
  rm -f "${HAPROXY_DIR}/web/certs/${domain}.pem"

  log_info "✅ Сертификат удалён"
}

force_renew() {
  clear_screen
  print_header "ПРИНУДИТЕЛЬНОЕ ОБНОВЛЕНИЕ" "⚡"

  printf "  ${CYAN}👉 Домен:${NC} "
  read -r domain < /dev/tty
  [ -z "$domain" ] && { log_error "❌ Домен не может быть пустым"; return; }
  if ! validate_domain "$domain"; then
    return
  fi

  if ! safe_docker_compose exec acme acme.sh --renew \
    -d "$domain" \
    --force; then
    log_error "❌ Ошибка обновления сертификата"
    return 1
  fi

  log_info "✅ Сертификат обновлён"

  if ! safe_docker_compose exec acme acme.sh --deploy \
    -d "$domain" \
    --deploy-hook haproxy; then
    log_error "❌ Ошибка деплоя сертификата"
    return 1
  fi

  log_info "✅ Сертификат задеплоен"
}

show_menu
