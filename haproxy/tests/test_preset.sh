#!/bin/bash
# Тесты пресетов: 3 базы (web-direct/xray-direct/stream-vision) + движок when/#if.
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

# --- list: все 3 базы на месте ---
out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" list 2>/dev/null)
for p in web-direct xray-direct stream-vision; do
  echo "$out" | grep -q "$p" \
    && printf "  ok: list показывает %s\n" "$p" \
    || { printf "  FAIL: list без %s\n" "$p"; fail=1; }
done

# --- старые имена: дружелюбная подсказка, а не молчаливый 404 ---
for o in "reality-selfsteal:stream-vision" "xhttp-path-split:stream-vision" "multi-site-l7:web-direct"; do
  old="${o%%:*}"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" show "$old" >/dev/null 2>&1; then
    printf "  FAIL: старое имя %s не отклонено\n" "$old"; fail=1
  else
    out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" show "$old" 2>&1 || true)
    echo "$out" | grep -q "переименован" \
      && printf "  ok: %s подсказывает новое имя\n" "$old" \
      || { printf "  FAIL: %s без подсказки\n" "$old"; fail=1; }
  fi
done

# --- dry-run web-direct sites: список собирается, xhttp-ветка выключена ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
WEB_MODE=sites
SITES_LINES=a.com:8080
SITES_LINES=b.com:9090
BLACKHOLE=deny
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"host=a.com to=127.0.0.1:8080"' \
    && echo "$out" | grep -q '"host=b.com to=127.0.0.1:9090"' \
    && echo "$out" | grep -q '"bind_web=\*:443"' \
    && ! echo "$out" | grep -q 'forwardfor' \
    && printf "  ok: web-direct sites рендерит список без xhttp\n" \
    || { printf "  FAIL: web-direct sites\n%s\n" "$out"; fail=1; }
  echo "$out" | grep -q '{{' \
    && { printf "  FAIL: остались плейсхолдеры\n"; fail=1; } \
    || printf "  ok: плейсхолдеров не осталось\n"
  trap - EXIT
  rm -rf "$TMP"
}

# --- dry-run web-direct xhttp-split: ящики + forwardfor + 1h ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
WEB_MODE=xhttp-split
XHTTP_DOMAIN=x.cdn.example.com
XHTTP_PORT=11443
XHTTP_PATH=/data/
STUB_PORT=8080
BLACKHOLE=deny
TIMEOUT_PROFILE=xhttp-1h
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"host=x.cdn.example.com use=xhttp path=/data/"' \
    && echo "$out" | grep -q '"name=xhttp to=127.0.0.1:11443"' \
    && echo "$out" | grep -q 'forwardfor_backends=bk_xhttp' \
    && echo "$out" | grep -q '"timeout_tunnel=1h"' \
    && printf "  ok: web-direct xhttp рендерит сплит\n" \
    || { printf "  FAIL: web-direct xhttp\n%s\n" "$out"; fail=1; }
  # e2e: генерация дает forwardfor на ящике
  printf "%s\n" "$out" > "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/preset-webxhttp-log.txt 2>&1 || { printf "  FAIL: generate после web-direct xhttp\n"; cat ${TEST_TMP:-/tmp}/preset-webxhttp-log.txt; fail=1; }
  grep -q 'option forwardfor' "$TMP/web/haproxy.cfg" \
    && grep -q '^backend bk_xhttp' "$TMP/web/haproxy.cfg" \
    && printf "  ok: e2e forwardfor на ящике применён\n" \
    || { printf "  FAIL: e2e forwardfor\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- when: лишние ответы под невыполненным условием игнорируются с варнингом ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
WEB_MODE=sites
SITES_LINES=a.com:8080
XHTTP_DOMAIN=x.cdn.example.com
BLACKHOLE=deny
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"host=a.com to=127.0.0.1:8080"' \
    && ! echo "$out" | grep -q 'x.cdn.example.com' \
    && printf "  ok: when отрезал xhttp-ветку\n" \
    || { printf "  FAIL: when не отработал\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- dry-run xray-direct: таргет на loopback, без PROXY ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
STUB_DOMAIN=drop.example.com
STUB_PORT=8080
BLACKHOLE=deny
WEB_ACCEPT_PROXY=off
XRAY_XVER=off
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply xray-direct --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"host=drop.example.com use=stub"' \
    && echo "$out" | grep -q '"bind_web=127.0.0.1:8443"' \
    && ! echo "$out" | grep -q 'proxy' \
    && printf "  ok: xray-direct рендерит таргет без PROXY\n" \
    || { printf "  FAIL: xray-direct\n%s\n" "$out"; fail=1; }
  # xver-кейс: WEB_ACCEPT_PROXY=on дает accept-proxy на бинде
  cat > "$TMP/answers-proxy" << 'EOF'
ACME_EMAIL=t@e.com
STUB_DOMAIN=drop.example.com
STUB_PORT=8080
BLACKHOLE=deny
WEB_ACCEPT_PROXY=on
XRAY_XVER=v2
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply xray-direct --dry-run --answers "$TMP/answers-proxy" 2>/dev/null)
  echo "$out" | grep -q '"web_accept_proxy=on"' \
    || { printf "  FAIL: xray-direct xver\n%s\n" "$out"; fail=1; }
  printf "%s\n" "$out" > "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/preset-xray-log.txt 2>&1 || { printf "  FAIL: generate после xray-direct\n"; cat ${TEST_TMP:-/tmp}/preset-xray-log.txt; fail=1; }
  grep -q 'bind 127.0.0.1:8443 ssl.*accept-proxy' "$TMP/web/haproxy.cfg" \
    && printf "  ok: xray-direct xver дает accept-proxy на бинде\n" \
    || { printf "  FAIL: e2e xray-direct accept-proxy\n"; fail=1; }
  unset HAPROXY_DIR_OVERRIDE
  trap - EXIT
  rm -rf "$TMP"
}

# --- dry-run stream-vision selfsteal+xhttp = прод-схема: 3 web-маршрута ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
SELFSTEAL=yes
WEB_MODE=xhttp-split
STUB_DOMAIN=drop.example.com
XHTTP_DOMAIN=x.cdn.example.com
XHTTP_PORT=11443
XHTTP_PATH=/data/
STUB_PORT=8080
REALITY_DOMAINS=drop.example.com
XRAY_PORT=10443
XRAY_PROXY=v2
XRAY_XVER=v2
STREAM_WEB_PROXY=v2
WEB_ACCEPT_PROXY=on
BLACKHOLE=deny
TIMEOUT_PROFILE=xhttp-1h
BACKEND_CHECK=off
STREAM_LOG_SNI=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply stream-vision --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"sni=drop.example.com use=xray"' \
    && echo "$out" | grep -q '"host=drop.example.com use=stub"' \
    && echo "$out" | grep -q '"host=x.cdn.example.com use=xhttp path=/data/"' \
    && echo "$out" | grep -q '"host=x.cdn.example.com use=stub"' \
    && echo "$out" | grep -q '"name=xray to=127.0.0.1:10443 proxy=v2"' \
    && printf "  ok: stream-vision selfsteal+xhttp как прод\n" \
    || { printf "  FAIL: stream-vision selfsteal+xhttp\n%s\n" "$out"; fail=1; }
  # e2e: stream шлет PROXY в xray и web, web делит по path
  printf "%s\n" "$out" > "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/preset-sv-log.txt 2>&1 || { printf "  FAIL: generate после stream-vision\n"; cat ${TEST_TMP:-/tmp}/preset-sv-log.txt; fail=1; }
  grep -q 'server xray 127.0.0.1:10443 send-proxy-v2' "$TMP/stream/haproxy.cfg" \
    && grep -q 'use_backend bk_xhttp if' "$TMP/web/haproxy.cfg" \
    && grep -q 'option forwardfor' "$TMP/web/haproxy.cfg" \
    && printf "  ok: e2e прод-схема генерируется\n" \
    || { printf "  FAIL: e2e прод-схема\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- dry-run stream-vision без селфстила xhttp: STUB_DOMAIN не спрашивается, 2 маршрута ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
SELFSTEAL=no
WEB_MODE=xhttp-split
XHTTP_DOMAIN=x.cdn.example.com
XHTTP_PORT=11443
XHTTP_PATH=/data/
STUB_PORT=8080
REALITY_DOMAINS=vpn.example.com
XRAY_PORT=10443
XRAY_PROXY=off
XRAY_XVER=off
STREAM_WEB_PROXY=v2
WEB_ACCEPT_PROXY=on
BLACKHOLE=deny
TIMEOUT_PROFILE=xhttp-1h
BACKEND_CHECK=off
STREAM_LOG_SNI=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply stream-vision --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"host=x.cdn.example.com use=xhttp path=/data/"' \
    && ! echo "$out" | grep -q 'host=drop.example.com' \
    && echo "$out" | grep -q '"name=xray to=127.0.0.1:10443"' \
    && ! echo "$out" | grep -q '"name=xray to=127.0.0.1:10443 proxy=' \
    && printf "  ok: stream-vision без селфстила (2 маршрута, xray без proxy)\n" \
    || { printf "  FAIL: stream-vision no-selfsteal\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- warn: SELFSTEAL=yes, но REALITY != STUB — предупреждение, рендер идет ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
SELFSTEAL=yes
WEB_MODE=xhttp-split
STUB_DOMAIN=drop.example.com
XHTTP_DOMAIN=x.cdn.example.com
XHTTP_PORT=11443
XHTTP_PATH=/data/
STUB_PORT=8080
REALITY_DOMAINS=other.example.com
XRAY_PORT=10443
XRAY_PROXY=v2
XRAY_XVER=v2
STREAM_WEB_PROXY=v2
WEB_ACCEPT_PROXY=on
BLACKHOLE=deny
TIMEOUT_PROFILE=xhttp-1h
BACKEND_CHECK=off
STREAM_LOG_SNI=off
LOGS_CAPTURE=off
EOF
  out=$(HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply stream-vision --dry-run --answers "$TMP/answers" 2>"$TMP/stderr.txt") \
    || { printf "  FAIL: selfsteal-warn уронил рендер\n"; fail=1; }
  grep -q 'SELFSTEAL=yes' "$TMP/stderr.txt" \
    && echo "$out" | grep -q '"sni=other.example.com use=xray"' \
    && printf "  ok: selfsteal-mismatch предупреждает и рендерит\n" \
    || { printf "  FAIL: selfsteal-warn\n"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- parity: xray_xver=v2 + accept=off — варнинг, генерация идет ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
  cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
WEB_BACKENDS=(
  "name=stub to=127.0.0.1:8080"
)
WEB_ROUTES=(
  "host=a.com use=stub"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_web=127.0.0.1:8443"
  "blackhole=deny"
  "xray_xver=v2"
)
EOF
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  if generate_configs >"$TMP/gen.log" 2>&1; then
    grep -q 'Xray шлёт PROXY' "$TMP/gen.log" \
      && printf "  ok: xver-parity предупреждает\n" \
      || { printf "  FAIL: нет xver-варнинга\n"; fail=1; }
  else
    printf "  FAIL: generate с xver упал\n"; fail=1
  fi
  # мусор в xray_xver — жесткая ошибка
  HAPROXY_DIR_OVERRIDE="$TMP" bash -c 'source "$0/scripts/lib/common.sh" 2>/dev/null; GLOBAL_OPTS=("xray_xver=v3"); check_proxy_parity' "$PROJ" >/dev/null 2>&1 \
    && { printf "  FAIL: мусор xray_xver принят\n"; fail=1; } \
    || printf "  ok: мусор xray_xver отклонён\n"
  trap - EXIT
  rm -rf "$TMP"
  unset HAPROXY_DIR_OVERRIDE
}

# --- answers-валидация: мусор отклоняется ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  printf 'ACME_EMAIL=t@e.com\nWEB_MODE=bogus\nSITES_LINES=a.com:8080\nBLACKHOLE=deny\nTIMEOUT_PROFILE=sites-50s\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$TMP/answers"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers" >/dev/null 2>&1; then
    printf "  FAIL: мусор в WEB_MODE принят\n"; fail=1
  else
    printf "  ok: мусор в WEB_MODE отклонён\n"
  fi
  printf 'ACME_EMAIL=t@e.com\nWEB_MODE=xhttp-split\nXHTTP_DOMAIN=x.cdn.example.com\nXHTTP_PORT=11443\nXHTTP_PATH=data-no-slash\nSTUB_PORT=8080\nBLACKHOLE=deny\nTIMEOUT_PROFILE=xhttp-1h\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$TMP/answers2"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers2" >/dev/null 2>&1; then
    printf "  FAIL: path без / принят\n"; fail=1
  else
    printf "  ok: path без / отклонён\n"
  fi
  printf 'ACME_EMAIL=сcool@example.com\nWEB_MODE=sites\nSITES_LINES=a.com:8080\nBLACKHOLE=deny\nTIMEOUT_PROFILE=sites-50s\nBACKEND_CHECK=off\nLOGS_CAPTURE=off\n' > "$TMP/answers3"
  if HAPROXY_DIR_OVERRIDE="$PROJ" bash "$PROJ/scripts/preset.sh" apply web-direct --dry-run --answers "$TMP/answers3" >/dev/null 2>&1; then
    printf "  FAIL: кириллица в email принята\n"; fail=1
  else
    printf "  ok: кириллица в email отклонена\n"
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

# --- #if/#else юнит на временном пресете ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/presets/cond"
  cat > "$TMP/presets/cond/preset.conf" << 'EOF'
ACME_EMAIL="{{ACME_EMAIL}}"
GLOBAL_OPTS=(
#if MODE==a
  "blackhole=deny"
#else
  "blackhole=tarpit"
#endif
)
EOF
  cat > "$TMP/presets/cond/questions" << 'EOF'
ACME_EMAIL|Email|mail@example.com|email
MODE|Режим|a|oneof:a,b
EOF
  printf 'ACME_EMAIL=t@e.com\nMODE=b\n' > "$TMP/answers"
  out=$(PRESETS_DIR_OVERRIDE="$TMP/presets" HAPROXY_DIR_OVERRIDE="$TMP" bash "$PROJ/scripts/preset.sh" apply cond --dry-run --answers "$TMP/answers" 2>/dev/null)
  echo "$out" | grep -q '"blackhole=tarpit"' \
    && ! echo "$out" | grep -q '"blackhole=deny"' \
    && printf "  ok: #if/#else переключает ветки\n" \
    || { printf "  FAIL: #if/#else\n%s\n" "$out"; fail=1; }
  trap - EXIT
  rm -rf "$TMP"
}

# --- golden: новые опции генератора не сломаны (sites4) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$TDIR/fixtures/sites4.conf" "$TMP/sites.conf"
  export HAPROXY_DIR_OVERRIDE="$TMP"
  # shellcheck disable=SC1091
  source "$PROJ/scripts/lib/common.sh"
  generate_configs > ${TEST_TMP:-/tmp}/preset-g4-log.txt 2>&1 || { printf "  FAIL: generate на sites4\n"; cat ${TEST_TMP:-/tmp}/preset-g4-log.txt; fail=1; }
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

# --- --no-validate: пишет без проверяльщика, с варнингом ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
WEB_MODE=sites
SITES_LINES=a.com:8080
BLACKHOLE=deny
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  if HAPROXY_NO_VALIDATE= HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply web-direct --yes --no-validate --answers "$TMP/answers" > "$TMP/nv.log" 2>&1; then
    grep -q 'Пропускаю проверку' "$TMP/nv.log" \
      && [ -f "$TMP/web/haproxy.cfg" ] \
      && printf "  ok: --no-validate пишет с варнингом\n" \
      || { printf "  FAIL: --no-validate без варнинга/файлов\n"; fail=1; }
  else
    printf "  FAIL: --no-validate упал\n"; fail=1
  fi
  trap - EXIT
  rm -rf "$TMP"
}

# --- пустой ответ на вопрос валидации = строго (без проверяльщика падает) ---
{
  TMP="$(mktmp)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/answers" << 'EOF'
ACME_EMAIL=t@e.com
WEB_MODE=sites
SITES_LINES=a.com:8080
BLACKHOLE=deny
TIMEOUT_PROFILE=sites-50s
BACKEND_CHECK=off
LOGS_CAPTURE=off
EOF
  printf '\ny\nn\n' > "$TMP/tty-in"
  if HAPROXY_NO_VALIDATE= PRESET_TTY="$TMP/tty-in" HAPROXY_DIR_OVERRIDE="$TMP" PRESETS_DIR_OVERRIDE="$PROJ/presets" \
      bash "$PROJ/scripts/preset.sh" apply web-direct --answers "$TMP/answers" > "$TMP/strict.log" 2>&1; then
    printf "  FAIL: строгая генерация без проверяльщика прошла\n"; fail=1
  else
    grep -q 'не прошёл валидацию\|Нечем проверить' "$TMP/strict.log" \
      && [ -f "$TMP/sites.conf" ] \
      && [ ! -f "$TMP/web/haproxy.cfg" ] \
      && printf "  ok: пустой ответ = строго (sites записан, cfg нет)\n" \
      || { printf "  FAIL: строгость по дефолту\n"; fail=1; }
  fi
  trap - EXIT
  rm -rf "$TMP"
}

exit "$fail"
