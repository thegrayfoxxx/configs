#!/bin/bash
# Регресс-тест порядка веток case в меню: '?)' обязан стоять ПОСЛЕ цифр/'0'
# и ПЕРЕД '*)'. Иначе '?' как односимвольный паттерн перехватывает '0'-'9'.
# (Статический анализ — интерактив не нужен.)
set -euo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$TDIR/.."
fail=0

python3 - "$PROJ" << 'EOF'
import pathlib, re, sys
proj = pathlib.Path(sys.argv[1])
files = ["haproxy.sh", "scripts/commands/stream.sh", "scripts/commands/web.sh",
         "scripts/commands/cert.sh", "scripts/commands/services.sh",
         "scripts/commands/backups.sh", "scripts/commands/preset.sh",
         "scripts/commands/global.sh",
         "scripts/ui/logs.sh"]
bad = 0
for rel in files:
    text = (proj / rel).read_text().splitlines()
    # найти все case-блоки меню: строки 'case ' ... 'esac', внутри ищем ветки
    in_case = 0
    seen_digit_or_zero = False
    q_line = None
    for i, line in enumerate(text, 1):
        s = line.strip()
        if re.match(r'^case\b', s):
            in_case += 1
            seen_digit_or_zero = False
            q_line = None
            continue
        if in_case and s == "esac":
            in_case -= 1
            continue
        if not in_case:
            continue
        if re.match(r'^(?:\d+\)|0\))', s):
            seen_digit_or_zero = True
        if re.match(r'^\?\)', s):
            if not seen_digit_or_zero:
                print(f"  FAIL: {rel}:{i}: ветка '?)' до цифр/'0'")
                bad += 1
            q_line = i
        if re.match(r'^\*\)', s) and q_line:
            q_line = None  # '?)' закрыта корректным '*)'
    # '?)' без последующего '*)' в том же кейсе
    if q_line:
        print(f"  FAIL: {rel}:{q_line}: после '?)' нет '*)'")
        bad += 1
print(f"  ok: порядок '?)' проверен в {len(files)} файлах" if bad == 0 else "  FAILURES in order check")
sys.exit(1 if bad else 0)
EOF
[ "$?" -eq 0 ] \
  && printf "  ok: '?)' всегда после цифр и перед '*'\n" \
  || { printf "  FAIL: порядок веток меню\n"; fail=1; }

# Структура секций Stream/Web: меню секции (Маршруты/Фронтенды/Бэкенды)
# + подменю маршрутов (добавить/изменить/удалить/список).
python3 - "$PROJ" << 'EOF'
import pathlib, sys
proj = pathlib.Path(sys.argv[1])
bad = 0
for rel, section in [("scripts/commands/stream.sh", "STREAM"),
                     ("scripts/commands/web.sh", "WEB")]:
    text = (proj / rel).read_text()
    for item in ["🧭 Маршруты", "🔌 Фронтенды", "📦 Бэкенды"]:
        if item not in text:
            print(f"  FAIL: {rel}: нет пункта секции {item}")
            bad += 1
    for fn in ["rt_menu()", "fe_menu()", "be_menu()",
               "add_route()", "edit_route()", "remove_route()", "print_routes_table()"]:
        if fn not in text:
            print(f"  FAIL: {rel}: нет функции {fn}")
            bad += 1
    if "print_section_status" not in text:
        print(f"  FAIL: {rel}: секция без print_section_status")
        bad += 1
print("  ok: структура секций Stream/Web на месте" if bad == 0 else "  FAILURES in section check")
sys.exit(1 if bad else 0)
EOF
[ "$?" -eq 0 ] \
  && printf "  ok: секции содержат Маршруты/Фронтенды/Бэкенды + статус\n" \
  || { printf "  FAIL: структура секций\n"; fail=1; }

# Дым: главное меню показывает пункт ? и выходит по 0 (однократный ввод).
printf '0\n' > ${TEST_TMP:-/tmp}/menu-order-tty
if MENU_TTY=${TEST_TMP:-/tmp}/menu-order-tty timeout 10 bash "$PROJ/haproxy.sh" < /dev/null > ${TEST_TMP:-/tmp}/menu-order-out.txt 2>&1; then
  grep -q '❓ Шпаргалка' ${TEST_TMP:-/tmp}/menu-order-out.txt \
    && printf "  ok: пункт ? отображается, выход по 0 работает\n" \
    || { printf "  FAIL: нет пункта ?\n"; fail=1; }
else
  printf "  FAIL: меню не вышло по 0\n"; fail=1
fi
rm -f ${TEST_TMP:-/tmp}/menu-order-tty ${TEST_TMP:-/tmp}/menu-order-out.txt

exit "$fail"
