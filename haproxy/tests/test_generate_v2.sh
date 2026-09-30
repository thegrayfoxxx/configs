#!/bin/bash
# Golden-тест v2: multi-backend reality + path-split + опции.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites2.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
generate_configs > ${TEST_TMP:-/tmp}/golden-v2-log.txt 2>&1 || { printf "  FAIL: generate_configs упал\n"; cat ${TEST_TMP:-/tmp}/golden-v2-log.txt; exit 1; }

diff -u "$TDIR/fixtures/expected2-stream.cfg" "$TMP/stream/haproxy.cfg" \
  && printf "  ok: v2 stream.cfg совпал\n" \
  || { printf "  FAIL: v2 stream.cfg отличается\n"; fail=1; }

diff -u "$TDIR/fixtures/expected2-web.cfg" "$TMP/web/haproxy.cfg" \
  && printf "  ok: v2 web.cfg совпал\n" \
  || { printf "  FAIL: v2 web.cfg отличается\n"; fail=1; }

# Точечные инварианты v2 (ловят регрессии смысла, а не байтов)
grep -q 'bk_xray_2' "$TMP/stream/haproxy.cfg" \
  && grep -q 'send-proxy-v2' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: второй reality-backend со своим портом и PROXY\n" \
  || { printf "  FAIL: per-entry backend/PROXY\n"; fail=1; }

# path-правило выше общего host-правила того же домена
path_line=$(grep -n 'path_beg /data/' "$TMP/web/haproxy.cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)
gen_line=$(grep -n 'use_backend bk_site_x_example_com_8080' "$TMP/web/haproxy.cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)
[ -n "$path_line" ] && [ -n "$gen_line" ] && [ "$path_line" -lt "$gen_line" ] \
  && printf "  ok: path-правило выше общего\n" \
  || { printf "  FAIL: порядок path-правил\n"; fail=1; }

grep -q 'http-request tarpit' "$TMP/web/haproxy.cfg" \
  && printf "  ok: blackhole=tarpit применён\n" \
  || { printf "  FAIL: tarpit\n"; fail=1; }

exit "$fail"
