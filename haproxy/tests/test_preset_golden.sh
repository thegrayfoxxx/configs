#!/bin/bash
# Golden-тесты новых пресетных топологий + global.sh.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

mktmp() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/stream" "$tmp/web" "$tmp/custom"
  printf "%s" "$tmp"
}

# --- golden web-direct sites (stream.cfg — неиспользуемый legacy-дефолт) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-web-direct.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-web-log.txt 2>&1 || { printf "  FAIL: generate web-direct\n"; cat ${TEST_TMP:-/tmp}/golden6-web-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-web-direct-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden6 web-direct stream совпал\n" \
    || { printf "  FAIL: golden6 web-direct stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-web-direct-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 web-direct web совпал\n" \
    || { printf "  FAIL: golden6 web-direct web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden stream selfsteal+xhttp (прод-схема) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-stream-selfsteal.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-sv-log.txt 2>&1 || { printf "  FAIL: generate selfsteal\n"; cat ${TEST_TMP:-/tmp}/golden6-sv-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-selfsteal-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden6 selfsteal stream совпал\n" \
    || { printf "  FAIL: golden6 selfsteal stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-selfsteal-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 selfsteal web совпал\n" \
    || { printf "  FAIL: golden6 selfsteal web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden xray-direct (web-таргет с accept-proxy при xver) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-xray-direct.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-xray-log.txt 2>&1 || { printf "  FAIL: generate xray-direct\n"; cat ${TEST_TMP:-/tmp}/golden6-xray-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-xray-direct-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden6 xray-direct stream совпал\n" \
    || { printf "  FAIL: golden6 xray-direct stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-xray-direct-web.cfg" "$TMP/web/haproxy.cfg" \
    && grep -q 'accept-proxy' "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 xray-direct web совпал (accept-proxy)\n" \
    || { printf "  FAIL: golden6 xray-direct web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden web-direct xhttp-split (forwardfor, без стрима) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-web-xhttp.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-webxhttp-log.txt 2>&1 || { printf "  FAIL: generate web-xhttp\n"; cat ${TEST_TMP:-/tmp}/golden6-webxhttp-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-web-xhttp-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden6 web-xhttp stream совпал\n" \
    || { printf "  FAIL: golden6 web-xhttp stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-web-xhttp-web.cfg" "$TMP/web/haproxy.cfg" \
    && grep -q 'option forwardfor' "$TMP/web/haproxy.cfg" \
    && ! grep -q 'accept-proxy' "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 web-xhttp web совпал (forwardfor, без proxy)\n" \
    || { printf "  FAIL: golden6 web-xhttp web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden stream-vision sites (vision отдельно, web список) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-stream-sites.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-svsites-log.txt 2>&1 || { printf "  FAIL: generate stream-sites\n"; cat ${TEST_TMP:-/tmp}/golden6-svsites-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-sites-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden6 stream-sites stream совпал\n" \
    || { printf "  FAIL: golden6 stream-sites stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-sites-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 stream-sites web совпал\n" \
    || { printf "  FAIL: golden6 stream-sites web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden stream-vision transit (edge + accept-proxy ухо, маршруты в обоих) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-stream-transit.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-transit-log.txt 2>&1 || { printf "  FAIL: generate transit\n"; cat ${TEST_TMP:-/tmp}/golden6-transit-log.txt; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-transit-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && grep -q 'bind \*:4443 accept-proxy' "$TMP/stream/haproxy.cfg" \
    && grep -q '^frontend ft_edge' "$TMP/stream/haproxy.cfg" \
    && [ "$(grep -c 'use_backend bk_xray' "$TMP/stream/haproxy.cfg")" = "2" ] \
    && printf "  ok: golden6 transit совпал (маршруты в обоих ушах)\n" \
    || { printf "  FAIL: golden6 transit\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected6-stream-transit-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden6 transit web совпал\n" \
    || { printf "  FAIL: golden6 transit web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- check-send-proxy: чеки в PROXY-цель идут с PROXY ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
STREAM_BACKENDS=(
  "name=xray to=127.0.0.1:10443 proxy=v2"
  "name=plain to=127.0.0.1:10444"
)
STREAM_ROUTES=(
  "sni=a.com use=xray"
  "sni=b.com use=plain"
  "sni=default to=127.0.0.1:8443 proxy=off name=web"
)
WEB_ROUTES=(
  "host=a.com to=127.0.0.1:8080"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_stream=*:443"
  "bind_web=127.0.0.1:8443"
  "blackhole=deny"
  "backend_check=tcp"
)
EOF
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/golden6-chkproxy-log.txt 2>&1 || { printf "  FAIL: generate check-proxy\n"; cat ${TEST_TMP:-/tmp}/golden6-chkproxy-log.txt; fail=1; }
  grep -q 'server xray 127.0.0.1:10443 send-proxy-v2 check .* check-send-proxy' "$TMP/stream/haproxy.cfg" \
    && grep -q 'server plain 127.0.0.1:10444 check inter' "$TMP/stream/haproxy.cfg" \
    && ! grep -q 'server plain .*check-send-proxy' "$TMP/stream/haproxy.cfg" \
    && printf "  ok: check-send-proxy только в PROXY-цель\n" \
    || { printf "  FAIL: check-send-proxy\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- global.sh --set/--show ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_ROUTES=(
  "host=a.com to=127.0.0.1:8080"
)
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:8443 proxy=off name=web"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_stream=*:443"
  "bind_web=*:8443"
  "blackhole=deny"
)
EOF
  HAPROXY_DIR_OVERRIDE="$TMP" bash "$PROJ/scripts/commands/global.sh" --set timeout_client=1h --set timeout_tunnel=1h >/dev/null 2>&1 \
    || { printf "  FAIL: global --set упал\n"; fail=1; }
  grep -q '"timeout_client=1h"' "$TMP/sites.conf" \
    && grep -q '"timeout_tunnel=1h"' "$TMP/sites.conf" \
    && printf "  ok: global --set пишет опции\n" \
    || { printf "  FAIL: global --set не записал\n"; fail=1; }
  HAPROXY_DIR_OVERRIDE="$TMP" bash "$PROJ/scripts/commands/global.sh" --show 2>/dev/null | grep -q 'timeout_client=1h' \
    && printf "  ok: global --show читает опции\n" \
    || { printf "  FAIL: global --show\n"; fail=1; }
  grep -q 'timeout tunnel 1h' "$TMP/web/haproxy.cfg" \
    && printf "  ok: global --set перегенерировал конфиги\n" \
    || { printf "  FAIL: конфиги не перегенерированы\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

exit "$fail"
