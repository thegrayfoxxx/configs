#!/bin/bash
# shellcheck shell=bash
# UI-хелперы меню: подтверждения, паузы, неверный пункт.
# Источник: source ui/menu.sh ПОСЛЕ lib/common.sh (нужны log_*/цвета).

# TTY для чтения (переопределяется тестами через MENU_TTY).
TTY_IN="${MENU_TTY:-/dev/tty}"

# menu_confirm [промпт] — 0 если y/Y, 1 иначе. Пусто = нет.
menu_confirm() {
  local prompt="${1:-Применить? [y/N]:}"
  local ans
  printf "  ${CYAN}👉 %s${NC} " "$prompt"
  read -r ans < "$TTY_IN"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# menu_pause — ждать Enter из TTY.
menu_pause() {
  read -p "[Enter]..." < "$TTY_IN"
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
  read -r ans < "$TTY_IN"
  if [ -z "$ans" ] || [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
    if safe_docker_compose restart; then
      log_info "✅ Сервисы перезапущены"
    else
      log_error "❌ Ошибка перезапуска сервисов"
    fi
  fi
}

# ask_default <промпт> <текущее> — ввод с дефолтом (пусто = оставить как было).
# Промпт строго в stderr: значение печатается в stdout для $(...)-захвата.
ask_default() {
  local prompt="$1" cur="$2" ans
  printf "  ${CYAN}%s [%s]:${NC} " "$prompt" "$cur" >&2
  read -r ans < "$TTY_IN" || ans=""
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
