#!/bin/bash
# global.sh: интерактив через MENU_TTY (общий FD, без зацикливания) + --set/--show.
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

# --- интерактив: 1 (таймауты) -> 2 (профиль xhttp-1h) -> n (без рестарта) -> пауза -> 0 ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
STREAM_ROUTES=(
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
  "bind_web=*:8443"
  "blackhole=deny"
)
EOF
  printf '1\n2\ny\nn\n\n0\n' > "$TMP/tty-in"
  timeout 25 bash -c 'MENU_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" bash "$2/scripts/commands/global.sh" > "$1/session.log" 2>&1' _ "$TMP" "$PROJ" \
    || { printf "  FAIL: global интерактив завис/упал\n"; fail=1; }
  grep -q '"timeout_client=1h"' "$TMP/sites.conf" \
    && grep -q '"timeout_tunnel=1h"' "$TMP/sites.conf" \
    && grep -q 'timeout tunnel 1h' "$TMP/web/haproxy.cfg" \
    && printf "  ok: интерактив применил профиль и перегенерировал\n" \
    || { printf "  FAIL: интерактив не применил профиль\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

exit "$fail"
