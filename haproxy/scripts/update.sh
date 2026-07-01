#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TMP_ARCHIVE="/tmp/haproxy.tar.gz"
TEMP_DIR="/tmp/haproxy-update"

cleanup() {
  rm -f "$TMP_ARCHIVE" 2>/dev/null || true
  rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

update_from_repo() {
  cd "$HAPROXY_DIR" || die "❌ Не удалось перейти в ${HAPROXY_DIR}"

  clear_screen
  print_header "ОБНОВЛЕНИЕ КОНФИГОВ" "🔄"

  printf "  ${CYAN}📥 Скачиваю свежие конфиги...${NC}\n"
  if ! curl -fsSL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o "$TMP_ARCHIVE"; then
    die "❌ Ошибка скачивания. Проверь интернет."
  fi

  rm -rf "$TEMP_DIR"
  mkdir -p "$TEMP_DIR"

  printf "  ${CYAN}📦 Распаковываю...${NC}\n"
  if ! tar xzf "$TMP_ARCHIVE" -C "$TEMP_DIR" \
    --strip=3 \
    --wildcards \
    --wildcards-match-slash \
    '*/haproxy/*'; then
    die "❌ Ошибка распаковки архива."
  fi

  printf "  ${CYAN}📋 Обновляю файлы...${NC}\n"
  shopt -s dotglob
  if ! cp -r "$TEMP_DIR"/* .; then
    log_error "❌ Ошибка копирования файлов"
    return 1
  fi
  shopt -u dotglob

  chmod +x scripts/*.sh 2>/dev/null || true
  chmod +x haproxy.sh 2>/dev/null || true

  printf "\n"
  log_info "  ✅ Готово"
  printf "\n"
  log_warn "  ⚠️  Не забудь создать sites.conf, если его нет:"
  printf "     ${CYAN}cp sites.conf.example sites.conf${NC}\n"
}

update_from_repo
