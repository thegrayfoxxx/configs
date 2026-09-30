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

# Stream fe_edit: битый бинд не оседает — возврат в меню полей, повтор, верный применяется.
# 2 (фронтенды) -> 2 (изменить) -> 1 (первый: public) -> 1 (Bind) ->
# 9443 (битый, возврат в меню) -> 1 (Bind снова) -> *:9443 ->
# 0 (готово) -> y (применить) -> y (проверка) -> n (без рестарта) -> 0 -> 0.
# Нужны именованные фронтенды — отдельный TMP на sites-v4fe.
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/stream" "$TMP2/web" "$TMP2/custom"
cp "$PROJ/tests/fixtures/sites-v4fe.conf" "$TMP2/sites.conf"
printf '2\n2\n1\n1\n9443\n1\n*:9443\n0\ny\ny\nn\n0\n0\n' > "$TMP2/tty-feedit"
timeout 25 bash -c 'MENU_TTY="$1/tty-feedit" HAPROXY_DIR_OVERRIDE="$1" bash "$2/scripts/commands/stream.sh" > "$1/feedit.log" 2>&1' _ "$TMP2" "$PROJ" \
  || { printf "  FAIL: fe_edit завис/упал\n"; fail=1; }
grep -q 'Жди host:порт' "$TMP2/feedit.log" \
  && grep -q '"name=public bind=\*:9443"' "$TMP2/sites.conf" \
  && ! grep -q '"name=public bind=9443"' "$TMP2/sites.conf" \
  && printf "  ok: битый бинд отклонен повтором, верный записан\n" \
  || { printf "  FAIL: re-prompt бинда\n"; fail=1; }
rm -rf "$TMP2"

exit "$fail"
