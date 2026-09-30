#!/bin/bash
# Раннер тестов волны 1: синтаксис + shellcheck (если есть) + golden + юниты.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

# Fail-closed по дефолту требует бинарник haproxy для валидации — в CI/dev его
# нет, поэтому тесты явно разрешают пропуск (прод так не делает).
export HAPROXY_NO_VALIDATE=1

printf "== bash -n ==\n"
while IFS= read -r f; do
  if bash -n "$f"; then
    printf "  ok: %s\n" "${f#$PROJ/}"
  else
    printf "  FAIL: %s\n" "${f#$PROJ/}"
    fail=1
  fi
done < <(find "$PROJ" -name '*.sh' -not -path '*/.git/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  printf "== shellcheck ==\n"
  sc_count=0
  while IFS= read -r f; do
    sc_count=$((sc_count + 1))
    if shellcheck -S warning "$f"; then
      printf "  ok: %s\n" "${f#$PROJ/}"
    else
      printf "  FAIL: %s\n" "${f#$PROJ/}"
      fail=1
    fi
  done < <(find "$PROJ" -name '*.sh' -not -path '*/.git/*' | sort)
  if [ "$sc_count" -eq 0 ]; then
    printf "  FAIL: shellcheck не нашёл ни одного файла (сломан путь поиска)\n"
    fail=1
  fi
else
  printf "== shellcheck пропущен (нет бинарника) ==\n"
fi

printf "== functional tests ==\n"
# Изолированная помойка для логов (иначе хардкод /tmp/*.txt гоняет между прогонами).
RUN_TMP=$(mktemp -d)
export TEST_TMP="$RUN_TMP"
trap 'rm -rf "$RUN_TMP"' EXIT
# Сторож от зависших визардов (если timeout есть).
TIMEOUT_RUN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_RUN="timeout 150"
while IFS= read -r t; do
  printf -- "-- %s --\n" "$(basename "$t")"
  # shellcheck disable=SC2086
  $TIMEOUT_RUN bash "$t" || fail=1
done < <(find "$TDIR" -maxdepth 1 -name 'test_*.sh' | sort)

if [ "$fail" -eq 0 ]; then
  printf "\nALL GREEN\n"
else
  printf "\nFAILURES PRESENT\n"
fi
exit "$fail"
