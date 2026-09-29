#!/bin/bash
# shellcheck shell=bash
# UI-хелперы меню: подтверждения, паузы, неверный пункт.
# Источник: source ui/menu.sh ПОСЛЕ lib/common.sh (нужны log_*/цвета).

# TTY для чтения (переопределяется тестами через MENU_TTY).
TTY_IN="${MENU_TTY:-/dev/tty}"

# Общий FD ввода: каждое `read < файл` переоткрывало бы файл с нулевого офсета
# и многошаговые визарды зацикливались бы на первой строке (тот же класс бага,
# что ловил PRESET_FD в preset.sh). Открываем ОДИН раз, читаем через tread.
# Реальный /dev/tty stateful и так — поведение для интерактива не меняется.
TTY_FD=-1
{ exec {TTY_FD}<"$TTY_IN"; } 2>/dev/null || TTY_FD=-1

# tread — чтение строки ввода как read, но через общий FD (офсет не сбрасывается).
# Использование: tread -r var [-p prompt]. FD нет (неинтерактив без TTY) — читаем
# напрямую из TTY_IN как раньше. Возврат как у read (EOF -> 1).
tread() {
  local __rc=0
  if [ "$TTY_FD" -ge 0 ]; then
    read "$@" <&$TTY_FD || __rc=1
  else
    read "$@" < "$TTY_IN" || __rc=1
  fi
  [ "$__rc" -ne 0 ] && return 1
  local __v="${@: -1}"
  case "$__v" in
    -*) return 0 ;;
  esac
  printf -v "$__v" "%s" "${!__v%$'\r'}"
}

# menu_confirm [промпт] — 0 если y/Y, 1 иначе. Пусто = нет.
menu_confirm() {
  local prompt="${1:-Применить? [y/N]:}"
  local ans
  printf "  ${CYAN}👉 %s${NC} " "$prompt"
  tread -r ans || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# menu_pause — ждать Enter из TTY.
menu_pause() {
  tread -p "[Enter]..." dummy || true
}

# menu_invalid — неверный пункт.
menu_invalid() {
  log_error "❌ Неверный пункт"
  sleep 1
}

# confirm_restart — спросить [Y/n] и перезапустить сервисы через dc.
confirm_restart() {
  printf "  ${CYAN}👉 Перезапустить сервисы? [Y/n]:${NC} "
  local ans
  tread -r ans || ans=""
  if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
    if safe_docker_compose restart; then
      log_info "✅ Сервисы перезапущены"
    else
      log_error "❌ Ошибка перезапуска сервисов"
    fi
  fi
}

# ask_validate — вопрос «Проверять конфиг haproxy -c перед записью? [Y/n]».
# Печатает в stdout флаг для generate_configs: "" (проверять, дефолт/пусто/y)
# или "--no-validate" (n — риск на операторе). Всегда возврат 0.
ask_validate() {
  local ans flag=""
  printf "  ${CYAN}👉 Проверить конфиг haproxy -c перед записью? [Y/n]:${NC} " >&2
  tread -r ans || ans=""
  if [ "$ans" = "n" ] || [ "$ans" = "N" ]; then
    log_warn "  ⚠  Без проверки: битый конфиг ляжет только на рестарте (crash-loop :443)" >&2
    flag="--no-validate"
  fi
  printf "%s" "$flag"
}

# generate_configs_ask — спросить про валидацию и сгенерировать.
# Возврат как у generate_configs. В неинтерактиве (EOF) — строго, как без флага.
generate_configs_ask() {
  local vflag
  vflag=$(ask_validate)
  if [ -z "$vflag" ]; then
    generate_configs
  else
    generate_configs "$vflag"
  fi
}
# ask_default <промпт> <текущее> — ввод с дефолтом (пусто = оставить как было).
# Промпт строго в stderr: значение печатается в stdout для $(...)-захвата.
ask_default() {
  local prompt="$1" cur="$2" ans
  printf "  ${CYAN}%s [%s]:${NC} " "$prompt" "$cur" >&2
  tread -r ans || ans=""
  [ -z "$ans" ] && ans="$cur"
  printf "%s" "$ans"
}

# print_cheatsheet — шпаргалка форматов и правил (пункт ? во всех меню).
print_cheatsheet() {
  clear_screen
  print_header "ШПАРГАЛКА" "❓"
  printf "  ${CYAN}Маршруты:${NC}\n"
  printf "    stream: sni=<домены|default> to=<host:порт> | use=<ящик> [proxy=] [log=] [frontend=]\n"
  printf "    web:    host=<домен> to=<host:порт> | use=<ящик> [path=/...] [log=] [frontend=]\n"
  printf "  ${CYAN}Сущности:${NC}\n"
  printf "    фронтенд: name=<имя> bind=<host:порт> [log=]  (пусто = одиночный режим)\n"
  printf "    ящик:     stream: name/to/[proxy]/[log]; web: name/to/[log]\n"
  printf "  ${CYAN}Правила:${NC}\n"
  printf "    0 или пустая строка = отмена/назад; [y/N] = деструктив только на 'y'\n"
  printf "    удаление всегда спрашивает; перед каждой записью — бэкап в .backup/\n"
  printf "    детали: README.md, примеры: sites.conf.example, визард: раздел 4 меню\n"
  printf "\n"
  menu_pause
}
