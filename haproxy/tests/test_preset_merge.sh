#!/bin/bash
# Тесты потерь при apply (A) и слияния --merge (B).
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
BLACKHOLE=deny
SITES_LINES=a.com:8080'

# --- A: отчёт о потерях через отмену (интерактив, выбор 'о') ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="old@e.com"
STREAM_FRONTENDS=(
  "name=office bind=10.0.0.1:443"
)
WEB_BACKENDS=(
  "name=app to=127.0.0.1:8080"
)
STREAM_ROUTES=(
  "sni=ops.internal to=127.0.0.1:10444 frontend=office"
  "sni=default to=127.0.0.1:8443 name=web"
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
  timeout 25 bash -c 'PRESET_TTY="$1/tty-in" HAPROXY_DIR_OVERRIDE="$1" PRESETS_DIR_OVERRIDE="$2/presets" bash "$2/scripts/preset.sh" apply multi-site-l7 --answers "$1/answers" > "$1/session.log" 2>&1' _ "$TMP" "$PROJ" \
    || { printf "  FAIL: apply с потерями упал/вис\n"; fail=1; }
  grep -q 'затрет текущее' "$TMP/session.log" \
    && printf "  ok: предупреждение о потерях показано\n" \
    || { printf "  FAIL: нет предупреждения\n"; fail=1; }
  grep -q 'office' "$TMP/session.log" \
    && grep -q 'app.example.com use=app' "$TMP/session.log" \
    && printf "  ok: потери перечислены (фронтенд, маршрут)\n" \
    || { printf "  FAIL: потери не перечислены\n"; fail=1; }
  grep -q 'Отмена' "$TMP/session.log" \
    && grep -q '"sni=ops.internal' "$TMP/sites.conf" \
    && printf "  ok: отмена оставила файл нетронутым\n" \
    || { printf "  FAIL: отмена не сработала\n"; fail=1; }

  # A2: --yes при потерях — отказ, а не тихая запись.
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --yes --answers "$TMP/answers" >/dev/null 2>&1; then
    printf "  FAIL: --yes с потерями записал\n"; fail=1
  else
    printf "  ok: --yes с потерями отказывает\n"
  fi
  grep -q '"sni=ops.internal' "$TMP/sites.conf" \
    && printf "  ok: файл цел после отказа --yes\n" \
    || { printf "  FAIL: файл задет\n"; fail=1; }

  # B1: --merge --yes — объединение без потерь.
  HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
    bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --merge --yes --answers "$TMP/answers" >/dev/null 2>&1 \
    || { printf "  FAIL: merge упал\n"; fail=1; }
  grep -q '"name=office bind=10.0.0.1:443"' "$TMP/sites.conf" \
    && grep -q '"host=a.com to=127.0.0.1:8080"' "$TMP/sites.conf" \
    && grep -q '"host=app.example.com use=app"' "$TMP/sites.conf" \
    && grep -q 'ACME_EMAIL="old@e.com"' "$TMP/sites.conf" \
    && grep -q '"blackhole=tarpit"' "$TMP/sites.conf" \
    && printf "  ok: merge объединил (своё цело, новое добавлено, email/опции свои)\n" \
    || { printf "  FAIL: merge неверный\n"; fail=1; }
  [ -f "$TMP/stream/haproxy.cfg" ] && [ -f "$TMP/web/haproxy.cfg" ] \
    && printf "  ok: конфиги перегенерированы после merge\n" \
    || { printf "  FAIL: нет конфигов после merge\n"; fail=1; }

  # B2: конфликт слияния — ошибка, файл цел.
  # Текущий default смотрит в другой бэкенд, чем default пресета.
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:9999 name=web"
)
WEB_ROUTES=(
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
  printf 'ACME_EMAIL=t@e.com\nBLACKHOLE=deny\nSITES_LINES=a.com:2222\n' > "$TMP/answers2"
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --merge --yes --answers "$TMP/answers2" > "$TMP/m2.log" 2>&1; then
    printf "  FAIL: конфликт слияния принят\n"; fail=1
  else
    grep -q 'Конфликт слияния' "$TMP/m2.log" \
      && printf "  ok: конфликт слияния — ошибка с объяснением\n" \
      || { printf "  FAIL: нет объяснения конфликта\n"; fail=1; }
  fi
  grep -q '"sni=default to=127.0.0.1:9999 name=web"' "$TMP/sites.conf" \
    && printf "  ok: файл цел после конфликта\n" \
    || { printf "  FAIL: файл задет конфликтом\n"; fail=1; }

  # B3: каноническое равенство — proxy=off явно vs по умолчанию не конфликт.
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:8443 name=web"
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
  printf 'ACME_EMAIL=t@e.com\nBLACKHOLE=deny\nSITES_LINES=a.com:8080\n' > "$TMP/answers3"
  if HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
    bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --merge --yes --answers "$TMP/answers3" > "$TMP/m3.log" 2>&1; then
    printf "  ok: дефолтные формы не конфликтуют\n"
  else
    printf "  FAIL: канонически равное слияние упало\n"; cat "$TMP/m3.log"; fail=1
  fi
  trap - EXIT
  rm -rf "$TMP"
}

exit "$fail"
