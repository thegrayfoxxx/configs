#!/bin/bash
# Unit-тест ask_default: пустой ввод оставляет текущее, ввод меняет.
# По одному чтению на файл: каждое `read < file` открывает файл заново,
# поэтому последовательные чтения тестируются отдельными файлами
# (на живом TTY это поток — там работает и подряд, как все меню).
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '\n' > "$TMP/empty.txt"
printf '8081\n' > "$TMP/value.txt"

out=$(MENU_TTY="$TMP/empty.txt" bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/ui/menu.sh"; ask_default "Backend" "127.0.0.1:8080"' _ "$PROJ" 2>/dev/null)
[ "$out" = "127.0.0.1:8080" ] \
  && printf "  ok: пусто оставляет текущее\n" \
  || { printf "  FAIL: пусто дало '%s'\n" "$out"; fail=1; }

out=$(MENU_TTY="$TMP/value.txt" bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/ui/menu.sh"; ask_default "Backend" "127.0.0.1:8080"' _ "$PROJ" 2>/dev/null)
[ "$out" = "8081" ] \
  && printf "  ok: ввод меняет значение\n" \
  || { printf "  FAIL: ввод дал '%s'\n" "$out"; fail=1; }

exit "$fail"
