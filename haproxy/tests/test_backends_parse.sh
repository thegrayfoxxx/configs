#!/bin/bash
# Unit-тесты сущности BACKENDS (фаза 1): парсеры ящиков и ключ use= в маршрутах.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
touch "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
ok() { printf "  ok: %s\n" "$1"; }
bad() { printf "  FAIL: %s\n" "$1"; fail=1; }

# --- parse_stream_backend ---
parse_stream_backend 'name=a to=127.0.0.1:10443' \
  && [ "$B_NAME" = "a" ] && [ "$B_TO" = "127.0.0.1:10443" ] && [ "$B_PROXY" = "off" ] && [ "$B_LOG" = "on" ] \
  && ok "stream-ящик парсится с дефолтами" || bad "stream-ящик"
parse_stream_backend 'name=a to=127.0.0.1:10443 proxy=v2 log=off' \
  && [ "$B_PROXY" = "v2" ] && [ "$B_LOG" = "off" ] \
  && ok "stream-ящик с флагами" || bad "stream-ящик с флагами"
parse_stream_backend 'name=a to=127.0.0.1:10443' >/dev/null 2>&1 \
  && ok "валидный ящик проходит" || bad "валидный ящик упал"
for be in 'name=a' 'to=127.0.0.1:10443' 'name=bad! to=127.0.0.1:1' 'name=a to=127.0.0.1:99999' \
           'name=a to=nocolon' 'name=a to=127.0.0.1:1 proxy=v9' 'name=a to=127.0.0.1:1 log=maybe' \
           'name=a to=127.0.0.1:1 foo=1' 'name=a to=127.0.0.1:1 extra-token'; do
  parse_stream_backend "$be" >/dev/null 2>&1 \
    && bad "битый stream-ящик принят: $be" || ok "битый stream-ящик отклонён: $be"
done

# --- parse_web_backend ---
parse_web_backend 'name=app to=127.0.0.1:8080 log=off' \
  && [ "$B_NAME" = "app" ] && [ "$B_LOG" = "off" ] \
  && ok "web-ящик парсится" || bad "web-ящик"
parse_web_backend 'name=app to=127.0.0.1:8080 proxy=v2' >/dev/null 2>&1 \
  && bad "proxy в web-ящике принят" || ok "proxy в web-ящике отклонён"
parse_web_backend 'name=app' >/dev/null 2>&1 \
  && bad "web-ящик без to принят" || ok "web-ящик без to отклонён"

# --- use= в маршрутах ---
parse_stream_route 'sni=a.com use=abox' >/dev/null 2>&1 \
  && [ "$S3_USE" = "abox" ] && [ -z "$S3_TO" ] \
  && ok "stream use= парсится" || bad "stream use="
parse_stream_route 'sni=a.com to=127.0.0.1:1 use=abox' >/dev/null 2>&1 \
  && bad "to+use приняты" || ok "to+use отклонены"
parse_stream_route 'sni=a.com' >/dev/null 2>&1 \
  && bad "маршрут без адреса принят" || ok "маршрут без адреса отклонён"
parse_stream_route 'sni=a.com use=abox name=x' >/dev/null 2>&1 \
  && bad "name при use принят" || ok "name при use отклонён"
parse_stream_route 'sni=a.com use=abox proxy=v2' >/dev/null 2>&1 \
  && bad "proxy при use принят" || ok "proxy при use отклонён"
parse_stream_route 'sni=a.com use=abox log=off' >/dev/null 2>&1 \
  && bad "log при use принят" || ok "log при use отклонён"
parse_stream_route 'sni=a.com use=bad!' >/dev/null 2>&1 \
  && bad "битый use принят" || ok "битый use отклонён"
# Старый формат без use продолжает работать.
parse_stream_route 'sni=a.com to=127.0.0.1:10443 proxy=off name=sni-1' >/dev/null 2>&1 \
  && [ -z "$S3_USE" ] \
  && ok "инлайн-формат без изменений" || bad "инлайн-формат сломан"

parse_web_route 'host=a.com use=app' >/dev/null 2>&1 \
  && [ "$W3_USE" = "app" ] \
  && ok "web use= парсится" || bad "web use="
parse_web_route 'host=a.com to=127.0.0.1:1 use=app' >/dev/null 2>&1 \
  && bad "web to+use приняты" || ok "web to+use отклонены"
parse_web_route 'host=a.com use=app path=/api/' >/dev/null 2>&1 \
  && [ "$W3_PATH" = "/api/" ] \
  && ok "path сочетается с use" || bad "path+use"
parse_web_route 'host=a.com' >/dev/null 2>&1 \
  && bad "web без адреса принят" || ok "web без адреса отклонён"

# --- validate_backend_refs ---
STREAM_BACKENDS=('name=abox to=127.0.0.1:10443')
WEB_BACKENDS=()
STREAM_ROUTES=('sni=a.com use=abox' 'sni=default to=127.0.0.1:8443 name=web')
WEB_ROUTES=()
validate_backend_refs stream >/dev/null 2>&1 \
  && ok "валидные ссылки проходят" || bad "валидные ссылки упали"

STREAM_ROUTES=('sni=a.com use=ghost' 'sni=default to=127.0.0.1:8443 name=web')
validate_backend_refs stream >/dev/null 2>&1 \
  && bad "ссылка в никуда принята" || ok "ссылка в никуда отклонена"

STREAM_BACKENDS=('name=abox to=127.0.0.1:1' 'name=abox to=127.0.0.1:2')
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
validate_backend_refs stream >/dev/null 2>&1 \
  && bad "дубли ящиков приняты" || ok "дубли ящиков отклонены"

# Висячий ящик — варнинг, но проход.
STREAM_BACKENDS=('name=lonely to=127.0.0.1:19999')
warn=$(validate_backend_refs stream 2>&1) \
  && echo "$warn" | grep -q 'висячий' \
  && ok "висячий: варнинг без падения" || bad "висячий"

# backend_exists / backend_refs.
STREAM_BACKENDS=('name=abox to=127.0.0.1:10443')
STREAM_ROUTES=('sni=a.com use=abox' 'sni=b.com use=abox' 'sni=default to=127.0.0.1:8443 name=web')
backend_exists stream abox && ok "exists находит ящик" || bad "exists"
backend_exists stream ghost && bad "exists нашёл призрака" || ok "exists не находит призрака"
[ "$(backend_refs stream abox | wc -l)" -eq 2 ] \
  && ok "refs считает ссылающиеся" || bad "refs"

# --- backend_add/backend_remove (lib-хелперы) ---
STREAM_BACKENDS=()
WEB_BACKENDS=()
STREAM_ROUTES=()
WEB_ROUTES=()
backend_add stream 'name=abox to=127.0.0.1:10443 proxy=v2 log=off' >/dev/null 2>&1 \
  && [ "${#STREAM_BACKENDS[@]}" -eq 1 ] \
  && ok "backend_add кладёт запись" || bad "backend_add"
backend_add stream 'name=abox to=127.0.0.1:1' >/dev/null 2>&1 \
  && bad "дубль ящика принят" || ok "дубль ящика отклонён"
backend_add stream 'name=bad to=nocolon' >/dev/null 2>&1 \
  && bad "битый ящик принят" || ok "битый ящик отклонён"
STREAM_ROUTES=('sni=a.com use=abox' 'sni=default to=127.0.0.1:8443 name=web')
backend_remove stream abox >/dev/null 2>&1 \
  && bad "удаление занятого принято" || ok "удаление занятого отклонено"
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
backend_remove stream abox >/dev/null 2>&1 \
  && [ "${#STREAM_BACKENDS[@]}" -eq 0 ] \
  && ok "свободный ящик удаляется" || bad "свободный не удалился"

# --- save/load round-trip держит ящики ---
STREAM_BACKENDS=('name=abox to=127.0.0.1:10443 proxy=v2')
WEB_BACKENDS=('name=app to=127.0.0.1:8080 log=off')
STREAM_ROUTES=('sni=a.com use=abox' 'sni=default to=127.0.0.1:8443 name=web')
WEB_ROUTES=('host=a.com use=app')
STREAM_FRONTENDS=()
WEB_FRONTENDS=()
ACME_EMAIL="t@e.com"
GLOBAL_OPTS=()
save_sites >/dev/null 2>&1
STREAM_BACKENDS=()
WEB_BACKENDS=()
STREAM_ROUTES=()
WEB_ROUTES=()
load_sites >/dev/null 2>&1
[ "${#STREAM_BACKENDS[@]}" -eq 1 ] && [ "${#WEB_BACKENDS[@]}" -eq 1 ] \
  && [ "${#STREAM_ROUTES[@]}" -eq 2 ] \
  && ok "round-trip держит ящики и ссылки" || bad "round-trip потерял ящики"
# --- Строгость: дубли ключей и пустые значения ---
parse_stream_route 'sni=a.com to=127.0.0.1:1 to=127.0.0.1:2' >/dev/null 2>&1 \
  && bad "дубль to принят" || ok "дубль to отклонён"
parse_stream_route 'sni=a.com to=127.0.0.1:1 name=' >/dev/null 2>&1 \
  && bad "пустой name принят" || ok "пустой name отклонён"
parse_stream_route 'sni=a.com to=' >/dev/null 2>&1 \
  && bad "пустой to принят" || ok "пустой to отклонён"
parse_web_route 'host=a.com to=127.0.0.1:1 to=127.0.0.1:2' >/dev/null 2>&1 \
  && bad "дубль to принят (web)" || ok "дубль to отклонён (web)"
parse_stream_backend 'name=a to=127.0.0.1:1 to=127.0.0.1:2' >/dev/null 2>&1 \
  && bad "дубль to принят (ящик)" || ok "дубль to отклонён (ящик)"
parse_frontend 'name=a bind=*:443 bind=*:444' >/dev/null 2>&1 \
  && bad "дубль bind принят" || ok "дубль bind отклонён"
parse_stream_route 'sni=default extra.com to=127.0.0.1:1' >/dev/null 2>&1 \
  && bad "default в списке принят" || ok "default в списке отклонён"

# --- kind=web: те же хелперы ---
WEB_BACKENDS=()
WEB_ROUTES=()
backend_add web 'name=app to=127.0.0.1:8080 log=off' >/dev/null 2>&1 \
  && [ "${#WEB_BACKENDS[@]}" -eq 1 ] \
  && ok "web: backend_add кладёт запись" || bad "web: backend_add"
backend_add web 'name=app to=127.0.0.1:1' >/dev/null 2>&1 \
  && bad "web: дубль принят" || ok "web: дубль отклонён"
WEB_ROUTES=('host=a.com use=app')
backend_remove web app >/dev/null 2>&1 \
  && bad "web: удаление занятого принято" || ok "web: удаление занятого отклонено"
WEB_ROUTES=()
backend_remove web app >/dev/null 2>&1 \
  && [ "${#WEB_BACKENDS[@]}" -eq 0 ] \
  && ok "web: свободный удаляется" || bad "web: удаление"

exit "$fail"
