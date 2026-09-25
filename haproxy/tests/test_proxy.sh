#!/bin/bash
# Тесты волны 3: golden PROXY/deny_status/check + негативные parity-проверки.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

mktmp() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/stream" "$tmp/web" "$tmp/custom"
  printf "%s" "$tmp"
}

# --- golden3: полный diff ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites3.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$TDIR/../scripts/lib/common.sh"
  generate_configs > /tmp/proxy-golden-log.txt 2>&1 || { printf "  FAIL: generate упал на sites3\n"; cat /tmp/proxy-golden-log.txt; exit 1; }
  diff -u "$TDIR/fixtures/expected3-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: wave3 stream совпал\n" \
    || { printf "  FAIL: wave3 stream отличается\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected3-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: wave3 web совпал\n" \
    || { printf "  FAIL: wave3 web отличается\n"; fail=1; }
  grep -q 'accept-proxy' "$TMP/web/haproxy.cfg" \
    && printf "  ok: accept-proxy на bind\n" \
    || { printf "  FAIL: нет accept-proxy\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- parity: web ждёт, stream не шлёт -> варнинг ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_SITES=("a.com:8080")
REALITY_SITES=("b.com:10443")
GLOBAL_OPTS=("web_accept_proxy=on")
EOF
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$TDIR/../scripts/lib/common.sh"
  out=$(generate_configs 2>&1)
  echo "$out" | grep -q 'рассинхрон' \
    && printf "  ok: варнинг desync web-ждёт/stream-молчит\n" \
    || { printf "  FAIL: нет варнинга desync\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- parity: stream шлёт, web не читает -> варнинг ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_SITES=("a.com:8080")
REALITY_SITES=("b.com:10443")
GLOBAL_OPTS=("stream_web_proxy=v2")
EOF
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$TDIR/../scripts/lib/common.sh"
  out=$(generate_configs 2>&1)
  echo "$out" | grep -q 'рассинхрон' \
    && printf "  ok: варнинг desync stream-шлёт/web-глух\n" \
    || { printf "  FAIL: нет варнинга desync\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- parity: битое значение -> генерация падает ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_SITES=("a.com:8080")
REALITY_SITES=("b.com:10443")
GLOBAL_OPTS=("stream_web_proxy=bogus")
EOF
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$TDIR/../scripts/lib/common.sh"
  if generate_configs >/dev/null 2>&1; then
    printf "  FAIL: битый proxy прошёл генерацию\n"
    fail=1
  else
    printf "  ok: битый proxy роняет генерацию\n"
  fi
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

exit "$fail"
