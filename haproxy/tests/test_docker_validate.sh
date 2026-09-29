#!/bin/bash
# validate_cfg через docker exec (стаб docker): выбор контейнера, reject битого,
# fallback без контейнеров. Без HAPROXY_NO_VALIDATE (проверяем настоящий путь).
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/stream" "$TMP/web" "$TMP/custom"

# Стаб docker: ps показывает оба haproxy; haproxy -c падает при VALIDATE_FAIL=1.
cat > "$TMP/bin/docker" << 'EOF'
#!/bin/bash
echo "CALL: $*" >> "${STUB_LOG:?}/calls.log"
case "$1" in
  info) exit 0 ;;
  ps) printf 'haproxy-stream\nhaproxy-web\nacme\n' ;;
  cp) exit 0 ;;
  exec)
    shift
    [ "$1" = "rm" ] && exit 0
    [ "${VALIDATE_FAIL:-0}" = "1" ] && exit 1 || exit 0
    ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export STUB_LOG="$TMP"

run_v() {
  PATH="$TMP/bin:$PATH" \
    bash -c 'source "$0/scripts/lib/common.sh" >/dev/null 2>&1; validate_cfg "$1" "$2" >/dev/null 2>&1' "$PROJ" "$1" "$2"
}

# web-файл едет в haproxy-web, stream — в haproxy-stream.
HAPROXY_NO_VALIDATE= run_v "$TDIR/fixtures/expected6-web-direct-web.cfg" "haproxy-web" \
  && grep -q "cp .* haproxy-web:/tmp/haproxy-validate.cfg" "$TMP/calls.log" \
  && printf "  ok: web проверяется в haproxy-web\n" \
  || { printf "  FAIL: выбор контейнера web\n"; fail=1; }
: > "$TMP/calls.log"
HAPROXY_NO_VALIDATE= run_v "$TDIR/fixtures/expected6-web-direct-stream.cfg" "haproxy-stream" \
  && grep -q "cp .* haproxy-stream:/tmp/haproxy-validate.cfg" "$TMP/calls.log" \
  && printf "  ok: stream проверяется в haproxy-stream\n" \
  || { printf "  FAIL: выбор контейнера stream\n"; fail=1; }

# Битый конфиг (по версии контейнера) отклоняется.
VALIDATE_FAIL=1 HAPROXY_NO_VALIDATE= run_v "$TDIR/fixtures/expected6-web-direct-web.cfg" "haproxy-web" \
  && { printf "  FAIL: битый конфиг принят\n"; fail=1; } \
  || printf "  ok: битый конфиг отклонен через docker\n"

# Нет запущенных контейнеров и нет bypass — ошибка (fail-closed).
cat > "$TMP/bin/docker" << 'EOF'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  ps) printf 'acme\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
HAPROXY_NO_VALIDATE= run_v "$TDIR/fixtures/expected6-web-direct-web.cfg" "haproxy-web" \
  && { printf "  FAIL: нечем проверить, но принят\n"; fail=1; } \
  || printf "  ok: без проверяльщика — отказ\n"

# Тот же кейс с HAPROXY_NO_VALIDATE=1 — пропуск с варнингом.
HAPROXY_NO_VALIDATE=1 run_v "$TDIR/fixtures/expected6-web-direct-web.cfg" "haproxy-web" \
  && printf "  ok: bypass работает\n" \
  || { printf "  FAIL: bypass сломан\n"; fail=1; }

exit "$fail"
