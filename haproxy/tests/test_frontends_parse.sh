#!/bin/bash
# Unit-тесты фазы фронтендов: parse_frontend, validate_frontends,
# ключ frontend= в маршрутах, route_in_frontend. Без генерации.
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

# --- parse_frontend: валидные ---
parse_frontend 'name=public bind=*:443' \
  && [ "$F_NAME" = "public" ] && [ "$F_BIND" = "*:443" ] && [ "$F_LOG" = "on" ] \
  && ok "парсинг name+bind" || bad "парсинг name+bind"
parse_frontend 'name=office bind=10.0.0.1:8445 log=off' \
  && [ "$F_LOG" = "off" ] \
  && ok "парсинг log=off" || bad "парсинг log падает"
parse_frontend 'name=transit bind=*:4443 accept_proxy=on' \
  && [ "$F_ACCEPT" = "on" ] \
  && ok "парсинг accept_proxy=on" || bad "парсинг accept_proxy падает"
parse_frontend 'name=a bind=*:443' \
  && [ "$F_ACCEPT" = "off" ] \
  && ok "accept_proxy дефолт off" || bad "accept_proxy дефолт не off"

# --- parse_frontend: битые (fail-closed) ---
parse_frontend 'name=public' >/dev/null 2>&1 \
  && bad "фронтенд без bind не упал" || ok "фронтенд без bind падает"
parse_frontend 'bind=*:443' >/dev/null 2>&1 \
  && bad "фронтенд без name не упал" || ok "фронтенд без name падает"
parse_frontend 'name=bad name! bind=*:443' >/dev/null 2>&1 \
  && bad "битое имя не упало" || ok "битое имя падает"
parse_frontend 'name=a bind=*:99999' >/dev/null 2>&1 \
  && bad "битый порт не упал" || ok "битый порт падает"
parse_frontend 'name=a bind=*:443 foo=1' >/dev/null 2>&1 \
  && bad "неизвестный ключ не упал" || ok "неизвестный ключ падает"
parse_frontend 'name=a bind=*:443 log=maybe' >/dev/null 2>&1 \
  && bad "битый log не упал" || ok "битый log падает"
parse_frontend 'name=a bind=*:443 accept_proxy=maybe' >/dev/null 2>&1 \
  && bad "битый accept_proxy не упал" || ok "битый accept_proxy падает"

# --- validate_frontends: дубли ---
STREAM_FRONTENDS=('name=a bind=*:443' 'name=a bind=*:8443')
validate_frontends stream >/dev/null 2>&1 \
  && bad "дубли имён не упали" || ok "дубли имён падают"
STREAM_FRONTENDS=('name=a bind=*:443' 'name=b bind=*:8443')
validate_frontends stream >/dev/null 2>&1 \
  && ok "уникальные имена проходят" || bad "уникальные имена упали"
STREAM_FRONTENDS=()
WEB_FRONTENDS=()
validate_frontends stream >/dev/null 2>&1 \
  && validate_frontends web >/dev/null 2>&1 \
  && ok "пустые массивы проходят" || bad "пустые массивы упали"

# --- frontend= в маршрутах ---
parse_stream_route 'sni=a.com to=127.0.0.1:10443 frontend=public' >/dev/null 2>&1 \
  && [ "$S3_FRONTEND" = "public" ] \
  && ok "stream frontend= парсится" || bad "stream frontend= не парсится"
parse_stream_route 'sni=a.com to=127.0.0.1:10443 frontend=bad!' >/dev/null 2>&1 \
  && bad "битый frontend= не упал" || ok "битый frontend= падает"
parse_web_route 'host=a.com to=127.0.0.1:8080 frontend=main' >/dev/null 2>&1 \
  && [ "$W3_FRONTEND" = "main" ] \
  && ok "web frontend= парсится" || bad "web frontend= не парсится"

# --- route_in_frontend: пустая область = везде ---
route_in_frontend "" "public" && ok "пустая область видна везде" || bad "пустая область"
route_in_frontend "public" "public" && ok "своя область видна" || bad "своя область"
route_in_frontend "office" "public" && bad "чужая область видна" || ok "чужая область скрыта"

# --- frontend_add/remove (lib-хелперы) ---
STREAM_FRONTENDS=()
GLOBAL_OPTS=("bind_stream=*:443")
frontend_add stream office 10.0.0.1:8445 >/dev/null 2>&1 \
  && [ "${#STREAM_FRONTENDS[@]}" -eq 2 ] \
  && [ "${STREAM_FRONTENDS[0]}" = "name=main bind=*:443" ] \
  && [ "${STREAM_FRONTENDS[1]}" = "name=office bind=10.0.0.1:8445" ] \
  && ok "первый фронтенд тянет авто-импорт main" || bad "авто-импорт main"
frontend_exists stream office && ok "exists видит добавленный" || bad "exists"
frontend_add stream office 10.0.0.1:8445 >/dev/null 2>&1 \
  && bad "дубль фронтенда не упал" || ok "дубль фронтенда падает"

# Удаление занятого отказывает с перечислением.
STREAM_ROUTES=('sni=x.com to=127.0.0.1:9999 frontend=office' 'sni=default to=127.0.0.1:8443 name=web')
[ -n "$(frontend_refs stream office)" ] \
  && ok "refs находит ссылающиеся маршруты" || bad "refs пустые"
frontend_remove stream office >/dev/null 2>&1 \
  && bad "удаление занятого не упало" || ok "удаление занятого падает"
frontend_exists stream office && ok "занятый на месте после отказа" || bad "занятый пропал"

# Удаление свободного проходит.
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
frontend_remove stream office >/dev/null 2>&1 \
  && ! frontend_exists stream office \
  && ok "свободный удаляется" || bad "свободный не удалился"

# --- save/load round-trip держит фронтенды ---
STREAM_FRONTENDS=('name=main bind=*:443' 'name=office bind=10.0.0.1:8445 log=off')
WEB_FRONTENDS=('name=main bind=*:8443')
STREAM_ROUTES=('sni=default to=127.0.0.1:8443 name=web')
WEB_ROUTES=()
ACME_EMAIL="t@e.com"
GLOBAL_OPTS=()
save_sites >/dev/null 2>&1
STREAM_FRONTENDS=()
WEB_FRONTENDS=()
STREAM_ROUTES=()
load_sites >/dev/null 2>&1
[ "${#STREAM_FRONTENDS[@]}" -eq 2 ] && [ "${#WEB_FRONTENDS[@]}" -eq 1 ] \
  && ok "round-trip держит фронтенды" || bad "round-trip потерял фронтенды"

# --- kind=web: те же хелперы ---
WEB_FRONTENDS=()
GLOBAL_OPTS=("bind_web=127.0.0.1:8443")
frontend_add web internal 10.0.0.1:9443 >/dev/null 2>&1 \
  && [ "${#WEB_FRONTENDS[@]}" -eq 2 ] \
  && [ "${WEB_FRONTENDS[0]}" = "name=main bind=127.0.0.1:8443" ] \
  && [ "${WEB_FRONTENDS[1]}" = "name=internal bind=10.0.0.1:9443" ] \
  && ok "web: авто-импорт bind_web→main" || bad "web: авто-импорт"
WEB_ROUTES=()
frontend_remove web internal >/dev/null 2>&1 \
  && ok "web: свободный удаляется" || bad "web: удаление"
frontend_add web internal 10.0.0.1:9443 >/dev/null 2>&1
WEB_ROUTES=('host=a.com frontend=internal to=127.0.0.1:1')
frontend_remove web internal >/dev/null 2>&1 \
  && bad "web: удаление занятого принято" || ok "web: удаление занятого отклонено"

# --- materialize_default_frontend: дефолт становится явным ---
STREAM_FRONTENDS=()
GLOBAL_OPTS=()
materialize_default_frontend stream >/dev/null 2>&1 \
  && [ "${#STREAM_FRONTENDS[@]}" -eq 1 ] \
  && [ "${STREAM_FRONTENDS[0]}" = "name=main bind=*:443" ] \
  && ok "stream: дефолт *:443 без GLOBAL_OPTS" || bad "stream: дефолт без опций"
WEB_FRONTENDS=()
materialize_default_frontend web >/dev/null 2>&1 \
  && [ "${WEB_FRONTENDS[0]}" = "name=main bind=*:8443" ] \
  && ok "web: дефолт *:8443 без GLOBAL_OPTS" || bad "web: дефолт без опций"
STREAM_FRONTENDS=()
GLOBAL_OPTS=("bind_stream=10.9.9.9:4443")
materialize_default_frontend stream >/dev/null 2>&1 \
  && [ "${STREAM_FRONTENDS[0]}" = "name=main bind=10.9.9.9:4443" ] \
  && ok "stream: дефолт берет bind из GLOBAL_OPTS" || bad "stream: дефолт из опций"
materialize_default_frontend stream >/dev/null 2>&1 \
  && [ "${#STREAM_FRONTENDS[@]}" -eq 1 ] \
  && ok "идемпотентность: повторный вызов ничего не добавляет" || bad "не идемпотентно"
GLOBAL_OPTS=("bind_stream=*:1111" "bind_stream=*:2222")
STREAM_FRONTENDS=()
materialize_default_frontend stream >/dev/null 2>&1 \
  && [ "${STREAM_FRONTENDS[0]}" = "name=main bind=*:1111" ] \
  && ok "дубль bind_*: берется первый" || bad "дубль bind_*"
GLOBAL_OPTS=()

exit "$fail"
