#!/bin/bash
# Секции stream/web через MENU_TTY: последовательные tread-чтения идут по одному
# файловому вводу без зацикливания (до унификации читали /dev/tty напрямую).
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$PROJ/tests/fixtures/sites6-web-direct.conf" "$TMP/sites.conf"

# Web: 3 (бэкенды) -> список -> 0 (назад) -> 0 (выход).
printf '3\n0\n0\n' > "$TMP/tty-web"
timeout 25 bash -c 'MENU_TTY="$1/tty-web" HAPROXY_DIR_OVERRIDE="$1" bash "$2/scripts/commands/web.sh" > "$1/web.log" 2>&1' _ "$TMP" "$PROJ" \
  || { printf "  FAIL: web-секция завис/упал\n"; fail=1; }
grep -q 'БЭКЕНД' "$TMP/web.log" \
  && printf "  ok: web-бэкенды по MENU_TTY\n" \
  || { printf "  FAIL: web-бэкенды\n"; fail=1; }

# Stream: 2 (фронтенды) -> список -> 0 -> 0.
printf '2\n0\n0\n' > "$TMP/tty-stream"
timeout 25 bash -c 'MENU_TTY="$1/tty-stream" HAPROXY_DIR_OVERRIDE="$1" bash "$2/scripts/commands/stream.sh" > "$1/stream.log" 2>&1' _ "$TMP" "$PROJ" \
  || { printf "  FAIL: stream-секция завис/упал\n"; fail=1; }
grep -q 'ФРОНТЕНД' "$TMP/stream.log" \
  && printf "  ok: stream-фронтенды по MENU_TTY\n" \
  || { printf "  FAIL: stream-фронтенды\n"; fail=1; }

exit "$fail"
