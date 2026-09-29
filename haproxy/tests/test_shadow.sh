#!/bin/bash
# Fail-closed: дубли SNI/Host+path с разным бэкендом роняют генерацию.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$PROJ/scripts/lib/common.sh"

# Stream v3: один SNI в разные бэкенды — ошибка.
STREAM_ROUTES=('sni=a.com to=127.0.0.1:1 name=x' 'sni=a.com to=127.0.0.1:2 name=y' 'sni=default to=127.0.0.1:8443 name=web')
STREAM_BACKENDS=()
STREAM_FRONTENDS=()
if generate_stream_config >/dev/null 2>&1; then
  printf "  FAIL: дубль SNI принят\n"; fail=1
else
  printf "  ok: дубль SNI роняет генерацию\n"
fi

# Stream v3: идентичный инлайн-дубль — тоже ошибка (клаш имен ящиков).
STREAM_ROUTES=('sni=a.com to=127.0.0.1:1 name=x' 'sni=a.com to=127.0.0.1:1 name=x' 'sni=default to=127.0.0.1:8443 name=web')
if generate_stream_config >/dev/null 2>&1; then
  printf "  FAIL: идентичный инлайн-дубль принят\n"; fail=1
else
  printf "  ok: идентичный инлайн-дубль роняет генерацию (клаш имен)\n"
fi

# Stream v3: тот же SNI на тот же именованный ящик — варнинг, не ошибка.
STREAM_BACKENDS=('name=shared to=127.0.0.1:1')
STREAM_ROUTES=('sni=a.com use=shared' 'sni=a.com use=shared' 'sni=default to=127.0.0.1:8443 name=web')
if generate_stream_config >/dev/null 2>&1; then
  printf "  ok: дубль ссылки на тот же ящик терпим\n"
else
  printf "  FAIL: дубль ссылки уронил генерацию\n"; fail=1
fi
STREAM_BACKENDS=()

# Stream v3: один SNI в разных фронтендах — легально.
STREAM_FRONTENDS=('name=one bind=*:443' 'name=two bind=127.0.0.1:4443')
STREAM_ROUTES=('sni=a.com to=127.0.0.1:1 name=x frontend=one' 'sni=a.com to=127.0.0.1:2 name=y frontend=two' 'sni=default to=127.0.0.1:8443 name=web')
if generate_stream_config >/dev/null 2>&1; then
  printf "  ok: один SNI в разных фронтендах легален\n"
else
  printf "  FAIL: скоупы фронтендов сломаны\n"; fail=1
fi
STREAM_FRONTENDS=()

# Web v3: один host+path в разные бэкенды — ошибка.
WEB_ROUTES=('host=a.com to=127.0.0.1:1' 'host=a.com to=127.0.0.1:2')
WEB_BACKENDS=()
WEB_FRONTENDS=()
if generate_web_config >/dev/null 2>&1; then
  printf "  FAIL: дубль host принят\n"; fail=1
else
  printf "  ok: дубль host роняет генерацию\n"
fi

# Web v3: один host, разные path — легально.
WEB_ROUTES=('host=a.com to=127.0.0.1:1 path=/x' 'host=a.com to=127.0.0.1:2')
if generate_web_config >/dev/null 2>&1; then
  printf "  ok: host с разными path легален\n"
else
  printf "  FAIL: path-сплит сломан\n"; fail=1
fi

# Legacy: один домен в разные порты — ошибка (v3-массивы пустые → legacy-ветка).
WEB_ROUTES=()
STREAM_ROUTES=()
WEB_SITES=('a.com:1111' 'a.com:2222')
REALITY_SITES=('r.com:10443')
if generate_web_config >/dev/null 2>&1; then
  printf "  FAIL: legacy дубль принят\n"; fail=1
else
  printf "  ok: legacy дубль роняет генерацию\n"
fi
WEB_SITES=()
REALITY_SITES=()

exit "$fail"
