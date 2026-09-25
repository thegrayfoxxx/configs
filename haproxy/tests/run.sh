#!/bin/bash
# Раннер тестов волны 1: синтаксис + shellcheck (если есть) + golden + юниты.
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

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
  while IFS= read -r f; do
    if shellcheck -S warning "$f"; then
      printf "  ok: %s\n" "${f#$PROJ/}"
    else
      printf "  FAIL: %s\n" "${f#$PROJ/}"
      fail=1
    fi
  done < <(find "$PROJ/haproxy" -name '*.sh' -not -path '*/.git/*' | sort)
else
  printf "== shellcheck пропущен (нет бинарника) ==\n"
fi

printf "== functional tests ==\n"
while IFS= read -r t; do
  printf -- "-- %s --\n" "$(basename "$t")"
  bash "$t" || fail=1
done < <(find "$TDIR" -maxdepth 1 -name 'test_*.sh' | sort)

if [ "$fail" -eq 0 ]; then
  printf "\nALL GREEN\n"
else
  printf "\nFAILURES PRESENT\n"
fi
exit "$fail"
