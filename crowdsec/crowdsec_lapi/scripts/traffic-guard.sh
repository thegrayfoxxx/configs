#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CSCLI="docker exec crowdsec-lapi cscli"
CSCLI_I="docker exec -i crowdsec-lapi cscli"
CONFIG_FILE="${SCRIPT_DIR}/traffic-guard.cfg"
BLOCKLISTS_DIR="${SCRIPT_DIR}/blocklists"

mkdir -p "$BLOCKLISTS_DIR"

declare -A LISTS=(
    ["traffic-guard-scanners"]="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
    ["traffic-guard-gov-networks"]="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
    ["traffic-guard-skipa"]="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"
)

declare -A DURATIONS=(
    ["traffic-guard-scanners"]="30"
    ["traffic-guard-gov-networks"]="90"
    ["traffic-guard-skipa"]="90"
)

LIST_NAMES=(
    "traffic-guard-scanners"
    "traffic-guard-gov-networks"
    "traffic-guard-skipa"
)

# ─── КОНФИГУРАЦИЯ ────────────────────────────────────────────

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
}

save_config() {
  local name
  cat > "$CONFIG_FILE" <<EOF
# Длительность бана в днях для каждого списка
EOF
  for name in "${!DURATIONS[@]}"; do
    printf "DURATIONS[\"%s\"]=\"%s\"\n" "$name" "${DURATIONS[$name]}" >> "$CONFIG_FILE"
  done
}

# ─── СТАТУС ──────────────────────────────────────────────────

show_stats() {
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│           🛡️  TRAFFIC GUARD MANAGER         │${NC}\n"
  printf "${CYAN}├─────────────────────────────────────────────┤${NC}\n"
  for sname in "${LIST_NAMES[@]}"; do
    local lc
    lc=$(grep -vE '^\s*#|^\s*$' "${BLOCKLISTS_DIR}/${sname}.txt" 2>/dev/null | wc -l)

    local lp
    if lapi_is_running; then
      lp=$($CSCLI decisions list --scenario "$sname" -o raw 2>/dev/null | wc -l)
    else
      lp="❌"
    fi

    printf "${CYAN}│${NC}  ${CYAN}%s${NC}\n" "$sname"
    printf "${CYAN}│${NC}    📥 Локально: ${GREEN}%s${NC} IP\n" "$lc"
    if [ "$lp" = "❌" ]; then
      printf "${CYAN}│${NC}    ☁️  В LAPI:   ${RED}%s${NC}\n" "$lp"
    else
      printf "${CYAN}│${NC}    ☁️  В LAPI:   ${GREEN}%s${NC}\n" "$lp"
    fi
    printf "${CYAN}│${NC}    ⏱  Срок:     ${DURATIONS[$sname]}д\n"
  done
  printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
}

# ─── ОПЕРАЦИИ С БЛОКЛИСТАМИ ─────────────────────────────────

download_all() {
  for name in "${LIST_NAMES[@]}"; do
    local local_file="${BLOCKLISTS_DIR}/${name}.txt"
    printf "  📥 ${CYAN}%s${NC}\n" "$name"
    if ! curl -fsSL -o "$local_file" "${LISTS[$name]}"; then
      log_error "    ❌ Ошибка скачивания"
      continue
    fi
    local c
    c=$(grep -vE '^\s*#|^\s*$' "$local_file" | wc -l)
    log_info "    ✅ $c IP"
  done
}

apply_all() {
  require_lapi || return 1
  for name in "${LIST_NAMES[@]}"; do
    local local_file="${BLOCKLISTS_DIR}/${name}.txt"
    if [ ! -f "$local_file" ]; then
      log_warn "  ⚠️  $name: нет локального файла"
      continue
    fi
    local dur="${DURATIONS[$name]}"
    printf "  ☁️  ${CYAN}%s${NC} (%sд)\n" "$name" "$dur"

    # Удаляем старые решения по этому сценарию
    $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1

    # Импортируем новые
    local valid
    valid=$(grep -vE '^\s*#|^\s*$' "$local_file")
    if [ -n "$valid" ]; then
      printf "%s\n" "$valid" | $CSCLI_I decisions import -i - --format values \
        --duration "${dur}d" --type ban --reason "$name" > /dev/null 2>&1

      local added
      added=$($CSCLI decisions list --scenario "$name" -o raw 2>/dev/null | wc -l)
      if [ "$added" -gt 0 ]; then
        log_info "    ✅ $added IP в LAPI"
      else
        log_error "    ❌ Ошибка добавления"
      fi
    fi
  done
  save_config
}

remove_all() {
  require_lapi || return 1
  for name in "${LIST_NAMES[@]}"; do
    remove_list "$name"
  done
}

remove_list() {
  local name="$1"
  if $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1; then
    log_info "  🗑️  ✅ $name: удалено"
  else
    log_error "  🗑️  ❌ $name: ошибка удаления"
  fi
}

# ─── ВЫБОР СПИСКА (универсальный) ──────────────────────────

select_list() {
  local i=1
  for name in "${LIST_NAMES[@]}"; do
    printf "  ${CYAN}%s.${NC} %s\n" "$i" "$name" >&2
    ((i++))
  done
  printf "  ${RED}0.${NC} Назад\n" >&2
  printf "\n" >&2
  printf "${CYAN}👉 Номер:${NC} " >&2
  read -r n < /dev/tty

  local idx=$((n - 1))
  if [ "$n" != "0" ] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#LIST_NAMES[@]}" ]; then
    printf "%s" "${LIST_NAMES[$idx]}"
    return 0
  fi
  return 1
}

# ─── ПОДМЕНЮ ─────────────────────────────────────────────────

delete_menu() {
  clear_screen
  show_stats
  printf "\n"
  log_warn "═══ УДАЛЕНИЕ ═══"
  printf "  ${CYAN}1.${NC} Удалить всё\n"
  printf "  ${CYAN}2.${NC} Выбрать список\n"
  printf "  ${RED}0.${NC} Назад\n"
  printf "\n"
  printf "${CYAN}👉 Действие:${NC} "
  read -r sub < /dev/tty

  case "$sub" in
    1)
      clear_screen
      show_stats
      printf "\n"
      log_warn "═══ УДАЛЕНИЕ ═══"
      remove_all
      ;;
    2)
      clear_screen
      show_stats
      printf "\n"
      log_warn "═══ УДАЛЕНИЕ ═══"
      local selected
      if selected=$(select_list); then
        require_lapi && remove_list "$selected"
      fi
      ;;
  esac
}

edit_duration_menu() {
  local name="$1"
  while true; do
    clear_screen
    show_stats
    printf "\n"
    log_warn "═══ СРОК БАНА ═══"
    printf "  Список: ${CYAN}%s${NC}\n" "$name"
    printf "  Текущий срок: ${GREEN}%s${NC} дней\n" "${DURATIONS[$name]}"
    printf "\n"
    printf "  ${CYAN}1.${NC} %sд (оставить)\n" "${DURATIONS[$name]}"
    printf "  ${CYAN}2.${NC} 7д\n"
    printf "  ${CYAN}3.${NC} 30д\n"
    printf "  ${CYAN}4.${NC} 90д\n"
    printf "  ${CYAN}5.${NC} 365д\n"
    printf "  ${CYAN}6.${NC} Свой вариант\n"
    printf "  ${RED}0.${NC} Назад\n"
    printf "\n"
    printf "${CYAN}👉 Срок:${NC} "
    read -r d < /dev/tty

    case "$d" in
      1) return ;;
      2) DURATIONS["$name"]="7" ;;
      3) DURATIONS["$name"]="30" ;;
      4) DURATIONS["$name"]="90" ;;
      5) DURATIONS["$name"]="365" ;;
      6)
        read -p "  Срок в днях: " custom < /dev/tty
        [[ "$custom" =~ ^[0-9]+$ ]] && DURATIONS["$name"]="$custom" || continue
        ;;
      0) return ;;
      *) continue ;;
    esac
    save_config
    log_info "✅ Обновлено: ${DURATIONS[$name]}д"
    read -p "[Enter]..." < /dev/tty
    return
  done
}

# ─── CRON ─────────────────────────────────────────────────────

setup_cron() {
  if [ "$(id -u)" -ne 0 ]; then
    printf "\n"
    log_warn "═══ НАСТРОЙКА CRON ═══"
    printf "\n"
    log_error "  ❌ Cron нужно настраивать от root"
    printf "\n"
    printf "  Скрипту нужен доступ к ${CYAN}docker${NC}.\n"
    printf "  Запусти от root и настрой заново:\n"
    printf "\n"
    printf "     ${CYAN}sudo bash traffic-guard.sh${NC}\n"
    printf "     → выбери пункт 6${NC}\n"
    printf "\n"
    printf "  Или добавь в crontab root вручную:\n"
    printf "     ${CYAN}sudo crontab -e${NC}\n"
    printf "     Добавь: ${CYAN}0 3 * * * cd ${SCRIPT_DIR} && bash traffic-guard.sh install${NC}\n"
    printf "\n"
    read -p "[Enter] назад..." < /dev/tty
    return
  fi

  local tg_cmd
  tg_cmd="cd ${SCRIPT_DIR} && bash traffic-guard.sh install"

  printf "\n"
  log_warn "═══ НАСТРОЙКА CRON ═══"
  printf "\n"

  # Проверяем, есть ли уже задача
  if crontab -l 2>/dev/null | grep -q -F "$tg_cmd"; then
    log_info "  ✅ Задача уже установлена:"
    crontab -l | grep -F "$tg_cmd"
    printf "\n"
    printf "  ${YELLOW}👉 Для удаления: ${CYAN}crontab -e${NC}\n"
    printf "\n"
    read -p "[Enter] назад..." < /dev/tty
    return
  fi

  printf "  Выбери интервал обновления блоклистов: \n"
  printf "\n"
  printf "  ${CYAN}1.${NC} Каждый час\n"
  printf "  ${CYAN}2.${NC} Каждые 6 часов\n"
  printf "  ${CYAN}3.${NC} Каждые 12 часов\n"
  printf "  ${CYAN}4.${NC} Раз в день (в 3:00)\n"
  printf "  ${CYAN}5.${NC} Свой вариант\n"
  printf "  ${RED}0.${NC} Отмена\n"
  printf "\n"
  printf "${CYAN}👉 Интервал:${NC} "
  read -r interval < /dev/tty

  local cron_time=""
  case "$interval" in
    1) cron_time="0 * * * *" ;;
    2) cron_time="0 */6 * * *" ;;
    3) cron_time="0 */12 * * *" ;;
    4) cron_time="0 3 * * *" ;;
    5)
      printf "\n"
      printf "  Формат: ${CYAN}минута час день месяц день_недели${NC}\n"
      printf "  Пример: ${CYAN}0 */4 * * *${NC} — каждые 4 часа\n"
      printf "\n"
      printf "${CYAN}👉 Введи cron-выражение:${NC} "
      read -r cron_time < /dev/tty
      [ -z "$cron_time" ] && return
      ;;
    0 | *) return ;;
  esac

  # Удаляем старую запись с этой же командой (если была), добавляем новую
  (crontab -l 2>/dev/null | grep -v -F "$tg_cmd"; printf "%s %s\n" "$cron_time" "$tg_cmd") | crontab -
  printf "\n"
  log_info "  ✅ Задача установлена!"
  printf "     ${CYAN}%s %s${NC}\n" "$cron_time" "$tg_cmd"
  printf "\n"
  read -p "[Enter] назад..." < /dev/tty
}

# ─── ГЛАВНОЕ МЕНЮ ────────────────────────────────────────────

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    show_stats
    printf "\n"
    printf "  ${GREEN}1.${NC} 📥 Только скачать (локально)\n"
    printf "  ${GREEN}2.${NC} ☁️  Установить в LAPI (из файлов)\n"
    printf "  ${GREEN}3.${NC} 🔄 Полное обновление (скачать + LAPI)\n"
    printf "  ${GREEN}4.${NC} 🗑️  Удалить списки из LAPI\n"
    printf "  ${GREEN}5.${NC} ⏱  Настроить срок бана\n"
    printf "  ${GREEN}6.${NC} ⏰  Автообновление (cron)\n"
    printf "  ${RED}0.${NC} ❌ Выход\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        clear_screen
        show_stats
        printf "\n"
        log_warn "═══ СКАЧИВАНИЕ ═══"
        download_all
        ;;
      2)
        clear_screen
        show_stats
        printf "\n"
        log_warn "═══ УСТАНОВКА В LAPI ═══"
        apply_all
        ;;
      3)
        clear_screen
        show_stats
        printf "\n"
        log_warn "═══ ПОЛНОЕ ОБНОВЛЕНИЕ ═══"
        download_all
        printf "\n"
        apply_all
        ;;
      4)
        delete_menu
        ;;
      5)
        clear_screen
        show_stats
        printf "\n"
        log_warn "═══ ВЫБОР СПИСКА ═══"
        local selected
        if selected=$(select_list); then
          edit_duration_menu "$selected"
        fi
        continue
        ;;
      6)
        clear_screen
        show_stats
        setup_cron
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac

    if [ "$choice" != "3" ] && [ "$choice" != "5" ] && [ "$choice" != "6" ]; then
      printf "\n"
      read -p "[Enter] в меню..." < /dev/tty
    fi
  done
}

# ─── АРГУМЕНТЫ КОМАНДНОЙ СТРОКИ ──────────────────────────────

load_config

case "${1:-}" in
  download) download_all ;;
  apply)
    require_lapi && apply_all
    ;;
  install)
    download_all
    printf "\n"
    require_lapi && apply_all
    ;;
  remove)
    require_lapi
    for name in "${LIST_NAMES[@]}"; do
      $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1
    done
    ;;
  status)
    for name in "${LIST_NAMES[@]}"; do
      lc=$(grep -vE '^\s*#|^\s*$' "${BLOCKLISTS_DIR}/${name}.txt" 2>/dev/null | wc -l)
      if lapi_is_running; then
        lp=$($CSCLI decisions list --scenario "$name" -o raw 2>/dev/null | wc -l)
      else
        lp="LAPI недоступен"
      fi
      printf "%s: локально %s, в LAPI %s\n" "$name" "$lc" "$lp"
    done
    ;;
  *) show_menu ;;
esac
