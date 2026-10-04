#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CSCLI="docker exec crowdsec-lapi cscli"

cd "$(dirname "$0")" || exit 1

# Имена, которые нельзя удалять этим скриптом (служебные, не ноды)
PROTECTED_NAMES="local-bouncer dashboard"

# ─── ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ─────────────────────────────────

is_protected() {
  local name="$1"
  local p=""
  for p in $PROTECTED_NAMES; do
    if [ "$name" = "$p" ]; then
      return 0
    fi
  done
  return 1
}

exists_machine() {
  $CSCLI machines list 2>/dev/null | grep -qw "$1"
}

exists_bouncer() {
  $CSCLI bouncers list 2>/dev/null | grep -qw "$1"
}

# Пронумерованный выбор ноды из зарегистрированных агентов.
# Меню печатает в stderr, выбранное базовое имя — в stdout.
# Возвращает 1, если выбрать не из чего (пустой LAPI / не распарсилось)
# или пользователь выбрал ручной ввод, — тогда вызывающий спрашивает
# имя вручную.
pick_node() {
  local raw=""
  raw=$($CSCLI machines list 2>/dev/null || true)
  [ -z "$raw" ] && return 1

  local names=()
  local n=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      *-agent)
        n="${n%-agent}"
        if ! is_protected "${n}-agent" && ! is_protected "$n"; then
          names+=("$n")
        fi
        ;;
    esac
  done < <(printf "%s\n" "$raw" | awk '!/─/ && !/^[[:space:]]*NAME([[:space:]]|$)/ && NF {print $1}')

  [ "${#names[@]}" -eq 0 ] && return 1

  printf "\n" >&2
  printf "  ${CYAN}📋 Зарегистрированные ноды:${NC}\n" >&2
  local i=1
  for n in "${names[@]}"; do
    printf "  ${GREEN}%d.${NC} %s\n" "$i" "$n" >&2
    i=$((i + 1))
  done
  printf "  ${GREEN}0.${NC} Ввести имя вручную\n" >&2
  printf "\n" >&2
  printf "  ${CYAN}👉 Номер (0 — вручную):${NC} " >&2
  local choice=""
  read -r choice < /dev/tty
  choice="${choice//$'\r'/}"
  if [ "$choice" = "0" ]; then
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
    log_error "  ❌ Нет такого номера" >&2
    return 1
  fi
  printf "%s" "${names[$((choice - 1))]}"
  return 0
}

# ─── MAIN ─────────────────────────────────────────────────────

clear_screen
print_header "УДАЛЕНИЕ УДАЛЁННОЙ НОДЫ" "🗑️"

# Проверка зависимостей
require_cmd docker "Установи Docker: https://docs.docker.com/engine/install/"
require_lapi || exit 1

# Имя ноды (+ опциональный --yes)
AUTO_YES=0
NODE_NAME=""
if [ -n "${1:-}" ]; then
  if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    AUTO_YES=1
  else
    NODE_NAME="$1"
  fi
fi
if [ -n "${2:-}" ] && { [ "${2:-}" = "--yes" ] || [ "${2:-}" = "-y" ]; }; then
  AUTO_YES=1
fi
if [ -z "$NODE_NAME" ] && [ "$AUTO_YES" = "0" ]; then
  if ! NODE_NAME="$(pick_node)"; then
    NODE_NAME=""
    printf "  ${CYAN}👉 Имя ноды (например, us6):${NC} "
    read -r NODE_NAME < /dev/tty
  fi
fi
[ -z "$NODE_NAME" ] && die "❌ Имя ноды не указано"
NODE_NAME="${NODE_NAME//$'\r'/}"

AGENT_NAME="$NODE_NAME-agent"
BOUNCER_NAME="$NODE_NAME-bouncer"

# Защита служебных имён
if is_protected "$AGENT_NAME" || is_protected "$BOUNCER_NAME"; then
  die "❌ '${NODE_NAME}' — служебное имя, удалять его этим скриптом нельзя."
fi

# Разведка: что из пары существует
printf "\n"
printf "  ${CYAN}🔍 Ищу '%s' в LAPI...${NC}\n" "$NODE_NAME"
HAS_AGENT=0
HAS_BOUNCER=0
if exists_machine "$AGENT_NAME"; then
  HAS_AGENT=1
  log_info "    Агент '${AGENT_NAME}' найден"
else
  log_warn "    ⚠️  Агент '${AGENT_NAME}' не найден"
fi
if exists_bouncer "$BOUNCER_NAME"; then
  HAS_BOUNCER=1
  log_info "    Баунсер '${BOUNCER_NAME}' найден"
else
  log_warn "    ⚠️  Баунсер '${BOUNCER_NAME}' не найден"
fi

if [ "$HAS_AGENT" = "0" ] && [ "$HAS_BOUNCER" = "0" ]; then
  printf "\n"
  log_info "  ✅ Нечего удалять — такой ноды нет в LAPI"
  exit 0
fi

# Подтверждение
if [ "$AUTO_YES" = "0" ]; then
  printf "\n"
  printf "  ${YELLOW}Будет удалено:${NC}\n"
  [ "$HAS_AGENT" = "1" ] && printf "    • агент %s\n" "$AGENT_NAME"
  [ "$HAS_BOUNCER" = "1" ] && printf "    • баунсер %s\n" "$BOUNCER_NAME"
  printf "\n"
  printf "  ${CYAN}👉 Удалить? [y/N]:${NC} "
  read -r answer < /dev/tty
  case "${answer,,}" in
    y|yes|д|да) ;;
    *) log_info "  Отменено"; exit 0 ;;
  esac
fi

# Удаление
printf "\n"
ERRORS=0
if [ "$HAS_AGENT" = "1" ]; then
  printf "  ${CYAN}🗑️  Удаляю агента '%s'...${NC}\n" "$AGENT_NAME"
  if $CSCLI machines delete "$AGENT_NAME" > /dev/null 2>&1; then
    log_info "    ✅ Агент удалён"
  else
    log_error "    ❌ Не удалось удалить агента"
    ERRORS=1
  fi
fi
if [ "$HAS_BOUNCER" = "1" ]; then
  printf "  ${CYAN}🗑️  Удаляю баунсера '%s'...${NC}\n" "$BOUNCER_NAME"
  if $CSCLI bouncers delete "$BOUNCER_NAME" > /dev/null 2>&1; then
    log_info "    ✅ Баунсер удалён"
  else
    log_error "    ❌ Не удалось удалить баунсера"
    ERRORS=1
  fi
fi

printf "\n"
if [ "$ERRORS" = "0" ]; then
  log_info "  ✅ Нода '${NODE_NAME}' удалена из LAPI"
else
  die "❌ Удаление прошло с ошибками — проверь списками выше"
fi
printf "  Активные решения от ноды истекут сами; при желании удали их вручную:\n"
printf "  ${CYAN}docker exec crowdsec-lapi cscli decisions list${NC}\n"
