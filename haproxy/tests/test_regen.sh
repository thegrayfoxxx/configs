#!/bin/bash
# regen: коды preview (0 чисто / 1 diff / 2 ошибка) + детектор сноса SNI.
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

# --- preview rc: чисто = 0 ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-web-direct.conf" "$TMP/sites.conf"
  cp "$TDIR/fixtures/expected6-web-direct-stream.cfg" "$TMP/stream/haproxy.cfg"
  cp "$TDIR/fixtures/expected6-web-direct-web.cfg" "$TMP/web/haproxy.cfg"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  rc=0; preview_configs >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    && printf "  ok: preview чисто = 0\n" \
    || { printf "  FAIL: preview чисто не 0\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- preview rc: оба файла различаются = 1 (не 2!), битый sites = 2 ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites6-web-direct.conf" "$TMP/sites.conf"
  printf 'bogus' > "$TMP/stream/haproxy.cfg"
  printf 'bogus' > "$TMP/web/haproxy.cfg"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  rc=0; preview_configs >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] \
    && printf "  ok: preview diff обоих = 1\n" \
    || { printf "  FAIL: preview diff обоих не 1\n"; fail=1; }
  printf 'STREAM_ROUTES=( "sni=a.com to=127.0.0.1' > "$TMP/sites.conf"
  rc=0; preview_configs >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] \
    && printf "  ok: preview битый sites = 2\n" \
    || { printf "  FAIL: preview битый sites не 2\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- regen со сносом SNI: без ДА не применяет, с ДА применяет ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_BACKENDS=(
  "name=stub to=127.0.0.1:8080"
)
WEB_ROUTES=(
  "host=a.com use=stub"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_web=127.0.0.1:8443"
  "blackhole=deny"
)
EOF
  cp "$TDIR/fixtures/expected6-stream-selfsteal-stream.cfg" "$TMP/stream/haproxy.cfg"
  cp "$TDIR/fixtures/expected6-stream-selfsteal-web.cfg" "$TMP/web/haproxy.cfg"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  printf 'n\n\n' > "$TMP/tty-no"
  printf 'ДА\ny\n\n' > "$TMP/tty-yes"
  export MENU_TTY="$TMP/tty-no"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/ui/menu.sh"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/ui/regen.sh"
  cmd_regen > "$TMP/r1.log" 2>&1 || true
  grep -q 'ВНИМАНИЕ' "$TMP/r1.log" \
    && grep -q 'is_s_1' "$TMP/stream/haproxy.cfg" \
    && printf "  ok: снос без ДА отклонен, живые целы\n" \
    || { printf "  FAIL: снос без ДА\n"; fail=1; }
  printf 'ДА\ny\ny\n\n' > "$TMP/tty-yes"
  export MENU_TTY="$TMP/tty-yes"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh" # переоткрыть FD на новый файл (FD живет в common.sh)
  # shellcheck disable=SC1091
  source "$PROJ/scripts/ui/menu.sh"
  cmd_regen > "$TMP/r2.log" 2>&1 || true
  ! grep -q 'is_s_1' "$TMP/stream/haproxy.cfg" \
    && printf "  ok: снос с ДА применен\n" \
    || { printf "  FAIL: снос с ДА не применен\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

exit "$fail"
