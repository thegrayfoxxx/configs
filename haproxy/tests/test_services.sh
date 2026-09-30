#!/bin/bash
# Юнит-тест сервисов: enable/disable roundtrip на временном .enabled_services.
# Docker не нужен (svc_running не дёргаем).
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0

[ "$(svc_load_enabled)" = "stream web acme" ] \
  && printf "  ok: дефолт включённых = все три\n" \
  || { printf "  FAIL: дефолт не stream web acme, а '%s'\n" "$(svc_load_enabled)"; fail=1; }

svc_disable web
svc_is_enabled web \
  && { printf "  FAIL: web остался включён после disable\n"; fail=1; } \
  || printf "  ok: disable web работает\n"

svc_is_enabled stream && svc_is_enabled acme \
  && printf "  ok: остальные не тронуты\n" \
  || { printf "  FAIL: disable web задел соседей\n"; fail=1; }

svc_enable web
svc_is_enabled web \
  && printf "  ok: enable web работает\n" \
  || { printf "  FAIL: enable не вернул web\n"; fail=1; }

[ "$(svc_container stream)" = "haproxy-stream" ] \
  && [ "$(svc_container web)" = "haproxy-web" ] \
  && [ "$(svc_container acme)" = "acme" ] \
  && printf "  ok: маппинг имён контейнеров\n" \
  || { printf "  FAIL: маппинг имён\n"; fail=1; }

exit "$fail"
