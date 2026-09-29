#!/bin/bash
# Тест миграции v1/v2 -> v3 (dry-run, ничего не пишет) + e2e эквивалентность.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v1.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
fail=0

out=$(bash "$TDIR/../scripts/migrate.sh" --dry-run 2>/dev/null) || { printf "  FAIL: migrate --dry-run упал\n"; exit 1; }

echo "$out" | grep -q 'STREAM_ROUTES=(' \
  && printf "  ok: блок STREAM_ROUTES добавлен\n" \
  || { printf "  FAIL: нет STREAM_ROUTES\n"; fail=1; }

echo "$out" | grep -q 'WEB_ROUTES=(' \
  && printf "  ok: блок WEB_ROUTES добавлен\n" \
  || { printf "  FAIL: нет WEB_ROUTES\n"; fail=1; }

echo "$out" | grep -q '"host=site1.com to=127.0.0.1:11443"' \
  && printf "  ok: web-запись сконвертирована\n" \
  || { printf "  FAIL: web-запись потеряна\n%s\n" "$out"; fail=1; }

echo "$out" | grep -q '"sni=www.google.com google.com to=127.0.0.1:10443' \
  && printf "  ok: stream-запись сконвертирована\n" \
  || { printf "  FAIL: stream-запись потеряна\n%s\n" "$out"; fail=1; }

echo "$out" | grep -q '"sni=default to=' \
  && printf "  ok: явный default дописан\n" \
  || { printf "  FAIL: нет явного default\n"; fail=1; }

echo "$out" | grep -q '"blackhole=deny"' \
  && printf "  ok: дефолты = поведение v1\n" \
  || { printf "  FAIL: дефолты не v1\n"; fail=1; }

echo "$out" | grep -qi 'reality_sites\|web_sites=(' \
  && { printf "  FAIL: в выводе остались legacy-массивы\n"; fail=1; } \
  || printf "  ok: legacy-массивов в выводе нет\n"

# dry-run не должен ничего писать
[ ! -d "$TMP/.backup" ] \
  && printf "  ok: dry-run ничего не пишет\n" \
  || { printf "  FAIL: dry-run создал бэкап\n"; fail=1; }

# e2e: мигрированный файл генерирует рабочие конфиги с той же семантикой
printf "%s\n" "$out" > "$TMP/sites.conf"
# shellcheck disable=SC1091
source "$PROJ/scripts/lib/common.sh"
generate_configs > ${TEST_TMP:-/tmp}/migrate-e2e-log.txt 2>&1 || { printf "  FAIL: generate после миграции\n"; cat ${TEST_TMP:-/tmp}/migrate-e2e-log.txt; fail=1; }
grep -q 'req.ssl_sni -i www.google.com google.com' "$TMP/stream/haproxy.cfg" \
  && grep -q 'server sni-1 127.0.0.1:10443' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: e2e stream сохранил семантику v1\n" \
  || { printf "  FAIL: e2e stream отличается\n"; fail=1; }
grep -q 'server site_site1_com 127.0.0.1:11443' "$TMP/web/haproxy.cfg" \
  && printf "  ok: e2e web сохранил семантику v1\n" \
  || { printf "  FAIL: e2e web отличается\n"; fail=1; }

exit "$fail"
