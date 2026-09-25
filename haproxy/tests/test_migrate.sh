#!/bin/bash
# Тест миграции v1 -> v2 (dry-run, ничего не пишет).
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v1.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
fail=0

out=$(bash "$TDIR/../scripts/migrate.sh" --dry-run 2>/dev/null) || { printf "  FAIL: migrate --dry-run упал\n"; exit 1; }

echo "$out" | grep -q 'GLOBAL_OPTS=(' \
  && printf "  ok: блок GLOBAL_OPTS добавлен\n" \
  || { printf "  FAIL: нет GLOBAL_OPTS\n"; fail=1; }

echo "$out" | grep -q '"site1.com:11443"' \
  && echo "$out" | grep -q '"www.google.com google.com:10443"' \
  && printf "  ok: массивы перенесены как есть\n" \
  || { printf "  FAIL: массивы потеряны\n"; fail=1; }

echo "$out" | grep -q '"blackhole=deny"' \
  && printf "  ok: дефолты = поведение v1\n" \
  || { printf "  FAIL: дефолты не v1\n"; fail=1; }

# dry-run не должен ничего писать
[ ! -d "$TMP/.backup" ] \
  && printf "  ok: dry-run ничего не пишет\n" \
  || { printf "  FAIL: dry-run создал бэкап\n"; fail=1; }

exit "$fail"
