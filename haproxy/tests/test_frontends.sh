#!/bin/bash
# Golden-тест multi-frontend stream+web + fail-closed областей.
# Герметичен: временная копия, docker/haproxy не нужны.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v4fe.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
generate_configs > /tmp/golden-4fe-log.txt 2>&1 || { printf "  FAIL: generate_configs упал\n"; cat /tmp/golden-4fe-log.txt; exit 1; }

diff -u "$TDIR/fixtures/expected4fe-stream.cfg" "$TMP/stream/haproxy.cfg" \
  && printf "  ok: 4fe stream.cfg совпал с эталоном\n" \
  || { printf "  FAIL: 4fe stream.cfg отличается\n"; fail=1; }

diff -u "$TDIR/fixtures/expected4fe-web.cfg" "$TMP/web/haproxy.cfg" \
  && printf "  ok: 4fe web.cfg совпал с эталоном\n" \
  || { printf "  FAIL: 4fe web.cfg отличается\n"; fail=1; }

# Два фронтенда, у каждого свой bind.
grep -q '^frontend ft_public' "$TMP/stream/haproxy.cfg" \
  && grep -q '^frontend ft_office' "$TMP/stream/haproxy.cfg" \
  && printf "  ok: оба фронтенда на месте\n" \
  || { printf "  FAIL: фронтендов нет\n"; fail=1; }

# Область: sni-1 только в public, sni-2 только в office, shared в обоих.
# Якоря use_backend исключают совпадения с префиксами (bk_sni-1 vs bk_sni-10).
pub=$(sed -n '/^frontend ft_public/,/^frontend ft_office/p' "$TMP/stream/haproxy.cfg")
echo "$pub" | grep -q 'use_backend bk_sni-1 ' \
  && ! echo "$pub" | grep -q 'use_backend bk_sni-2 ' \
  && printf "  ok: области public соблюдены\n" \
  || { printf "  FAIL: области public\n"; fail=1; }
off=$(sed -n '/^frontend ft_office/,/^backend /p' "$TMP/stream/haproxy.cfg" | grep -v '^backend ')
echo "$off" | grep -q 'use_backend bk_sni-2' \
  && ! echo "$off" | grep -q 'use_backend bk_sni-1' \
  && printf "  ok: области office соблюдены\n" \
  || { printf "  FAIL: области office\n"; fail=1; }

# Бэкенды общие: bk_shared и bk_web по одному разу.
[ "$(grep -c '^backend bk_shared' "$TMP/stream/haproxy.cfg")" = "1" ] \
  && [ "$(grep -c '^backend bk_web' "$TMP/stream/haproxy.cfg")" = "1" ] \
  && printf "  ok: бэкенды общие, без дублей\n" \
  || { printf "  FAIL: дубли бэкендов\n"; fail=1; }

# Frontend log=off глушит только свой фронтенд (проверяем секцию frontend,
# а не весь кусок — 'no log' бэкендов ниже не должен влиять).
echo "$off" | sed -n '/^frontend /,/^ *default_backend/p' | grep -q 'no log' \
  && ! echo "$pub" | sed -n '/^frontend /,/^ *default_backend/p' | grep -q 'no log' \
  && printf "  ok: log=off только на своём фронтенде\n" \
  || { printf "  FAIL: frontend log\n"; fail=1; }

# --- Web-фронтенды ---
grep -q '^frontend ft_main' "$TMP/web/haproxy.cfg" \
  && grep -q '^frontend ft_internal' "$TMP/web/haproxy.cfg" \
  && printf "  ok: оба web-фронтенда на месте\n" \
  || { printf "  FAIL: web-фронтендов нет\n"; fail=1; }

wmain=$(sed -n '/^frontend ft_main/,/^frontend ft_internal/p' "$TMP/web/haproxy.cfg")
echo "$wmain" | grep -q 'use_backend bk_site_site1_com ' \
  && ! echo "$wmain" | grep -q 'bk_site_ops_internal' \
  && printf "  ok: области web-main соблюдены\n" \
  || { printf "  FAIL: области web-main\n"; fail=1; }
wint=$(sed -n '/^frontend ft_internal/,/^backend /p' "$TMP/web/haproxy.cfg" | grep -v '^backend ')
echo "$wint" | grep -q 'use_backend bk_site_ops_internal' \
  && ! echo "$wint" | grep -q 'use_backend bk_site_site1_com' \
  && printf "  ok: области web-internal соблюдены\n" \
  || { printf "  FAIL: области web-internal\n"; fail=1; }

# log=off web-фронтенда глушит его секцию (бэкенды ниже — отдельно).
wint_fe=$(sed -n '/^frontend ft_internal/,/^ *default_backend/p' "$TMP/web/haproxy.cfg")
echo "$wint_fe" | grep -q '^    no log' \
  && printf "  ok: log=off web-фронтенда применён\n" \
  || { printf "  FAIL: web frontend log\n"; fail=1; }

# Общий бэкенд и blackhole — по одному разу.
[ "$(grep -c '^backend bk_site_shared_example_com' "$TMP/web/haproxy.cfg")" = "1" ] \
  && [ "$(grep -c '^backend bk_blackhole' "$TMP/web/haproxy.cfg")" = "1" ] \
  && printf "  ok: web-бэкенды общие, без дублей\n" \
  || { printf "  FAIL: дубли web-бэкендов\n"; fail=1; }

# log=off на web-маршруте глушит его backend.
grep -A3 '^backend bk_site_ops_internal' "$TMP/web/haproxy.cfg" | grep -q 'no log' \
  && printf "  ok: web log=off даёт no log\n" \
  || { printf "  FAIL: web log=off\n"; fail=1; }

# --- Fail-closed ---
# 1. Маршрут на неизвестный фронтенд.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 frontend=ghost' 'sni=default to=127.0.0.1:8443 name=web')
STREAM_FRONTENDS=('name=public bind=*:443')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: неизвестный фронтенд не уронил генерацию\n"; fail=1
else
  printf "  ok: неизвестный фронтенд роняет генерацию\n"
fi

# 2. Фронтенд без default.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 frontend=public')
STREAM_FRONTENDS=('name=public bind=*:443')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: фронтенд без default не уронил генерацию\n"; fail=1
else
  printf "  ok: фронтенд без default роняет генерацию\n"
fi

# 3. Дублирующиеся имена бэкендов.
STREAM_ROUTES=(
  'sni=a.com to=127.0.0.1:10443 name=dup'
  'sni=b.com to=127.0.0.1:10444 name=dup'
  'sni=default to=127.0.0.1:8443 name=web'
)
STREAM_FRONTENDS=()
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: дубли имён не уронили генерацию\n"; fail=1
else
  printf "  ok: дубли имён роняют генерацию\n"
fi

# 4. frontend= без объявленных фронтендов.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:10443 frontend=public' 'sni=default to=127.0.0.1:8443 name=web')
STREAM_FRONTENDS=()
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: область без фронтендов не уронила генерацию\n"; fail=1
else
  printf "  ok: область без фронтендов роняет генерацию\n"
fi

# 5. Web: маршрут на неизвестный фронтенд.
WEB_ROUTES=('host=a.com to=127.0.0.1:8080 frontend=ghost')
WEB_FRONTENDS=('name=main bind=*:8443')
if generate_web_v3 >/dev/null 2>&1; then
  printf "  FAIL: web на неизвестный фронтенд не уронил генерацию\n"; fail=1
else
  printf "  ok: web на неизвестный фронтенд роняет генерацию\n"
fi

# 6. Два своих default на один фронтенд.
STREAM_ROUTES=(
  'sni=default to=127.0.0.1:8443 name=web frontend=public'
  'sni=default to=127.0.0.1:8444 name=web2 frontend=public'
)
STREAM_FRONTENDS=('name=public bind=*:443')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: два своих default не уронили генерацию\n"; fail=1
else
  printf "  ok: два своих default роняют генерацию\n"
fi

# 7. Два глобальных default — непонятно какой для фронтенда.
STREAM_ROUTES=(
  'sni=default to=127.0.0.1:8443 name=web'
  'sni=default to=127.0.0.1:8444 name=web2'
)
STREAM_FRONTENDS=('name=public bind=*:443')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: два глобальных default не уронили генерацию\n"; fail=1
else
  printf "  ok: два глобальных default роняют генерацию\n"
fi

# 8. Default-ссылка в никуда.
STREAM_BACKENDS=('name=web to=127.0.0.1:8443')
STREAM_ROUTES=('sni=default use=ghost')
STREAM_FRONTENDS=()
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: default use=ghost не уронил генерацию\n"; fail=1
else
  printf "  ok: default use=ghost роняет генерацию\n"
fi
STREAM_BACKENDS=()

# 9. Пустой фронтенд (нет маршрутов — только default_backend).
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
STREAM_FRONTENDS=('name=lonely bind=127.0.0.1:9443')
out=$(generate_stream_v3) || { printf "  FAIL: пустой фронтенд уронил генерацию\n"; fail=1; }
echo "$out" | grep -q '^frontend ft_lonely' \
  && echo "$out" | grep -q 'default_backend bk_web' \
  && printf "  ok: пустой фронтенд генерируется с дефолтом\n" \
  || { printf "  FAIL: пустой фронтенд\n"; fail=1; }

# 10. Дубли фронтендов в generate.
STREAM_FRONTENDS=('name=dup bind=*:443' 'name=dup bind=*:8443')
if generate_stream_v3 >/dev/null 2>&1; then
  printf "  FAIL: дубли фронтендов не уронили генерацию\n"; fail=1
else
  printf "  ok: дубли фронтендов роняют генерацию\n"
fi
STREAM_FRONTENDS=()

# 11. Web: коллизия инлайн-тега с ящиком.
WEB_BACKENDS=('name=site_a_com to=127.0.0.1:9999')
WEB_ROUTES=('host=a.com to=127.0.0.1:8080')
WEB_FRONTENDS=()
if generate_web_v3 >/dev/null 2>&1; then
  printf "  FAIL: коллизия web-тега не уронила генерацию\n"; fail=1
else
  printf "  ok: коллизия web-тега роняет генерацию\n"
fi
WEB_BACKENDS=()

# 12. PROXY-parity видит proxy на ящике через ссылку.
STREAM_BACKENDS=('name=px to=127.0.0.1:10443 proxy=v2')
STREAM_ROUTES=('sni=a.com use=px' 'sni=default to=127.0.0.1:8443 name=web')
STREAM_FRONTENDS=()
GLOBAL_OPTS=()
par_out=$(check_proxy_parity 2>&1) \
  && echo "$par_out" | grep -q 'шлёт PROXY (v2)' \
  && printf "  ok: parity видит PROXY на ящике\n" \
  || { printf "  FAIL: parity слеп к ящику\n"; fail=1; }
STREAM_BACKENDS=()

# 13. Опции в multi: sni-лог + fallback proxy + checks.
STREAM_ROUTES=(
  'sni=a.com to=127.0.0.1:10443 name=sni-1 frontend=public'
  'sni=default to=127.0.0.1:8443 name=web'
)
STREAM_FRONTENDS=('name=public bind=*:443')
GLOBAL_OPTS=("stream_log_sni=on" "stream_web_proxy=v2" "backend_check=tcp")
out=$(generate_stream_v3 2>/dev/null) || { printf "  FAIL: multi+опции упал\n"; fail=1; }
echo "$out" | grep -q 'log-format.*SNI' \
  && echo "$out" | grep -q 'server web 127.0.0.1:8443 send-proxy-v2 check' \
  && echo "$out" | grep -q 'server sni-1 127.0.0.1:10443 check' \
  && printf "  ok: опции работают в multi\n" \
  || { printf "  FAIL: опции в multi\n"; fail=1; }
GLOBAL_OPTS=()
STREAM_FRONTENDS=()

# 14. use= + frontend= + sni-список через пробел.
STREAM_BACKENDS=('name=pair to=127.0.0.1:10443')
STREAM_ROUTES=(
  'sni=a.com b.com use=pair frontend=public'
  'sni=default to=127.0.0.1:8443 name=web'
)
STREAM_FRONTENDS=('name=public bind=*:443' 'name=office bind=127.0.0.1:4443')
out=$(generate_stream_v3 2>/dev/null) || { printf "  FAIL: use+frontend+список упал\n"; fail=1; }
echo "$out" | grep -q 'req.ssl_sni -i a.com b.com' \
  && echo "$out" | grep -q 'use_backend bk_pair' \
  && printf "  ok: use+frontend+список комбинируются\n" \
  || { printf "  FAIL: use+frontend+список\n"; fail=1; }
STREAM_BACKENDS=()
STREAM_FRONTENDS=()

# 15. Custom-вставки подклеиваются в каждый фронтенд multi.
 custom_tmp="$TMP/custom/stream-frontend-99-t.cfg"
printf '    # marker-fe-456\n' > "$custom_tmp"
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
STREAM_FRONTENDS=('name=one bind=*:443' 'name=two bind=*:444')
out=$(generate_stream_v3 2>/dev/null) || { printf "  FAIL: custom multi упал\n"; fail=1; }
[ "$(echo "$out" | grep -c 'marker-fe-456')" = "2" ] \
  && printf "  ok: custom в каждом фронтенде\n" \
  || { printf "  FAIL: custom multi\n"; fail=1; }
rm -f "$custom_tmp"
STREAM_FRONTENDS=()

exit "$fail"
