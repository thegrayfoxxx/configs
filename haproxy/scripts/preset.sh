#!/bin/bash
# Библиотека пресетов (волна 4): готовые сценарии sites.conf.v2 + визард.
# presets/<имя>/: preset.conf (шаблон с {{VAR}}), questions (VAR|промпт|дефолт|валидатор),
#   README.md, custom/ (опциональный оверлей в haproxy/custom/).
# Использование: preset.sh list|show <n>|apply <n> [--dry-run] [--yes] [--answers f]|diff <n>|new <n>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

PRESETS_DIR="${PRESETS_DIR_OVERRIDE:-${HAPROXY_DIR}/presets}"
# PRESET_TTY: откуда визард читает ответы (дефолт /dev/tty; тесты подсовывают файл).
TTY_IN="${PRESET_TTY:-/dev/tty}"

declare -A PVALS=()   # собранные значения VAR -> значение
declare -A PGIVEN=()  # предзаполненные из --answers

preset_dir() { printf "%s/%s" "$PRESETS_DIR" "$1"; }
preset_exists() { [ -f "$(preset_dir "$1")/preset.conf" ] && [ -f "$(preset_dir "$1")/questions" ]; }

preset_title() {
  local r
  r=$(grep -m1 '^# ' "$(preset_dir "$1")/README.md" 2>/dev/null | sed 's/^# //')
  printf "%s" "${r:-$1}"
}

ask() { # ask VAR "промпт" "дефолт" валидатор -> печатает значение
  local var="$1" prompt="$2" def="$3" validator="$4"
  local ans
  while true; do
    if [ -n "$def" ]; then
      printf "  ${CYAN}%s [%s]:${NC} " "$prompt" "$def"
    else
      printf "  ${CYAN}%s:${NC} " "$prompt"
    fi
    read -r ans < "$TTY_IN"
    [ -z "$ans" ] && ans="$def"
    case "$validator" in
      any) printf "%s" "$ans"; return 0 ;;
      nonempty)
        [ -n "$ans" ] && { printf "%s" "$ans"; return 0; }
        log_error "  ❌ Значение не может быть пустым"
        ;;
      domain)
        if validate_domain "$ans" 2>/dev/null; then printf "%s" "$ans"; return 0; fi
        ;;
      port)
        if validate_port "$ans" "порт" 2>/dev/null; then printf "%s" "$ans"; return 0; fi
        ;;
      email)
        if [[ "$ans" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then printf "%s" "$ans"; return 0; else log_error "  ❌ Введи корректный email"; fi
        ;;
      *)
        log_error "  ❌ Неизвестный валидатор '${validator}' в questions (пресет битый)"
        return 1
        ;;
    esac
  done
}

# collect <preset> <mode:ask|defaults> — заполняет PVALS (вопросы + derive).
collect() {
  local name="$1" mode="$2"
  local qfile
  qfile="$(preset_dir "$name")/questions"
  PVALS=()
  local line var prompt def validator
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line//[[:space:]]/}" ] && continue
    if [[ "$line" == derive:* ]]; then
      continue # derive — вторым проходом
    fi
    IFS='|' read -r var prompt def validator <<< "$line"
    if [ "$mode" = "defaults" ]; then
      PVALS["$var"]="$def"
      continue
    fi
    if [[ -v PGIVEN["$var"] ]]; then
      # Значение из --answers: скаляры подхватит render через PVALS ниже,
      # list-наборы превратит apply_answers_lists. Здесь только скаляры.
      if [[ "$validator" != list:* ]]; then
        case "$validator" in
          any | nonempty) [ -n "${PGIVEN[$var]}" ] || { log_error "  ❌ Пустое ${var} в answers"; return 1; } ;;
          domain) validate_domain "${PGIVEN[$var]}" 2>/dev/null || return 1 ;;
          port) validate_port "${PGIVEN[$var]}" "порт" 2>/dev/null || return 1 ;;
          email) [[ "${PGIVEN[$var]}" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || { log_error "  ❌ Битый email в answers"; return 1; } ;;
          *) log_error "  ❌ Неизвестный валидатор '${validator}'"; return 1 ;;
        esac
        PVALS["$var"]="${PGIVEN[$var]}"
      fi
      continue
    fi
    if [[ "$validator" == list:* ]]; then
      collect_list "$var" "$prompt" "$validator"
    else
      PVALS["$var"]="$(ask "$var" "$prompt" "$def" "$validator")"
    fi
  done < "$qfile"
  # Второй проход: derive (сейчас только tag: VAR=tag DOMVAR PORTVAR)
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == derive:* ]] || continue
    local spec="${line#derive:}"
    local dvar="${spec%%=*}"
    local rexpr="${spec#*=}"
    local kind="${rexpr%% *}"
    local dargs="${rexpr#* }"
    case "$kind" in
      tag)
        local dvar2 pvar2
        read -r dvar2 pvar2 <<< "$dargs"
        PVALS["$dvar"]="$(tag_for_domain "${PVALS[$dvar2]}")_${PVALS[$pvar2]}"
        ;;
      *)
        log_error "  ❌ Неизвестный derive '${kind}' (пресет битый)"
        return 1
        ;;
    esac
  done < "$qfile"
}

# collect_list: повторяющийся ввод "домен:порт", складывает строки '  "d:p"'.
collect_list() {
  local var="$1" prompt="$2" validator="$3"
  local fmt="${validator#list:}"
  local lines=() dom port
  printf "  ${CYAN}%s (Enter на пустом домене = готово):${NC}\n" "$prompt"
  while true; do
    printf "    ${CYAN}Домен:${NC} "
    read -r dom < "$TTY_IN"
    [ -z "$dom" ] && break
    if ! validate_domain "$dom" 2>/dev/null; then continue; fi
    # shellcheck disable=SC2086
    if [ "$fmt" = "domainport" ]; then
      printf "    ${CYAN}Порт бэкенда:${NC} "
      read -r port < "$TTY_IN"
      validate_port "$port" "порт" 2>/dev/null || continue
      lines+=("  \"${dom}:${port}\"")
    else
      log_error "  ❌ Неизвестный list-формат '${fmt}'"
      return 1
    fi
  done
  if [ "${#lines[@]}" -eq 0 ]; then
    log_error "  ❌ Нужна хотя бы одна запись"
    return 1
  fi
  PVALS["$var"]=$(printf "%s\n" "${lines[@]}")
}

render_preset() { # render <preset> -> stdout готовый sites.conf
  local name="$1"
  local content key leftovers
  content=$(cat "$(preset_dir "$name")/preset.conf")
  for key in "${!PVALS[@]}"; do
    content="${content//\{\{$key\}\}/"${PVALS[$key]}"}"
  done
  leftovers=$(printf "%s" "$content" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' | sort -u || true)
  if [ -n "$leftovers" ]; then
    log_error "  ❌ Незаполненные плейсхолдеры: ${leftovers}"
    return 1
  fi
  printf "%s\n" "$content"
}

load_answers() { # load_answers <file> — VAR=val построчно (повторы для list: append через \n)
  local f="$1" k v
  PGIVEN=()
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line//[[:space:]]/}" ] && continue
    k="${line%%=*}"
    v="${line#*=}"
    if [[ -v PGIVEN["$k"] ]]; then
      PGIVEN["$k"]="${PGIVEN[$k]}"$'\n'"$v"
    else
      PGIVEN["$k"]="$v"
    fi
  done < "$f"
}

# Спец-обработка answers для list-переменных: файл даёт строки "VAR=домен:порт",
# а collect_list ждёт интерактив. Здесь: если для list-VAR есть готовые строки —
# превращаем их сразу в готовые строки конфига '  "d:p"'.
apply_answers_lists() {
  local qfile="$1" var fmt
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line//[[:space:]]/}" ] && continue
    [[ "$line" == derive:* ]] && continue
    IFS='|' read -r var _ _ fmt <<< "$line"
    if [[ "$fmt" == list:* ]] && [[ -v PGIVEN["$var"] ]]; then
      local out=() row d p
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        d="${row%%:*}"
        p="${row##*:}"
        validate_domain "$d" 2>/dev/null || { log_error "  ❌ Битый домен в answers: $d"; return 1; }
        validate_port "$p" "порт" 2>/dev/null || return 1
        out+=("  \"${d}:${p}\"")
      done <<< "${PGIVEN[$var]}"
      [ "${#out[@]}" -eq 0 ] && { log_error "  ❌ Пустой список ${var} в answers"; return 1; }
      PVALS["$var"]=$(printf "%s\n" "${out[@]}")
    fi
  done < "$qfile"
}

cmd_list() {
  printf "  Доступные пресеты (${CYAN}%s${NC}):\n" "$PRESETS_DIR"
  local d
  for d in "$PRESETS_DIR"/*/; do
    [ -d "$d" ] || continue
    printf "  ${GREEN}%s${NC} — %s\n" "$(basename "$d")" "$(preset_title "$(basename "$d")")"
  done
}

cmd_show() {
  local name="${1:?укажи имя пресета}"
  preset_exists "$name" || die "❌ Пресет '${name}' не найден"
  cat "$(preset_dir "$name")/README.md"
  printf "\n  ${CYAN}Вопросы визарда:${NC}\n"
  grep -v '^[[:space:]]*#' "$(preset_dir "$name")/questions" | grep -v '^[[:space:]]*$' || true
}

cmd_apply() {
  local name="$1"
  shift
  preset_exists "$name" || die "❌ Пресет '${name}' не найден"
  local dry_run=false yes=false answers=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --yes) yes=true ;;
      --answers) answers="${2:?}"; shift ;;
      *) die "❌ Неизвестный флаг: $1" ;;
    esac
    shift
  done
  if [ -n "$answers" ]; then
    [ -f "$answers" ] || die "❌ Файл ответов не найден: $answers"
    load_answers "$answers"
  fi
  clear_screen 2>/dev/null || true
  print_header "ПРИМЕНЕНИЕ ПРЕСЕТА: ${name}" "🎛️"
  printf "  %s\n\n" "$(preset_title "$name")"
  collect "$name" ask || return 1
  apply_answers_lists "$(preset_dir "$name")/questions" || return 1
  local rendered
  rendered=$(render_preset "$name") || return 1
  if [ "$dry_run" = true ]; then
    printf "%s\n" "$rendered"
    return 0
  fi
  printf "  ${CYAN}--- Что будет записано в sites.conf: ---${NC}\n"
  if [ -f "$SITES_CONF" ]; then
    diff -u "$SITES_CONF" <(printf "%s\n" "$rendered") || true
  else
    printf "%s\n" "$rendered"
  fi
  printf "\n"
  if [ "$yes" != true ]; then
    printf "  ${CYAN}👉 Применить? [y/N]:${NC} "
    local ans
    read -r ans < "$TTY_IN"
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then log_info "Отмена"; return 0; fi
  fi
  local bd
  bd=$(backup_now "pre-preset-${name}")
  printf "%s\n" "$rendered" > "$SITES_CONF"
  # Оверлей custom/ пресета (с бэкапом затираемых)
  if [ -d "$(preset_dir "$name")/custom" ]; then
    mkdir -p "$bd/custom-prev" "$CUSTOM_DIR"
    local f base
    shopt -s nullglob
    for f in "$(preset_dir "$name")"/custom/*.cfg; do
      base="$(basename "$f")"
      [ -f "${CUSTOM_DIR}/${base}" ] && cp "${CUSTOM_DIR}/${base}" "$bd/custom-prev/"
      cp "$f" "${CUSTOM_DIR}/${base}"
      log_info "  ✓ custom/${base} обновлён"
    done
    shopt -u nullglob
  fi
  log_info "  ✅ sites.conf записан (бэкап: ${bd})"
  if ! generate_configs; then
    log_error "  ❌ Генерация не удалась — sites.conf новый, конфиги старые (см. бэкап)"
    return 1
  fi
  if [ "$yes" != true ]; then
    printf "  ${CYAN}👉 Поднять сервисы сейчас? [y/N]:${NC} "
    local ans2
    read -r ans2 < "$TTY_IN"
    if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
      require_docker
      safe_docker_compose up -d || log_error "  ❌ up завершился с ошибкой"
    fi
  fi
}

cmd_diff() {
  local name="${1:?укажи имя пресета}"
  preset_exists "$name" || die "❌ Пресет '${name}' не найден"
  collect "$name" defaults
  local rendered
  rendered=$(render_preset "$name") || return 1
  if [ -f "$SITES_CONF" ]; then
    diff -u "$SITES_CONF" <(printf "%s\n" "$rendered") || true
  else
    printf "%s\n" "$rendered"
  fi
}

cmd_new() {
  local name="${1:?укажи имя пресета (латиница, без пробелов)}"
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "❌ Имя: только a-z, 0-9, дефис"
  local dir
  dir="$(preset_dir "$name")"
  [ -e "$dir" ] && die "❌ Такой пресет уже есть"
  mkdir -p "$dir/custom"
  cat > "$dir/preset.conf" << 'EOF'
# preset: NAME (сгенерировано preset.sh new)
ACME_EMAIL="{{ACME_EMAIL}}"
WEB_SITES=(
{{SITES_LINES}}
)
REALITY_SITES=(
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_stream=*:443"
  "bind_web=*:8443"
  "blackhole=deny"
)
EOF
  sed -i "s/NAME/$name/" "$dir/preset.conf"
  cat > "$dir/questions" << 'EOF'
# Формат: VAR|промпт|дефолт|валидатор (any|nonempty|domain|port|email, list:domainport)
# derive:VAR=tag DOMVAR PORTVAR — вычислить тег бэкенда (site_домен_порт)
ACME_EMAIL|Email для ACME|mail@example.com|email
SITES_LINES|Сайты: домен и порт||list:domainport
EOF
  cat > "$dir/README.md" << EOF
# $name — описание пресета

Что настраивает, зачем и когда использовать. Допиши руками.
EOF
  log_info "✅ Скелет пресета создан: ${dir}"
}

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "ПРЕСЕТЫ" "🎛️"
    cmd_list
    printf "\n"
    printf "  ${GREEN}a.${NC} Применить пресет\n"
    printf "  ${GREEN}s.${NC} Показать пресет (README + вопросы)\n"
    printf "  ${GREEN}d.${NC} Diff пресета (дефолты vs текущий sites.conf)\n"
    printf "  ${GREEN}n.${NC} Новый пресет (скелет)\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty
    case "$choice" in
      a|A)
        printf "  ${CYAN}👉 Имя пресета:${NC} "
        read -r pname < /dev/tty
        [ -z "$pname" ] && continue
        cmd_apply "$pname"
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      s|S)
        printf "  ${CYAN}👉 Имя пресета:${NC} "
        read -r pname < /dev/tty
        [ -z "$pname" ] && continue
        cmd_show "$pname"
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      d|D)
        printf "  ${CYAN}👉 Имя пресета:${NC} "
        read -r pname < /dev/tty
        [ -z "$pname" ] && continue
        cmd_diff "$pname"
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      n|N)
        printf "  ${CYAN}👉 Имя нового пресета:${NC} "
        read -r pname < /dev/tty
        [ -z "$pname" ] && continue
        cmd_new "$pname"
        printf "\n"
        read -p "[Enter]..." < /dev/tty
        ;;
      0) exit 0 ;;
      *) log_error "❌ Неверный пункт"; sleep 1; continue ;;
    esac
  done
}

case "${1:-}" in
  list) cmd_list ;;
  show) cmd_show "${2:?}" ;;
  apply) cmd_apply "${2:?}" "${@:3}" ;;
  diff) cmd_diff "${2:?}" ;;
  new) cmd_new "${2:?}" ;;
  *) show_menu ;;
esac
