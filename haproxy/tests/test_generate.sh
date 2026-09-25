#!/bin/bash
# Golden-тест генерации: фикстура sites.conf -> generate_configs -> diff с эталоном.
# Герметичен: работает во временной копии, docker/haproxy не нужны.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stream" "$TMP/web" "$TMP/custom"
cp "$TDIR/fixtures/sites-v1.conf" "$TMP/sites.conf"

export HAPROXY_DIR_OVERRIDE="$TMP"
# shellcheck disable=SC1091
source "$TDIR/../scripts/lib/common.sh"

fail=0
check() { # check <описание> <команда...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  ok: %s\n" "$desc"
  else
    printf "  FAIL: %s\n" "$desc"
    fail=1
  fi
}

# Заглушаем интерактив/внешнее: generate_configs не должен ничего спрашивать
generate_configs > /tmp/golden-test-log.txt 2>&1 || { printf "  FAIL: generate_configs упал\n"; cat /tmp/golden-test-log.txt; exit 1; }

diff -u "$TDIR/fixtures/expected-stream.cfg" "$TMP/stream/haproxy.cfg" \
  && printf "  ok: stream.cfg совпал с эталоном\n" \
  || { printf "  FAIL: stream.cfg отличается от эталона\n"; fail=1; }

diff -u "$TDIR/fixtures/expected-web.cfg" "$TMP/web/haproxy.cfg" \
  && printf "  ok: web.cfg совпал с эталоном\n" \
  || { printf "  FAIL: web.cfg отличается от эталона\n"; fail=1; }

# Custom-вставка должна подклеиться
printf '    # test-marker-123\n' > "$TMP/custom/web-frontend-99-test.cfg"
generate_configs > /tmp/golden-test-log.txt 2>&1
grep -q 'test-marker-123' "$TMP/web/haproxy.cfg" \
  && printf "  ok: custom-вставка подклеилась\n" \
  || { printf "  FAIL: custom-вставка потерялась\n"; fail=1; }
rm -f "$TMP/custom/web-frontend-99-test.cfg"

# Бэкапы создаются и ротируются
count=$(list_backups | wc -l)
[ "$count" -ge 1 ] \
  && printf "  ok: бэкапы создаются (%s шт)\n" "$count" \
  || { printf "  FAIL: бэкапов нет\n"; fail=1; }

exit "$fail"
