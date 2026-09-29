#!/bin/bash
# Библиотека пресетов (волна 4): готовые сценарии sites.conf v3 + визард.
# presets/<имя>/: preset.conf (шаблон с {{VAR}}), questions (VAR|промпт|дефолт|валидатор),
#   README.md, custom/ (опциональный оверлей в haproxy/custom/).
# Использование: preset.sh list|show <n>|apply <n> [--dry-run] [--yes] [--answers f]|diff <n>|new <n>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

PRESETS_DIR="${PRESETS_DIR_OVERRIDE:-${HAPROXY_DIR}/presets}"
# PRESET_TTY: откуда визард читает ответы (дефолт /dev/tty; тесты подсовывают файл).
# Ввод открывается ОДИН раз на FD: каждое `read < file` переоткрывало бы файл
# с нулевого офсета и визард зацикливался на первой строке. Если открыть
# нечего (неинтерактивный list/show/diff без TTY) — FD остаётся закрыт,
# pread падает обратно на путь (одноразовые чтения там безопасны).
TTY_IN="${PRESET_TTY:-/dev/tty}"
PRESET_FD=-1
# Открытие может упасть (нет /dev/tty в неинтерактивной среде). Сообщение
# об ошибке редиректа exec печатается до применения 2>/dev/null в той же
# строке, поэтому открываем в группе с заранее перенаправленным stderr.
{ exec {PRESET_FD}<"$TTY_IN"; } 2>/dev/null || PRESET_FD=-1

# pread — чтение строки ввода как read, но через общий FD (офсет не сбрасывается).
# Использование: pread -r var [-p prompt]; код возврата как у read (EOF -> 1).
# Последний аргумент считается именем переменной: с него срезается висячий
# \r (вставка из Windows), чтобы CRLF-ввод не отравлял значения и ответы y/n.
pread() {
  local __rc=0
  if [ "$PRESET_FD" -ge 0 ]; then
    read "$@" <&$PRESET_FD || __rc=1
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

declare -A PVALS=()   # собранные значения VAR -> значение
declare -A PGIVEN=()  # предзаполненные из --answers

preset_dir() { printf "%s/%s" "$PRESETS_DIR" "$1"; }
preset_exists() { [ -f "$(preset_dir "$1")/preset.conf" ] && [ -f "$(preset_dir "$1")/questions" ]; }

# Чистое переименование старых пресетов (без алиасов): подсказка вместо молчаливого 404.
preset_renamed_hint() {
  case "$1" in
    reality-selfsteal) printf "stream-vision (WEB_MODE=sites, SELFSTEAL=no/yes)" ;;
    xhttp-path-split) printf "stream-vision (WEB_MODE=xhttp-split)" ;;
    multi-site-l7) printf "web-direct (WEB_MODE=sites)" ;;
    twin-frontends) printf "удален: второе ухо делается через frontend= вручную + merge (см. README)" ;;
    xhttp-selfsteal) printf "stream-vision (WEB_MODE=xhttp-split, SELFSTEAL=yes)" ;;
    *) return 1 ;;
  esac
  return 0
}

preset_require() {
  local name="$1"
  if preset_exists "$name"; then return 0; fi
  local hint
  if hint=$(preset_renamed_hint "$name"); then
    die "❌ Пресет '${name}' переименован/удален → используй: ${hint}"
  fi
  die "❌ Пресет '${name}' не найден"
}

# preset_pick — нумерованный выбор пресета из списка (динамика по PRESETS_DIR).
# Печатает имя в stdout, весь UI — строго в stderr (как ask).
# Возврат 1 = отмена (пусто/0/EOF). Неверный номер — повтор запроса.
preset_pick() {
  local -a names=()
  local d
  for d in "$PRESETS_DIR"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}/preset.conf" ] && [ -f "${d}/questions" ] || continue
    names+=("$(basename "$d")")
  done
  if [ "${#names[@]}" -eq 0 ]; then
    log_error "  ❌ Нет доступных пресетов в ${PRESETS_DIR}"
    return 1
  fi
  local i ans
  for i in "${!names[@]}"; do
    printf "  ${GREEN}%d.${NC} %s — %s\n" "$((i + 1))" "${names[$i]}" "$(preset_title "${names[$i]}")" >&2
  done
  printf "  ${RED}0.${NC} ⬅️  Назад\n" >&2
  printf "\n" >&2
  while true; do
    printf "${CYAN}👉 Номер пресета:${NC} " >&2
    pread -r ans || return 1
    [ -z "$ans" ] && return 1
    [ "$ans" = "0" ] && return 1
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#names[@]}" ]; then
      printf "%s" "${names[$((ans - 1))]}"
      return 0
    fi
    log_error "  ❌ Неверный номер (жди 1-${#names[@]} или 0)"
  done
}

preset_title() {
  local r
  r=$(grep -m1 '^# ' "$(preset_dir "$1")/README.md" 2>/dev/null | sed 's/^# //')
  printf "%s" "${r:-$1}"
}

ask() { # ask VAR "промпт" "дефолт" валидатор -> печатает значение
  # ВАЖНО: вызывается через $(ask ...) — в stdout только значение,
  # все промпты и ошибки строго в stderr, иначе они отравят значение.
  local var="$1" prompt="$2" def="$3" validator="$4"
  local ans
  while true; do
    if [ -n "$def" ]; then
      printf "  ${CYAN}%s [%s]:${NC} " "$prompt" "$def" >&2
    else
      printf "  ${CYAN}%s:${NC} " "$prompt" >&2
    fi
    pread -r ans || return 1
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
        if validate_email "$ans" 2>/dev/null; then printf "%s" "$ans"; return 0; else log_error "  ❌ Введи корректный email"; fi
        ;;
      bind)
        # host:порт (звёздочка-хост для *:443 разрешена).
        if [[ "$ans" =~ ^[^:]+:[0-9]+$ ]] && validate_port "${ans##*:}" "порт" 2>/dev/null; then
          printf "%s" "$ans"; return 0
        else
          log_error "  ❌ Жди host:порт (например, 127.0.0.1:8443 или *:443)"
        fi
        ;;
      snis)
        # Домены через пробел (SNI-список).
        if [ -n "$ans" ]; then
          local _d _ok=true _di
          local -a _snis=()
          read -ra _snis <<< "$ans" || true
          for ((_di = 0; _di < ${#_snis[@]}; _di++)); do
            _d="${_snis[$_di]}"
            validate_domain "$_d" 2>/dev/null || _ok=false
          done
          if [ "$_ok" = true ]; then printf "%s" "$ans"; return 0; fi
        fi
        log_error "  ❌ Жди домены через пробел (например, vpn.example.com)"
        ;;
      hostport)
        # Порт или host:порт (как_backend в web.sh).
        local _to="$ans" _p
        [[ "$_to" != *:* ]] && _to="127.0.0.1:${_to}"
        _p="${_to##*:}"
        if [ -n "${_to%:*}" ] && [ "${_to%:*}" != "$_to" ] && validate_port "$_p" "порт" 2>/dev/null; then
          printf "%s" "$_to"; return 0
        else
          log_error "  ❌ Жди порт или host:порт (например, 8080)"
        fi
        ;;
      path)
        if [[ "$ans" == /* ]]; then
          printf "%s" "$ans"; return 0
        else
          log_error "  ❌ Path должен начинаться с '/' (например, /data/)"
        fi
        ;;
      oneof:*)
        # oneof:a,b,c — значение обязано совпасть с одним из вариантов
        # (запятая, т.к. pipe занят разделителем формата questions).
        local _opts="${validator#oneof:}" _o _match=false _oi
        local _old_ifs="$IFS"
        local -a _optlist=()
        IFS=',' read -ra _optlist <<< "$_opts" || true
        IFS="$_old_ifs"
        for ((_oi = 0; _oi < ${#_optlist[@]}; _oi++)); do
          _o="${_optlist[$_oi]}"
          [ "$ans" = "$_o" ] && _match=true
        done
        if [ "$_match" = true ]; then
          printf "%s" "$ans"; return 0
        else
          log_error "  ❌ Жди одно из: $(echo "$_opts" | tr ',' ' ')"
        fi
        ;;
      *)
        log_error "  ❌ Неизвестный валидатор '${validator}' в questions (пресет битый)"
        return 1
        ;;
    esac
  done
}

# cond_satisfied <условие> — проверка #if/when через PVALS (+PGIVEN как fallback).
# Формат: ATOM[&&ATOM...], ATOM: VAR==val[,val2] | VAR!=val[,val2].
# Возврат 0 = выполнено (и пустое условие), 1 = не выполнено, 2 = битый синтаксис.
cond_satisfied() {
  local cond="$1"
  [ -z "$cond" ] && return 0
  local atom rest="$cond"
  # Разбиваем по && вручную (значения с & не встречаются).
  while [ -n "$rest" ]; do
    if [[ "$rest" == *"&&"* ]]; then
      atom="${rest%%&&*}"
      rest="${rest#*&&}"
    else
      atom="$rest"
      rest=""
    fi
    # trim пробелов
    atom="$(printf "%s" "$atom" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$atom" ] && continue
    local op var want cur
    if [[ "$atom" == *"!="* ]]; then
      op="!="
      var="${atom%%!=*}"
      want="${atom#*!=}"
    elif [[ "$atom" == *"=="* ]]; then
      op="=="
      var="${atom%%==*}"
      want="${atom#*==}"
    elif [[ "$atom" == *"="* ]]; then
      op="=="
      var="${atom%%=*}"
      want="${atom#*=}"
    else
      log_error "  ❌ Битое условие '${atom}' (жди VAR==val / VAR!=val, && — И)" >&2
      return 2
    fi
    var="$(printf "%s" "$var" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf "%s" "$want" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -v PVALS["$var"] ]]; then
      cur="${PVALS[$var]}"
    elif [[ -v PGIVEN["$var"] ]]; then
      cur="${PGIVEN[$var]}"
    else
      cur=""
    fi
    local hit=false o _oi _ifs="$IFS"
    local -a _want=()
    IFS=',' read -ra _want <<< "$want" || true
    IFS="$_ifs"
    for ((_oi = 0; _oi < ${#_want[@]}; _oi++)); do
      o="$(printf "%s" "${_want[$_oi]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ "$cur" = "$o" ] && hit=true
    done
    if [ "$op" = "==" ] && [ "$hit" != true ]; then
      return 1
    fi
    if [ "$op" = "!=" ] && [ "$hit" = true ]; then
      return 1
    fi
  done
  return 0
}

# collect <preset> <mode:ask|defaults> — заполняет PVALS (вопросы + derive).
collect() {
  local name="$1" mode="$2"
  local qfile
  qfile="$(preset_dir "$name")/questions"
  PVALS=()
  local line var prompt def validator when_field extra
  while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}" # терпим CRLF (редактирование под Windows)
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line//[[:space:]]/}" ] && continue
    if [[ "$line" == derive:* ]]; then
      continue # derive — вторым проходом
    fi
    if [[ "$line" == warn:* ]]; then
      continue # warn — третьим проходом
    fi
    IFS='|' read -r var prompt def validator when_field extra <<< "$line"
    if [ -n "${extra:-}" ]; then
      log_error "  ❌ Битая строка questions (лишний '|'): '${line}'"
      return 1
    fi
    local when_cond=""
    if [ -n "${when_field:-}" ]; then
      if [[ "$when_field" != when:* ]]; then
        log_error "  ❌ Битое 5-е поле (жди when:COND): '${line}'"
        return 1
      fi
      when_cond="${when_field#when:}"
    fi
    if [ "$mode" = "defaults" ]; then
      PVALS["$var"]="$def"
      continue
    fi
    # when: условие не выполнено — вопрос пропускаем (ответы из --answers игнорируем с варнингом).
    if [ -n "$when_cond" ]; then
      cond_satisfied "$when_cond"
      local _wcrc=$?
      if [ "$_wcrc" -eq 2 ]; then
        return 1
      fi
      if [ "$_wcrc" -ne 0 ]; then
        if [[ -v PGIVEN["$var"] ]]; then
          log_warn "  ⚠  ${var} в answers проигнорирован (не подходит под ${when_cond})"
        fi
        continue
      fi
    fi
    if [[ -v PGIVEN["$var"] ]]; then
      # Значение из --answers: скаляры подхватит render через PVALS ниже,
      # list-наборы превратит apply_answers_lists. Здесь только скаляры.
      if [[ "$validator" != list:* ]]; then
        case "$validator" in
          any | nonempty) [ -n "${PGIVEN[$var]}" ] || { log_error "  ❌ Пустое ${var} в answers"; return 1; } ;;
          domain) validate_domain "${PGIVEN[$var]}" 2>/dev/null || return 1 ;;
          port) validate_port "${PGIVEN[$var]}" "порт" 2>/dev/null || return 1 ;;
          email) validate_email "${PGIVEN[$var]}" 2>/dev/null || { log_error "  ❌ Битый email в answers"; return 1; } ;;
          bind) [[ "${PGIVEN[$var]}" =~ ^[^:]+:[0-9]+$ ]] && validate_port "${PGIVEN[$var]##*:}" "порт" 2>/dev/null || return 1 ;;
          snis)
            local _d _di
            local -a _snis=()
            read -ra _snis <<< "${PGIVEN[$var]}" || true
            for ((_di = 0; _di < ${#_snis[@]}; _di++)); do
              _d="${_snis[$_di]}"
              validate_domain "$_d" 2>/dev/null || return 1
            done
            [ -n "${PGIVEN[$var]}" ] || return 1
            ;;
          hostport)
            local _hto="${PGIVEN[$var]}"
            [[ "$_hto" != *:* ]] && _hto="127.0.0.1:${_hto}"
            validate_port "${_hto##*:}" "порт" 2>/dev/null || return 1
            PGIVEN["$var"]="$_hto"
            ;;
          path) [[ "${PGIVEN[$var]}" == /* ]] || return 1 ;;
          oneof:*)
            local _opts="${validator#oneof:}" _o _hit=false _sifs="$IFS" _oi
            local -a _optlist=()
            IFS=',' read -ra _optlist <<< "$_opts" || true
            IFS="$_sifs"
            for ((_oi = 0; _oi < ${#_optlist[@]}; _oi++)); do
              _o="${_optlist[$_oi]}"
              [ "${PGIVEN[$var]}" = "$_o" ] && _hit=true
            done
            [ "$_hit" = true ] || { log_error "  ❌ ${var} вне допустимых: $(echo "$_opts" | tr ',' ' ')"; return 1; }
            ;;
          *) log_error "  ❌ Неизвестный валидатор '${validator}'"; return 1 ;;
        esac
        PVALS["$var"]="${PGIVEN[$var]}"
      fi
      continue
    fi
    if [[ "$validator" == list:* ]]; then
      collect_list "$var" "$prompt" "$validator" || return 1
    else
      PVALS["$var"]="$(ask "$var" "$prompt" "$def" "$validator")" || return 1
    fi
  done < "$qfile"
  # Второй проход: derive (tag: VAR=tag DOMVAR PORTVAR; eq: VAR=eq AVAR BVAR -> yes/no;
  # has: VAR=has LISTVAR ITEMVAR -> yes/no, ITEM есть в списке через пробел).
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}" # терпим CRLF
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
      eq)
        local avar bvar
        read -r avar bvar <<< "$dargs"
        if [ "${PVALS[$avar]:-}" = "${PVALS[$bvar]:-}" ] && [ -n "${PVALS[$avar]:-}" ]; then
          PVALS["$dvar"]="yes"
        else
          PVALS["$dvar"]="no"
        fi
        ;;
      has)
        local lvar ivar _h _hi
        read -r lvar ivar <<< "$dargs"
        PVALS["$dvar"]="no"
        local -a _hl=()
        read -ra _hl <<< "${PVALS[$lvar]:-}" || true
        for ((_hi = 0; _hi < ${#_hl[@]}; _hi++)); do
          if [ "${_hl[$_hi]}" = "${PVALS[$ivar]:-}" ] && [ -n "${PVALS[$ivar]:-}" ]; then
            PVALS["$dvar"]="yes"
          fi
        done
        ;;
      *)
        log_error "  ❌ Неизвестный derive '${kind}' (пресет битый)"
        return 1
        ;;
    esac
  done < "$qfile"
  # Третий проход: warn:COND|текст — мягкие проверки после всех значений.
  # Важно: варнинги в stderr, stdout dry-run остается чистым конфигом.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}" # терпим CRLF
    [[ "$line" == warn:* ]] || continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local wspec="${line#warn:}"
    local wcond="${wspec%%|*}"
    local wtext="${wspec#*|}"
    if [ "$wcond" = "$wspec" ]; then
      log_error "  ❌ Битая warn-строка (жди warn:COND|текст): '${line}'"
      return 1
    fi
    # when: внутри warn — условие показа (чтобы не дублировать логику в COND).
    local wwhen=""
    if [[ "$wtext" == *"|when:"* ]]; then
      wwhen="${wtext#*|when:}"
      wtext="${wtext%%|when:*}"
    fi
    if [ -n "$wwhen" ]; then
      cond_satisfied "$wwhen" || continue
      local _wcrc=$?
      [ "$_wcrc" -eq 2 ] && return 1
    fi
    cond_satisfied "$wcond" || continue
    local _ccrc=$?
    [ "$_ccrc" -eq 2 ] && return 1
    log_warn "  ⚠  ${wtext}"
  done < "$qfile"
}

# collect_list: повторяющийся ввод, складывает готовые строки конфига.
# Форматы: domainport -> '  "d:p"' (legacy v1/v2), hostport -> '  "host=d to=127.0.0.1:p"' (v3).
collect_list() {
  local var="$1" prompt="$2" validator="$3"
  local fmt="${validator#list:}"
  local lines=() dom port to
  printf "  ${CYAN}%s (Enter на пустом домене = готово):${NC}\n" "$prompt"
  while true; do
    printf "    ${CYAN}Домен:${NC} "
    pread -r dom || return 1
    [ -z "$dom" ] && break
    if ! validate_domain "$dom" 2>/dev/null; then continue; fi
    # shellcheck disable=SC2086
    if [ "$fmt" = "domainport" ]; then
      printf "    ${CYAN}Порт бэкенда:${NC} "
      pread -r port || return 1
      validate_port "$port" "порт" 2>/dev/null || continue
      lines+=("  \"${dom}:${port}\"")
    elif [ "$fmt" = "hostport" ]; then
      printf "    ${CYAN}Backend (порт или host:порт):${NC} "
      pread -r to || return 1
      [ -z "$to" ] && { log_error "  ❌ Backend не может быть пустым"; continue; }
      [[ "$to" != *:* ]] && to="127.0.0.1:${to}"
      port="${to##*:}"
      validate_port "$port" "порт" 2>/dev/null || continue
      lines+=("  \"host=${dom} to=${to}\"")
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
  # Поддерживает условные блоки в preset.conf:
  #   #if VAR==val[&&VAR2!=val2] ... #else ... #endif (вложенность разрешена).
  # Строки директив в вывод не попадают. {{VAR}} подставляется только
  # в активных ветках, поэтому плейсхолдеры из выключенных веток не требуют ответов.
  local name="$1"
  local key leftovers out=""
  local -a st_cond=() st_else=()
  local line cond active top_cond in_else eff
  local i
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # Директива #if (допустим ведущий пробел).
    if [[ "$line" =~ ^[[:space:]]*#if[[:space:]]+(.+)$ ]]; then
      cond="${BASH_REMATCH[1]}"
      cond="$(printf "%s" "$cond" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      cond_satisfied "$cond"
      local _crc=$?
      if [ "$_crc" -eq 2 ]; then
        return 1
      elif [ "$_crc" -eq 0 ]; then
        st_cond+=(true)
      else
        st_cond+=(false)
      fi
      st_else+=(false)
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*#else[[:space:]]*$ ]]; then
      if [ "${#st_cond[@]}" -eq 0 ]; then
        log_error "  ❌ #else без #if (пресет битый)"
        return 1
      fi
      i=$((${#st_cond[@]} - 1))
      if [ "${st_else[$i]}" = true ]; then
        log_error "  ❌ Двойной #else (пресет битый)"
        return 1
      fi
      st_else[$i]=true
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*#endif[[:space:]]*$ ]]; then
      if [ "${#st_cond[@]}" -eq 0 ]; then
        log_error "  ❌ #endif без #if (пресет битый)"
        return 1
      fi
      unset 'st_cond[-1]' 'st_else[-1]'
      continue
    fi
    # Активна ли строка? AND по стеку с учетом #else.
    active=true
    for ((i = 0; i < ${#st_cond[@]}; i++)); do
      top_cond="${st_cond[$i]}"
      in_else="${st_else[$i]}"
      if [ "$in_else" = true ]; then
        eff=true
        [ "$top_cond" = true ] && eff=false
      else
        eff="$top_cond"
      fi
      if [ "$eff" != true ]; then
        active=false
        break
      fi
    done
    # parent_ok не нужен отдельно: active уже учитывает весь стек.
    if [ "$active" != true ]; then
      continue
    fi
    for key in "${!PVALS[@]}"; do
      line="${line//\{\{$key\}\}/"${PVALS[$key]}"}"
    done
    out+="${line}"$'\n'
  done < "$(preset_dir "$name")/preset.conf"
  if [ "${#st_cond[@]}" -ne 0 ]; then
    log_error "  ❌ Незакрытый #if (нет #endif, пресет битый)"
    return 1
  fi
  leftovers=$(printf "%s" "$out" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' | sort -u || true)
  if [ -n "$leftovers" ]; then
    log_error "  ❌ Незаполненные плейсхолдеры: ${leftovers}"
    return 1
  fi
  printf "%s" "$out"
}

load_answers() { # load_answers <file> — VAR=val построчно (повторы для list: append через \n)
  local f="$1" k v
  PGIVEN=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}" # терпим CRLF
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

# Спец-обработка answers для list-переменных: файл даёт строки "VAR=домен:порт"
# (или "VAR=домен:host:порт"), а collect_list ждёт интерактив. Здесь: если для
# list-VAR есть готовые строки — превращаем их сразу в готовые строки конфига
# ('  "d:p"' для domainport, '  "host=d to=127.0.0.1:p"' для hostport).
apply_answers_lists() {
  local qfile="$1" var fmt when_field extra
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}" # терпим CRLF
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line//[[:space:]]/}" ] && continue
    [[ "$line" == derive:* ]] && continue
    IFS='|' read -r var _ _ fmt when_field extra <<< "$line"
    if [[ "$fmt" == list:* ]] && [[ -v PGIVEN["$var"] ]]; then
      local listfmt="${fmt#list:}"
      local out=() row d p to
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        d="${row%%:*}"
        p="${row##*:}"
        validate_domain "$d" 2>/dev/null || { log_error "  ❌ Битый домен в answers: $d"; return 1; }
        if [ "$listfmt" = "hostport" ] && [[ "$p" == *:* ]]; then
          # Форма "домен:host:порт" — host с двоеточием внутри.
          to="${row#*:}"
          p="${to##*:}"
        else
          to="127.0.0.1:${p}"
        fi
        validate_port "$p" "порт" 2>/dev/null || return 1
        if [ "$listfmt" = "hostport" ]; then
          out+=("  \"host=${d} to=${to}\"")
        else
          out+=("  \"${d}:${p}\"")
        fi
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
  preset_require "$name"
  cat "$(preset_dir "$name")/README.md"
  printf "\n  ${CYAN}Вопросы визарда:${NC}\n"
  grep -v '^[[:space:]]*#' "$(preset_dir "$name")/questions" | grep -v '^[[:space:]]*$' || true
}

# _names_of <kind> <which> — имена фронтендов/ящиков из текущих массивов.
_names_of() {
  local kind="$1" which="$2" entry
  if [ "$which" = frontend ]; then
    if [ "$kind" = stream ]; then local -n arr=STREAM_FRONTENDS; else local -n arr=WEB_FRONTENDS; fi
    for entry in ${arr[@]+"${arr[@]}"}; do
      parse_frontend "$entry" 2>/dev/null || continue
      printf "%s\n" "$F_NAME"
    done
  elif [ "$kind" = stream ]; then
    for entry in ${STREAM_BACKENDS[@]+"${STREAM_BACKENDS[@]}"}; do
      parse_stream_backend "$entry" 2>/dev/null || continue
      printf "%s\n" "$B_NAME"
    done
  else
    for entry in ${WEB_BACKENDS[@]+"${WEB_BACKENDS[@]}"}; do
      parse_web_backend "$entry" 2>/dev/null || continue
      printf "%s\n" "$B_NAME"
    done
  fi
}

# _print_lost <заголовок> <потерянные...> — компактный вывод группы потерь.
_print_lost() {
  local title="$1"
  shift
  [ "$#" -eq 0 ] && return 0
  local shown=0
  printf "  ${YELLOW}• %s:${NC}\n" "$title"
  local item
  for item in "$@"; do
    if [ "$shown" -lt 8 ]; then
      printf "      %s\n" "$item"
    fi
    shown=$((shown + 1))
  done
  if [ "$shown" -gt 8 ]; then
    printf "      … и ещё %d\n" "$((shown - 8))"
  fi
}

# preset_wipes_stream <rendered-file> — новый конфиг сносит ВСЕ SNI-маршруты, а были.
# Возврат 0 = снос (требует отдельного явного подтверждения), 1 = все спокойно.
# Срабатывает ровно в кейсе «stream-vision -> xray-direct поверх»: молча умерли бы
# vision-ветка, таймауты и forwardfor. Проверяются только не-default SNI.
preset_wipes_stream() {
  local rendered="$1"
  [ -f "$SITES_CONF" ] || return 1
  local -a s_sr=(${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"})
  local -a s_wr=(${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"})
  local -a s_bes=(${STREAM_BACKENDS[@]+"${STREAM_BACKENDS[@]}"}) s_bew=(${WEB_BACKENDS[@]+"${WEB_BACKENDS[@]}"})
  local -a s_fes=(${STREAM_FRONTENDS[@]+"${STREAM_FRONTENDS[@]}"}) s_few=(${WEB_FRONTENDS[@]+"${WEB_FRONTENDS[@]}"})
  local -a s_opts=(${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"})
  local s_mail="${ACME_EMAIL:-}"
  local cur_n=0 new_n=0
  STREAM_ROUTES=()
  WEB_ROUTES=()
  STREAM_BACKENDS=()
  WEB_BACKENDS=()
  STREAM_FRONTENDS=()
  WEB_FRONTENDS=()
  GLOBAL_OPTS=()
  if ! source_sites_file "$SITES_CONF" 2>/dev/null; then
    STREAM_ROUTES=(${s_sr[@]+"${s_sr[@]}"})
    return 1
  fi
  local e
  for e in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    parse_stream_route "$e" 2>/dev/null || continue
    [ "$S3_SNI" != "default" ] && cur_n=$((cur_n + 1))
  done
  STREAM_ROUTES=()
  if ! source_sites_file "$rendered" 2>/dev/null; then
    STREAM_ROUTES=(${s_sr[@]+"${s_sr[@]}"})
    WEB_ROUTES=(${s_wr[@]+"${s_wr[@]}"})
    return 1
  fi
  for e in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    parse_stream_route "$e" 2>/dev/null || continue
    [ "$S3_SNI" != "default" ] && new_n=$((new_n + 1))
  done
  STREAM_ROUTES=(${s_sr[@]+"${s_sr[@]}"})
  WEB_ROUTES=(${s_wr[@]+"${s_wr[@]}"})
  STREAM_BACKENDS=(${s_bes[@]+"${s_bes[@]}"})
  WEB_BACKENDS=(${s_bew[@]+"${s_bew[@]}"})
  STREAM_FRONTENDS=(${s_fes[@]+"${s_fes[@]}"})
  WEB_FRONTENDS=(${s_few[@]+"${s_few[@]}"})
  GLOBAL_OPTS=(${s_opts[@]+"${s_opts[@]}"})
  ACME_EMAIL="$s_mail"
  if [ "$cur_n" -gt 0 ] && [ "$new_n" -eq 0 ]; then
    return 0
  fi
  return 1
}

# preset_losses <rendered-file> — что исчезнет из текущего sites.conf при записи.
# Сравнение по именам (фронтенды/ящики) и по полному тексту (маршруты),
# плюс email/глобальные опции целиком. Печатает отчёт.
# Возврат: 0 + отчёт (пустой вывод = потерь нет), 1 = посчитать не удалось
# (тогда вызыватель показывает только diff — молча пропускать потери нельзя).
preset_losses() {
  local rendered="$1"
  [ -f "$SITES_CONF" ] || return 0
  load_sites >/dev/null 2>&1 || return 1
  # Снапшот текущего.
  local -a c_fe_s=() c_fe_w=() c_be_s=() c_be_w=()
  local -a c_sr=() c_wr=()
  local c_mail="${ACME_EMAIL:-}" c_opts=""
  mapfile -t c_fe_s < <(_names_of stream frontend)
  mapfile -t c_fe_w < <(_names_of web frontend)
  mapfile -t c_be_s < <(_names_of stream backend)
  mapfile -t c_be_w < <(_names_of web backend)
  c_sr=(${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"})
  c_wr=(${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"})
  c_opts=$(printf "%s\n" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} | sort)
  # Новое — во временные массивы (текущие не трогаем: сохраняем/восстанавливаем).
  local -a s_fe_s=("${STREAM_FRONTENDS[@]}") s_fe_w=("${WEB_FRONTENDS[@]}")
  local -a s_be_s=("${STREAM_BACKENDS[@]}") s_be_w=("${WEB_BACKENDS[@]}")
  local -a s_sr=("${STREAM_ROUTES[@]}") s_wr=("${WEB_ROUTES[@]}")
  local -a s_opts=(${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"})
  local s_mail="$c_mail"
  STREAM_FRONTENDS=()
  WEB_FRONTENDS=()
  STREAM_BACKENDS=()
  WEB_BACKENDS=()
  STREAM_ROUTES=()
  WEB_ROUTES=()
  GLOBAL_OPTS=()
  # shellcheck disable=SC1090
  if ! source_sites_file "$rendered" 2>/dev/null; then
    STREAM_FRONTENDS=("${s_fe_s[@]}")
    WEB_FRONTENDS=("${s_fe_w[@]}")
    STREAM_BACKENDS=("${s_be_s[@]}")
    WEB_BACKENDS=("${s_be_w[@]}")
    STREAM_ROUTES=("${s_sr[@]}")
    WEB_ROUTES=("${s_wr[@]}")
    GLOBAL_OPTS=("${s_opts[@]}")
    return 1
  fi
  local -a n_fe_s=() n_fe_w=() n_be_s=() n_be_w=()
  mapfile -t n_fe_s < <(_names_of stream frontend)
  mapfile -t n_fe_w < <(_names_of web frontend)
  mapfile -t n_be_s < <(_names_of stream backend)
  mapfile -t n_be_w < <(_names_of web backend)
  local n_opts
  n_opts=$(printf "%s\n" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} | sort)
  local n_mail="$ACME_EMAIL"
  local -a n_sr=("${STREAM_ROUTES[@]}") n_wr=("${WEB_ROUTES[@]}")
  # Восстановление текущего состояния.
  STREAM_FRONTENDS=("${s_fe_s[@]}")
  WEB_FRONTENDS=("${s_fe_w[@]}")
  STREAM_BACKENDS=("${s_be_s[@]}")
  WEB_BACKENDS=("${s_be_w[@]}")
  STREAM_ROUTES=("${s_sr[@]}")
  WEB_ROUTES=("${s_wr[@]}")
  GLOBAL_OPTS=("${s_opts[@]}")
  ACME_EMAIL="$c_mail"
  # Разности: есть сейчас, нет в новом (маршруты — канонически, дефолты равны).
  local -a l_fe_s=() l_fe_w=() l_be_s=() l_be_w=() l_sr=() l_wr=()
  local x y found xc yc
  for x in ${c_fe_s[@]+"${c_fe_s[@]}"}; do
    found=false
    for y in ${n_fe_s[@]+"${n_fe_s[@]}"}; do [ "$x" = "$y" ] && found=true; done
    $found || l_fe_s+=("$x")
  done
  for x in ${c_fe_w[@]+"${c_fe_w[@]}"}; do
    found=false
    for y in ${n_fe_w[@]+"${n_fe_w[@]}"}; do [ "$x" = "$y" ] && found=true; done
    $found || l_fe_w+=("$x")
  done
  for x in ${c_be_s[@]+"${c_be_s[@]}"}; do
    found=false
    for y in ${n_be_s[@]+"${n_be_s[@]}"}; do [ "$x" = "$y" ] && found=true; done
    $found || l_be_s+=("$x")
  done
  for x in ${c_be_w[@]+"${c_be_w[@]}"}; do
    found=false
    for y in ${n_be_w[@]+"${n_be_w[@]}"}; do [ "$x" = "$y" ] && found=true; done
    $found || l_be_w+=("$x")
  done
  # shellcheck disable=SC2030,SC2031
  for x in ${c_sr[@]+"${c_sr[@]}"}; do
    xc=$(_canon_stream_route "$x" 2>/dev/null || true)
    found=false
    for y in ${n_sr[@]+"${n_sr[@]}"}; do
      yc=$(_canon_stream_route "$y" 2>/dev/null || true)
      [ -n "$xc" ] && [ "$xc" = "$yc" ] && found=true
    done
    $found || l_sr+=("$x")
  done
  for x in ${c_wr[@]+"${c_wr[@]}"}; do
    xc=$(_canon_web_route "$x" 2>/dev/null || true)
    found=false
    for y in ${n_wr[@]+"${n_wr[@]}"}; do
      yc=$(_canon_web_route "$y" 2>/dev/null || true)
      [ -n "$xc" ] && [ "$xc" = "$yc" ] && found=true
    done
    $found || l_wr+=("$x")
  done
  # Печать.
  _print_lost "stream-фронтенды" ${l_fe_s[@]+"${l_fe_s[@]}"}
  _print_lost "web-фронтенды" ${l_fe_w[@]+"${l_fe_w[@]}"}
  _print_lost "stream-ящики" ${l_be_s[@]+"${l_be_s[@]}"}
  _print_lost "web-ящики" ${l_be_w[@]+"${l_be_w[@]}"}
  _print_lost "stream-маршруты" ${l_sr[@]+"${l_sr[@]}"}
  _print_lost "web-маршруты" ${l_wr[@]+"${l_wr[@]}"}
  # То же имя, другое содержимое = изменится, а не исчезнет (видно и в diff).
  local -a chg=()
  local cn cc
  for x in ${c_be_s[@]+"${c_be_s[@]}"} ${c_be_w[@]+"${c_be_w[@]}"}; do
    cn=$(parse_stream_backend "$x" 2>/dev/null && printf "%s" "$B_NAME" || parse_web_backend "$x" 2>/dev/null && printf "%s" "$B_NAME" || true)
    [ -n "$cn" ] || continue
    for y in ${n_be_s[@]+"${n_be_s[@]}"} ${n_be_w[@]+"${n_be_w[@]}"}; do
      cc=$(parse_stream_backend "$y" 2>/dev/null && printf "%s" "$B_NAME" || parse_web_backend "$y" 2>/dev/null && printf "%s" "$B_NAME" || true)
      if [ "$cc" = "$cn" ] && [ "$x" != "$y" ]; then
        chg+=("ящик '${cn}': '${x}' → '${y}'")
      fi
    done
  done
  _print_lost "изменится" ${chg[@]+"${chg[@]}"}
  [ "$c_mail" != "$n_mail" ] && printf "  ${YELLOW}• email: '%s' → '%s'${NC}\n" "$c_mail" "$n_mail"
  [ "$c_opts" != "$n_opts" ] && printf "  ${YELLOW}• глобальные опции изменятся${NC}\n"
  return 0
}

# _canon_* — каноническая форма записи для сравнений (дефолты явно,
# порядок ключей фиксирован). Хранимый текст не меняется — канон только
# для diff/merge, чтобы `proxy=off` явно и по умолчанию считались равными.
_canon_stream_route() {
  parse_stream_route "$1" 2>/dev/null || return 1
  printf "sni=%s|to=%s|use=%s|proxy=%s|name=%s|log=%s|frontend=%s" \
    "$S3_SNI" "$S3_TO" "$S3_USE" "$S3_PROXY" "$S3_NAME" "$S3_LOG" "$S3_FRONTEND"
}

_canon_web_route() {
  parse_web_route "$1" 2>/dev/null || return 1
  printf "host=%s|to=%s|use=%s|path=%s|name=%s|log=%s|frontend=%s" \
    "$W3_HOST" "$W3_TO" "$W3_USE" "$W3_PATH" "$W3_NAME" "$W3_LOG" "$W3_FRONTEND"
}

_canon_frontend() {
  parse_frontend "$1" 2>/dev/null || return 1
  printf "name=%s|bind=%s|log=%s" "$F_NAME" "$F_BIND" "$F_LOG"
}

_canon_stream_be() {
  parse_stream_backend "$1" 2>/dev/null || return 1
  printf "name=%s|to=%s|proxy=%s|log=%s" "$B_NAME" "$B_TO" "$B_PROXY" "$B_LOG"
}

_canon_web_be() {
  parse_web_backend "$1" 2>/dev/null || return 1
  printf "name=%s|to=%s|log=%s" "$B_NAME" "$B_TO" "$B_LOG"
}

# _merge_named <kind> <which> <новые...> — слить именованные сущности.
# Одинаковые (канонически) скипаются, same-name-different = ошибка.
_merge_named() {
  local kind="$1" which="$2"
  shift 2
  local cur_arr new_rec
  if [ "$which" = frontend ]; then
    if [ "$kind" = stream ]; then local -n cur=STREAM_FRONTENDS; else local -n cur=WEB_FRONTENDS; fi
  else
    if [ "$kind" = stream ]; then local -n cur=STREAM_BACKENDS; else local -n cur=WEB_BACKENDS; fi
  fi
  for new_rec in "$@"; do
    local nn new_canon dup=false same=false
    if [ "$which" = frontend ]; then
      parse_frontend "$new_rec" || return 1
      nn="$F_NAME"
      new_canon=$(_canon_frontend "$new_rec")
    elif [ "$kind" = "stream" ]; then
      parse_stream_backend "$new_rec" || return 1
      nn="$B_NAME"
      new_canon=$(_canon_stream_be "$new_rec")
    else
      parse_web_backend "$new_rec" || return 1
      nn="$B_NAME"
      new_canon=$(_canon_web_be "$new_rec")
    fi
    local e en ec
    for e in ${cur[@]+"${cur[@]}"}; do
      if [ "$which" = frontend ]; then
        parse_frontend "$e" 2>/dev/null || continue
        en="$F_NAME"
        ec=$(_canon_frontend "$e")
      elif [ "$kind" = "stream" ]; then
        parse_stream_backend "$e" 2>/dev/null || continue
        en="$B_NAME"
        ec=$(_canon_stream_be "$e")
      else
        parse_web_backend "$e" 2>/dev/null || continue
        en="$B_NAME"
        ec=$(_canon_web_be "$e")
      fi
      if [ "$en" = "$nn" ]; then
        dup=true
        [ "$ec" = "$new_canon" ] && same=true
      fi
    done
    if [ "$dup" = true ] && [ "$same" = false ]; then
      log_error "  ❌ Конфликт слияния: ${kind}-${which} '${nn}' уже есть с другим содержимым" >&2
      return 1
    fi
    # shellcheck disable=SC2030,SC2031
    $dup || cur+=("$new_rec")
  done
  return 0
}

# _stream_rkey <запись> / _web_rkey <запись> — ключ маршрута для слияния.
_stream_rkey() {
  parse_stream_route "$1" 2>/dev/null || return 1
  printf "%s|%s" "$S3_SNI" "$S3_FRONTEND"
}

_web_rkey() {
  parse_web_route "$1" 2>/dev/null || return 1
  printf "%s|%s|%s" "$W3_HOST" "$W3_PATH" "$W3_FRONTEND"
}

# preset_merge_rendered <rendered-file> — слить рендер с текущим sites.conf.
# Правила: идентичные записи скипаются; тот же ключ сущности/маршрута
# с другим содержимым = ошибка; email и глобалки остаются текущие (варнинг).
preset_merge_rendered() {
  local rendered="$1"
  load_sites || return 1
  # Новое — во временные массивы.
  local -a n_fe_s=() n_fe_w=() n_be_s=() n_be_w=() n_sr=() n_wr=()
  STREAM_FRONTENDS=()
  WEB_FRONTENDS=()
  STREAM_BACKENDS=()
  WEB_BACKENDS=()
  STREAM_ROUTES=()
  WEB_ROUTES=()
  # shellcheck disable=SC1090
  if ! source_sites_file "$rendered" 2>/dev/null; then
    log_error "  ❌ Не читается рендер пресета" >&2
    return 1
  fi
  n_fe_s=(${STREAM_FRONTENDS[@]+"${STREAM_FRONTENDS[@]}"})
  n_fe_w=(${WEB_FRONTENDS[@]+"${WEB_FRONTENDS[@]}"})
  n_be_s=(${STREAM_BACKENDS[@]+"${STREAM_BACKENDS[@]}"})
  n_be_w=(${WEB_BACKENDS[@]+"${WEB_BACKENDS[@]}"})
  n_sr=(${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"})
  n_wr=(${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"})
  local n_mail="${ACME_EMAIL:-}"
  local n_opts
  n_opts=$(printf "%s\n" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} | sort)
  # Возвращаем текущее из файла (то же, что было; source идемпотентен —
  # файл только что успешно прочитан через load_sites).
  # shellcheck disable=SC1090
  source "$SITES_CONF" >/dev/null 2>&1 || return 1
  legacy_to_v3_arrays 2>/dev/null || true
  # Слияние именованных.
  _merge_named stream frontend ${n_fe_s[@]+"${n_fe_s[@]}"} || return 1
  _merge_named web frontend ${n_fe_w[@]+"${n_fe_w[@]}"} || return 1
  _merge_named stream backend ${n_be_s[@]+"${n_be_s[@]}"} || return 1
  _merge_named web backend ${n_be_w[@]+"${n_be_w[@]}"} || return 1
  # Слияние маршрутов по ключу (каноническое сравнение — дефолты равны).
  local nr key dup same e nk ek ec
  for nr in ${n_sr[@]+"${n_sr[@]}"}; do
    key=$(_stream_rkey "$nr") || return 1
    nk=$(_canon_stream_route "$nr") || return 1
    dup=false
    same=false
    for e in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
      ek=$(_stream_rkey "$e" 2>/dev/null || true)
      [ "$ek" = "$key" ] || continue
      dup=true
      ec=$(_canon_stream_route "$e" 2>/dev/null || true)
      [ "$ec" = "$nk" ] && same=true
    done
    if [ "$dup" = true ] && [ "$same" = false ]; then
      log_error "  ❌ Конфликт слияния: stream-маршрут с ключом '${key}' уже есть с другим содержимым" >&2
      return 1
    fi
    # shellcheck disable=SC2030,SC2031
    $dup || STREAM_ROUTES+=("$nr")
  done
  for nr in ${n_wr[@]+"${n_wr[@]}"}; do
    key=$(_web_rkey "$nr") || return 1
    nk=$(_canon_web_route "$nr") || return 1
    dup=false
    same=false
    for e in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
      ek=$(_web_rkey "$e" 2>/dev/null || true)
      [ "$ek" = "$key" ] || continue
      dup=true
      ec=$(_canon_web_route "$e" 2>/dev/null || true)
      [ "$ec" = "$nk" ] && same=true
    done
    if [ "$dup" = true ] && [ "$same" = false ]; then
      log_error "  ❌ Конфликт слияния: web-маршрут с ключом '${key}' уже есть с другим содержимым" >&2
      return 1
    fi
    # shellcheck disable=SC2030,SC2031
    $dup || WEB_ROUTES+=("$nr")
  done
  if [ "${ACME_EMAIL:-}" != "$n_mail" ]; then
    log_warn "  ⚠  Email пресета (${n_mail}) проигнорирован, оставлен текущий (${ACME_EMAIL:-})"
  fi
  local c_opts
  c_opts=$(printf "%s\n" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} | sort)
  if [ "$c_opts" != "$n_opts" ]; then
    log_warn "  ⚠  Глобальные опции пресета проигнорированы, оставлены текущие"
    # Бинды — отдельно и громко: молчаливое расхождение ушей дает гибрид,
    # который ни один пресет не генерит (например web *:443 vs 127.0.0.1:8443).
    local _bk
    for _bk in bind_stream bind_web; do
      local _cur _new
      _cur=$(cfg_opt "$_bk" "")
      _new=$(printf "%s\n" "$n_opts" | grep -m1 "^${_bk}=" | cut -d= -f2- || true)
      if [ -n "$_cur" ] && [ -n "$_new" ] && [ "$_cur" != "$_new" ]; then
        log_warn "  ⚠  ${_bk}: текущий '${_cur}', у пресета '${_new}' — оставлен текущий"
      fi
    done
  fi
  validate_all || return 1
}

cmd_apply() {
  local name="$1"
  shift
  preset_require "$name"
  local dry_run=false yes=false merge=false answers="" novalidate=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --yes) yes=true ;;
      --merge) merge=true ;;
      --no-validate) novalidate=true ;;
      --answers) answers="${2:?}"; shift ;;
      *) die "❌ Неизвестный флаг: $1 (жди --dry-run/--yes/--merge/--no-validate/--answers файл)" ;;
    esac
    shift
  done
  if [ -n "$answers" ]; then
    [ -f "$answers" ] || die "❌ Файл ответов не найден: $answers"
    load_answers "$answers"
  fi
  # dry-run — машинный режим: только конфиг на stdout, без шапки и clear_screen
  # (вывод редиректится в файлы/pipe и должен сорситься bash без ошибок).
  if [ "$dry_run" != true ]; then
    clear_screen 2>/dev/null || true
    print_header "ПРИМЕНЕНИЕ ПРЕСЕТА: ${name}" "🎛️"
    printf "  %s\n\n" "$(preset_title "$name")"
  fi
  collect "$name" ask || return 1
  apply_answers_lists "$(preset_dir "$name")/questions" || return 1
  local rendered
  rendered=$(render_preset "$name") || return 1
  if [ "$dry_run" = true ]; then
    # Только конфиг, без шапки: вывод можно перенаправлять в файл/pipe.
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
  # Потери: что исчезнет из текущего конфига при затирании.
  local tmp_render losses=""
  tmp_render=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_render'" RETURN
  printf "%s\n" "$rendered" > "$tmp_render"
  local losses="" losses_rc=0 losses_tmp="" mode="overwrite" genflag=""
  if [ "$novalidate" = true ]; then
    genflag="--no-validate"
  fi
  if losses_tmp=$(preset_losses "$tmp_render"); then
    losses="$losses_tmp"
  else
    losses_rc=1
  fi
  if [ "$losses_rc" -ne 0 ]; then
    log_warn "  ⚠  Потери посчитать не удалось — решай по diff выше"
  elif [ -n "$losses" ]; then
    printf "  ${YELLOW}⚠  Применение затрет текущее:${NC}\n"
    printf "%s\n" "$losses"
    printf "\n"
    if [ "$merge" = true ]; then
      mode="merge"
      log_info "  Режим слияния (--merge): общее скипается, конфликты — ошибка"
    elif [ "$yes" = true ]; then
      die "  ❌ Есть потери, а --yes запрещает спрашивать: убери --yes (выбор вручную) или добавь --merge"
    else
      printf "  ${GREEN}1.${NC} Затереть текущее пресетом\n"
      printf "  ${GREEN}2.${NC} Слить с текущим (общее скипается, конфликты — ошибка)\n"
      printf "  ${RED}0.${NC} Отмена\n"
      printf "  ${CYAN}👉 Пункт [0]:${NC} "
      local how
      pread -r how || how=""
      case "$how" in
        1|з|З|z|Z) mode="overwrite" ;;
        2|с|С|s|S) mode="merge" ;;
        *) log_info "Отмена"; return 0 ;;
      esac
    fi
    printf "\n"
  elif [ "$merge" = true ]; then
    mode="merge"
  fi
  if [ "$mode" = "merge" ] && [ "$yes" != true ]; then
    printf "  ${CYAN}👉 Слить пресет с текущим конфигом? [y/N]:${NC} "
    local mconfirm
    pread -r mconfirm || mconfirm=""
    if [ "$mconfirm" != "y" ] && [ "$mconfirm" != "Y" ]; then
      log_info "Отмена"
      return 0
    fi
  fi
  if [ "$mode" = "overwrite" ] && [ "$yes" != true ]; then
    if preset_wipes_stream "$tmp_render"; then
      printf "  ${RED}❌ ВНИМАНИЕ: новый конфиг сносит ВСЕ SNI-маршруты stream (vision-ветка,${NC}\n"
      printf "  ${RED}   таймауты, forwardfor — см. diff выше. Для подтверждения введи ДА:${NC} "
      local wipe
      pread -r wipe || wipe=""
      if [ "$wipe" != "ДА" ]; then log_info "Отмена (живые файлы не тронуты)"; return 0; fi
      printf "\n"
    fi
    # Вопрос валидации — через pread (единый PRESET_FD): ask_validate из menu.sh
    # сидит на другом FD и при файловом вводе читал бы сначала.
    if [ "$novalidate" = true ]; then
      genflag="--no-validate"
    else
      printf "  ${CYAN}👉 Проверить конфиг haproxy -c перед записью? [Y/n]:${NC} "
      local vans
      pread -r vans || vans=""
      if [ "$vans" = "n" ] || [ "$vans" = "N" ]; then
        log_warn "  ⚠  Без проверки: битый конфиг ляжет только на рестарте (crash-loop :443)"
        genflag="--no-validate"
      fi
    fi
    printf "  ${CYAN}👉 Применить? [y/N]:${NC} "
    local ans
    pread -r ans || ans=""
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then log_info "Отмена"; return 0; fi
  fi
  local bd
  bd=$(backup_now "pre-preset-${name}")
  if [ "$mode" = "merge" ]; then
    if ! preset_merge_rendered "$tmp_render"; then
      log_error "  ❌ Слияние не удалось — файл не тронут (см. конфликт выше)"
      return 1
    fi
    save_sites
  else
    printf "%s\n" "$rendered" > "$SITES_CONF"
  fi
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
  # shellcheck disable=SC2086
  if ! generate_configs $genflag; then
    log_error "  ❌ Генерация не удалась — sites.conf новый, конфиги старые (откат: раздел 6 → бэкапы → ${bd##*/})"
    return 1
  fi
  if [ "$yes" != true ]; then
    printf "  ${CYAN}👉 Поднять сервисы сейчас? [y/N]:${NC} "
    local ans2
    pread -r ans2 || ans2=""
    if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
      require_docker
      safe_docker_compose up -d || log_error "  ❌ up завершился с ошибкой"
    fi
  fi
}

cmd_diff() {
  local name="${1:?укажи имя пресета}"
  preset_require "$name"
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
# preset: NAME (сгенерировано preset.sh new, формат v3)
# Управляем только HAProxy. Xray/nginx/static — отдельно, тут только стык (порты/домены/path).
ACME_EMAIL="{{ACME_EMAIL}}"
# Фронтенды (опционально): пусто = один из bind_*. Пример:
# STREAM_FRONTENDS=(
#   "name=public bind=*:443"
#   "name=internal bind=127.0.0.1:4443"
# )
# WEB_FRONTENDS=(
#   "name=main bind=127.0.0.1:8443"
# )
# Ящики (опционально): маршруты ссылаются через use=<имя>. Пример:
# STREAM_BACKENDS=(
#   "name=xray to=127.0.0.1:10443"
# )
# WEB_BACKENDS=(
#   "name=app to=127.0.0.1:8080 log=off"
# )
# Условия: #if VAR==val[&&VAR2!=val2] ... #else ... #endif (вложенность разрешена).
STREAM_ROUTES=(
  "sni=default to=127.0.0.1:8443 proxy=off name=web"
)
WEB_ROUTES=(
{{SITES_LINES}}
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
#if TIMEOUT_PROFILE==xhttp-1h
  "timeout_client=1h"
  "timeout_server=1h"
  "timeout_tunnel=1h"
#else
  "timeout_client=50s"
  "timeout_server=50s"
#endif
  "bind_stream=*:443"
  "bind_web=*:8443"
  "blackhole=deny"
)
EOF
  sed -i "s/NAME/$name/" "$dir/preset.conf"
  cat > "$dir/questions" << 'EOF'
# Формат: VAR|промпт|дефолт|валидатор[|when:COND]
# Валидаторы: any|nonempty|domain|port|email|bind|snis|hostport|path|oneof:a,b|list:domainport|list:hostport
# COND: VAR==val[&&VAR2!=val2], значения через запятую = ИЛИ. Вопрос задается только если условие выполнено.
# derive:VAR=tag DOMVAR PORTVAR | VAR=eq AVAR BVAR | VAR=has LISTVAR ITEMVAR (yes/no).
# warn:COND|текст[|when:COND2] — мягкое предупреждение после всех значений.
ACME_EMAIL|Email для ACME|mail@example.com|email
TIMEOUT_PROFILE|Профиль таймаутов (sites-50s — обычные сайты, xhttp-1h — долгие сессии)|sites-50s|oneof:sites-50s,xhttp-1h
SITES_LINES|Сайты: домен и бэкенд||list:hostport
EOF
  cat > "$dir/README.md" << EOF
# $name — описание пресета

> Управляем только HAProxy. Xray/nginx/static — отдельно, тут только стык (порты/домены/path).

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
    printf "  ${GREEN}1.${NC} Применить пресет\n"
    printf "  ${GREEN}2.${NC} Показать пресет (README + вопросы)\n"
    printf "  ${GREEN}3.${NC} Diff пресета (дефолты vs текущий sites.conf)\n"
    printf "  ${GREEN}4.${NC} Новый пресет (скелет)\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    pread -r choice || exit 0
    case "$choice" in
      1)
        pname="$(preset_pick)" || continue
        cmd_apply "$pname"
        printf "\n"
        menu_pause
        ;;
      2)
        pname="$(preset_pick)" || continue
        cmd_show "$pname"
        printf "\n"
        menu_pause
        ;;
      3)
        pname="$(preset_pick)" || continue
        cmd_diff "$pname"
        printf "\n"
        menu_pause
        ;;
      4)
        printf "  ${CYAN}👉 Имя нового пресета:${NC} "
        pread -r pname || continue
        [ -z "$pname" ] && continue
        cmd_new "$pname"
        printf "\n"
        menu_pause
        ;;
      0) exit 0 ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

case "${1:-}" in
  list) cmd_list ;;
  show) if [ -n "${2:-}" ]; then cmd_show "$2"; else pname="$(preset_pick)" || exit 0; cmd_show "$pname"; fi ;;
  apply) if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then cmd_apply "$2" "${@:3}"; else pname="$(preset_pick)" || exit 0; cmd_apply "$pname" "${@:2}"; fi ;;
  diff) if [ -n "${2:-}" ]; then cmd_diff "$2"; else pname="$(preset_pick)" || exit 0; cmd_diff "$pname"; fi ;;
  new) cmd_new "${2:?}" ;;
  *) show_menu ;;
esac
