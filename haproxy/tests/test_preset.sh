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

# --- list: все 4 пресета на месте ---
out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" list 2>/dev/null)
for p in reality-selfsteal xhttp-path-split multi-site-l7 twin-frontends; do
  echo "$out" | grep -q "$p" \
    && printf "  ok: list показывает %s\n" "$p" \
    || { printf "  FAIL: list без %s\n" "$p"; fail=1; }
done

# --- diff reality-selfsteal на дефолтах (герметично: пустой sites.conf во tmp) ---
DIFFTMP="$(mktemp -d)"
mkdir -p "$DIFFTMP/stream" "$DIFFTMP/web" "$DIFFTMP/custom"
printf 'ACME_EMAIL="t@e.com"\n' > "$DIFFTMP/sites.conf"
PRESETS_DIR_OVERRIDE="$PROJ/presets" HAPROXY_DIR_OVERRIDE="$DIFFTMP" bash "$PROJ/scripts/preset.sh" diff reality-selfsteal >/dev/null 2>&1 \
  && printf "  ok: diff reality-selfsteal работает\n" \
  || { printf "  FAIL: diff reality-selfsteal\n"; fail=1; }
rm -rf "$DIFFTMP"

# --- apply --dry-run xhttp с answers: ящики поименно, плейсхолдеров нет ---
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
  echo "$out" | grep -q 'forwardfor_backends=bk_xhttp' \
    && printf "  ok: forwardfor ссылается на именованный ящик\n" \
    || { printf "  FAIL: forwardfor не на ящик\n%s\n" "$out"; fail=1; }
  echo "$out" | grep -q '{{' \
    && { printf "  FAIL: остались плейсхолдеры\n"; fail=1; } \
    || printf "  ok: плейсхолдеров не осталось\n"
  echo "$out" | grep -q '"host=x.cdn.example.com use=xhttp path=/data/"' \
    && printf "  ok: path-запись со ссылкой на месте\n" \
    || { printf "  FAIL: нет path-записи\n"; fail=1; }
  echo "$out" | grep -q '"name=xhttp to=127.0.0.1:11443"' \
    && printf "  ok: ящик xhttp объявлен\n" \
    || { printf "  FAIL: нет ящика xhttp\n"; fail=1; }
  # e2e: рендер пресета генерируется в рабочие конфиги.
  printf "%s\n" "$out" > "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > /tmp/preset-xhttp-log.txt 2>&1 || { printf "  FAIL: generate после xhttp\n"; cat /tmp/preset-xhttp-log.txt; fail=1; }
  grep -q 'option forwardfor' "$TMP/web/haproxy.cfg" \
    && grep -q '^backend bk_xhttp' "$TMP/web/haproxy.cfg" \
    && printf "  ok: e2e forwardfor на ящике применён\n" \
    || { printf "  FAIL: e2e forwardfor\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- answers-валидация: мусор в строгих полях отклоняется ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  printf 'ACME_EMAIL=t@e.com\nBLACKHOLE=bogus\nSITES_LINES=a.com:8080\n' > "$TMP/answers"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply multi-site-l7 --dry-run --answers "$TMP/answers" >/dev/null 2>&1; then
    printf "  FAIL: мусор в BLACKHOLE принят\n"; fail=1
  else
    printf "  ok: мусор в BLACKHOLE отклонён\n"
  fi
  printf 'ACME_EMAIL=t@e.com\nXHTTP_DOMAIN=x.cdn.example.com\nXHTTP_PORT=11443\nXHTTP_PATH=data-no-slash\nSTUB_PORT=8080\nREALITY_DOMAINS=vpn.example.com\nXRAY_PORT=10443\n' > "$TMP/answers2"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply xhttp-path-split --dry-run --answers "$TMP/answers2" >/dev/null 2>&1; then
    printf "  FAIL: path без / принят\n"; fail=1
  else
    printf "  ok: path без / отклонён\n"
  fi
  trap - EXIT
  rm -rf "$TMP"
}

# --- derive: движок тегов жив (юнит на временном пресете) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/presets/drv"
  cat > "$TMP/presets/drv/preset.conf" << 'EOF'
ACME_EMAIL="{{ACME_EMAIL}}"
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:8443 proxy=off name=web"
)
WEB_ROUTES=(
  "host={{D}} to=127.0.0.1:{{P}}"
)
GLOBAL_OPTS=(
  "forwardfor_backends=bk_{{TAG}}"
)
EOF
  cat > "$TMP/presets/drv/questions" << 'EOF'
ACME_EMAIL|Email|mail@example.com|email
D|Домен|x.example.com|domain
P|Порт|11443|port
derive:TAG=tag D P
EOF
  out=$(PRESETS_DIR_OVERRIDE="$TMP/presets" HAPROXY_DIR_OVERRIDE="$TMP" bash "$PROJ/scripts/preset.sh" diff drv 2>/dev/null)
  echo "$out" | grep -q 'forwardfor_backends=bk_site_x_example_com_11443' \
    && printf "  ok: derive TAG вычислен\n" \
    || { printf "  FAIL: TAG не вычислен\n%s\n" "$out"; fail=1; }
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
  echo "$out" | grep -q '"host=a.com to=127.0.0.1:8080"' \
    && echo "$out" | grep -q '"host=b.com to=127.0.0.1:9090"' \
    && echo "$out" | grep -q '"blackhole=tarpit"' \
    && printf "  ok: multi-site list собран\n" \
    || { printf "  FAIL: multi-site render\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- e2e: рендер reality-selfsteal -> generate (нейтральное ядро переваривает пресет) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
STUB_DOMAIN=drop.example.com
STUB_PORT=8080
REALITY_DOMAINS=vpn.example.com
XRAY_PORT=10443
EOF
  HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply reality-selfsteal --dry-run --answers "$TMP/answers" 2>/dev/null > "$TMP/rendered.conf" \
    || { printf "  FAIL: рендер reality-selfsteal\n"; fail=1; }
  grep -q 'STREAM_ROUTES=(' "$TMP/rendered.conf" \
    && grep -q 'sni=default to=' "$TMP/rendered.conf" \
    && printf "  ok: пресет рендерит v3 с явным default\n" \
    || { printf "  FAIL: рендер не v3\n"; fail=1; }
  cp "$TMP/rendered.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > /tmp/preset-e2e-log.txt 2>&1 || { printf "  FAIL: generate после пресета\n"; cat /tmp/preset-e2e-log.txt; fail=1; }
  grep -q 'default_backend bk_web' "$TMP/stream/haproxy.cfg" \
    && ! grep -q 'is_reality\|bk_haproxy_web' "$TMP/stream/haproxy.cfg" \
    && grep -q 'use_backend bk_xray' "$TMP/stream/haproxy.cfg" \
    && printf "  ok: e2e stream без legacy-артефактов ядра\n" \
    || { printf "  FAIL: e2e stream\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- e2e: рендер twin-frontends -> generate (пресет с именованными фронтендами) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
PUB_BIND=*:443
INT_BIND=127.0.0.1:4443
PUB_SNI=vpn.example.com
PUB_TO=127.0.0.1:10443
INT_SNI=ops.internal
INT_TO=127.0.0.1:10444
WEB_BIND=127.0.0.1:8443
WEB_DEF_TO=127.0.0.1:8443
SITES_LINES=site1.com:8080
EOF
  HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply twin-frontends --dry-run --answers "$TMP/answers" 2>/dev/null > "$TMP/rendered.conf" \
    || { printf "  FAIL: рендер twin-frontends\n"; fail=1; }
  grep -q 'STREAM_FRONTENDS=(' "$TMP/rendered.conf" \
    && printf "  ok: twin-frontends рендерит фронтенды\n" \
    || { printf "  FAIL: нет фронтендов в рендере\n"; fail=1; }
  grep -q '{{' "$TMP/rendered.conf" \
    && { printf "  FAIL: остались плейсхолдеры\n"; fail=1; } \
    || printf "  ok: плейсхолдеров не осталось (twin)\n"
  cp "$TMP/rendered.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > /tmp/preset-twin-log.txt 2>&1 || { printf "  FAIL: generate после twin-frontends\n"; cat /tmp/preset-twin-log.txt; fail=1; }
  grep -q '^frontend ft_public' "$TMP/stream/haproxy.cfg" \
    && grep -q '^frontend ft_internal' "$TMP/stream/haproxy.cfg" \
    && grep -q '^frontend ft_main' "$TMP/web/haproxy.cfg" \
    && printf "  ok: e2e фронтенды пресета в конфигах\n" \
    || { printf "  FAIL: e2e фронтенды пресета\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- golden4: новые опции генератора ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites4.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > /tmp/preset-g4-log.txt 2>&1 || { printf "  FAIL: generate на sites4\n"; cat /tmp/preset-g4-log.txt; fail=1; }
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
