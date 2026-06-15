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
    '*/crowdsec/crowdsec_lapi/compose-example.yml' \
    '*/crowdsec/crowdsec_lapi/.env.example' \
    '*/crowdsec/crowdsec_lapi/config/*' \
    '*/crowdsec/crowdsec_lapi/scripts/*'; then
    printf "\n"
    rm -f "$TMP_ARCHIVE"
    rm -rf "$TEMP_DIR"
    die "❌ Ошибка распаковки архива."
  fi
  # scripts/lib/ может отсутствовать в старых архивах — не фатально
  tar xzf "$TMP_ARCHIVE" -C "$TEMP_DIR" \
    --strip=3 \
    --wildcards \
    '*/crowdsec/crowdsec_lapi/scripts/lib/*' 2>/dev/null || true

  # Копируем (не перезаписывая существующие файлы)
  printf "  ${CYAN}📋 Обновляю файлы...${NC}\n"
  cp -n "$TEMP_DIR"/compose-example.yml . 2>/dev/null || true
  cp -n "$TEMP_DIR"/.env.example . 2>/dev/null || true
  cp -r "$TEMP_DIR"/config/* config/ 2>/dev/null || true
  cp -r "$TEMP_DIR"/scripts/* scripts/ 2>/dev/null || true

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
