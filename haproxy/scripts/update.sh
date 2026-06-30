#!/bin/bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TMP_ARCHIVE="/tmp/haproxy.tar.gz"
TEMP_DIR="/tmp/haproxy-update"

update_from_repo() {
  cd "$HAPROXY_DIR"

  clear_screen
  print_header "ОБНОВЛЕНИЕ КОНФИГОВ" "🔄"

  printf "  ${CYAN}📥 Скачиваю свежие конфиги...${NC}\n"
  if ! curl -fsSL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o "$TMP_ARCHIVE"; then
    printf "\n"
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
    printf "\n"
    rm -f "$TMP_ARCHIVE"
    rm -rf "$TEMP_DIR"
    die "❌ Ошибка распаковки архива."
  fi

  printf "  ${CYAN}📋 Обновляю файлы...${NC}\n"
  shopt -s dotglob
  cp -r "$TEMP_DIR"/* . 2>/dev/null || true
  shopt -u dotglob

  chmod +x scripts/*.sh 2>/dev/null || true
  chmod +x haproxy.sh 2>/dev/null || true

  rm -f "$TMP_ARCHIVE"
  rm -rf "$TEMP_DIR"

  printf "\n"
  log_info "  ✅ Готово"
  printf "\n"
  log_warn "  ⚠️  Не забудь создать sites.conf, если его нет:"
  printf "     ${CYAN}cp sites.conf.example sites.conf${NC}\n"
}

update_from_repo
