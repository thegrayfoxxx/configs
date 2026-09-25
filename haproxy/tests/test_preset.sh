#!/bin/bash
# Тесты волны 4: библиотека пресетов (list/diff/apply dry-run) + golden4.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

# Пресеты — из репозитория (трекаются), состояние — во временном корне.
mktmp() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/stream" "$tmp/web" "$tmp/custom"
  printf "%s" "$tmp"
}

# --- list: все 3 пресета на месте ---
out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" list 2>/dev/null)
for p in reality-selfsteal xhttp-path-split multi-site-l7; do
  echo "$out" | grep -q "$p" \
    && printf "  ok: list показывает %s\n" "$p" \
    || { printf "  FAIL: list без %s\n" "$p"; fail=1; }
done

# --- diff reality-selfsteal на дефолтах (без вопросов) ---
HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" diff reality-selfsteal >/dev/null 2>&1 \
  && printf "  ok: diff reality-selfsteal работает\n" \
  || { printf "  FAIL: diff reality-selfsteal\n"; fail=1; }

# --- apply --dry-run xhttp с answers: TAG вычислен, плейсхолдеров нет ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
XHTTP_DOMAIN=x.cdn.example.com
XHTTP_PORT=11443
XHTTP_PATH=/data/
STUB_PORT=8080
REALITY_DOMAINS=vpn.example.com
XRAY_PORT=10443
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply xhttp-path-split --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q 'forwardfor_backends=bk_site_x_cdn_example_com_11443' \
    && printf "  ok: derive TAG вычислен\n" \
    || { printf "  FAIL: TAG не вычислен\n%s\n" "$out"; fail=1; }
  echo "$out" | grep -q '{{' \
    && { printf "  FAIL: остались плейсхолдеры\n"; fail=1; } \
    || printf "  ok: плейсхолдеров не осталось\n"
  echo "$out" | grep -q '"x.cdn.example.com:11443:path=/data/"' \
    && printf "  ok: path-запись на месте\n" \
    || { printf "  FAIL: нет path-записи\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- apply --dry-run multi-site с повторяющимися SITES_LINES ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
BLACKHOLE=tarpit
SITES_LINES=a.com:8080
SITES_LINES=b.com:9090
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"a.com:8080"' \
    && echo "$out" | grep -q '"b.com:9090"' \
    && echo "$out" | grep -q '"blackhole=tarpit"' \
    && printf "  ok: multi-site list собран\n" \
    || { printf "  FAIL: multi-site render\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- golden4: новые опции генератора ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites4.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > /tmp/preset-g4-log.txt 2>&1 || { printf "  FAIL: generate на sites4\n"; cat /tmp/preset-g4-log.txt; exit 1; }
  diff -u "$TDIR/fixtures/expected4-stream.cfg" "$TMP/stream/haproxy.cfg" \
    && printf "  ok: golden4 stream совпал\n" \
    || { printf "  FAIL: golden4 stream\n"; fail=1; }
  diff -u "$TDIR/fixtures/expected4-web.cfg" "$TMP/web/haproxy.cfg" \
    && printf "  ok: golden4 web совпал\n" \
    || { printf "  FAIL: golden4 web\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

exit "$fail"
