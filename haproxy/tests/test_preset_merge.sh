#!/bin/bash
# Тесты потерь при apply (A) и слияния --merge (B) на web-direct.
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

BASE_ANSWERS='ACME_EMAIL=t@e.com
WEB_MODE=sites
SITES_LINES=a.com:8080
BLACKHOLE=deny
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off'

# --- A: отчёт о потерях через отмену (интерактив, выбор 'о') ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="old@e.com"
WEB_BACKENDS=(
  "name=app to=127.0.0.1:8080"
)
WEB_ROUTES=(
  "host=app.example.com use=app"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "blackhole=tarpit"
)
EOF
  printf '%s\n' "$BASE_ANSWERS" > "$TMP/answers"
  printf 'o\n' > "$TMP/tty-in"
  timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply web-direct --answers "$1/answers" > "$1/session.log" 2>&1' _ "$TMP" "$PROJ" \
    || { printf "  FAIL: apply с потерями упал/вис\n"; fail=1; }
  grep -q 'затрет текущее' "$TMP/session.log" \
    && printf "  ok: предупреждение о потерях показано\n" \
    || { printf "  FAIL: нет предупреждения\n"; fail=1; }
  grep -q 'app.example.com use=app' "$TMP/session.log" \
    && printf "  ok: потери перечислены (маршрут)\n" \
    || { printf "  FAIL: потери не перечислены\n"; fail=1; }
  grep -q 'Отмена' "$TMP/session.log" \
    && grep -q '"host=app.example.com use=app"' "$TMP/sites.conf" \
    && printf "  ok: отмена оставила файл нетронутым\n" \
    || { printf "  FAIL: отмена не сработала\n"; fail=1; }

  # A2: --yes при потерях — отказ, а не тихая запись.
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply web-direct --yes --answers "$TMP/answers" >/dev/null 2>&1; then
    printf "  FAIL: --yes с потерями записал\n"; fail=1
  else
    printf "  ok: --yes с потерями отказывает\n"
  fi
  grep -q '"host=app.example.com use=app"' "$TMP/sites.conf" \
    && printf "  ok: файл цел после отказа --yes\n" \
    || { printf "  FAIL: файл задет\n"; fail=1; }

  # B1: --merge --yes — объединение без потерь.
  HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
    bash "$PROJ/scripts/preset.sh" apply web-direct --merge --yes --answers "$TMP/answers" >/dev/null 2>&1 \
    || { printf "  FAIL: merge упал\n"; fail=1; }
  grep -q '"host=a.com to=127.0.0.1:8080"' "$TMP/sites.conf" \
    && grep -q '"host=app.example.com use=app"' "$TMP/sites.conf" \
    && grep -q 'ACME_EMAIL="old@e.com"' "$TMP/sites.conf" \
    && grep -q '"blackhole=tarpit"' "$TMP/sites.conf" \
    && printf "  ok: merge объединил (своё цело, новое добавлено, email/опции свои)\n" \
    || { printf "  FAIL: merge неверный\n"; fail=1; }
  [ -f "$TMP/stream/haproxy.cfg" ] && [ -f "$TMP/web/haproxy.cfg" ] \
    && printf "  ok: конфиги перегенерированы после merge\n" \
    || { printf "  FAIL: нет конфигов после merge\n"; fail=1; }

  # B2: конфликт слияния — ошибка, файл цел.
  # Тот же host, другой backend.
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_ROUTES=(
  "host=a.com to=127.0.0.1:9999"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_web=*:443"
  "blackhole=deny"
)
EOF
  printf 'ACME_EMAIL=t@e.com\nWEB_MODE=sites\nSITES_LINES=a.com:2222\nBLACKHOLE=deny\nTIMEOUT_PROFILE=sites-50s\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$TMP/answers2"
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply web-direct --merge --yes --answers "$TMP/answers2" > "$TMP/m2.log" 2>&1; then
    printf "  FAIL: конфликт слияния принят\n"; fail=1
  else
    grep -q 'Конфликт слияния' "$TMP/m2.log" \
      && printf "  ok: конфликт слияния — ошибка с объяснением\n" \
      || { printf "  FAIL: нет объяснения конфликта\n"; fail=1; }
  fi
  grep -q '"host=a.com to=127.0.0.1:9999"' "$TMP/sites.conf" \
    && printf "  ok: файл цел после конфликта\n" \
    || { printf "  FAIL: файл задет конфликтом\n"; fail=1; }

  # B3: идентичное слияние — не конфликт.
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_ROUTES=(
  "host=a.com to=127.0.0.1:8080"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_web=*:443"
  "blackhole=deny"
)
EOF
  printf 'ACME_EMAIL=t@e.com\nWEB_MODE=sites\nSITES_LINES=a.com:8080\nBLACKHOLE=deny\nTIMEOUT_PROFILE=sites-50s\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$TMP/answers3"
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
    bash "$PROJ/scripts/preset.sh" apply web-direct --merge --yes --answers "$TMP/answers3" > "$TMP/m3.log" 2>&1; then
    printf "  ok: идентичное слияние не конфликтует\n"
  else
    printf "  FAIL: идентичное слияние упало\n"; cat "$TMP/m3.log"; fail=1
  fi
  trap - EXIT
  rm -rf "$TMP"
}

exit "$fail"
