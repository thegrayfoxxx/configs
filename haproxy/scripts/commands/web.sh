#!/bin/bash
# Управление web-маршрутами (L7, Host -> backend за терминацией) и web-фронтендами.
# Нейтрально.
# Маршрут: "host=<домен> to=<host:порт>[ path=/prefix][ name=<метка>][ log=..][ frontend=<имя>]".
# Фронтенд: "name=<метка> bind=<host:порт>[ log=..]". Пусто = один из bind_web.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "WEB" "🌐"
    print_section_status web
    printf "  ${GREEN}1.${NC} 🧭 Маршруты\n"
    printf "  ${GREEN}2.${NC} 🔌 Фронтенды\n"
    printf "  ${GREEN}3.${NC} 📦 Бэкенды\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r choice

    case "$choice" in
      1) rt_menu || true ;;
      2) fe_menu || true ;;
      3) be_menu || true ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

rt_menu() {
  load_sites
  while true; do
    clear_screen
    print_header "WEB-МАРШРУТЫ" "🧭"
    print_routes_table
    printf "  ${GREEN}1.${NC} ➕ Добавить маршрут\n"
    printf "  ${GREEN}2.${NC} ✏️  Изменить маршрут\n"
    printf "  ${GREEN}3.${NC} ➖ Удалить маршрут\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r choice

    case "$choice" in
      1) add_route || true ;;
      2) edit_route || true ;;
      3) remove_route || true ;;
      0) return 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

add_route() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ WEB-МАРШРУТА" "➕"

  load_sites

  # Host
  printf "  ${CYAN}👉 Домен (например, example.com):${NC} "
  tread -r host
  [ -z "$host" ] && { log_error "❌ Домен не может быть пустым"; return; }
  validate_domain "$host" || return

  # Бэкенд: существующий ящик или новый адрес.
  local use_ref="" to="" be_log="on"
  if [ "${#WEB_BACKENDS[@]}" -gt 0 ]; then
    printf "  ${CYAN}Ящики:${NC}\n"
    local bi=0 bentry
    for bentry in "${WEB_BACKENDS[@]}"; do
      bi=$((bi + 1))
      parse_web_backend "$bentry" 2>/dev/null || continue
      printf "  ${GREEN}%d.${NC} %s → %s%s\n" "$bi" "$B_NAME" "$B_TO" "$([ "$B_LOG" = "off" ] && printf ", без логов")"
    done
    printf "  ${GREEN}0.${NC} Новый адрес\n"
    printf "  ${CYAN}👉 Номер ящика (0 = новый):${NC} "
    tread -r be_num
    [ -z "$be_num" ] && be_num="0"
    if ! [[ "$be_num" =~ ^[0-9]+$ ]] || [ "$be_num" -gt "$bi" ]; then
      log_error "❌ Неверный номер"
      return
    fi
    if [ "$be_num" -gt 0 ]; then
      parse_web_backend "${WEB_BACKENDS[$((be_num - 1))]}" || return
      use_ref="$B_NAME"
    fi
  fi

  if [ -z "$use_ref" ]; then
    # Новый адрес (инлайн-ящик).
    printf "  ${CYAN}👉 Backend (порт или host:порт, например 8080):${NC} "
    tread -r to
    [ -z "$to" ] && { log_error "❌ Backend не может быть пустым"; return; }
    [[ "$to" != *:* ]] && to="127.0.0.1:${to}"
    local _h="${to%:*}"
    local _p="${to##*:}"
    if [ -z "$_h" ] || [ "$_h" = "$to" ]; then
      log_error "❌ Жди порт или host:порт"
      return
    fi
    validate_port "$_p" "порт бэкенда" || return
  fi

  # Path (опционально)
  printf "  ${CYAN}👉 Path-префикс (Enter = весь хост):${NC} "
  tread -r path
  if [ -n "$path" ] && [[ "$path" != /* ]]; then
    log_error "❌ Path должен начинаться с '/'"
    return
  fi

  # Логи бэкенда — только для нового адреса (у ящика свои).
  if [ -z "$use_ref" ]; then
    printf "  ${CYAN}👉 Писать логи бэкенда (on/off) [on]:${NC} "
    tread -r be_log
    [ -z "$be_log" ] && be_log="on"
    case "$be_log" in
      on | off) ;;
      *) log_error "❌ Жди on/off"; return ;;
    esac
  fi

  local rec
  if [ -n "$use_ref" ]; then
    rec="host=${host} use=${use_ref}"
  else
    rec="host=${host} to=${to}"
    [ "$be_log" = "off" ] && rec="${rec} log=off"
  fi
  [ -n "$path" ] && rec="${rec} path=${path}"
  # Область: фронтенд или везде.
  local scope=""
  if [ "${#WEB_FRONTENDS[@]}" -gt 0 ]; then
    printf "  ${CYAN}👉 Фронтенд (имена: %s; Enter = все):${NC} " "$(frontend_names "${WEB_FRONTENDS[@]}" 2>/dev/null | tr '\n' ' ')"
    tread -r scope
    if [ -n "$scope" ]; then
      if ! frontend_exists web "$scope"; then
        log_error "❌ Нет такого web-фронтенда (пункт 2 «Фронтенды» — список)"
        return
      fi
      rec="${rec} frontend=${scope}"
    fi
  fi
  # Дубли? Один хост+path может жить в разных фронтендах — сравниваем тройку.
  local entry
  for entry in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
    parse_web_route "$entry" 2>/dev/null || continue
    if [ "$W3_HOST" = "$host" ] && [ "$W3_PATH" = "$path" ] && [ "${W3_FRONTEND:-}" = "$scope" ]; then
      log_error "❌ Маршрут '${host}${path}' уже существует (фронтенд: ${scope:-все})"
      return
    fi
  done

  # Итог перед записью: опечатку видно до save, а не после.
  local sum_be="to=${to} log=${be_log}"
  [ -n "$use_ref" ] && sum_be="use=${use_ref} (настройки на ящике)"
  printf "\n"
  printf "  ${CYAN}Создать маршрут:${NC}\n"
  printf "    Host:     %s%s\n" "$host" "$path"
  printf "    Backend:  %s\n" "$sum_be"
  printf "    Фронтенд: %s\n" "${scope:-все}"
  printf "\n"
  if ! menu_confirm "Всё верно? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  WEB_ROUTES+=("$rec")
  ensure_stream_default

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Web-маршрут '${host}${path}' добавлен в sites.conf"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  # Сертификат для нового хоста.
  printf "\n"
  printf "  ${CYAN}👉 Выпустить сертификат для ${host}? [Y/n]:${NC} "
  tread -r issue_cert
  if [ -z "$issue_cert" ] || [ "$issue_cert" = "Y" ] || [ "$issue_cert" = "y" ]; then
    bash "${SCRIPT_DIR}/cert.sh" --issue "$host" < /dev/tty || true
  fi

  printf "\n"
  confirm_restart
}

edit_route() {
  clear_screen
  print_header "ИЗМЕНЕНИЕ WEB-МАРШРУТА" "✏️"

  load_sites

  if [ "${#WEB_ROUTES[@]}" -eq 0 ]; then
    log_warn "⚠️  Маршрутов нет — нечего менять"
    return
  fi

  printf "  ${CYAN}Маршруты:${NC}\n"
  local i
  for i in "${!WEB_ROUTES[@]}"; do
    parse_web_route "${WEB_ROUTES[$i]}" 2>/dev/null || continue
    local be_show="$W3_TO"
    [ -n "$W3_USE" ] && be_show="use:${W3_USE}"
    printf "  ${GREEN}%d.${NC} %s%s → %s\n" "$((i + 1))" "$W3_HOST" "$W3_PATH" "$be_show"
  done
  printf "\n"
  printf "  ${CYAN}👉 Номер маршрута (0 - отмена):${NC} "
  tread -r num
  { [ "$num" = "0" ] || [ -z "$num" ]; } && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#WEB_ROUTES[@]}" ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local idx=$((num - 1))
  parse_web_route "${WEB_ROUTES[$idx]}" 2>/dev/null || return 1
  local o_host="$W3_HOST" o_to="$W3_TO" o_use="$W3_USE" o_path="$W3_PATH"
  local o_log="$W3_LOG" o_fe="$W3_FRONTEND"

  # Рабочая копия полей + picker «что меняем».
  local host="$o_host" path="$o_path"
  local use_ref="$o_use" to="$o_to" be_log="$o_log" scope="$o_fe"
  local has_fe=false has_be=false
  [ "${#WEB_FRONTENDS[@]}" -gt 0 ] && has_fe=true
  [ "${#WEB_BACKENDS[@]}" -gt 0 ] && has_be=true

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ WEB-МАРШРУТА" "✏️"
    printf "  ${CYAN}Домен:${NC}     %s\n" "$host"
    if [ -n "$use_ref" ]; then
      printf "  ${CYAN}Backend:${NC}  ящик: %s\n" "$use_ref"
      printf "  ${CYAN}Логи:${NC}     — (на ящике)\n"
    else
      printf "  ${CYAN}Backend:${NC}  %s\n" "$to"
      printf "  ${CYAN}Логи:${NC}     %s\n" "$be_log"
    fi
    printf "  ${CYAN}Path:${NC}      %s\n" "${path:-весь хост}"
    printf "  ${CYAN}Фронтенд:${NC} %s\n" "${scope:-все}"
    printf "\n"
    printf "  ${GREEN}1.${NC} Домен\n"
    printf "  ${GREEN}2.${NC} Backend\n"
    printf "  ${GREEN}3.${NC} Path\n"
    printf "  ${GREEN}4.${NC} Логи\n"
    printf "  ${GREEN}5.${NC} Фронтенд\n"
    printf "  ${GREEN}0.${NC} Готово, применить\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r fchoice

    case "$fchoice" in
      1)
        host=$(ask_default "Домен" "$host")
        [ -z "$host" ] && { log_error "❌ Домен не может быть пустым"; sleep 1; continue; }
        validate_domain "$host" || { sleep 1; continue; }
        ;;
      2)
        if $has_be; then
          local cur_be="инлайн: ${to:-—}"
          [ -n "$use_ref" ] && cur_be="ящик: ${use_ref}"
          printf "  ${CYAN}Сейчас: %s (Enter = оставить, 0 = новый адрес)${NC}\n" "$cur_be"
          printf "  ${CYAN}Ящики:${NC}\n"
          local bi=0 bentry
          for bentry in "${WEB_BACKENDS[@]}"; do
            bi=$((bi + 1))
            parse_web_backend "$bentry" 2>/dev/null || continue
            printf "  ${GREEN}%d.${NC} %s → %s%s\n" "$bi" "$B_NAME" "$B_TO" "$([ "$B_LOG" = "off" ] && printf ", без логов")"
          done
          printf "  ${CYAN}👉 Номер ящика (Enter = оставить):${NC} "
          tread -r be_num
          if [ -n "$be_num" ]; then
            if ! [[ "$be_num" =~ ^[0-9]+$ ]] || [ "$be_num" -lt 0 ] || [ "$be_num" -gt "$bi" ]; then
              log_error "❌ Неверный номер"
              sleep 1; continue
            fi
            if [ "$be_num" = "0" ]; then
              use_ref=""
            elif [ "$be_num" -gt 0 ]; then
              parse_web_backend "${WEB_BACKENDS[$((be_num - 1))]}" || { sleep 1; continue; }
              use_ref="$B_NAME"
              to=""; be_log="on"
              continue
            fi
          else
            continue
          fi
        fi
        if [ -z "$use_ref" ]; then
          [ -z "$to" ] && to="$o_to"
        fi
        to=$(ask_default "Backend (порт или host:порт)" "$to")
        [ -z "$to" ] && { log_error "❌ Backend не может быть пустым"; sleep 1; continue; }
        [[ "$to" != *:* ]] && to="127.0.0.1:${to}"
        local _h="${to%:*}"
        local _p="${to##*:}"
        if [ -z "$_h" ] || [ "$_h" = "$to" ]; then
          log_error "❌ Жди порт или host:порт"
          sleep 1; continue
        fi
        validate_port "$_p" "порт бэкенда" || { sleep 1; continue; }
        use_ref=""
        be_log=$(ask_default "Логи бэкенда (on/off)" "$be_log")
        case "$be_log" in
          on | off) ;;
          *) log_error "❌ Жди on/off"; sleep 1; continue ;;
        esac
        ;;
      3)
        path=$(ask_default "Path-префикс ('-' = весь хост)" "${path:--}")
        if [ -n "$path" ] && [[ "$path" != /* ]] && [ "$path" != "-" ]; then
          log_error "❌ Path должен начинаться с '/' ('-' = весь хост)"
          sleep 1; continue
        fi
        [ "$path" = "-" ] && path=""
        ;;
      4)
        if [ -n "$use_ref" ]; then
          log_error "❌ У ссылки настроек нет — смени backend (п.2)"
          sleep 1; continue
        fi
        be_log=$(ask_default "Логи бэкенда (on/off)" "$be_log")
        case "$be_log" in
          on | off) ;;
          *) log_error "❌ Жди on/off"; sleep 1; continue ;;
        esac
        ;;
      5)
        if [ "$has_fe" = false ]; then
          log_error "❌ Фронтенды не заданы"
          sleep 1; continue
        fi
        printf "  ${CYAN}Фронтенды (имена: %s; Enter = оставить [%s], '-' = все):${NC} " "$(frontend_names "${WEB_FRONTENDS[@]}" 2>/dev/null | tr '\n' ' ')" "${scope:-все}"
        tread -r scope_in
        if [ -n "$scope_in" ]; then
          if [ "$scope_in" = "-" ]; then
            scope=""
          elif frontend_exists web "$scope_in"; then
            scope="$scope_in"
          else
            log_error "❌ Нет такого web-фронтенда ('-' = все)"
            sleep 1; continue
          fi
        fi
        ;;
      0) break ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done

  local rec
  if [ -n "$use_ref" ]; then
    rec="host=${host} use=${use_ref}"
  else
    rec="host=${host} to=${to}"
    [ "$be_log" = "off" ] && rec="${rec} log=off"
  fi
  [ -n "$path" ] && rec="${rec} path=${path}"
  [ -n "$scope" ] && rec="${rec} frontend=${scope}"

  # Дубли? Себя исключаем.
  local entry j=0
  for entry in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
    if [ "$j" -ne "$idx" ]; then
      parse_web_route "$entry" 2>/dev/null || continue
      if [ "$W3_HOST" = "$host" ] && [ "$W3_PATH" = "$path" ] && [ "${W3_FRONTEND:-}" = "$scope" ]; then
        log_error "❌ Такой маршрут уже существует (фронтенд: ${scope:-все})"
        return
      fi
    fi
    j=$((j + 1))
  done

  if [ "$rec" = "${WEB_ROUTES[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${WEB_ROUTES[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  WEB_ROUTES[$idx]="$rec"
  ensure_stream_default

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Web-маршрут '${host}${path}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

remove_route() {
  clear_screen
  print_header "УДАЛЕНИЕ WEB-МАРШРУТА" "➖"

  load_sites

  if [ "${#WEB_ROUTES[@]}" -eq 0 ]; then
    log_warn "⚠️  Нет маршрутов для удаления"
    return
  fi

  printf "  ${CYAN}Доступные маршруты:${NC}\n"
  local i
  for i in "${!WEB_ROUTES[@]}"; do
    parse_web_route "${WEB_ROUTES[$i]}" 2>/dev/null || continue
    local scope_mark="все"
    [ -n "$W3_FRONTEND" ] && scope_mark="$W3_FRONTEND"
    local be_show="$W3_TO"
    [ -n "$W3_USE" ] && be_show="use:${W3_USE}"
    printf "  ${GREEN}%d.${NC} %s%s → %s (фронт: %s)\n" "$((i + 1))" "$W3_HOST" "$W3_PATH" "$be_show" "$scope_mark"
  done
  printf "\n"

  printf "  ${CYAN}👉 Номер маршрута для удаления (0 - отмена):${NC} "
  tread -r num
  { [ "$num" = "0" ] || [ -z "$num" ]; } && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#WEB_ROUTES[@]}" ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local idx=$((num - 1))
  parse_web_route "${WEB_ROUTES[$idx]}" 2>/dev/null || return 1
  local old_host="$W3_HOST"
  local old_path="$W3_PATH" old_be="$W3_TO"
  [ -n "$W3_USE" ] && old_be="use:${W3_USE}"

  if ! menu_confirm "Удалить маршрут '${old_host}${old_path}' → ${old_be}? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi

  unset 'WEB_ROUTES[$idx]'
  WEB_ROUTES=("${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}")

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Web-маршрут '${old_host}${old_path}' удалён из sites.conf"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  printf "  ${CYAN}👉 Удалить сертификат для ${old_host}? [y/N]:${NC} "
  tread -r del_cert
  if [ "$del_cert" = "y" ] || [ "$del_cert" = "Y" ]; then
    bash "${SCRIPT_DIR}/cert.sh" --remove "$old_host" < /dev/tty || true
  fi

  printf "\n"
  confirm_restart
}

# print_routes_table — таблица маршрутов для шапки rt_menu (без очистки/паузы).
print_routes_table() {
  load_sites
  if [ "${#WEB_ROUTES[@]}" -eq 0 ]; then
    log_warn "  ⚠️  Маршрутов нет"
    printf "\n"
    return
  fi

  printf "  ${CYAN}%-28s %-22s %-16s %s${NC}\n" "HOST" "BACKEND" "ФРОНТЕНД" "PATH"
  printf "  ${CYAN}%-28s %-22s %-16s %s${NC}\n" "────────────────────────────" "──────────────────────" "────────────────" "────"

  local entry
  for entry in "${WEB_ROUTES[@]}"; do
    parse_web_route "$entry" 2>/dev/null || continue
    local log_mark=""
    [ "$W3_LOG" = "off" ] && log_mark=" (без логов)"
    local be_col="$W3_TO"
    if [ -n "$W3_USE" ]; then
      be_col="use:${W3_USE}"
      local rec rest
      if rec=$(resolve_web_backend "$W3_USE" 2>/dev/null); then
        rest="${rec#*|}"
        [ "$rest" = "off" ] && log_mark=" (без логов)"
      fi
    fi
    printf "  %-28s %-22s %-16s %s%s\n" "$W3_HOST" "$be_col" "${W3_FRONTEND:-все}" "${W3_PATH:-—}" "$log_mark"
  done

  printf "\n"
}

fe_menu() {
  load_sites
  while true; do
    clear_screen
    print_header "WEB-ФРОНТЕНДЫ" "🔌"
    if [ "${#WEB_FRONTENDS[@]}" -eq 0 ]; then
      printf "  ${YELLOW}(не заданы — по умолчанию bind_web: %s; создать — пункт 1)${NC}\n\n" "$(cfg_opt bind_web "*:8443")"
    else
      printf "  ${CYAN}%-14s %-22s %s${NC}\n" "ИМЯ" "BIND" "МАРШРУТОВ"
      printf "  ${CYAN}%-14s %-22s %s${NC}\n" "──────────────" "──────────────────────" "─────────"
      local entry refs
      for entry in "${WEB_FRONTENDS[@]}"; do
        parse_frontend "$entry" 2>/dev/null || continue
        refs=$(frontend_refs web "$F_NAME" | wc -l)
        printf "  %-14s %-22s %s\n" "$F_NAME" "$F_BIND" "$refs"
      done
      printf "\n"
    fi
    printf "  ${GREEN}1.${NC} ➕ Добавить фронтенд\n"
    printf "  ${GREEN}2.${NC} ✏️  Изменить фронтенд\n"
    printf "  ${GREEN}3.${NC} ➖ Удалить фронтенд\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r choice

    case "$choice" in
      1) fe_add || true ;;
      2) fe_edit || true ;;
      3) fe_remove || true ;;
      0) return 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

fe_add() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ WEB-ФРОНТЕНДА" "➕"

  load_sites

  printf "  ${CYAN}👉 Имя (латиница, например internal):${NC} "
  tread -r fe_name
  [ -z "$fe_name" ] && { log_error "❌ Имя не может быть пустым"; return; }

  printf "  ${CYAN}👉 Bind host:порт (например, 127.0.0.1:9443):${NC} "
  tread -r fe_bind
  [ -z "$fe_bind" ] && { log_error "❌ Bind не может быть пустым"; return; }

  printf "  ${CYAN}👉 Писать логи фронтенда (on/off) [on]:${NC} "
  tread -r fe_log
  [ -z "$fe_log" ] && fe_log="on"

  frontend_add web "$fe_name" "$fe_bind" "$fe_log" || return

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi
  log_info "✅ Готово: фронтенд ft_${fe_name} в конфигах"

  printf "\n"
  confirm_restart
}

fe_edit() {
  clear_screen
  print_header "ИЗМЕНЕНИЕ WEB-ФРОНТЕНДА" "✏️"

  load_sites

  if [ "${#WEB_FRONTENDS[@]}" -eq 0 ]; then
    local cur_bind
    cur_bind=$(cfg_opt bind_web "*:8443")
    printf "  ${CYAN}Фронтенды не заданы — сейчас работает bind %s.${NC}\n" "$cur_bind"
    printf "  ${CYAN}👉 Создать явный 'main' из него и править? [y/N]:${NC} "
    local mk_ans
    tread -r mk_ans
    if [ "$mk_ans" != "y" ] && [ "$mk_ans" != "Y" ]; then
      log_info "Отмена"
      return
    fi
    materialize_default_frontend web || return
    log_info "  Введи имя 'main' ниже."
  fi

  printf "  ${CYAN}👉 Имя фронтенда (0 - отмена):${NC} "
  tread -r fe_name
  { [ "$fe_name" = "0" ] || [ -z "$fe_name" ]; } && return

  local idx=-1 i
  for i in "${!WEB_FRONTENDS[@]}"; do
    parse_frontend "${WEB_FRONTENDS[$i]}" 2>/dev/null || continue
    if [ "$F_NAME" = "$fe_name" ]; then
      idx="$i"
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    log_error "❌ web-фронтенд '${fe_name}' не найден"
    return
  fi
  parse_frontend "${WEB_FRONTENDS[$idx]}" || return 1
  local o_bind="$F_BIND" o_log="$F_LOG"

  # Рабочая копия + picker.
  local fe_bind="$o_bind" fe_log="$o_log"

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ WEB-ФРОНТЕНДА" "✏️"
    printf "  ${CYAN}Имя:${NC}       %s (неизменно)\n" "$fe_name"
    printf "  ${CYAN}Bind:${NC}      %s\n" "$fe_bind"
    printf "  ${CYAN}Логи:${NC}      %s\n" "$fe_log"
    printf "\n"
    printf "  ${GREEN}1.${NC} Bind\n"
    printf "  ${GREEN}2.${NC} Логи\n"
    printf "  ${GREEN}0.${NC} Готово, применить\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r fchoice

    case "$fchoice" in
      1)
        fe_bind=$(ask_default "Bind host:порт" "$fe_bind")
        local _h="${fe_bind%:*}"
        local _p="${fe_bind##*:}"
        if [ -z "$_h" ] || [ "$_h" = "$fe_bind" ]; then
          log_error "❌ Жди host:порт (например, 127.0.0.1:9443)"
          sleep 1; continue
        fi
        validate_port "$_p" "порт фронтенда" || { sleep 1; continue; }
        ;;
      2)
        fe_log=$(ask_default "Логи фронтенда (on/off)" "$fe_log")
        case "$fe_log" in
          on | off) ;;
          *) log_error "❌ Жди on/off"; sleep 1; continue ;;
        esac
        ;;
      0) break ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done

  local rec="name=${fe_name} bind=${fe_bind}"
  [ "$fe_log" = "off" ] && rec="${rec} log=off"
  if [ "$rec" = "${WEB_FRONTENDS[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${WEB_FRONTENDS[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  WEB_FRONTENDS[$idx]="$rec"

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Web-фронтенд '${fe_name}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

fe_remove() {
  clear_screen
  print_header "УДАЛЕНИЕ WEB-ФРОНТЕНДА" "➖"

  load_sites

  if [ "${#WEB_FRONTENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Фронтенды не заданы — удалять нечего"
    return
  fi

  printf "  ${CYAN}👉 Имя фронтенда (0 - отмена):${NC} "
  tread -r fe_name
  { [ "$fe_name" = "0" ] || [ -z "$fe_name" ]; } && return

  if ! frontend_exists web "$fe_name"; then
    log_error "❌ web-фронтенд '${fe_name}' не найден"
    return
  fi
  if ! menu_confirm "Удалить фронтенд '${fe_name}'? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi
  frontend_remove web "$fe_name" || return

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi
  log_info "✅ Готово"

  printf "\n"
  confirm_restart
}

be_menu() {
  load_sites
  while true; do
    clear_screen
    print_header "WEB-БЭКЕНДЫ" "📦"
    if [ "${#WEB_BACKENDS[@]}" -eq 0 ]; then
      printf "  ${YELLOW}(именованных ящиков нет — маршруты несут адреса инлайн; создать — пункт 1)${NC}\n\n"
    else
      printf "  ${CYAN}%-14s %-22s %-9s %s${NC}\n" "ИМЯ" "BACKEND" "ЛОГИ" "МАРШРУТОВ"
      printf "  ${CYAN}%-14s %-22s %-9s %s${NC}\n" "──────────────" "──────────────────────" "─────────" "─────────"
      local bentry refs
      for bentry in "${WEB_BACKENDS[@]}"; do
        parse_web_backend "$bentry" 2>/dev/null || continue
        refs=$(backend_refs web "$B_NAME" | wc -l)
        printf "  %-14s %-22s %-9s %s\n" "$B_NAME" "$B_TO" "$B_LOG" "$refs"
      done
      printf "\n"
    fi
    printf "  ${GREEN}1.${NC} ➕ Добавить ящик\n"
    printf "  ${GREEN}2.${NC} ✏️  Изменить ящик\n"
    printf "  ${GREEN}3.${NC} ➖ Удалить ящик\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r choice

    case "$choice" in
      1) be_add || true ;;
      2) be_edit || true ;;
      3) be_remove || true ;;
      0) return 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

be_add() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ WEB-ЯЩИКА" "➕"

  load_sites

  printf "  ${CYAN}👉 Имя (латиница, например app):${NC} "
  tread -r be_name
  [ -z "$be_name" ] && { log_error "❌ Имя не может быть пустым"; return; }

  printf "  ${CYAN}👉 Backend (порт или host:порт, например 8080):${NC} "
  tread -r be_to
  [ -z "$be_to" ] && { log_error "❌ Backend не может быть пустым"; return; }
  [[ "$be_to" != *:* ]] && be_to="127.0.0.1:${be_to}"

  printf "  ${CYAN}👉 Писать логи (on/off) [on]:${NC} "
  tread -r be_log
  [ -z "$be_log" ] && be_log="on"

  local rec="name=${be_name} to=${be_to} log=${be_log}"
  backend_add web "$rec" || return

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi
  log_info "✅ Готово: ящик bk_${be_name} в конфигах (маршруты привяжутся через use=${be_name})"

  printf "\n"
  confirm_restart
}

be_edit() {
  clear_screen
  print_header "ИЗМЕНЕНИЕ WEB-ЯЩИКА" "✏️"

  load_sites

  if [ "${#WEB_BACKENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Именованных ящиков нет — нечего менять"
    return
  fi

  printf "  ${CYAN}👉 Имя ящика (0 - отмена):${NC} "
  tread -r be_name
  { [ "$be_name" = "0" ] || [ -z "$be_name" ]; } && return

  local idx=-1 i
  for i in "${!WEB_BACKENDS[@]}"; do
    parse_web_backend "${WEB_BACKENDS[$i]}" 2>/dev/null || continue
    if [ "$B_NAME" = "$be_name" ]; then
      idx="$i"
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    log_error "❌ web-бэкенд '${be_name}' не найден"
    return
  fi
  parse_web_backend "${WEB_BACKENDS[$idx]}" || return 1
  local o_to="$B_TO" o_log="$B_LOG"
  local refs
  refs=$(backend_refs web "$be_name" | wc -l)

  # Рабочая копия + picker.
  local be_to="$o_to" be_log="$o_log"

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ WEB-ЯЩИКА" "✏️"
    printf "  ${CYAN}Имя:${NC}       %s (неизменно, затронет маршрутов: %s)\n" "$be_name" "$refs"
    printf "  ${CYAN}Адрес:${NC}     %s\n" "$be_to"
    printf "  ${CYAN}Логи:${NC}      %s\n" "$be_log"
    printf "\n"
    printf "  ${GREEN}1.${NC} Адрес\n"
    printf "  ${GREEN}2.${NC} Логи\n"
    printf "  ${GREEN}0.${NC} Готово, применить\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r fchoice

    case "$fchoice" in
      1)
        be_to=$(ask_default "Backend (порт или host:порт)" "$be_to")
        [ -z "$be_to" ] && { log_error "❌ Backend не может быть пустым"; sleep 1; continue; }
        [[ "$be_to" != *:* ]] && be_to="127.0.0.1:${be_to}"
        local _h="${be_to%:*}"
        local _p="${be_to##*:}"
        if [ -z "$_h" ] || [ "$_h" = "$be_to" ]; then
          log_error "❌ Жди порт или host:порт"
          sleep 1; continue
        fi
        validate_port "$_p" "порт бэкенда" || { sleep 1; continue; }
        ;;
      2)
        be_log=$(ask_default "Логи (on/off)" "$be_log")
        case "$be_log" in
          on | off) ;;
          *) log_error "❌ Жди on/off"; sleep 1; continue ;;
        esac
        ;;
      0) break ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done

  local rec="name=${be_name} to=${be_to}"
  [ "$be_log" = "off" ] && rec="${rec} log=off"
  if [ "$rec" = "${WEB_BACKENDS[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${WEB_BACKENDS[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "  ${CYAN}Затронет маршрутов:${NC} %s\n" "$refs"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  WEB_BACKENDS[$idx]="$rec"

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Web-ящик '${be_name}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

be_remove() {
  clear_screen
  print_header "УДАЛЕНИЕ WEB-ЯЩИКА" "➖"

  load_sites

  if [ "${#WEB_BACKENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Именованных ящиков нет — удалять нечего"
    return
  fi

  printf "  ${CYAN}👉 Имя ящика (0 - отмена):${NC} "
  tread -r be_name
  { [ "$be_name" = "0" ] || [ -z "$be_name" ]; } && return

  if ! backend_exists web "$be_name"; then
    log_error "❌ web-бэкенд '${be_name}' не найден"
    return
  fi
  if ! menu_confirm "Удалить ящик '${be_name}'? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi
  backend_remove web "$be_name" || return

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi
  log_info "✅ Готово"

  printf "\n"
  confirm_restart
}

show_menu
