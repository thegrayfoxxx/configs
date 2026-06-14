#!/bin/bash
set -u

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CSCLI="docker exec crowdsec-lapi cscli"
CSCLI_I="docker exec -i crowdsec-lapi cscli"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/traffic-guard.cfg"
BLOCKLISTS_DIR="${SCRIPT_DIR}/blocklists"
mkdir -p "$BLOCKLISTS_DIR"

declare -A LISTS=(
    ["traffic-guard-scanners"]="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
    ["traffic-guard-gov-networks"]="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
)

declare -A DURATIONS=(
    ["traffic-guard-scanners"]="30"
    ["traffic-guard-gov-networks"]="90"
)

LIST_NAMES=(
    "traffic-guard-scanners"
    "traffic-guard-gov-networks"
)

if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# Длительность бана в днях для каждого списка
EOF
  for name in "${!DURATIONS[@]}"; do
    echo "DURATIONS[\"$name\"]=\"${DURATIONS[$name]}\"" >> "$CONFIG_FILE"
  done
}

# --- ПРОВЕРКА LAPI ---
check_lapi() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec-lapi'
}

lapi_available() {
  if ! check_lapi; then
    echo -e "\n${RED}❌ Контейнер crowdsec-lapi не запущен${NC}"
    return 1
  fi
}

# --- СТАТУС-БАР (шапка меню) ---
show_stats() {
  echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│           🛡️  TRAFFIC GUARD MANAGER         │${NC}"
  echo -e "${CYAN}├─────────────────────────────────────────────┤${NC}"
  for sname in "${LIST_NAMES[@]}"; do
    local lc=$(grep -vE '^\s*#|^\s*$' "${BLOCKLISTS_DIR}/${sname}.txt" 2>/dev/null | wc -l)
    if check_lapi; then
      local lp=$($CSCLI decisions list --scenario "$sname" -o count 2>/dev/null || echo "?")
    else
      local lp="❌"
    fi
    echo -e "${CYAN}│${NC}  ${CYAN}$sname${NC}"
    printf "${CYAN}│${NC}    📥 Локально: ${GREEN}%s${NC} IP\n" "$lc"
    if [ "$lp" = "❌" ]; then
      echo -e "${CYAN}│${NC}    ☁️  В LAPI:   ${RED}$lp${NC}"
    else
      printf "${CYAN}│${NC}    ☁️  В LAPI:   ${GREEN}%s${NC}\n" "$lp"
    fi
    echo -e "${CYAN}│${NC}    ⏱  Срок:     ${DURATIONS[$sname]}д"
  done
  echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
}

# --- СКАЧАТЬ ЛОКАЛЬНО ---
download_all() {
  for name in "${LIST_NAMES[@]}"; do
    local LOCAL_FILE="${BLOCKLISTS_DIR}/${name}.txt"
    echo -e "  📥 ${CYAN}$name${NC}"
    curl -fsSL -o "$LOCAL_FILE" "${LISTS[$name]}"
    if [ $? -ne 0 ]; then
      echo -e "    ${RED}❌ Ошибка скачивания${NC}"
      continue
    fi
    local c=$(grep -vE '^\s*#|^\s*$' "$LOCAL_FILE" | wc -l)
    echo -e "    ${GREEN}✅${NC} $c IP"
  done
}

# --- УСТАНОВИТЬ В LAPI ---
apply_all() {
  lapi_available || return 1
  for name in "${LIST_NAMES[@]}"; do
    local LOCAL_FILE="${BLOCKLISTS_DIR}/${name}.txt"
    if [ ! -f "$LOCAL_FILE" ]; then
      echo -e "  ${YELLOW}⚠️${NC} ${CYAN}$name${NC}: нет локального файла"
      continue
    fi
    local DUR="${DURATIONS[$name]}"
    echo -e "  ☁️  ${CYAN}$name${NC} (${DUR}д)"
    $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1

    local valid=$(grep -vE '^\s*#|^\s*$' "$LOCAL_FILE")
    if [ -n "$valid" ]; then
      echo "$valid" | $CSCLI_I decisions import -i - --format values \
        --duration "${DUR}d" --type ban --reason "$name" > /dev/null 2>&1

      local added=$($CSCLI decisions list --scenario "$name" -o count 2>/dev/null || echo 0)
      if [ "$added" -gt 0 ]; then
        echo -e "    ${GREEN}✅${NC} $added IP в LAPI"
      else
        echo -e "    ${RED}❌${NC} Ошибка добавления"
      fi
    fi
  done
  save_config
}

# --- УДАЛИТЬ ИЗ LAPI ---
remove_list() {
  local name="$1"
  if $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1; then
    echo -e "  🗑️  ${GREEN}✅${NC} ${CYAN}$name${NC}: удалено"
  else
    echo -e "  🗑️  ${RED}❌${NC} ${CYAN}$name${NC}: ошибка удаления"
  fi
}

remove_all() {
  lapi_available || return 1
  for name in "${LIST_NAMES[@]}"; do
    remove_list "$name"
  done
}

# --- ПОДМЕНЮ: НАСТРОЙКА СРОКА ---
edit_duration_menu() {
  local name="$1"
  while true; do
    tput clear
    show_stats
    echo -e "
${YELLOW}═══ СРОК БАНА ═══${NC}"
    echo -e "  Список: ${CYAN}$name${NC}"
    echo -e "  Текущий срок: ${GREEN}${DURATIONS[$name]}${NC} дней"
    echo ""
    echo -e "  ${CYAN}1.${NC} ${DURATIONS[$name]}д (оставить)"
    echo -e "  ${CYAN}2.${NC} 7д"
    echo -e "  ${CYAN}3.${NC} 30д"
    echo -e "  ${CYAN}4.${NC} 90д"
    echo -e "  ${CYAN}5.${NC} 365д"
    echo -e "  ${CYAN}6.${NC} Свой вариант"
    echo -e "  ${RED}0.${NC} Назад"
    echo ""
    echo -ne "${CYAN}👉 Срок:${NC} "
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
    echo -e "\n${GREEN}✅${NC} Обновлено: ${DURATIONS[$name]}д"
    read -p "[Enter]..." < /dev/tty
    return
  done
}

# --- НАСТРОЙКА CRON ---
setup_cron() {
  if [ "$(id -u)" -ne 0 ]; then
    echo ""
    echo -e "${YELLOW}═══ НАСТРОЙКА CRON ═══${NC}"
    echo ""
    echo -e "  ${RED}❌ Cron нужно настраивать от root${NC}"
    echo ""
    echo -e "  Скрипту нужен доступ к ${CYAN}docker${NC} и ${CYAN}ipset${NC}."
    echo -e "  Запусти от root и настрой заново:"
    echo ""
    echo -e "     ${CYAN}sudo bash traffic-guard.sh${NC}"
    echo -e "     → выбери пункт 6${NC}"
    echo ""
    echo -e "  Или добавь в crontab root вручную:"
    echo -e "     ${CYAN}sudo crontab -e${NC}"
    echo -e "     Добавь: ${CYAN}0 3 * * * cd ${SCRIPT_DIR} && bash traffic-guard.sh install${NC}"
    echo ""
    read -p "[Enter] назад..." < /dev/tty
    return
  fi
  local TG_CMD
  TG_CMD="cd ${SCRIPT_DIR} && bash traffic-guard.sh install"
  local HAS_CRON=$(crontab -l 2>/dev/null | grep -F "$TG_CMD")

  echo ""
  echo -e "${YELLOW}═══ НАСТРОЙКА CRON ═══${NC}"
  echo ""

  if [ -n "$HAS_CRON" ]; then
    echo -e "  ${GREEN}✅ Задача уже установлена:${NC}"
    crontab -l | grep -F "$TG_CMD"
    echo ""
    echo -e "  ${YELLOW}👉 Для удаления: ${CYAN}crontab -e${NC}"
    echo ""
    read -p "[Enter] назад..." < /dev/tty
    return
  fi

  echo -e "  Выбери интервал обновления блоклистов: "
  echo ""
  echo -e "  ${CYAN}1.${NC} Каждый час"
  echo -e "  ${CYAN}2.${NC} Каждые 6 часов"
  echo -e "  ${CYAN}3.${NC} Каждые 12 часов"
  echo -e "  ${CYAN}4.${NC} Раз в день (в 3:00)"
  echo -e "  ${CYAN}5.${NC} Свой вариант"
  echo -e "  ${RED}0.${NC} Отмена"
  echo ""
  echo -ne "${CYAN}👉 Интервал:${NC} "
  read -r interval < /dev/tty

  local CRON_TIME=""
  case "$interval" in
    1) CRON_TIME="0 * * * *" ;;
    2) CRON_TIME="0 */6 * * *" ;;
    3) CRON_TIME="0 */12 * * *" ;;
    4) CRON_TIME="0 3 * * *" ;;
    5)
      echo ""
      echo -e "  Формат: ${CYAN}минута час день месяц день_недели${NC}"
      echo -e "  Пример: ${CYAN}0 */4 * * *${NC} — каждые 4 часа"
      echo ""
      echo -ne "${CYAN}👉 Введи cron-выражение:${NC} "
      read -r CRON_TIME < /dev/tty
      [ -z "$CRON_TIME" ] && return
      ;;
    0 | *) return ;;
  esac

  (crontab -l 2>/dev/null; echo "$CRON_TIME $TG_CMD") | crontab -
  echo ""
  echo -e "  ${GREEN}✅ Задача установлена!${NC}"
  echo -e "     ${CYAN}$CRON_TIME $TG_CMD${NC}"
  echo ""
  read -p "[Enter] назад..." < /dev/tty
}

# --- ГЛАВНОЕ МЕНЮ ---
show_menu() {
  trap 'exit 0' INT
  while true; do
    tput clear
    show_stats
    echo ""
    echo -e "  ${GREEN}1.${NC} 📥 Только скачать (локально)"
    echo -e "  ${GREEN}2.${NC} ☁️  Установить в LAPI (из файлов)"
    echo -e "  ${GREEN}3.${NC} 🔄 Полное обновление (скачать + LAPI)"
    echo -e "  ${GREEN}4.${NC} 🗑️  Удалить списки из LAPI"
    echo -e "  ${GREEN}5.${NC} ⏱  Настроить срок бана"
    echo -e "  ${GREEN}6.${NC} ⏰  Автообновление (cron)"
    echo -e "  ${RED}0.${NC} ❌ Выход"
    echo ""
    echo -ne "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      1)
        tput clear
        show_stats
        echo -e "
${YELLOW}═══ СКАЧИВАНИЕ ═══${NC}"
        download_all
        ;;
      2)
        tput clear
        show_stats
        echo -e "
${YELLOW}═══ УСТАНОВКА В LAPI ═══${NC}"
        apply_all
        ;;
      3)
        tput clear
        show_stats
        echo -e "
${YELLOW}═══ ПОЛНОЕ ОБНОВЛЕНИЕ ═══${NC}"
        download_all
        echo ""
        apply_all
        ;;
      4)
        echo -e "
${YELLOW}═══ УДАЛЕНИЕ ═══${NC}"
        echo -e "  ${CYAN}1.${NC} Удалить всё"
        echo -e "  ${CYAN}2.${NC} Выбрать список"
        echo -e "  ${RED}0.${NC} Назад"
        echo ""
        echo -ne "${CYAN}👉 Действие:${NC} "
        read -r sub < /dev/tty
        if [ "$sub" = "1" ]; then
          tput clear
          show_stats
          echo -e "
${YELLOW}═══ УДАЛЕНИЕ ═══${NC}"
          remove_all
        elif [ "$sub" = "2" ]; then
          tput clear
          show_stats
          echo -e "
${YELLOW}═══ УДАЛЕНИЕ ═══${NC}"
          local i=1
          for name in "${LIST_NAMES[@]}"; do
            echo -e "  ${CYAN}$i.${NC} $name"
            ((i++))
          done
          echo -e "  ${RED}0.${NC} Назад"
          echo ""
          echo -ne "${CYAN}👉 Номер:${NC} "
          read -r n < /dev/tty
          local idx=$((n - 1))
          if [ "$n" != "0" ] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#LIST_NAMES[@]}" ]; then
            lapi_available && remove_list "${LIST_NAMES[$idx]}"
          fi
        else
          continue
        fi
        ;;
      5)
        tput clear
        show_stats
        echo -e "
${YELLOW}═══ ВЫБОР СПИСКА ═══${NC}"
        local i=1
        for name in "${LIST_NAMES[@]}"; do
          echo -e "  ${CYAN}$i.${NC} $name"
          ((i++))
        done
        echo -e "  ${RED}0.${NC} Назад"
        echo ""
        echo -ne "${CYAN}👉 Номер:${NC} "
        read -r n < /dev/tty
        local idx=$((n - 1))
        if [ "$n" != "0" ] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#LIST_NAMES[@]}" ]; then
          edit_duration_menu "${LIST_NAMES[$idx]}"
        fi
        continue
        ;;
      6)
        tput clear
        show_stats
        setup_cron
        ;;
      0) exit 0 ;;
      *) echo -e "${RED}❌ Неверный пункт${NC}"; sleep 1; continue ;;
    esac

    if [ "$choice" != "3" ] && [ "$choice" != "5" ]; then
      echo ""
      read -p "[Enter] в меню..." < /dev/tty
    fi
  done
}

# --- АРГУМЕНТЫ КОМАНДНОЙ СТРОКИ ---
case "${1:-}" in
  download) download_all ;;
  apply) lapi_available && apply_all ;;
  install) download_all; echo ""; lapi_available && apply_all ;;
  remove) lapi_available && for name in "${LIST_NAMES[@]}"; do $CSCLI decisions delete --scenario "$name" > /dev/null 2>&1; done ;;
  status)
    for name in "${LIST_NAMES[@]}"; do
      lc=$(grep -vE '^\s*#|^\s*$' "${BLOCKLISTS_DIR}/${name}.txt" 2>/dev/null | wc -l)
      if check_lapi; then
        lp=$($CSCLI decisions list --scenario "$name" -o count 2>/dev/null || echo "?")
      else
        lp="LAPI недоступен"
      fi
      echo "$name: локально $lc, в LAPI $lp"
    done
    ;;
  *) show_menu ;;
esac
