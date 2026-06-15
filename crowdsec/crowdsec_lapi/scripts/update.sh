#!/bin/bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TMP_ARCHIVE="/tmp/crowdsec-lapi.tar.gz"
TEMP_DIR="/tmp/crowdsec-lapi-update"

update_from_repo() {
  # Переходим в корень lapi
  cd "$(dirname "$0")/.." || exit 1

  clear_screen
  print_header "ОБНОВЛЕНИЕ КОНФИГОВ" "🔄"

  printf "  ${CYAN}📥 Скачиваю свежие конфиги...${NC}\n"
  if ! curl -fsSL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o "$TMP_ARCHIVE"; then
    printf "\n"
    die "❌ Ошибка скачивания. Проверь интернет."
  fi

  # Очищаем временную директорию
  rm -rf "$TEMP_DIR"
  mkdir -p "$TEMP_DIR"

  printf "  ${CYAN}📦 Распаковываю...${NC}\n"
  if ! tar xzf "$TMP_ARCHIVE" -C "$TEMP_DIR" \
    --strip=3 \
    --wildcards \
    --wildcards-match-slash \
    '*/crowdsec/crowdsec_lapi/*'; then
    printf "\n"
    rm -f "$TMP_ARCHIVE"
    rm -rf "$TEMP_DIR"
    die "❌ Ошибка распаковки архива."
  fi

  # Копируем всё из временной папки (включая dot-файлы)
  printf "  ${CYAN}📋 Обновляю файлы...${NC}\n"
  shopt -s dotglob
  cp -r "$TEMP_DIR"/* . 2>/dev/null || true
  shopt -u dotglob

  chmod +x scripts/*.sh 2>/dev/null || true

  # Очистка
  rm -f "$TMP_ARCHIVE"
  rm -rf "$TEMP_DIR"

  printf "\n"
  log_info "  ✅ Готово"
  printf "\n"
  log_warn "  ⚠️  Не забудь скопировать шаблон:"
  printf "     ${CYAN}cp compose-example.yml compose.yml${NC}\n"
}

update_from_repo
