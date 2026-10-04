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
  # Сравнение по части до @: записи вида имя@IP тоже защищены
  local name="${1%%@*}"
  local p=""
  for p in $PROTECTED_NAMES; do
    if [ "$name" = "$p" ]; then
      return 0
    fi
  done
  return 1
}

# Первая колонка cscli-таблицы: режем рамки и шапку, по имени на строку.
list_names() {
  # $1 = machines|bouncers
  $CSCLI "$1" list 2>/dev/null \
    | awk '!/─/ && !/^[[:space:]]*NAME([[:space:]]|$)/ && NF {print $1}' || true
}

# Совпадения базы в уже полученном списке имён: точное + имя@IP.
# $1 = база, остальные аргументы = имена. Печатает по одному на строку.
match_base() {
  local base="$1"
  shift
  local e=""
  for e in "$@"; do
    [ -n "$e" ] || continue
    # Звёздочка вне кавычек: "$base" точное совпадение, "$base"@* — варианты имя@IP
    if [ "$e" = "$base" ] || [[ "$e" == "$base"@* ]]; then
      printf "%s\n" "$e"
    fi
  done
}

# Все записи LAPI с базовым именем: точное совпадение + варианты имя@IP
# (один ключ баунсера с разных IP плодит такие записи).
# $1 = machines|bouncers, $2 = базовое имя. Печатает по одной на строку.
find_entries() {
  local kind="$1" base="$2"
  local all=()
  mapfile -t all < <(list_names "$kind") || true
  [ "${#all[@]}" -eq 0 ] && return 0
  match_base "$base" "${all[@]}"
}

# Удаление одной записи LAPI.
# При падении перепроверяет список: запись могла исчезнуть каскадом
# (удаление базового имени тянет варианты имя@IP) или гонкой —
# тогда это успех, а не ошибка. Иначе показывает текст ошибки cscli.
# $1 = machines|bouncers, $2 = имя, $3 = подпись для вывода.
delete_entry() {
  local kind="$1" name="$2" label="$3"
  local err=""
  printf "  ${CYAN}🗑️  Удаляю %s '%s'...${NC}\n" "$label" "$name"
  if err=$($CSCLI "$kind" delete "$name" 2>&1); then
    log_info "    ✅ Готово"
    return 0
  fi
  if [ -z "$(find_entries "$kind" "$name")" ]; then
    log_info "    ✅ Уже отсутствует (удалена каскадом)"
    return 0
  fi
  log_error "    ❌ Не удалось удалить '${name}': ${err:-неизвестная ошибка}"
  return 1
}

# Пронумерованный выбор ноды из зарегистрированных агентов.
# Строка вида: us6 (баунсер: us6-bouncer, us6-bouncer@172.22.0.1).
# Баунсеры без агента идут отдельной секцией сирот.
# Меню печатает в stderr, выбранное базовое имя — в stdout.
# Возвращает 1, если выбрать не из чего (пустой LAPI / не распарсилось)
# или пользователь выбрал ручной ввод, — тогда вызывающий спрашивает
# имя вручную.
pick_node() {
  local agents="" bouncers=""
  agents=$(list_names machines || true)
  [ -z "$agents" ] && return 1
  bouncers=$(list_names bouncers || true)

  # Базы нод: *-agent (срезать @IP, потом -agent), дедуп, без служебных
  local -A seen=()
  local bases=()
  local e="" b=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    e="${e%%@*}"
    case "$e" in
      *-agent)
        b="${e%-agent}"
        if ! is_protected "$e" && [ -z "${seen[$b]:-}" ]; then
          seen[$b]=1
          bases+=("$b")
        fi
        ;;
    esac
  done < <(printf "%s\n" "$agents")

  [ "${#bases[@]}" -eq 0 ] && return 1

  local ball=()
  if [ -n "$bouncers" ]; then
    mapfile -t ball < <(printf "%s\n" "$bouncers") || true
  fi

  printf "\n" >&2
  printf "  ${CYAN}📋 Зарегистрированные ноды:${NC}\n" >&2
  local i=1
  local show_brackets
  show_brackets() {
    # $1 = база, $2 = подпись скобки
    local b="$1" tag="$2"
    local bent=()
    if [ "${#ball[@]}" -gt 0 ]; then
      mapfile -t bent < <(match_base "${b}-bouncer" "${ball[@]}") || true
    fi
    if [ "${#bent[@]}" -gt 0 ]; then
      local joined=""
      joined=$(printf "%s, " "${bent[@]}")
      printf "  ${GREEN}%d.${NC} %s (%s: %s)\n" "$i" "$b" "$tag" "${joined%, }" >&2
    else
      printf "  ${GREEN}%d.${NC} %s (без баунсера)\n" "$i" "$b" >&2
    fi
    i=$((i + 1))
  }
  local b=""
  for b in "${bases[@]}"; do
    show_brackets "$b" "баунсер"
  done

  # Сироты: баунсеры *-bouncer, чьей базы нет среди агентов.
  # Баунсеры без суффикса -bouncer пропускаем — из них не вывести базу.
  local orphans=()
  if [ "${#ball[@]}" -gt 0 ]; then
    local -A seen_orphan=()
    local be="" bb=""
    while IFS= read -r be; do
      [ -n "$be" ] || continue
      be="${be%%@*}"
      case "$be" in
        *-bouncer)
          bb="${be%-bouncer}"
          if [ -z "${seen[$bb]:-}" ] && [ -z "${seen_orphan[$bb]:-}" ] && ! is_protected "$be"; then
            seen_orphan[$bb]=1
            orphans+=("$bb")
          fi
          ;;
      esac
    done < <(printf "%s\n" "$bouncers")
  fi
  if [ "${#orphans[@]}" -gt 0 ]; then
    printf "\n" >&2
    printf "  ${YELLOW}⚠️  Баунсеры-сироты (агента нет):${NC}\n" >&2
    local o=""
    for o in "${orphans[@]}"; do
      show_brackets "$o" "только баунсер"
      bases+=("$o")
    done
  fi
  printf "  ${GREEN}0.${NC} Ввести имя вручную\n" >&2
  printf "\n" >&2
  printf "  ${CYAN}👉 Номер (0 — вручную):${NC} " >&2
  local choice=""
  read -r choice < /dev/tty
  choice="${choice//$'\r'/}"
  if [ "$choice" = "0" ]; then
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#bases[@]}" ]; then
    log_error "  ❌ Нет такого номера" >&2
    return 1
  fi
  printf "%s" "${bases[$((choice - 1))]}"
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

# Разведка: все записи пары, включая варианты имя@IP
# (один ключ баунсера с разных IP плодит такие записи)
printf "\n"
printf "  ${CYAN}🔍 Ищу '%s' в LAPI...${NC}\n" "$NODE_NAME"
AGENT_ENTRIES=()
BOUNCER_ENTRIES=()
mapfile -t AGENT_ENTRIES < <(find_entries machines "$AGENT_NAME") || true
mapfile -t BOUNCER_ENTRIES < <(find_entries bouncers "$BOUNCER_NAME") || true
if [ "${#AGENT_ENTRIES[@]}" -gt 0 ]; then
  log_info "    Агенты:"
  for e in "${AGENT_ENTRIES[@]}"; do printf "      • %s\n" "$e"; done
else
  log_warn "    ⚠️  Агент '${AGENT_NAME}' не найден"
fi
if [ "${#BOUNCER_ENTRIES[@]}" -gt 0 ]; then
  log_info "    Баунсеры:"
  for e in "${BOUNCER_ENTRIES[@]}"; do printf "      • %s\n" "$e"; done
else
  log_warn "    ⚠️  Баунсер '${BOUNCER_NAME}' не найден"
fi

if [ "${#AGENT_ENTRIES[@]}" -eq 0 ] && [ "${#BOUNCER_ENTRIES[@]}" -eq 0 ]; then
  printf "\n"
  log_info "  ✅ Нечего удалять — такой ноды нет в LAPI"
  exit 0
fi

# Подтверждение
if [ "$AUTO_YES" = "0" ]; then
  printf "\n"
  printf "  ${YELLOW}Будет удалено:${NC}\n"
  if [ "${#AGENT_ENTRIES[@]}" -gt 0 ]; then
    for e in "${AGENT_ENTRIES[@]}"; do printf "    • агент %s\n" "$e"; done
  fi
  if [ "${#BOUNCER_ENTRIES[@]}" -gt 0 ]; then
    for e in "${BOUNCER_ENTRIES[@]}"; do printf "    • баунсер %s\n" "$e"; done
  fi
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
if [ "${#AGENT_ENTRIES[@]}" -gt 0 ]; then
  for e in "${AGENT_ENTRIES[@]}"; do
    delete_entry machines "$e" "агента" || ERRORS=1
  done
fi
if [ "${#BOUNCER_ENTRIES[@]}" -gt 0 ]; then
  for e in "${BOUNCER_ENTRIES[@]}"; do
    delete_entry bouncers "$e" "баунсера" || ERRORS=1
  done
fi

printf "\n"
if [ "$ERRORS" = "0" ]; then
  log_info "  ✅ Нода '${NODE_NAME}' удалена из LAPI"
else
  die "❌ Удаление прошло с ошибками — проверь списками выше"
fi
printf "  Активные решения от ноды истекут сами; при желании удали их вручную:\n"
printf "  ${CYAN}docker exec crowdsec-lapi cscli decisions list${NC}\n"
