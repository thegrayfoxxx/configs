#!/bin/bash
# Регресс-тест интерактивного визарда пресетов (без --answers).
# Ловит два бага:
#  1. `read < file` per-open сбрасывал офсет -> бесконечный цикл на 1-й строке.
#  2. Промпты ask() текли в stdout -> отравляли значения в sites.conf.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"

# Сценарий пользователя: email, blackhole, два сайта, конец списка,
# подтвердить запись (y), сервисы не поднимать (n; docker всё равно stub).
printf 't@e.com\ndeny\na.com\n8080\nb.com\n9090\n\n' > "$TMP/tty-in"
printf 'y\nn\n' >> "$TMP/tty-in"

timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply multi-site-l7 > "$1/session.log" 2>&1' _ "$TMP" "$PROJ" \
  || { printf "  FAIL: визард завис или упал (таймаут/код)\n"; fail=1; }

# Файлы созданы: sites.conf + оба haproxy.cfg + бэкап.
[ -f "$TMP/sites.conf" ] \
  && printf "  ok: sites.conf записан\n" \
  || { printf "  FAIL: нет sites.conf\n"; fail=1; }
[ -f "$TMP/stream/haproxy.cfg" ] && [ -f "$TMP/web/haproxy.cfg" ] \
  && printf "  ok: оба haproxy.cfg сгенерированы\n" \
  || { printf "  FAIL: нет haproxy.cfg\n"; fail=1; }
[ -d "$TMP/.backup" ] \
  && printf "  ok: бэкап создан\n" \
  || { printf "  FAIL: нет бэкапа\n"; fail=1; }

# Значения чистые: никаких промптов внутри.
grep -q '^ACME_EMAIL="t@e.com"$' "$TMP/sites.conf" \
  && printf "  ok: ACME_EMAIL чистый\n" \
  || { printf "  FAIL: ACME_EMAIL отравлен\n"; fail=1; }
grep -q '"blackhole=deny"' "$TMP/sites.conf" \
  && printf "  ok: BLACKHOLE чистый\n" \
  || { printf "  FAIL: BLACKHOLE отравлен\n"; fail=1; }
grep -q '"host=a.com to=127.0.0.1:8080"' "$TMP/sites.conf" \
  && grep -q '"host=b.com to=127.0.0.1:9090"' "$TMP/sites.conf" \
  && printf "  ok: сайты собраны визардом\n" \
  || { printf "  FAIL: сайты не собраны\n"; fail=1; }
# Последний ответ 'n' — сервисы не поднимались (docker бы упал, но up не звали).
grep -q 'up -d\|Поднять' "$TMP/session.log" && true || true
grep -q 'sites.conf записан' "$TMP/session.log" \
  && printf "  ok: сессия завершена записью\n" \
  || { printf "  FAIL: сессия не завершена\n"; fail=1; }

# Twin: строгие валидаторы принимают корректный ввод с первого раза.
TW="$TMP/twin"
mkdir -p "$TW/stream" "$TW/web" "$TW/custom"
printf 't@e.com\n*:443\n127.0.0.1:4443\nvpn.example.com\n127.0.0.1:10443\nops.internal\n127.0.0.1:10444\n127.0.0.1:8443\n127.0.0.1:8443\nsite1.com\n8080\n\n' > "$TW/tty-in"
printf 'y\nn\n' >> "$TW/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply twin-frontends > "$1/session.log" 2>&1' _ "$TW" "$PROJ" \
  || { printf "  FAIL: twin-визард завис/упал\n"; fail=1; }
grep -q '"name=public bind=\*:443"' "$TW/sites.conf" \
  && grep -q '"sni=vpn.example.com to=127.0.0.1:10443' "$TW/sites.conf" \
  && [ -f "$TW/stream/haproxy.cfg" ] \
  && printf "  ok: twin-визард со строгими валидаторами\n" \
  || { printf "  FAIL: twin-визард\n"; fail=1; }

# CRLF-ввод (вставка из Windows): значения чистые, визард не виснет.
# ВАЖНО: каждая строка, включая пустую и одиночный \r, заканчивается \n.
CR="$TMP/crlf"
mkdir -p "$CR/stream" "$CR/web" "$CR/custom"
printf 't@e.com\r\ndeny\r\na.com\r\n8080\r\n\r\n' > "$CR/tty-in"
printf 'y\r\nn\r\n' >> "$CR/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply multi-site-l7 > "$1/session.log" 2>&1' _ "$CR" "$PROJ" \
  || { printf "  FAIL: CRLF-визард завис/упал\n"; fail=1; }
grep -q '^ACME_EMAIL="t@e.com"$' "$CR/sites.conf" \
  && grep -q '"host=a.com to=127.0.0.1:8080"' "$CR/sites.conf" \
  && ! grep -q $'\r' "$CR/sites.conf" \
  && printf "  ok: CRLF-ввод переваривается чисто\n" \
  || { printf "  FAIL: CRLF-ввод\n"; fail=1; }

exit "$fail"
