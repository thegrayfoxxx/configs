#!/bin/bash
# Регресс-тест интерактивного визарда пресетов (без --answers).
# Ловит два бага:
#  1. `read < file` per-open сбрасывал офсет -> бесконечный цикл на 1-й строке.
#  2. Промпты ask() текли в stdout -> отравляли значения в sites.conf.
# Плюс: when-условия пропускают вопросы без зависания.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"

# Сценарий пользователя web-direct sites: email, режим, два сайта, конец списка,
# blackhole/timeouts/check/logs по дефолту (пусто), подтвердить запись (y), сервисы не поднимать (n).
printf '%s\n' 't@e.com' 'sites' 'a.com' '8080' 'b.com' '9090' '' '' '' '' '' > "$TMP/tty-in"
printf '%s\n' 'y' 'n' >> "$TMP/tty-in"

timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply web-direct > "$1/session.log" 2>&1' _ "$TMP" "$PROJ" \
  || { printf "  FAIL: визард завис или упал (таймаут/код)\n"; fail=1; }

[ -f "$TMP/sites.conf" ] \
  && printf "  ok: sites.conf записан\n" \
  || { printf "  FAIL: нет sites.conf\n"; fail=1; }
[ -f "$TMP/stream/haproxy.cfg" ] && [ -f "$TMP/web/haproxy.cfg" ] \
  && printf "  ok: оба haproxy.cfg сгенерированы\n" \
  || { printf "  FAIL: нет haproxy.cfg\n"; fail=1; }
[ -d "$TMP/.backup" ] \
  && printf "  ok: бэкап создан\n" \
  || { printf "  FAIL: нет бэкапа\n"; fail=1; }

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
grep -q 'sites.conf записан' "$TMP/session.log" \
  && printf "  ok: сессия завершена записью\n" \
  || { printf "  FAIL: сессия не завершена\n"; fail=1; }

# When: stream-vision SELFSTEAL=no + xhttp — STUB_DOMAIN не спрашивается, визард не виснет.
SV="$TMP/sv"
mkdir -p "$SV/stream" "$SV/web" "$SV/custom"
# Порядок вопросов: email, SELFSTEAL, WEB_MODE, [STUB только если yes: пропуск],
# XHTTP_DOMAIN/PORT/PATH/STUB_PORT, REALITY, XRAY_PORT, XRAY_PROXY, STREAM_WEB_PROXY,
# WEB_ACCEPT_PROXY, BLACKHOLE, TIMEOUT, BACKEND_CHECK, STREAM_LOG_SNI, LOGS_CAPTURE.
printf '%s\n' 't@e.com' 'no' 'xhttp-split' 'x.cdn.example.com' '11443' '/data/' '8080' 'vpn.example.com' '10443' 'off' 'off' 'v2' 'on' 'deny' 'xhttp-1h' 'off' 'off' 'off' > "$SV/tty-in"
printf '%s\n' 'y' 'n' >> "$SV/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply stream-vision > "$1/session.log" 2>&1' _ "$SV" "$PROJ" \
  || { printf "  FAIL: when-визард завис/упал\n"; fail=1; }
grep -q '"host=x.cdn.example.com use=xhttp path=/data/"' "$SV/sites.conf" \
  && ! grep -q 'host=drop.example.com' "$SV/sites.conf" \
  && [ -f "$SV/stream/haproxy.cfg" ] \
  && printf "  ok: when пропустил STUB_DOMAIN без сдвига ввода\n" \
  || { printf "  FAIL: when-визард\n"; fail=1; }

# CRLF-ввод (вставка из Windows): значения чистые, визард не виснет.
CR="$TMP/crlf"
mkdir -p "$CR/stream" "$CR/web" "$CR/custom"
printf '%s\r\n' 't@e.com' 'sites' 'a.com' '8080' '' '' '' '' '' > "$CR/tty-in"
printf '%s\r\n' 'y' 'n' >> "$CR/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply web-direct > "$1/session.log" 2>&1' _ "$CR" "$PROJ" \
  || { printf "  FAIL: CRLF-визард завис/упал\n"; fail=1; }
grep -q '^ACME_EMAIL="t@e.com"$' "$CR/sites.conf" \
  && grep -q '"host=a.com to=127.0.0.1:8080"' "$CR/sites.conf" \
  && ! grep -q $'\r' "$CR/sites.conf" \
  && printf "  ok: CRLF-ввод переваривается чисто\n" \
  || { printf "  FAIL: CRLF-ввод\n"; fail=1; }

# Выбор из списка: номер вместо имени.
PK="$TMP/pick"
mkdir -p "$PK/stream" "$PK/web" "$PK/custom"
printf '2\n' > "$PK/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" show > "$1/out.txt" 2>"$1/err.txt"' _ "$PK" "$PROJ" \
  || { printf "  FAIL: show-by-number упал\n"; fail=1; }
grep -q 'web-direct' "$PK/out.txt" \
  && grep -q 'Номер пресета' "$PK/err.txt" \
  && printf "  ok: show без имени выбирает номером\n" \
  || { printf "  FAIL: show-by-number\n"; fail=1; }

# Отмена (0) — выход 0 без записи.
printf '0\n' > "$PK/tty-in2"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in2" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" show > "$1/out2.txt" 2>/dev/null' _ "$PK" "$PROJ" \
  || { printf "  FAIL: отмена пикера не 0\n"; fail=1; }
[ ! -s "$PK/out2.txt" ] \
  && printf "  ok: отмена пикера молча выходит\n" \
  || { printf "  FAIL: отмена пикера что-то напечатала\n"; fail=1; }

# Мусор (99, abc) — повтор запроса, затем верный номер.
printf '99\nabc\n3\n' > "$PK/tty-in3"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in3" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" show > "$1/out3.txt" 2>"$1/err3.txt"' _ "$PK" "$PROJ" \
  || { printf "  FAIL: пикер с мусором упал/вис\n"; fail=1; }
grep -q 'xray-direct' "$PK/out3.txt" \
  && grep -q 'Неверный номер' "$PK/err3.txt" \
  && printf "  ok: пикер отклоняет мусор и повторяет\n" \
  || { printf "  FAIL: пикер-мусор\n"; fail=1; }

# Apply без имени: номер + флаги дальше работают.
printf 'ACME_EMAIL=t@e.com\nWEB_MODE=sites\nSITES_LINES=a.com:8080\nBLACKHOLE=deny\nTIMEOUT_PROFILE=sites-50s\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$PK/answers"
printf '2\n' > "$PK/tty-in4"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in4" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply --dry-run --answers "$1/answers" > "$1/out4.txt" 2>/dev/null' _ "$PK" "$PROJ" \
  || { printf "  FAIL: apply без имени упал\n"; fail=1; }
grep -q '"host=a.com to=127.0.0.1:8080"' "$PK/out4.txt" \
  && printf "  ok: apply без имени берет номер и флаги\n" \
  || { printf "  FAIL: apply без имени\n"; fail=1; }

# Потери цифрами + снос SNI только по ДА (кейс stream-vision -> xray-direct).
WP="$TMP/wipe"
mkdir -p "$WP/stream" "$WP/web" "$WP/custom"
cp "$PROJ/tests/fixtures/sites6-stream-selfsteal.conf" "$WP/sites.conf"
cp "$PROJ/tests/fixtures/expected6-stream-selfsteal-stream.cfg" "$WP/stream/haproxy.cfg"
cp "$PROJ/tests/fixtures/expected6-stream-selfsteal-web.cfg" "$WP/web/haproxy.cfg"
# Ответы xray-direct (дефолты), затем: 1 (затереть), ДА (снос), y (применить), n (без up).
printf '%s\n' 't@e.com' 'drop.example.com' '8080' 'deny' 'off' 'off' 'sites-50s' 'off' 'off' '1' 'ДА' 'y' 'n' > "$WP/tty-in"
timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply xray-direct > "$1/session.log" 2>&1' _ "$WP" "$PROJ" \
  || { printf "  FAIL: apply со сносом упал/вис\n"; fail=1; }
grep -q 'ВНИМАНИЕ' "$WP/session.log" \
  && grep -q 'Пункт \[0\]' "$WP/session.log" \
  && ! grep -q 'sni=drop.example.com' "$WP/sites.conf" \
  && printf "  ok: цифры + ДА-гейт со сносом работают\n" \
  || { printf "  FAIL: цифры/ДА-гейт\n"; fail=1; }

exit "$fail"
