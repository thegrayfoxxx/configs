#!/bin/bash
# Golden-тест BACKENDS-сущности (stream): shared-ящик, инлайн рядом, default ссылкой.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v5be.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
generate_configs > ${TEST_TMP:-/tmp}/golden-5be-log.txt 2>&1 || { printf "  FAIL: generate_configs упал\n"; cat ${TEST_TMP:-/tmp}/golden-5be-log.txt; exit 1; }

diff -u "$TDIR/fixtures/expected5be-stream.cfg" "$TMP/stream/haproxy.cfg" \
  && printf "  ok: 5be stream.cfg совпал с эталоном\n" \
  || { printf "  FAIL: 5be stream.cfg отличается\n"; fail=1; }

diff -u "$TDIR/fixtures/expected5be-web.cfg" "$TMP/web/haproxy.cfg" \
  && printf "  ok: 5be web.cfg совпал с эталоном\n" \
  || { printf "  FAIL: 5be web.cfg отличается\n"; fail=1; }

# Один ящик на два маршрута — секция ровно одна.
[ "$(grep -c '^backend bk_shared-be' "$TMP/stream/haproxy.cfg")" = "1" ] \
  && grep -q 'use_backend bk_shared-be if is_s_1' "$TMP/stream/haproxy.cfg" \
  && grep -q 'use_backend bk_shared-be if is_s_2' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: shared-ящик один на два маршрута\n" \
  || { printf "  FAIL: shared-ящик\n"; fail=1; }

# Флаги ящика (log=off) применены.
grep -A3 '^backend bk_shared-be' "$TMP/stream/haproxy.cfg" | grep -q 'no log' \
  && printf "  ok: флаги ящика применены\n" \
  || { printf "  FAIL: флаги ящика\n"; fail=1; }

# Инлайн-маршрут рядом не пострадал.
grep -q 'server sni-3 127.0.0.1:10444 send-proxy-v2' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: инлайн рядом с use= работает\n" \
  || { printf "  FAIL: инлайн\n"; fail=1; }

# Web: один ящик на два хоста — секция одна, ACL уникальны (без затирания!).
[ "$(grep -c '^backend bk_app' "$TMP/web/haproxy.cfg")" = "1" ] \
  && grep -q 'use_backend bk_app if host_app$' "$TMP/web/haproxy.cfg" \
  && grep -q 'use_backend bk_app if host_app_2$' "$TMP/web/haproxy.cfg" \
  && printf "  ok: web shared-ящик один, ACL уникальны\n" \
  || { printf "  FAIL: web shared-ящик/ACL\n"; fail=1; }

# Флаг ящика и инлайн рядом.
grep -A3 '^backend bk_app' "$TMP/web/haproxy.cfg" | grep -q 'no log' \
  && grep -q 'server site_plain_example_com 127.0.0.1:8080' "$TMP/web/haproxy.cfg" \
  && printf "  ok: web флаги ящика + инлайн рядом\n" \
  || { printf "  FAIL: web флаги/инлайн\n"; fail=1; }

# --- Fail-closed ---
# Коллизия: инлайн-имя занято ящиком.
STREAM_ROUTES=(
  'sni=a.com to=127.0.0.1:1 name=clash'
  'sni=default to=127.0.0.1:8443 name=web'
)
STREAM_BACKENDS=('name=clash to=127.0.0.1:2')
STREAM_FRONTENDS=()
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: коллизия имён не уронила генерацию\n"; fail=1
else
  printf "  ok: коллизия имён роняет генерацию\n"
fi

exit "$fail"
