#!/bin/bash
# Управление stream-маршрутами (L4, SNI -> backend) и stream-фронтендами.
# Нейтрально: никаких xray/reality.
# Маршрут: "sni=<домены|default> to=<host:порт>[ proxy=..][ name=..][ log=..][ frontend=<имя>]".
# Фронтенд: "name=<метка> bind=<host:порт>[ log=..]". Пусто = один из bind_stream.
# Запись sni=default создается автоматически и здесь не правится (только показ).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "STREAM" "🔀"
    print_section_status stream
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
    print_header "STREAM-МАРШРУТЫ" "🧭"
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

# _is_default_idx <idx> — 0 если запись является sni=default.
_is_default_idx() {
  local entry="${STREAM_ROUTES[$1]}"
  parse_stream_route "$entry" 2>/dev/null || return 1
  [ "$S3_SNI" = "default" ]
}

add_route() {
  clear_screen
  print_header "ДОБАВЛЕНИЕ STREAM-МАРШРУТА" "➕"

  load_sites

  # SNI
  printf "  ${CYAN}👉 SNI через пробел (например, vpn.example.com):${NC} "
  tread -r sni
  [ -z "$sni" ] && { log_error "❌ SNI не может быть пустым"; return; }
  if [ "$sni" = "default" ]; then
    log_error "❌ Маршрут default создается автоматически (правится в файле/пресете)"
    return
  fi
  local d
  # shellcheck disable=SC2086
  for d in $sni; do
    validate_domain "$d" || return
  done

  # Бэкенд: существующий ящик или новый адрес.
  local use_ref="" to="" proxy="off" name="" be_log="on"
  if [ "${#STREAM_BACKENDS[@]}" -gt 0 ]; then
    printf "  ${CYAN}Ящики:${NC}\n"
    local bi=0 bentry
    for bentry in "${STREAM_BACKENDS[@]}"; do
      bi=$((bi + 1))
      parse_stream_backend "$bentry" 2>/dev/null || continue
      printf "  ${GREEN}%d.${NC} %s → %s (proxy %s%s)\n" "$bi" "$B_NAME" "$B_TO" "$B_PROXY" "$([ "$B_LOG" = "off" ] && printf ", без логов")"
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
      parse_stream_backend "${STREAM_BACKENDS[$((be_num - 1))]}" || return
      use_ref="$B_NAME"
    fi
  fi

  if [ -z "$use_ref" ]; then
    # Новый адрес (инлайн-ящик).
    printf "  ${CYAN}👉 Backend host:порт (например, 127.0.0.1:10443):${NC} "
    tread -r to
    [ -z "$to" ] && { log_error "❌ Backend не может быть пустым"; return; }
    local _h="${to%:*}"
    local _p="${to##*:}"
    if [ -z "$_h" ] || [ "$_h" = "$to" ]; then
      log_error "❌ Жди host:порт (например, 127.0.0.1:10443)"
      return
    fi
    validate_port "$_p" "порт бэкенда" || return

    # PROXY
    printf "  ${CYAN}👉 PROXY-протокол [off]:${NC} "
    tread -r proxy
    [ -z "$proxy" ] && proxy="off"
    case "$proxy" in
      off | v1 | v2) ;;
      *) log_error "❌ Жди off/v1/v2"; return ;;
    esac

    # Имя
    local auto_name="sni-$((${#STREAM_ROUTES[@]} + 1))"
    printf "  ${CYAN}👉 Имя маршрута [%s]:${NC} " "$auto_name"
    tread -r name
    [ -z "$name" ] && name="$auto_name"
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
      log_error "❌ Имя: только латиница/цифры/_/-"
      return
    fi

    # Логи бэкенда
    printf "  ${CYAN}👉 Писать логи бэкенда (on/off) [on]:${NC} "
    tread -r be_log
    [ -z "$be_log" ] && be_log="on"
    case "$be_log" in
      on | off) ;;
      *) log_error "❌ Жди on/off"; return ;;
    esac
  fi

  # Область: фронтенд или везде.
  local scope=""
  if [ "${#STREAM_FRONTENDS[@]}" -gt 0 ]; then
    printf "  ${CYAN}👉 Фронтенд (имена: %s; Enter = все):${NC} " "$(frontend_names "${STREAM_FRONTENDS[@]}" 2>/dev/null | tr '\n' ' ')"
    tread -r scope
    if [ -n "$scope" ] && ! frontend_exists stream "$scope"; then
      log_error "❌ Нет такого stream-фронтенда (пункт 2 «Фронтенды» — список)"
      return
    fi
  fi

  local rec
  if [ -n "$use_ref" ]; then
    rec="sni=${sni} use=${use_ref}"
  else
    rec="sni=${sni} to=${to} proxy=${proxy} name=${name} log=${be_log}"
  fi
  [ -n "$scope" ] && rec="${rec} frontend=${scope}"

  # Дубли? Один SNI может жить в разных фронтендах — сравниваем пару (матч + область).
  local entry
  for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    parse_stream_route "$entry" 2>/dev/null || continue
    if [ "$S3_SNI" = "$sni" ] && [ "${S3_FRONTEND:-}" = "$scope" ]; then
      log_error "❌ Маршрут для '${sni}' уже существует (фронтенд: ${scope:-все})"
      return
    fi
  done

  # Итог перед записью: опечатку видно до save, а не после.
  local sum_be="to=${to} proxy=${proxy} name=${name} log=${be_log}"
  [ -n "$use_ref" ] && sum_be="use=${use_ref} (настройки на ящике)"
  printf "\n"
  printf "  ${CYAN}Создать маршрут:${NC}\n"
  printf "    SNI:      %s\n" "$sni"
  printf "    Backend:  %s\n" "$sum_be"
  printf "    Фронтенд: %s\n" "${scope:-все}"
  printf "\n"
  if ! menu_confirm "Всё верно? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  STREAM_ROUTES+=("$rec")
  ensure_stream_default

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Stream-маршрут '${sni}' добавлен в sites.conf"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

edit_route() {
  clear_screen
  print_header "ИЗМЕНЕНИЕ STREAM-МАРШРУТА" "✏️"

  load_sites

  if [ "${#STREAM_ROUTES[@]}" -eq 0 ]; then
    log_warn "⚠️  Маршрутов нет — нечего менять"
    return
  fi

  # Выбор (включая default — его backend менять можно, SNI нет).
  printf "  ${CYAN}Маршруты:${NC}\n"
  local i
  for i in "${!STREAM_ROUTES[@]}"; do
    parse_stream_route "${STREAM_ROUTES[$i]}" 2>/dev/null || continue
    local be_show="$S3_TO"
    [ -n "$S3_USE" ] && be_show="use:${S3_USE}"
    printf "  ${GREEN}%d.${NC} %s → %s\n" "$((i + 1))" "$S3_SNI" "$be_show"
  done
  printf "\n"
  printf "  ${CYAN}👉 Номер маршрута (0 - отмена):${NC} "
  tread -r num
  { [ "$num" = "0" ] || [ -z "$num" ]; } && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#STREAM_ROUTES[@]}" ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local idx=$((num - 1))
  parse_stream_route "${STREAM_ROUTES[$idx]}" 2>/dev/null || return 1
  local o_sni="$S3_SNI" o_to="$S3_TO" o_use="$S3_USE" o_proxy="$S3_PROXY"
  local o_name="$S3_NAME" o_log="$S3_LOG" o_fe="$S3_FRONTEND"
  local is_def=false
  [ "$o_sni" = "default" ] && is_def=true

  # Рабочая копия полей + picker «что меняем».
  local sni="$o_sni" use_ref="$o_use" to="$o_to" proxy="$o_proxy"
  local name="$o_name" be_log="$o_log" scope="$o_fe"
  local has_fe=false has_be=false
  [ "${#STREAM_FRONTENDS[@]}" -gt 0 ] && has_fe=true
  [ "${#STREAM_BACKENDS[@]}" -gt 0 ] && has_be=true

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ STREAM-МАРШРУТА" "✏️"
    printf "  ${CYAN}SNI:${NC}      %s\n" "$sni"
    if [ -n "$use_ref" ]; then
      printf "  ${CYAN}Backend:${NC}  ящик: %s\n" "$use_ref"
      printf "  ${CYAN}PROXY:${NC}    — (на ящике)\n"
      printf "  ${CYAN}Имя:${NC}      — (имя ящика)\n"
      printf "  ${CYAN}Логи:${NC}     — (на ящике)\n"
    else
      printf "  ${CYAN}Backend:${NC}  %s\n" "$to"
      printf "  ${CYAN}PROXY:${NC}    %s\n" "$proxy"
      printf "  ${CYAN}Имя:${NC}      %s\n" "${name:-—}"
      printf "  ${CYAN}Логи:${NC}     %s\n" "$be_log"
    fi
    printf "  ${CYAN}Фронтенд:${NC} %s\n" "${scope:-все}"
    printf "\n"
    printf "  ${GREEN}1.${NC} SNI\n"
    printf "  ${GREEN}2.${NC} Backend\n"
    printf "  ${GREEN}3.${NC} PROXY\n"
    printf "  ${GREEN}4.${NC} Имя\n"
    printf "  ${GREEN}5.${NC} Логи\n"
    printf "  ${GREEN}6.${NC} Фронтенд\n"
    printf "  ${GREEN}0.${NC} Готово, применить\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r fchoice

    case "$fchoice" in
      1)
        if [ "$is_def" = true ]; then
          log_error "❌ SNI=default зафиксирован (меняется только backend)"
          sleep 1; continue
        fi
        sni=$(ask_default "SNI через пробел" "$sni")
        [ -z "$sni" ] && { log_error "❌ SNI не может быть пустым"; sleep 1; continue; }
        local d bad=false
        # shellcheck disable=SC2086
        for d in $sni; do
          validate_domain "$d" || bad=true
        done
        [ "$bad" = true ] && { sleep 1; continue; }
        ;;
      2)
        if $has_be; then
          local cur_be="инлайн: ${to}"
          [ -n "$use_ref" ] && cur_be="ящик: ${use_ref}"
          printf "  ${CYAN}Сейчас: %s${NC}\n" "$cur_be"
          printf "  ${CYAN}Ящики:${NC}\n"
          local bi=0 bentry
          for bentry in "${STREAM_BACKENDS[@]}"; do
            bi=$((bi + 1))
            parse_stream_backend "$bentry" 2>/dev/null || continue
            printf "  ${GREEN}%d.${NC} %s → %s (proxy %s%s)\n" "$bi" "$B_NAME" "$B_TO" "$B_PROXY" "$([ "$B_LOG" = "off" ] && printf ", без логов")"
          done
          printf "  ${GREEN}0.${NC} Новый адрес\n"
          printf "  ${CYAN}👉 Номер ящика (Enter = оставить):${NC} "
          tread -r be_num
          [ -z "$be_num" ] && continue
          if ! [[ "$be_num" =~ ^[0-9]+$ ]] || [ "$be_num" -lt 0 ] || [ "$be_num" -gt "$bi" ]; then
            log_error "❌ Неверный номер"
            sleep 1; continue
          fi
          if [ "$be_num" -gt 0 ]; then
            parse_stream_backend "${STREAM_BACKENDS[$((be_num - 1))]}" || { sleep 1; continue; }
            use_ref="$B_NAME"
            to=""; proxy="off"; name=""; be_log="on"
            continue
          fi
        fi
        to=$(ask_default "Backend host:порт" "$to")
        local _h="${to%:*}"
        local _p="${to##*:}"
        if [ -z "$_h" ] || [ "$_h" = "$to" ]; then
          log_error "❌ Жди host:порт (например, 127.0.0.1:10443)"
          sleep 1; continue
        fi
        validate_port "$_p" "порт бэкенда" || { sleep 1; continue; }
        use_ref=""
        proxy=$(ask_default "PROXY-протокол (off/v1/v2)" "$proxy")
        case "$proxy" in
          off | v1 | v2) ;;
          *) log_error "❌ Жди off/v1/v2"; sleep 1; continue ;;
        esac
        if [ -z "$name" ]; then
          name="sni-$((${#STREAM_ROUTES[@]} + 1))"
        fi
        name=$(ask_default "Имя маршрута" "$name")
        if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
          log_error "❌ Имя: только латиница/цифры/_/-"
          sleep 1; continue
        fi
        be_log=$(ask_default "Логи бэкенда (on/off)" "$be_log")
        case "$be_log" in
          on | off) ;;
          *) log_error "❌ Жди on/off"; sleep 1; continue ;;
        esac
        ;;
      3)
        if [ -n "$use_ref" ]; then
          log_error "❌ У ссылки настроек нет — смени backend (п.2)"
          sleep 1; continue
        fi
        proxy=$(ask_default "PROXY-протокол (off/v1/v2)" "$proxy")
        case "$proxy" in
          off | v1 | v2) ;;
          *) log_error "❌ Жди off/v1/v2"; sleep 1; continue ;;
        esac
        ;;
      4)
        if [ -n "$use_ref" ]; then
          log_error "❌ У ссылки настроек нет — смени backend (п.2)"
          sleep 1; continue
        fi
        if [ -z "$name" ]; then
          name="sni-$((${#STREAM_ROUTES[@]} + 1))"
        fi
        name=$(ask_default "Имя маршрута" "$name")
        if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
          log_error "❌ Имя: только латиница/цифры/_/-"
          sleep 1; continue
        fi
        ;;
      5)
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
      6)
        if [ "$has_fe" = false ]; then
          log_error "❌ Фронтенды не заданы"
          sleep 1; continue
        fi
        printf "  ${CYAN}Фронтенды (имена: %s; Enter = оставить [%s], '-' = все):${NC} " "$(frontend_names "${STREAM_FRONTENDS[@]}" 2>/dev/null | tr '\n' ' ')" "${scope:-все}"
        tread -r scope_in
        if [ -n "$scope_in" ]; then
          if [ "$scope_in" = "-" ]; then
            scope=""
          elif frontend_exists stream "$scope_in"; then
            scope="$scope_in"
          else
            log_error "❌ Нет такого stream-фронтенда ('-' = все)"
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
    rec="sni=${sni} use=${use_ref}"
  else
    rec="sni=${sni} to=${to} proxy=${proxy} name=${name} log=${be_log}"
  fi
  [ -n "$scope" ] && rec="${rec} frontend=${scope}"

  # Дубли? Себя исключаем.
  local entry j=0
  for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    if [ "$j" -ne "$idx" ]; then
      parse_stream_route "$entry" 2>/dev/null || continue
      if [ "$S3_SNI" = "$sni" ] && [ "${S3_FRONTEND:-}" = "$scope" ]; then
        log_error "❌ Такой маршрут уже существует (фронтенд: ${scope:-все})"
        return
      fi
    fi
    j=$((j + 1))
  done

  # Итог перед записью.
  if [ "$rec" = "${STREAM_ROUTES[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  local sum_be="to=${to} proxy=${proxy} name=${name} log=${be_log}"
  [ -n "$use_ref" ] && sum_be="use=${use_ref} (настройки на ящике)"
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${STREAM_ROUTES[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  STREAM_ROUTES[$idx]="$rec"

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Stream-маршрут '${sni}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

remove_route() {
  clear_screen
  print_header "УДАЛЕНИЕ STREAM-МАРШРУТА" "➖"

  load_sites

  # Индексы не-default записей.
  local -a idxs=()
  local i
  for i in "${!STREAM_ROUTES[@]}"; do
    _is_default_idx "$i" || idxs+=("$i")
  done

  if [ "${#idxs[@]}" -eq 0 ]; then
    log_warn "⚠️  Нет маршрутов для удаления (default не удаляется)"
    return
  fi

  printf "  ${CYAN}Доступные маршруты:${NC}\n"
  local n=0
  for i in "${idxs[@]}"; do
    n=$((n + 1))
    parse_stream_route "${STREAM_ROUTES[$i]}" 2>/dev/null || continue
    local scope_mark="все"
    [ -n "$S3_FRONTEND" ] && scope_mark="$S3_FRONTEND"
    local be_show="$S3_TO" eff_proxy="$S3_PROXY" nm="$S3_NAME"
    if [ -n "$S3_USE" ]; then
      be_show="use:${S3_USE}"
      nm="$S3_USE"
      local rec rest
      if rec=$(resolve_stream_backend "$S3_USE" 2>/dev/null); then
        rest="${rec#*|}"
        eff_proxy="${rest%%|*}"
      fi
    fi
    printf "  ${GREEN}%d.${NC} %s → %s (proxy %s, %s, фронт: %s)\n" "$n" "$S3_SNI" "$be_show" "$eff_proxy" "$nm" "$scope_mark"
  done
  printf "\n"

  printf "  ${CYAN}👉 Номер маршрута для удаления (0 - отмена):${NC} "
  tread -r num
  { [ "$num" = "0" ] || [ -z "$num" ]; } && return

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#idxs[@]}" ]; then
    log_error "❌ Неверный номер"
    return
  fi

  local target="${idxs[$((num - 1))]}"
  parse_stream_route "${STREAM_ROUTES[$target]}" 2>/dev/null || return 1
  local old_sni="$S3_SNI" old_be="$S3_TO"
  [ -n "$S3_USE" ] && old_be="use:${S3_USE}"

  if ! menu_confirm "Удалить маршрут '${old_sni}' → ${old_be}? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi

  unset 'STREAM_ROUTES[$target]'
  STREAM_ROUTES=("${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}")

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Stream-маршрут '${old_sni}' удалён из sites.conf"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

# print_routes_table — таблица маршрутов для шапки rt_menu (без очистки/паузы).
print_routes_table() {
  load_sites
  if [ "${#STREAM_ROUTES[@]}" -eq 0 ]; then
    log_warn "  ⚠️  Маршрутов нет"
    printf "\n"
    return
  fi

  printf "  ${CYAN}%-30s %-22s %-12s %-7s %s${NC}\n" "SNI" "BACKEND" "ФРОНТЕНД" "PROXY" "ИМЯ"
  printf "  ${CYAN}%-30s %-22s %-12s %-7s %s${NC}\n" "──────────────────────────────" "──────────────────────" "────────────" "───────" "────"

  local entry
  for entry in "${STREAM_ROUTES[@]}"; do
    parse_stream_route "$entry" 2>/dev/null || continue
    local log_mark=""
    [ "$S3_LOG" = "off" ] && log_mark=" (без логов)"
    local be_col="$S3_TO" eff_proxy="$S3_PROXY"
    local nm="${S3_NAME:-—}"
    if [ -n "$S3_USE" ]; then
      be_col="use:${S3_USE}"
      nm="$S3_USE"
      local rec rest
      if rec=$(resolve_stream_backend "$S3_USE" 2>/dev/null); then
        rest="${rec#*|}"
        eff_proxy="${rest%%|*}"
        [ "${rest#*|}" = "off" ] && log_mark=" (без логов)"
      fi
    fi
    printf "  %-30s %-22s %-12s %-7s %s%s\n" "$S3_SNI" "$be_col" "${S3_FRONTEND:-все}" "$eff_proxy" "$nm" "$log_mark"
  done

  printf "\n"
}

fe_menu() {
  load_sites
  while true; do
    clear_screen
    print_header "STREAM-ФРОНТЕНДЫ" "🔌"
    if [ "${#STREAM_FRONTENDS[@]}" -eq 0 ]; then
      printf "  ${YELLOW}(не заданы — по умолчанию bind_stream: %s; создать — пункт 1)${NC}\n\n" "$(cfg_opt bind_stream "*:443")"
    else
      printf "  ${CYAN}%-14s %-22s %s${NC}\n" "ИМЯ" "BIND" "МАРШРУТОВ"
      printf "  ${CYAN}%-14s %-22s %s${NC}\n" "──────────────" "──────────────────────" "─────────"
      local entry refs n
      for entry in "${STREAM_FRONTENDS[@]}"; do
        parse_frontend "$entry" 2>/dev/null || continue
        refs=$(frontend_refs stream "$F_NAME" | wc -l)
        n="$refs"
        printf "  %-14s %-22s %s\n" "$F_NAME" "$F_BIND" "$n"
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
  print_header "ДОБАВЛЕНИЕ STREAM-ФРОНТЕНДА" "➕"

  load_sites

  printf "  ${CYAN}👉 Имя (латиница, например office):${NC} "
  tread -r fe_name
  [ -z "$fe_name" ] && { log_error "❌ Имя не может быть пустым"; return; }

  printf "  ${CYAN}👉 Bind host:порт (например, 10.0.0.1:8445):${NC} "
  tread -r fe_bind
  [ -z "$fe_bind" ] && { log_error "❌ Bind не может быть пустым"; return; }

  printf "  ${CYAN}👉 Писать логи фронтенда (on/off) [on]:${NC} "
  tread -r fe_log
  [ -z "$fe_log" ] && fe_log="on"

  frontend_add stream "$fe_name" "$fe_bind" "$fe_log" || return

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов (фронтенд записан, проверь default-маршруты)"
    return
  fi
  log_info "✅ Готово: фронтенд ft_${fe_name} в конфигах"

  printf "\n"
  confirm_restart
}

fe_edit() {
  clear_screen
  print_header "ИЗМЕНЕНИЕ STREAM-ФРОНТЕНДА" "✏️"

  load_sites

  if [ "${#STREAM_FRONTENDS[@]}" -eq 0 ]; then
    local cur_bind
    cur_bind=$(cfg_opt bind_stream "*:443")
    printf "  ${CYAN}Фронтенды не заданы — сейчас работает bind %s.${NC}\n" "$cur_bind"
    printf "  ${CYAN}👉 Создать явный 'main' из него и править? [y/N]:${NC} "
    local mk_ans
    tread -r mk_ans
    if [ "$mk_ans" != "y" ] && [ "$mk_ans" != "Y" ]; then
      log_info "Отмена"
      return
    fi
    materialize_default_frontend stream || return
    log_info "  Введи имя 'main' ниже."
  fi

  printf "  ${CYAN}👉 Имя фронтенда (0 - отмена):${NC} "
  tread -r fe_name
  { [ "$fe_name" = "0" ] || [ -z "$fe_name" ]; } && return

  local idx=-1 i
  for i in "${!STREAM_FRONTENDS[@]}"; do
    parse_frontend "${STREAM_FRONTENDS[$i]}" 2>/dev/null || continue
    if [ "$F_NAME" = "$fe_name" ]; then
      idx="$i"
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    log_error "❌ stream-фронтенд '${fe_name}' не найден"
    return
  fi
  parse_frontend "${STREAM_FRONTENDS[$idx]}" || return 1
  local o_bind="$F_BIND" o_log="$F_LOG"

  # Рабочая копия + picker.
  local fe_bind="$o_bind" fe_log="$o_log"

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ STREAM-ФРОНТЕНДА" "✏️"
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
          log_error "❌ Жди host:порт (например, 10.0.0.1:8445)"
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
  if [ "$rec" = "${STREAM_FRONTENDS[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${STREAM_FRONTENDS[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  STREAM_FRONTENDS[$idx]="$rec"

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Stream-фронтенд '${fe_name}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

fe_remove() {
  clear_screen
  print_header "УДАЛЕНИЕ STREAM-ФРОНТЕНДА" "➖"

  load_sites

  if [ "${#STREAM_FRONTENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Фронтенды не заданы — удалять нечего"
    return
  fi

  printf "  ${CYAN}👉 Имя фронтенда (0 - отмена):${NC} "
  tread -r fe_name
  { [ "$fe_name" = "0" ] || [ -z "$fe_name" ]; } && return

  if ! frontend_exists stream "$fe_name"; then
    log_error "❌ stream-фронтенд '${fe_name}' не найден"
    return
  fi
  if ! menu_confirm "Удалить фронтенд '${fe_name}'? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi
  frontend_remove stream "$fe_name" || return

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
    print_header "STREAM-БЭКЕНДЫ" "📦"
    if [ "${#STREAM_BACKENDS[@]}" -eq 0 ]; then
      printf "  ${YELLOW}(именованных ящиков нет — маршруты несут адреса инлайн; создать — пункт 1)${NC}\n\n"
    else
      printf "  ${CYAN}%-14s %-22s %-7s %-9s %s${NC}\n" "ИМЯ" "BACKEND" "PROXY" "ЛОГИ" "МАРШРУТОВ"
      printf "  ${CYAN}%-14s %-22s %-7s %-9s %s${NC}\n" "──────────────" "──────────────────────" "───────" "─────────" "─────────"
      local bentry refs
      for bentry in "${STREAM_BACKENDS[@]}"; do
        parse_stream_backend "$bentry" 2>/dev/null || continue
        refs=$(backend_refs stream "$B_NAME" | wc -l)
        printf "  %-14s %-22s %-7s %-9s %s\n" "$B_NAME" "$B_TO" "$B_PROXY" "$B_LOG" "$refs"
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
  print_header "ДОБАВЛЕНИЕ STREAM-ЯЩИКА" "➕"

  load_sites

  printf "  ${CYAN}👉 Имя (латиница, например app):${NC} "
  tread -r be_name
  [ -z "$be_name" ] && { log_error "❌ Имя не может быть пустым"; return; }

  printf "  ${CYAN}👉 Backend host:порт (например, 127.0.0.1:10443):${NC} "
  tread -r be_to
  [ -z "$be_to" ] && { log_error "❌ Backend не может быть пустым"; return; }

  printf "  ${CYAN}👉 PROXY-протокол [off]:${NC} "
  tread -r be_proxy
  [ -z "$be_proxy" ] && be_proxy="off"

  printf "  ${CYAN}👉 Писать логи (on/off) [on]:${NC} "
  tread -r be_log
  [ -z "$be_log" ] && be_log="on"

  local rec="name=${be_name} to=${be_to} proxy=${be_proxy} log=${be_log}"
  backend_add stream "$rec" || return

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
  print_header "ИЗМЕНЕНИЕ STREAM-ЯЩИКА" "✏️"

  load_sites

  if [ "${#STREAM_BACKENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Именованных ящиков нет — нечего менять"
    return
  fi

  printf "  ${CYAN}👉 Имя ящика (0 - отмена):${NC} "
  tread -r be_name
  { [ "$be_name" = "0" ] || [ -z "$be_name" ]; } && return

  local idx=-1 i
  for i in "${!STREAM_BACKENDS[@]}"; do
    parse_stream_backend "${STREAM_BACKENDS[$i]}" 2>/dev/null || continue
    if [ "$B_NAME" = "$be_name" ]; then
      idx="$i"
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    log_error "❌ stream-бэкенд '${be_name}' не найден"
    return
  fi
  parse_stream_backend "${STREAM_BACKENDS[$idx]}" || return 1
  local o_to="$B_TO" o_proxy="$B_PROXY" o_log="$B_LOG"
  local refs
  refs=$(backend_refs stream "$be_name" | wc -l)

  # Рабочая копия + picker.
  local be_to="$o_to" be_proxy="$o_proxy" be_log="$o_log"

  while true; do
    clear_screen
    print_header "ИЗМЕНЕНИЕ STREAM-ЯЩИКА" "✏️"
    printf "  ${CYAN}Имя:${NC}      %s (неизменно, затронет маршрутов: %s)\n" "$be_name" "$refs"
    printf "  ${CYAN}Адрес:${NC}    %s\n" "$be_to"
    printf "  ${CYAN}PROXY:${NC}    %s\n" "$be_proxy"
    printf "  ${CYAN}Логи:${NC}     %s\n" "$be_log"
    printf "\n"
    printf "  ${GREEN}1.${NC} Адрес\n"
    printf "  ${GREEN}2.${NC} PROXY\n"
    printf "  ${GREEN}3.${NC} Логи\n"
    printf "  ${GREEN}0.${NC} Готово, применить\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r fchoice

    case "$fchoice" in
      1)
        be_to=$(ask_default "Backend host:порт" "$be_to")
        local _h="${be_to%:*}"
        local _p="${be_to##*:}"
        if [ -z "$_h" ] || [ "$_h" = "$be_to" ]; then
          log_error "❌ Жди host:порт (например, 127.0.0.1:10443)"
          sleep 1; continue
        fi
        validate_port "$_p" "порт бэкенда" || { sleep 1; continue; }
        ;;
      2)
        be_proxy=$(ask_default "PROXY-протокол (off/v1/v2)" "$be_proxy")
        case "$be_proxy" in
          off | v1 | v2) ;;
          *) log_error "❌ Жди off/v1/v2"; sleep 1; continue ;;
        esac
        ;;
      3)
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

  local rec="name=${be_name} to=${be_to} proxy=${be_proxy} log=${be_log}"
  if [ "$rec" = "${STREAM_BACKENDS[$idx]}" ]; then
    log_info "Без изменений — ничего не записано"
    return
  fi
  printf "\n"
  printf "  ${CYAN}Было:${NC}  %s\n" "${STREAM_BACKENDS[$idx]}"
  printf "  ${CYAN}Станет:${NC} %s\n" "$rec"
  printf "  ${CYAN}Затронет маршрутов:${NC} %s\n" "$refs"
  printf "\n"
  if ! menu_confirm "Применить изменения? [y/N]:"; then
    log_info "Отмена (ничего не записано)"
    return
  fi
  STREAM_BACKENDS[$idx]="$rec"

  if ! validate_all; then
    log_error "❌ Проверка не пройдена — файл не тронут"
    return
  fi
  save_sites
  log_info "✅ Stream-ящик '${be_name}' обновлён"

  if ! generate_configs_ask; then
    log_error "❌ Ошибка генерации конфигов"
    return
  fi

  printf "\n"
  confirm_restart
}

be_remove() {
  clear_screen
  print_header "УДАЛЕНИЕ STREAM-ЯЩИКА" "➖"

  load_sites

  if [ "${#STREAM_BACKENDS[@]}" -eq 0 ]; then
    log_warn "⚠️  Именованных ящиков нет — удалять нечего"
    return
  fi

  printf "  ${CYAN}👉 Имя ящика (0 - отмена):${NC} "
  tread -r be_name
  { [ "$be_name" = "0" ] || [ -z "$be_name" ]; } && return

  if ! backend_exists stream "$be_name"; then
    log_error "❌ stream-бэкенд '${be_name}' не найден"
    return
  fi
  if ! menu_confirm "Удалить ящик '${be_name}'? [y/N]:"; then
    log_info "Отмена (ничего не удалено)"
    return
  fi
  backend_remove stream "$be_name" || return

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
