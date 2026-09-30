#!/bin/bash
# Регресс-тест: подменю-списки обязаны грузить данные из файла сами.
# Баг: fe_menu/be_menu читали массивы из памяти без load_sites — при прямом
# входе в пункт всегда показывали "не заданы", хотя файл полон.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

# 1. Статика: каждое меню-отображение грузит данные до цикла.
for spec in \
  "commands/stream.sh:fe_menu" "commands/stream.sh:be_menu" \
  "commands/web.sh:fe_menu" "commands/web.sh:be_menu" \
  "commands/stream.sh:add_route" "commands/stream.sh:remove_route" "commands/stream.sh:rt_menu" "commands/stream.sh:print_routes_table" \
  "commands/web.sh:add_route" "commands/web.sh:remove_route" "commands/web.sh:rt_menu" "commands/web.sh:print_routes_table" \
  "commands/stream.sh:fe_add" "commands/stream.sh:fe_remove" \
  "commands/stream.sh:be_add" "commands/stream.sh:be_remove" \
  "commands/web.sh:fe_add" "commands/web.sh:fe_remove" \
  "commands/web.sh:be_add" "commands/web.sh:be_remove"; do
  f="${spec%%:*}"
  fn="${spec##*:}"
  body=$(awk "/^$fn\(\)/{flag=1} flag{print} flag&&/^\}/{exit}" "$PROJ/scripts/$f")
  if echo "$body" | grep -q "load_sites"; then
    printf "  ok: %s %s грузит данные\n" "$f" "$fn"
  else
    printf "  FAIL: %s %s без load_sites\n" "$f" "$fn"
    fail=1
  fi
done

# 2. Поведение: свежий процесс, массивы пусты, файл полон — извлечение
# через load_sites (как теперь делают меню) видит сущности.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cat > "$TMP/sites.conf" << 'EOF'
ACME_EMAIL="t@e.com"
STREAM_FRONTENDS=(
  "name=public bind=*:443"
)
WEB_BACKENDS=(
  "name=app to=127.0.0.1:8080"
)
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:8443 name=web"
)
WEB_ROUTES=(
  "host=a.com use=app"
)
GLOBAL_OPTS=(
)
EOF
export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$PROJ/scripts/lib/common.sh"
# Имитация входа в подменю без предзагрузки: массивы из source — пустые.
[ "${#STREAM_FRONTENDS[@]}" -eq 0 ] && [ "${#WEB_BACKENDS[@]}" -eq 0 ] \
  && printf "  ok: стартовое состояние пустое (как у свежего меню)\n" \
  || { printf "  FAIL: массивы непусты на старте\n"; fail=1; }
load_sites >/dev/null 2>&1
[ "${#STREAM_FRONTENDS[@]}" -eq 1 ] && [ "${#WEB_BACKENDS[@]}" -eq 1 ] \
  && frontend_exists stream public \
  && backend_exists web app \
  && printf "  ok: после load_sites меню видит фронтенды и ящики\n" \
  || { printf "  FAIL: load_sites не отдал сущности\n"; fail=1; }

exit "$fail"
