#!/bin/bash
# Миграция sites.conf v1/v2 -> v3 (нейтральные STREAM_ROUTES/WEB_ROUTES + явный default).
# Семантика сохраняется: SNI/port/PROXY/path маппятся 1:1, дефолт stream->web
# дописывается явно из bind_web. Сгенерированные haproxy.cfg эквивалентны.
# Использование: migrate.sh [--dry-run]  (--dry-run: показать результат, ничего не писать)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

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
STREAM_ROUTES=()
WEB_ROUTES=()
# shellcheck disable=SC1090
source "$SITES_CONF"

if [ "${#STREAM_ROUTES[@]}" -gt 0 ] || [ "${#WEB_ROUTES[@]}" -gt 0 ]; then
  log_info "Уже v3 (блоки STREAM_ROUTES/WEB_ROUTES на месте) — мигрировать нечего"
  exit 0
fi

# Дефолты GLOBAL_OPTS = поведение v1 (как migrate v1->v2).
if [ "${#GLOBAL_OPTS[@]}" -eq 0 ]; then
  GLOBAL_OPTS=(
    "timeout_connect=5s"
    "timeout_client=50s"
    "timeout_server=50s"
    "bind_stream=*:443"
    "bind_web=*:8443"
    "blackhole=deny"
  )
fi

legacy_to_v3_arrays

render_v3() {
  {
    echo "# HAProxy конфигурация (v3)"
    echo "# Мигрировано из v1/v2: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "ACME_EMAIL=\"${ACME_EMAIL:-}\""
    echo ""
    echo "# Stream-маршруты (L4, SNI -> backend). Одна запись sni=default обязательна."
    echo "# Формат: \"sni=<домены|default> to=<host:порт>|use=<ящик>[ proxy=off|v1|v2][ name=<метка>][ log=on|off][ frontend=<имя>]\""
    echo "STREAM_ROUTES=("
    printf '  "%s"\n' "${STREAM_ROUTES[@]}"
    echo ")"
    echo ""
    echo "# Web-маршруты (L7, Host -> backend за терминацией)."
    echo "# Формат: \"host=<домен> to=<host:порт>|use=<ящик>[ path=/prefix][ name=<метка>][ log=on|off][ frontend=<имя>]\""
    echo "WEB_ROUTES=("
    if [ "${#WEB_ROUTES[@]}" -gt 0 ]; then
      printf '  "%s"\n' "${WEB_ROUTES[@]}"
    fi
    echo ")"
    echo ""
    echo "# Глобальные опции"
    echo "GLOBAL_OPTS=("
    printf '  "%s"\n' "${GLOBAL_OPTS[@]}"
    echo ")"
  }
}

if [ "$DRY_RUN" = true ]; then
  render_v3
  exit 0
fi

printf "  Мигрировать %s в v3? [y/N]: " "$SITES_CONF"
read -r ans < /dev/tty
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
  log_info "Отмена"
  exit 0
fi

backup_now "pre-migrate-v3" >/dev/null
render_v3 > "$SITES_CONF"
log_info "✅ Мигрировано в v3 (бэкап — в .backup/). Проверь diff и перегенерируй конфиги (раздел 6 меню)."
