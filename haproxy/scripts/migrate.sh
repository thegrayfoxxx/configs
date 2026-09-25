#!/bin/bash
# Миграция sites.conf v1 -> v2 (волна 2).
# v2 обратно совместим: старые записи парсятся как раньше, добавляется только
# блок GLOBAL_OPTS со значениями = текущее поведение (выхлоп генерации не меняется).
# Использование: migrate.sh [--dry-run]  (--dry-run: показать результат, ничего не писать)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

if [ ! -f "$SITES_CONF" ]; then
  die "❌ sites.conf не найден: ${SITES_CONF}"
fi

WEB_SITES=()
REALITY_SITES=()
GLOBAL_OPTS=()
# shellcheck disable=SC1090
source "$SITES_CONF"

if [ "${#GLOBAL_OPTS[@]}" -gt 0 ]; then
  log_info "Уже v2 (блок GLOBAL_OPTS на месте) — мигрировать нечего"
  exit 0
fi

render_v2() {
  {
    echo "# HAProxy конфигурация (v2)"
    echo "# Мигрировано из v1: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "ACME_EMAIL=\"${ACME_EMAIL:-}\""
    echo ""
    echo "# Сайты (L7). Формат: \"домен:порт[:path=/prefix][:опции...]\""
    echo "# Одна запись на домен без path => поведение v1. Несколько записей"
    echo "# на домен: path-правила ставятся выше общего host-правила."
    echo "WEB_SITES=("
    printf '  "%s"\n' "${WEB_SITES[@]+"${WEB_SITES[@]}"}"
    echo ")"
    echo ""
    echo "# Reality (L4). Формат: \"домены:порт[:proxy=off|v1|v2]\"."
    echo "# Каждая запись => свой backend (порт и PROXY берутся из записи)."
    echo "REALITY_SITES=("
    printf '  "%s"\n' "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"
    echo ")"
    echo ""
    echo "# Глобальные опции (v2). Значения ниже = поведение v1."
    echo "# timeout_tunnel: пусто = не задавать. blackhole: deny|tarpit."
    echo "GLOBAL_OPTS=("
    echo '  "timeout_connect=5s"'
    echo '  "timeout_client=50s"'
    echo '  "timeout_server=50s"'
    echo '  "bind_stream=*:443"'
    echo '  "bind_web=*:8443"'
    echo '  "blackhole=deny"'
    echo ")"
  }
}

if [ "$DRY_RUN" = true ]; then
  render_v2
  exit 0
fi

printf "  Мигрировать %s в v2? [y/N]: " "$SITES_CONF"
read -r ans < /dev/tty
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
  log_info "Отмена"
  exit 0
fi

backup_now "pre-migrate" >/dev/null
render_v2 > "$SITES_CONF"
log_info "✅ Мигрировано (бэкап v1 — в .backup/). Проверь diff и перегенерируй конфиги (п.8 меню)."
