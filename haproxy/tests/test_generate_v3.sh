#!/bin/bash
# Golden-тест v3: нейтральные STREAM_ROUTES/WEB_ROUTES + явный sni=default.
# Герметичен: временная копия, docker/haproxy не нужны.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v3.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
generate_configs > ${TEST_TMP:-/tmp}/golden-v3-log.txt 2>&1 || { printf "  FAIL: generate_configs упал\n"; cat ${TEST_TMP:-/tmp}/golden-v3-log.txt; exit 1; }

diff -u "$TDIR/fixtures/expected3v-stream.cfg" "$TMP/stream/haproxy.cfg" \
  && printf "  ok: v3 stream.cfg совпал с эталоном\n" \
  || { printf "  FAIL: v3 stream.cfg отличается\n"; fail=1; }

diff -u "$TDIR/fixtures/expected3v-web.cfg" "$TMP/web/haproxy.cfg" \
  && printf "  ok: v3 web.cfg совпал с эталоном\n" \
  || { printf "  FAIL: v3 web.cfg отличается\n"; fail=1; }

# Ядро не знает слов reality/xray: их нет в сгенерированном stream-конфиге.
if grep -qi 'reality\|xray' "$TMP/stream/haproxy.cfg"; then
  printf "  FAIL: в stream-конфиге осталась reality-специфика\n"; fail=1
else
  printf "  ok: stream-конфиг без reality-специфики\n"
fi

# Дефолт явный: ровно одна default_backend запись на bk_web.
grep -q 'default_backend bk_web' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: явный default_backend bk_web\n" \
  || { printf "  FAIL: нет явного default\n"; fail=1; }

# PROXY per-entry работает в нейтральной модели.
grep -q 'send-proxy-v2' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: per-entry proxy=v2 применён\n" \
  || { printf "  FAIL: per-entry proxy потерян\n"; fail=1; }

# path-правило выше общего host-правила того же домена.
path_line=$(grep -n 'path_beg /data/' "$TMP/web/haproxy.cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)
gen_line=$(grep -n 'use_backend bk_site_x_example_com_8080' "$TMP/web/haproxy.cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)
[ -n "$path_line" ] && [ -n "$gen_line" ] && [ "$path_line" -lt "$gen_line" ] \
  && printf "  ok: path-правило выше общего\n" \
  || { printf "  FAIL: порядок path-правил\n"; fail=1; }

# --- Fail-closed: битые v3-записи роняют генерацию, живые файлы не тронуты ---
cp "$TMP/stream/haproxy.cfg" ${TEST_TMP:-/tmp}/golden-v3-stream-live.cfg
cp "$TMP/web/haproxy.cfg" ${TEST_TMP:-/tmp}/golden-v3-web-live.cfg

# 1. Нет sni=default.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 proxy=off name=sni-1')
WEB_ROUTES=('host=a.com to=127.0.0.1:8080')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: генерация без default не упала\n"; fail=1
else
  printf "  ok: без sni=default генерация падает\n"
fi

# 2. Битый proxy.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 proxy=v9 name=sni-1' 'sni=default to=127.0.0.1:8443 proxy=off name=web')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: битый proxy не уронил генерацию\n"; fail=1
else
  printf "  ok: битый proxy роняет генерацию\n"
fi

# 3. Неизвестный ключ.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 foo=bar' 'sni=default to=127.0.0.1:8443 proxy=off name=web')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: неизвестный ключ не уронил генерацию\n"; fail=1
else
  printf "  ok: неизвестный ключ роняет генерацию\n"
fi

# 4. Маршрут без явного sni=.
STREAM_ROUTES=('a.com to=127.0.0.1:10443' 'sni=default to=127.0.0.1:8443 proxy=off name=web')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: маршрут без sni= не уронил генерацию\n"; fail=1
else
  printf "  ok: маршрут без sni= роняет генерацию\n"
fi

# --- Конвертер legacy -> v3 ---
WEB_SITES=('site1.com:11443')
REALITY_SITES=('www.google.com google.com:10443')
conv=$(convert_legacy_to_v3)
echo "$conv" | grep -q 'sni=default to=127.0.0.1:8443' \
  && printf "  ok: конвертер дописывает явный default\n" \
  || { printf "  FAIL: конвертер без default\n"; fail=1; }
echo "$conv" | grep -q 'host=site1.com to=127.0.0.1:11443' \
  && printf "  ok: конвертер маппит web-записи\n" \
  || { printf "  FAIL: конвертер потерял web\n"; fail=1; }
echo "$conv" | grep -qi 'reality\|xray' \
  && { printf "  FAIL: конвертер тащит reality-лексику\n"; fail=1; } \
  || printf "  ok: конвертер без reality-лексики\n"

# --- log=off: тишина точечно на маршрут ---
STREAM_ROUTES=(
  'sni=noisy.example.com to=127.0.0.1:11999 proxy=off name=noisy log=off'
  'sni=default to=127.0.0.1:8443 proxy=off name=web'
)
out=$(generate_stream_v3) || { printf "  FAIL: generate с log=off упал\n"; fail=1; }
echo "$out" | grep -A3 '^backend bk_noisy' | grep -q 'no log' \
  && printf "  ok: stream log=off даёт no log в своём backend\n" \
  || { printf "  FAIL: нет no log в bk_noisy\n"; fail=1; }
echo "$out" | grep -A3 '^backend bk_web' | grep -q 'no log' \
  && { printf "  FAIL: no log протёк в соседний backend\n"; fail=1; } \
  || printf "  ok: соседний backend без no log\n"

WEB_ROUTES=(
  'host=quiet.example.com to=127.0.0.1:11888 log=off'
  'host=loud.example.com to=127.0.0.1:11889'
)
out=$(generate_web_v3) || { printf "  FAIL: web-generate с log=off упал\n"; fail=1; }
echo "$out" | grep -A4 '^backend bk_site_quiet_example_com' | grep -q 'no log' \
  && printf "  ok: web log=off даёт no log в своём backend\n" \
  || { printf "  FAIL: нет no log в quiet-backend\n"; fail=1; }
echo "$out" | grep -A4 '^backend bk_site_loud_example_com' | grep -q 'no log' \
  && { printf "  FAIL: no log протёк в loud-backend\n"; fail=1; } \
  || printf "  ok: loud-backend без no log\n"

# Один backend на два маршрута (path + общий): тишина только если оба off.
WEB_ROUTES=(
  'host=mix.example.com to=127.0.0.1:11777 path=/data/ log=off'
  'host=mix.example.com to=127.0.0.1:11777'
)
out=$(generate_web_v3) || { printf "  FAIL: web-generate mix упал\n"; fail=1; }
echo "$out" | grep -A4 '^backend bk_site_mix_example_com_11777' | grep -q 'no log' \
  && { printf "  FAIL: тихий path заглушил общий хост\n"; fail=1; } \
  || printf "  ok: общий backend не глушится одним тихим path\n"

# Битое значение log роняет генерацию.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 log=maybe' 'sni=default to=127.0.0.1:8443 proxy=off name=web')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: битый log не уронил генерацию\n"; fail=1
else
  printf "  ok: битый log роняет генерацию\n"
fi

# Живые файлы не тронуты всеми fail-кейсами выше (генерация пишет через tmp+mv).
diff -q ${TEST_TMP:-/tmp}/golden-v3-stream-live.cfg "$TMP/stream/haproxy.cfg" >/dev/null \
  && diff -q ${TEST_TMP:-/tmp}/golden-v3-web-live.cfg "$TMP/web/haproxy.cfg" >/dev/null \
  && printf "  ok: живые файлы не тронуты fail-кейсами\n" \
  || { printf "  FAIL: живые файлы изменились\n"; fail=1; }

exit "$fail"
