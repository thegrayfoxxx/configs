#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

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
    --strip=2 \
    --wildcards \
    --wildcards-match-slash \
    '*/haproxy/*'; then
    die "❌ Ошибка распаковки архива."
  fi

  printf "  ${CYAN}📋 Обновляю файлы...${NC}\n"
  # Бэкап всего haproxy/ до перезаписи (кроме самого .backup)
  backup_now "pre-update" >/dev/null
  # Allowlist: обновляем только код/шаблоны/доки. Никогда не трогаем
  # локальное состояние: sites.conf, .enabled_services, .backup/,
  # живые stream/web/haproxy.cfg, web/certs/, custom/*.cfg.
  local item
  for item in haproxy.sh compose.yml README.md MIGRATION.md sites.conf.example; do
    [ -e "$TEMP_DIR/$item" ] && cp -f "$TEMP_DIR/$item" "./$item"
  done
  for item in scripts presets tests stream/haproxy.cfg.example web/haproxy.cfg.example; do
    if [ -e "$TEMP_DIR/$item" ]; then
      mkdir -p "./$(dirname "$item")"
      rm -rf "./$item"
      cp -r "$TEMP_DIR/$item" "./$item"
    fi
  done

  chmod +x scripts/*.sh scripts/commands/*.sh scripts/ui/*.sh 2>/dev/null || true
  chmod +x haproxy.sh 2>/dev/null || true

  printf "\n"
  log_info "  ✅ Готово"
  printf "\n"
  log_warn "  ⚠️  Если менялся compose.yml (например, политика рестарта) — один раз:"
  printf "     ${CYAN}docker compose up -d (через раздел 5, с нужными профилями)${NC}\n"
  printf "\n"
  log_warn "  ⚠️  Не забудь создать sites.conf, если его нет:"
  printf "     ${CYAN}cp sites.conf.example sites.conf${NC}\n"
}

update_from_repo
