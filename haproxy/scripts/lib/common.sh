#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
# Общие утилиты для скриптов HAProxy Manager

# --- ЦВЕТА ---
# Стандарт NO_COLOR (https://no-color.org): непустой NO_COLOR гасит цвета.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
if [ -n "${NO_COLOR:-}" ]; then
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  NC=""
fi

# --- ВВОД (единый для всех меню и визардов) ---
# Источник: PRESET_TTY (визарды пресетов/тесты) -> MENU_TTY (тесты) -> /dev/tty.
# Открывается ОДИН раз на FD: повторные `read < файл` переоткрывали бы файл
# с нулевого офсета, и многошаговые визарды на файловом вводе зацикливались
# или читали сначала. Реальный /dev/tty stateful и так — для интерактива
# поведение не меняется.
TTY_IN="${PRESET_TTY:-${MENU_TTY:-/dev/tty}}"
TTY_FD=-1
# Открытие может упасть (нет /dev/tty в неинтерактивной среде) — молча, чтения
# через tread тогда идут напрямую из TTY_IN как раньше.
{ exec {TTY_FD}<"$TTY_IN"; } 2>/dev/null || TTY_FD=-1

# tread — чтение строки ввода как read, но через общий FD (офсет не сбрасывается).
# Использование: tread -r var [-p prompt]; код возврата как у read (EOF -> 1).
# Последний аргумент считается именем переменной: с него срезается висячий
# \r (вставка из Windows), чтобы CRLF-ввод не отравлял значения и ответы y/n.
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

# --- ПУТИ ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HAPROXY_DIR_OVERRIDE нужен тестам: подменяет корень проекта на временную копию
HAPROXY_DIR="${HAPROXY_DIR_OVERRIDE:-$(cd "${LIB_DIR}/../.." && pwd)}"
SITES_CONF="${HAPROXY_DIR}/sites.conf"
# V2: массивы всегда инициализированы (v1-файлы их не задают — тогда пусто).
WEB_SITES=()
REALITY_SITES=()
GLOBAL_OPTS=()
# V3: нейтральная модель (stream = SNI-маршруты, web = Host-маршруты).
# Ядро не знает слов reality/xray — они живут только в presets/.
STREAM_ROUTES=()
WEB_ROUTES=()
STREAM_FRONTENDS=()
WEB_FRONTENDS=()
STREAM_BACKENDS=()
WEB_BACKENDS=()
# Волна 1: локальное состояние (не в git, см. .gitignore)
BACKUP_DIR="${HAPROXY_DIR}/.backup"
CUSTOM_DIR="${HAPROXY_DIR}/custom"
ENABLED_FILE="${HAPROXY_DIR}/.enabled_services"
BACKUP_KEEP=10

# --- ОЧИСТКА ЭКРАНА ---
# Только 2J (без 3J): скроллбэк терминала сохраняется, ошибки можно проскроллить.
# HAPROXY_NO_CLEAR=1 — вообще не чистить (удобно по SSH и в логах).
clear_screen() {
  if [ -n "${HAPROXY_NO_CLEAR:-}" ]; then
    return 0
  fi
  printf '\033[2J\033[H'
}

# --- ЛОГГЕРЫ ---
# Волна 3: warn/error идут в stderr. Это критично: генераторы пишут stdout
# в файл конфига, и любая диагностика внутри них иначе отравила бы конфиг.
log_info()  { printf "${GREEN}%s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}%s${NC}\n" "$*" >&2; }
log_error() { printf "${RED}%s${NC}\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- ШАПКИ МЕНЮ ---
print_header() {
  local title="$1"
  local icon="${2:-}"
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  if [ -n "$icon" ]; then
    printf "${CYAN}│${NC}  ${icon}  %s\n" "$title"
  else
    printf "${CYAN}│${NC}  %s\n" "$title"
  fi
  printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  printf "\n"
}

print_status_box() {
  local green_on="${GREEN}●${NC}"
  local red_off="${RED}●${NC}"

  # Контейнеры
  local stream_status="$red_off"
  local web_status="$red_off"
  local acme_status="$red_off"
  local containers
  containers=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
  echo "$containers" | grep -q 'haproxy-stream' && stream_status="$green_on" || true
  echo "$containers" | grep -q 'haproxy-web' && web_status="$green_on" || true
  echo "$containers" | grep -q 'acme' && acme_status="$green_on" || true

  # Stream- и web-маршруты (v3; legacy-файлы маппятся на лету)
  local site_count=0
  local reality_count=0
  local fe_stream_count=0
  local fe_web_count=0
  if [ -f "$SITES_CONF" ]; then
    WEB_SITES=()
    REALITY_SITES=()
    STREAM_ROUTES=()
    WEB_ROUTES=()
    STREAM_FRONTENDS=()
    WEB_FRONTENDS=()
    STREAM_BACKENDS=()
    WEB_BACKENDS=()
    GLOBAL_OPTS=()
    # Статус best-effort: битый файл не должен убивать меню.
    source_sites_file "$SITES_CONF" 2>/dev/null || true
    legacy_to_v3_arrays 2>/dev/null || true
    site_count=${#WEB_ROUTES[@]}
    reality_count=${#STREAM_ROUTES[@]}
    fe_stream_count=${#STREAM_FRONTENDS[@]}
    fe_web_count=${#WEB_FRONTENDS[@]}
  fi

  # Сертификаты
  local cert_count=0
  local cert_info=""
  if [ -d "${HAPROXY_DIR}/web/certs" ]; then
    shopt -s nullglob
    for pem in "${HAPROXY_DIR}/web/certs"/*.pem; do
      cert_count=$((cert_count + 1))
      local expiry=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
      if [ -z "$expiry" ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem): не читается${NC}"
        continue
      fi
      local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
      local now_epoch=$(date +%s)
      local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      if [ "$expiry_epoch" -eq 0 ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem): не читается${NC}"
      elif [ $days_left -lt 0 ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem) ПРОСРОЧЕН${NC}"
      elif [ $days_left -lt 30 ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem) истекает через ${days_left}d${NC}"
      fi
    done
    shopt -u nullglob
  fi

  # Рисуем рамку
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│${NC}  Сервисы: %b stream  %b web  %b acme\n" "$stream_status" "$web_status" "$acme_status"
  printf "${CYAN}│${NC}  Профили: ${GREEN}%s${NC}\n" "$(svc_load_enabled)"
  # Волна 4: счётчик кастомных вставок (видно, что генератор подхватит)
  local custom_count=0
  if [ -d "$CUSTOM_DIR" ]; then
    custom_count=$(find "$CUSTOM_DIR" -maxdepth 1 -name '*.cfg' 2>/dev/null | wc -l || true)
  fi
  if [ "$custom_count" -gt 0 ]; then
    printf "${CYAN}│${NC}  Custom:  ${GREEN}%d${NC} файлов\n" "$custom_count"
  fi
  printf "${CYAN}│${NC}  Конфиг:  ${GREEN}%d${NC} stream  ${GREEN}%d${NC} web\n" "$reality_count" "$site_count"
  if [ "$fe_stream_count" -gt 0 ] || [ "$fe_web_count" -gt 0 ]; then
    printf "${CYAN}│${NC}  Фронтенды: ${GREEN}%d${NC} stream  ${GREEN}%d${NC} web\n" "$fe_stream_count" "$fe_web_count"
  fi

  # Статус конфигов HAProxy
  local stream_cfg="${HAPROXY_DIR}/stream/haproxy.cfg"
  local web_cfg="${HAPROXY_DIR}/web/haproxy.cfg"
  if [ -f "$stream_cfg" ] && [ -f "$web_cfg" ]; then
    if [ -f "$SITES_CONF" ]; then
      local sites_time=$(stat -c %Y "$SITES_CONF" 2>/dev/null || echo 0)
      local stream_time=$(stat -c %Y "$stream_cfg" 2>/dev/null || echo 0)
      local web_time=$(stat -c %Y "$web_cfg" 2>/dev/null || echo 0)
      if [ "$sites_time" -gt "$stream_time" ] || [ "$sites_time" -gt "$web_time" ]; then
        printf "${CYAN}│${NC}  HAProxy:  ${YELLOW}устарели${NC}\n"
      else
        printf "${CYAN}│${NC}  HAProxy:  ${GREEN}ок${NC}\n"
      fi
    else
      printf "${CYAN}│${NC}  HAProxy:  ${GREEN}ок${NC}\n"
    fi
  else
    printf "${CYAN}│${NC}  HAProxy:  ${RED}нет конфигов${NC}\n"
  fi

  if [ $cert_count -gt 0 ]; then
    printf "${CYAN}│${NC}  Серты:   ${GREEN}%d${NC}\n" "$cert_count"
  else
    printf "${CYAN}│${NC}  Серты:   ${YELLOW}нет${NC}\n"
  fi
  printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  printf "\n"
}

# Компактный статус секции (как print_status_box, но по одному сервису):
# print_section_status <stream|web> — счётчики маршрутов/фронтендов/бэкендов.
print_section_status() {
  local kind="$1"
  local routes=() frontends=() backends=()
  if [ -f "$SITES_CONF" ]; then
    WEB_SITES=()
    REALITY_SITES=()
    STREAM_ROUTES=()
    WEB_ROUTES=()
    STREAM_FRONTENDS=()
    WEB_FRONTENDS=()
    STREAM_BACKENDS=()
    WEB_BACKENDS=()
    GLOBAL_OPTS=()
    # Статус best-effort: битый файл не должен убивать меню.
    source_sites_file "$SITES_CONF" 2>/dev/null || true
    legacy_to_v3_arrays 2>/dev/null || true
    if [ "$kind" = "stream" ]; then
      routes=(${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"})
      frontends=(${STREAM_FRONTENDS[@]+"${STREAM_FRONTENDS[@]}"})
      backends=(${STREAM_BACKENDS[@]+"${STREAM_BACKENDS[@]}"})
    else
      routes=(${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"})
      frontends=(${WEB_FRONTENDS[@]+"${WEB_FRONTENDS[@]}"})
      backends=(${WEB_BACKENDS[@]+"${WEB_BACKENDS[@]}"})
    fi
  fi
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│${NC}  Маршрутов: ${GREEN}%d${NC}   Фронтендов: ${GREEN}%d${NC}   Бэкендов: ${GREEN}%d${NC}\n" "${#routes[@]}" "${#frontends[@]}" "${#backends[@]}"
  printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  printf "\n"
}

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ -n "$hint" ]; then
      die "❌ $cmd не найден. $hint"
    else
      die "❌ $cmd не найден. Установи: apt install $cmd"
    fi
  fi
}

# --- ВАЛИДАЦИЯ ---
validate_port() {
  local port="$1"
  local name="${2:-порт}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    log_error "❌ Некорректный ${name}: ${port} (допустимо 1-65535)"
    return 1
  fi
}

validate_domain() {
  local domain="$1"
  if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    log_error "❌ Некорректный домен: ${domain}"
    return 1
  fi
}

require_docker() {
  require_cmd docker "Установи: https://docs.docker.com/engine/install/"
  if ! docker info >/dev/null 2>&1; then
    die "❌ Docker daemon не запущен или нет доступа. Запусти: sudo systemctl start docker"
  fi
  require_cmd docker compose "Установи Docker Compose plugin"
}

# Волна 3: проверяет, что TCP-порт свободен (для acme standalone).
# Возврат 0 — свободен (или проверить нечем), 1 — занят.
require_port_free() {
  local port="$1" why="${2:-}"
  if ! command -v ss >/dev/null 2>&1; then
    log_warn "  ⚠  Нет ss — не могу проверить занятость :${port}, продолжаю на свой риск"
    return 0
  fi
  local holder
  holder=$(ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1 || true)
  if [ -n "$holder" ]; then
    log_error "  ❌ Порт :${port} занят: ${holder}"
    [ -n "$why" ] && log_error "  ${why}"
    log_error "  Освободи порт или используй DNS-01 вместо standalone."
    return 1
  fi
  return 0
}

# --- БЕЗОПАСНЫЙ DOCKER COMPOSE (через dc: с профилями включённых сервисов) ---
safe_docker_compose() {
  if ! dc "$@"; then
    log_error "❌ docker compose $* завершился с ошибкой"
    return 1
  fi
}

# --- РАБОТА С sites.conf ---
ensure_sites_conf() {
  if [ -f "$SITES_CONF" ]; then
    return 0
  fi

  clear_screen
  print_header "НАСТРОЙКА HAProxy" "⚙️"
  printf "  ${YELLOW}Файл sites.conf не найден.${NC}\n\n"
  printf "  ${GREEN}1.${NC} Настроить сейчас\n"
  printf "  ${RED}2.${NC} Пропустить\n\n"
  printf "${CYAN}👉 Пункт:${NC} "
  tread -r setup_choice

  if [ "$setup_choice" = "1" ]; then
    interactive_setup
  fi
}

# __ask_validate_inline — вопрос валидации там, где нет ask_validate из menu.sh
# (common.sh не видит menu.sh). Читает /dev/tty как соседи. Возврат 0 = проверять.
__ask_validate_inline() {
  local _a
  printf "  ${CYAN}👉 Проверить конфиг haproxy -c перед записью? [Y/n]:${NC} "
  tread -r _a || _a=""
  if [ "$_a" = "n" ] || [ "$_a" = "N" ]; then
    log_warn "  ⚠  Без проверки: битый конфиг ляжет только на рестарте (crash-loop :443)"
    return 1
  fi
  return 0
}

ensure_configs() {
  local stream_cfg="${HAPROXY_DIR}/stream/haproxy.cfg"
  local web_cfg="${HAPROXY_DIR}/web/haproxy.cfg"

  # Если конфигов нет — генерируем
  if [ ! -f "$stream_cfg" ] || [ ! -f "$web_cfg" ]; then
    printf "  ${YELLOW}⚠  Конфиги HAProxy не найдены.${NC}\n"
    printf "  ${GREEN}1.${NC} Сгенерировать\n"
    printf "  ${GREEN}3.${NC} Только показать diff (без записи)\n"
    printf "  ${RED}2.${NC} Пропустить\n\n"
    printf "${CYAN}👉 Пункт:${NC} "
    tread -r gen_choice || gen_choice=""
    if [ "$gen_choice" = "1" ]; then
      if __ask_validate_inline; then
        generate_configs
      else
        generate_configs --no-validate
      fi
    elif [ "$gen_choice" = "3" ]; then
      preview_configs || true
    fi
    return
  fi

  # Если конфиги есть — проверяем дату
  if [ -f "$SITES_CONF" ]; then
    local sites_time=$(stat -c %Y "$SITES_CONF" 2>/dev/null || echo 0)
    local stream_time=$(stat -c %Y "$stream_cfg" 2>/dev/null || echo 0)
    local web_time=$(stat -c %Y "$web_cfg" 2>/dev/null || echo 0)

    if [ "$sites_time" -gt "$stream_time" ] || [ "$sites_time" -gt "$web_time" ]; then
      printf "  ${YELLOW}⚠  sites.conf новее конфигов HAProxy.${NC}\n"
      printf "  ${GREEN}1.${NC} Перегенерировать\n"
      printf "  ${GREEN}3.${NC} Только показать diff (без записи)\n"
      printf "  ${RED}2.${NC} Пропустить\n\n"
      printf "${CYAN}👉 Пункт:${NC} "
      tread -r regen_choice || regen_choice=""
      if [ "$regen_choice" = "1" ]; then
        if __ask_validate_inline; then
          generate_configs
        else
          generate_configs --no-validate
        fi
      elif [ "$regen_choice" = "3" ]; then
        preview_configs || true
      fi
    fi
  fi
}

interactive_setup() {
  clear_screen
  print_header "НАСТРОЙКА HAProxy" "⚙️"
  printf "  ${YELLOW}Файл sites.conf не найден. Создадим его.${NC}\n\n"

  # Email
  while true; do
    printf "  ${CYAN}📧 Email для сертификатов:${NC} "
    tread -r acme_email
    if validate_email "$acme_email" 2>/dev/null; then
      break
    fi
    printf "  ${RED}   ✗ Введи корректный email латиницей (например, user@example.com)${NC}\n"
  done

  # Stream-маршруты (нейтрально: SNI -> backend, без xray-специфики)
  printf "\n  ${CYAN}🔀 Stream-маршруты (SNI -> backend)${NC}\n"
  printf "  ${CYAN}   SNI через пробел (Enter = пропустить):${NC} "
  tread -r stream_sni

  local stream_to="" stream_name="sni-1"
  if [ -n "$stream_sni" ]; then
    local _d bad_sni=false
    local -a _sni_toks=()
    read -ra _sni_toks <<< "$stream_sni" || true
    local _di
    for ((_di = 0; _di < ${#_sni_toks[@]}; _di++)); do
      _d="${_sni_toks[$_di]}"
      if ! validate_domain "$_d" 2>/dev/null; then
        log_error "  ❌ Битый SNI '${_d}' — пропускаю stream-секцию, маршруты добавишь в меню"
        bad_sni=true
        break
      fi
    done
    $bad_sni && stream_sni=""
  fi
  if [ -n "$stream_sni" ]; then
    while true; do
      printf "  ${CYAN}   Backend host:порт [127.0.0.1:10443]:${NC} "
      tread -r stream_to
      [ -z "$stream_to" ] && stream_to="127.0.0.1:10443"
      local _h="${stream_to%:*}"
      local _p="${stream_to##*:}"
      if [ -n "$_h" ] && [ "$_h" != "$stream_to" ] && validate_port "$_p" "порт бэкенда" 2>/dev/null; then
        break
      fi
      printf "  ${RED}   ✗ Жди host:порт (например, 127.0.0.1:10443)${NC}\n"
    done
  fi

  # Web-маршруты
  printf "\n  ${CYAN}🌐 Web-маршруты (Host -> backend)${NC}\n"
  local web_routes=()
  while true; do
    printf "  ${CYAN}   Домен (Enter = готово):${NC} "
    tread -r domain
    [ -z "$domain" ] && break

    if ! validate_domain "$domain" 2>/dev/null; then
      continue
    fi

    while true; do
      printf "  ${CYAN}   Backend host:порт:${NC} "
      tread -r port
      if [ -z "$port" ]; then
        printf "  ${RED}   ✗ Backend обязателен${NC}\n"
        continue
      fi
      # Принимаем "порт" или "host:порт".
      local _to="$port"
      [[ "$_to" != *:* ]] && _to="127.0.0.1:${_to}"
      local _h="${_to%:*}"
      local _p="${_to##*:}"
      if [ -n "$_h" ] && [ "$_h" != "$_to" ] && validate_port "$_p" "порт бэкенда" 2>/dev/null; then
        port="$_to"
        break
      fi
      printf "  ${RED}   ✗ Жди порт или host:порт${NC}\n"
    done

    web_routes+=("host=${domain} to=${port}")
    printf "  ${GREEN}   ✓ %s → %s${NC}\n" "$domain" "$port"
  done

  # Сохраняем (v3)
  ACME_EMAIL="${acme_email}"
  STREAM_ROUTES=()
  [ -n "$stream_sni" ] && STREAM_ROUTES+=("sni=${stream_sni} to=${stream_to} proxy=off name=${stream_name}")
  STREAM_ROUTES+=("sni=default to=127.0.0.1:8443 proxy=off name=web")
  WEB_ROUTES=("${web_routes[@]+"${web_routes[@]}"}")
  GLOBAL_OPTS=(
    "timeout_connect=5s"
    "timeout_client=50s"
    "timeout_server=50s"
    "bind_stream=*:443"
    "bind_web=*:8443"
    "blackhole=deny"
  )
  save_sites

  printf "\n"
  log_info "  ✓ sites.conf создан (v3)"

  # Генерируем конфиги если есть данные
  if [ "${#WEB_ROUTES[@]}" -gt 0 ] || [ -n "$stream_sni" ]; then
    if __ask_validate_inline; then
      generate_configs
    else
      generate_configs --no-validate
    fi
  fi

  log_warn "  ⚠  Проверь: ${CYAN}${SITES_CONF}${NC}"
  printf "\n"
  tread -p "[Enter] для продолжения..." _tread_pause
}

# legacy_to_v3_arrays — in-memory миграция v1/v2 -> v3 после source файла.
# Если legacy-массивы непусты, а v3 пусты — заполняет STREAM_ROUTES/WEB_ROUTES
# (файл не трогает; запись в новом формате произойдет при ближайшем save).
legacy_to_v3_arrays() {
  if [ "${#STREAM_ROUTES[@]}" -gt 0 ] || [ "${#WEB_ROUTES[@]}" -gt 0 ]; then
    return 0
  fi
  if [ "${#WEB_SITES[@]}" -eq 0 ] && [ "${#REALITY_SITES[@]}" -eq 0 ]; then
    return 0
  fi
  local entry i=1
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    parse_entry "$entry" || return 1
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Битая запись REALITY_SITES: '${entry}'" >&2
      return 1
    fi
    local _d
    local -a _dom_toks=()
    read -ra _dom_toks <<< "$ENTRY_DOMAINS" || true
    local _di
    for ((_di = 0; _di < ${#_dom_toks[@]}; _di++)); do
      _d="${_dom_toks[$_di]}"
      validate_domain "$_d" >&2 || return 1
    done
    validate_port "$ENTRY_PORT" "порт" >&2 || return 1
    local proxy
    # shellcheck disable=SC2086
    proxy="$(opt_value proxy off ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    STREAM_ROUTES+=("sni=${ENTRY_DOMAINS} to=127.0.0.1:${ENTRY_PORT} proxy=${proxy} name=sni-${i}")
    i=$((i + 1))
  done
  # Явный default из bind_web (GLOBAL_OPTS) или дефолта *:8443.
  local bind_web="*:8443"
  local g
  for g in ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"}; do
    [[ "$g" == bind_web=* ]] && bind_web="${g#bind_web=}"
  done
  local web_port="${bind_web##*:}"
  [[ "$web_port" =~ ^[0-9]+$ ]] || web_port="8443"
  STREAM_ROUTES+=("sni=default to=127.0.0.1:${web_port} proxy=off name=web")
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    parse_entry "$entry" || return 1
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Битая запись WEB_SITES: '${entry}'" >&2
      return 1
    fi
    validate_domain "$ENTRY_DOMAINS" >&2 || return 1
    validate_port "$ENTRY_PORT" "порт" >&2 || return 1
    local epath
    # shellcheck disable=SC2086
    epath="$(opt_value path "" ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    if [ -n "$epath" ]; then
      WEB_ROUTES+=("host=${ENTRY_DOMAINS} to=127.0.0.1:${ENTRY_PORT} path=${epath}")
    else
      WEB_ROUTES+=("host=${ENTRY_DOMAINS} to=127.0.0.1:${ENTRY_PORT}")
    fi
  done
}

# ensure_stream_default — дописать sni=default если его нет (fail-closed генератору нужен).
ensure_stream_default() {
  local entry
  for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    parse_stream_route "$entry" 2>/dev/null || continue
    [ "$S3_SNI" = "default" ] && return 0
  done
  STREAM_ROUTES+=("sni=default to=127.0.0.1:8443 proxy=off name=web")
  log_info "  ✓ Добавлен stream-маршрут по умолчанию (sni=default → 127.0.0.1:8443)"
}

load_sites() {
  ensure_sites_conf
  WEB_SITES=()
  REALITY_SITES=()
  GLOBAL_OPTS=()
  STREAM_ROUTES=()
  WEB_ROUTES=()
  STREAM_FRONTENDS=()
  WEB_FRONTENDS=()
  STREAM_BACKENDS=()
  WEB_BACKENDS=()
  if ! source_sites_file "$SITES_CONF"; then
    die "❌ Ошибка чтения ${SITES_CONF}. Проверь синтаксис файла."
  fi
  legacy_to_v3_arrays || die "❌ Битые legacy-массивы в ${SITES_CONF}."
}

# source_sites_file <файл> — source конфига с защитой служебного окружения.
# sites.conf исполняется как bash: кривой файл не должен уводить HAPROXY_DIR /
# BACKUP_DIR (rm -rf!), PATH / IFS, основание ротации и переопределять функции.
# Данные (массивы маршрутов, ACME_EMAIL) остаются из файла.
source_sites_file() {
  local _f="$1"
  local _hap="${HAPROXY_DIR:-}" _sites="${SITES_CONF:-}" _bak="${BACKUP_DIR:-}"
  local _keep="${BACKUP_KEEP:-10}" _custom="${CUSTOM_DIR:-}" _en="${ENABLED_FILE:-}"
  local _lib="${LIB_DIR:-}" _svc="${SVC_ALL:-}" _path="$PATH" _ifs="$IFS"
  local _fns_before _fns_after
  _fns_before=$(declare -F | awk '{print $NF}')
  local _rc=0
  source "$_f" 2>/dev/null || _rc=1
  _fns_after=$(declare -F | awk '{print $NF}')
  # Служебное — назад безусловно (и при успехе, и при ошибке).
  HAPROXY_DIR="$_hap"
  SITES_CONF="$_sites"
  BACKUP_DIR="$_bak"
  BACKUP_KEEP="$_keep"
  CUSTOM_DIR="$_custom"
  ENABLED_FILE="$_en"
  LIB_DIR="$_lib"
  SVC_ALL="$_svc"
  PATH="$_path"
  IFS="$_ifs"
  # Чужие функции из конфига — выкинуть (имена функций — идентификаторы, glob нет).
  local _fn _known
  for _fn in $_fns_after; do
    _known=false
    local _b
    for _b in $_fns_before; do
      [ "$_b" = "$_fn" ] && _known=true
    done
    if [ "$_known" = false ]; then
      unset -f "$_fn" 2>/dev/null || true
    fi
  done
  return "$_rc"
}

save_sites() {
  # Волна 1: бэкап перед перезаписью sites.conf. Пишем только v3.
  [ -f "$SITES_CONF" ] && backup_now "pre-save" >/dev/null
  cat > "$SITES_CONF" << EOF
# HAProxy конфигурация (v3)
# Генерируется скриптами, можно редактировать вручную

ACME_EMAIL="${ACME_EMAIL:-}"

# Stream-фронтенды (L4 уши). Пусто = один фронтенд из bind_stream.
# формат: "name=<метка> bind=<host:порт>[ log=on|off]"
STREAM_FRONTENDS=(
$(if [ "${#STREAM_FRONTENDS[@]}" -gt 0 ]; then printf '  "%s"\n' "${STREAM_FRONTENDS[@]}"; fi)
)

# Web-фронтенды (L7 уши). Пусто = один фронтенд из bind_web.
# формат: "name=<метка> bind=<host:порт>[ log=on|off]"
WEB_FRONTENDS=(
$(if [ "${#WEB_FRONTENDS[@]}" -gt 0 ]; then printf '  "%s"\n' "${WEB_FRONTENDS[@]}"; fi)
)

# Stream-бэкенды (L4 ящики). Маршруты ссылаются через use=<имя>.
# формат: "name=<метка> to=<host:порт>[ proxy=off|v1|v2][ log=on|off]"
STREAM_BACKENDS=(
$(if [ "${#STREAM_BACKENDS[@]}" -gt 0 ]; then printf '  "%s"\n' "${STREAM_BACKENDS[@]}"; fi)
)

# Web-бэкенды (L7 ящики). Маршруты ссылаются через use=<имя>.
# формат: "name=<метка> to=<host:порт>[ log=on|off]"
WEB_BACKENDS=(
$(if [ "${#WEB_BACKENDS[@]}" -gt 0 ]; then printf '  "%s"\n' "${WEB_BACKENDS[@]}"; fi)
)

# Stream-маршруты (L4, SNI -> backend). Одна запись sni=default обязательна.
# формат: "sni=<домены|default> to=<host:порт>[ proxy=off|v1|v2][ name=<метка>][ log=on|off][ frontend=<имя>]"
STREAM_ROUTES=(
$(if [ "${#STREAM_ROUTES[@]}" -gt 0 ]; then printf '  "%s"\n' "${STREAM_ROUTES[@]}"; fi)
)

# Web-маршруты (L7, Host -> backend за терминацией).
# формат: "host=<домен> to=<host:порт>[ path=/prefix][ name=<метка>][ log=on|off][ frontend=<имя>]"
WEB_ROUTES=(
$(if [ "${#WEB_ROUTES[@]}" -gt 0 ]; then printf '  "%s"\n' "${WEB_ROUTES[@]}"; fi)
)
EOF
  # Глобальные опции — пишем только если заданы
  if [ "${#GLOBAL_OPTS[@]}" -gt 0 ]; then
    {
      echo ""
      echo "# Глобальные опции"
      echo "GLOBAL_OPTS=("
      printf '  "%s"\n' "${GLOBAL_OPTS[@]}"
      echo ")"
    } >> "$SITES_CONF"
  fi
}

# validate_all — сухая проверка всего конфига в памяти (без записи файлов).
# Те же проверки, что при генерации: parity + оба генератора в /dev/null.
# Вызывать в командах ДО save_sites, чтобы не пачкать файл битыми данными
# (откат всё равно есть через pre-save бэкап, но лучше не пачкать).
validate_all() {
  check_proxy_parity || return 1
  generate_stream_config >/dev/null || return 1
  generate_web_config >/dev/null || return 1
}

# --- CUSTOM-ВСТАВКИ (волна 1: переживают перегенерацию) ---
# Выводит содержимое custom/<pattern> с заголовками. Нет директории — молча ничего.
emit_custom() {
  local pattern="$1"
  [ -d "$CUSTOM_DIR" ] || return 0
  shopt -s nullglob
  local f
  for f in "$CUSTOM_DIR"/$pattern; do
    printf "\n    # --- custom: %s ---\n" "$(basename "$f")"
    cat "$f"
  done
  shopt -u nullglob
}

# --- БЭКАПЫ (волна 1) ---
backup_now() {
  local reason="${1:-manual}"
  local ts
  ts=$(date '+%Y%m%d-%H%M%S')
  local dest="${BACKUP_DIR}/${ts}-${reason}"
  mkdir -p "$dest"
  [ -f "$SITES_CONF" ] && cp "$SITES_CONF" "$dest/sites.conf"
  [ -f "${HAPROXY_DIR}/stream/haproxy.cfg" ] && cp "${HAPROXY_DIR}/stream/haproxy.cfg" "$dest/stream.cfg"
  [ -f "${HAPROXY_DIR}/web/haproxy.cfg" ] && cp "${HAPROXY_DIR}/web/haproxy.cfg" "$dest/web.cfg"
  # Ротация: держим последние BACKUP_KEEP
  local old
  old=$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort | head -n -"$BACKUP_KEEP" || true)
  if [ -n "$old" ]; then
    echo "$old" | while read -r d; do rm -rf "${BACKUP_DIR:?}/$d"; done
  fi
  printf "%s" "$dest"
}

list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r
}

rollback_backup() {
  local name="$1"
  local src="${BACKUP_DIR}/${name}"
  [ -d "$src" ] || { log_error "❌ Бэкап ${name} не найден"; return 1; }
  backup_now "pre-rollback" >/dev/null
  [ -f "$src/sites.conf" ] && cp "$src/sites.conf" "$SITES_CONF"
  [ -f "$src/stream.cfg" ] && cp "$src/stream.cfg" "${HAPROXY_DIR}/stream/haproxy.cfg"
  [ -f "$src/web.cfg" ] && cp "$src/web.cfg" "${HAPROXY_DIR}/web/haproxy.cfg"
  log_info "✅ Откат к ${name} выполнен (предыдущее состояние — в свежем бэкапе pre-rollback)"
  log_warn "  ⚠  Проверь откаченные конфиги (раздел 6 → проверка): валидацию при откате не делаем"
}

# --- ВАЛИДАЦИЯ КОНФИГОВ (волна 1) ---
# Проверяет haproxy-конфиг. Возврат: 0 ок, 1 битый конфиг / нечем проверить.
# Fail-closed: непроверенный конфиг НЕ пишется в прод — битый cfg + restart: always
# = crash-loop :443, а не «старый конфиг продолжает работать».
# Проверяется только СИНТАКСИС тем же билдом, что в проде. Запущенные сервисы
# НЕ требуются: порядок — локальный бинарник, exec в запущенный контейнер,
# одноразовый `compose run` из образа (сервисы могут стоять). Обход только явный:
# HAPROXY_NO_VALIDATE=1 (тесты/CI).
validate_cfg() {
  local file="$1" want="${2:-}"
  if [ -z "$want" ]; then
    case "$file" in
      */stream/*) want="haproxy-stream" ;;
      */web/*) want="haproxy-web" ;;
    esac
  fi
  if command -v haproxy >/dev/null 2>&1; then
    if haproxy -c -V -f "$file" >/dev/null 2>&1; then
      return 0
    fi
    log_error "  ❌ Битый конфиг: ${file}"
    haproxy -c -V -f "$file" 2>&1 | head -20 || true
    return 1
  fi
  # Бинарника нет — пробуем docker. Сервисы при этом крутиться НЕ обязаны.
  local _have_docker=false _daemon_ok=false
  if command -v docker >/dev/null 2>&1; then
    _have_docker=true
    docker info >/dev/null 2>&1 && _daemon_ok=true
  fi
  if [ "$_daemon_ok" != true ]; then
    if [ "$_have_docker" = true ]; then
      log_error "  ❌ Нечем проверить ${file}: docker стоит, но демон недоступен (не запущен Docker?)."
    else
      log_error "  ❌ Нечем проверить ${file}: нет ни бинарника haproxy, ни docker."
      log_error "     Поставь haproxy локально либо docker с образом haproxy (compose pull)."
    fi
    _validate_bypass "$file" && return 0
    return 1
  fi
  # Быстрый путь: запущенный контейнер (та же версия, что в проде).
    if [ -z "$want" ]; then
      case "$file" in
        */stream/*) want="haproxy-stream" ;;
        */web/*) want="haproxy-web" ;;
      esac
    fi
    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    local cname=""
    if [ -n "$want" ] && echo "$running" | grep -qx "$want"; then
      cname="$want"
    else
      # Подойдет любой запущенный haproxy-* (версия та же, проверяется только синтаксис).
      cname=$(printf "%s\n" "$running" | grep -m1 '^haproxy-' || true)
    fi
    if [ -n "$cname" ]; then
      local remote="/tmp/haproxy-validate.cfg"
      if docker cp "$file" "${cname}:${remote}" >/dev/null 2>&1 \
        && docker exec "$cname" haproxy -c -V -f "$remote" >/dev/null 2>&1; then
        docker exec "$cname" rm -f "$remote" >/dev/null 2>&1 || true
        return 0
      fi
      docker exec "$cname" rm -f "$remote" >/dev/null 2>&1 || true
      log_error "  ❌ Битый конфиг: ${file} (проверено в ${cname})"
      docker cp "$file" "${cname}:${remote}" >/dev/null 2>&1 \
        && docker exec "$cname" haproxy -c -V -f "$remote" 2>&1 | head -20 || true
      docker exec "$cname" rm -f "$remote" >/dev/null 2>&1 || true
      return 1
    fi
    # Демон есть, запущенных haproxy-* нет — одноразовый compose run из образа
    # (сервисы могут стоять; ничего навсегда не запускает, --rm убирает за собой).
    if [ -f "${HAPROXY_DIR}/compose.yml" ] && [ -n "$want" ]; then
      # -v требует абсолютный хост-путь.
      local abs="$file"
      if [[ "$abs" != /* ]]; then
        if command -v realpath >/dev/null 2>&1; then
          abs="$(realpath -m "$abs" 2>/dev/null || printf "%s" "$abs")"
        else
          abs="$(pwd)/${abs#./}"
        fi
      fi
      local out rc=0
      out=$(cd "$HAPROXY_DIR" && docker compose -f compose.yml run --rm --no-deps -T \
        -v "${abs}:/tmp/haproxy-validate.cfg:ro" \
        --entrypoint haproxy "$want" -c -V -f /tmp/haproxy-validate.cfg 2>&1) || rc=$?
      if [ "$rc" -eq 0 ]; then
        return 0
      fi
      if echo "$out" | grep -qiE 'no such image|not found|pull access|unable to find image'; then
        log_error "  ❌ Нечем проверить ${file}: нет образа haproxy (подтяни: docker compose pull)."
      else
        log_error "  ❌ Битый конфиг: ${file} (проверено одноразовым контейнером ${want})"
        printf "%s\n" "$out" | head -20 || true
      fi
      return 1
    fi
    log_error "  ❌ Нечем проверить ${file}: демон на месте, но ни запущенных haproxy-контейнеров, ни compose.yml для одноразовой проверки."
    _validate_bypass "$file" && return 0
    return 1
}

# _validate_bypass <файл> — явный обход fail-closed. Возврат 0 если разрешен.
_validate_bypass() {
  local file="$1"
  if [ -n "${HAPROXY_NO_VALIDATE:-}" ]; then
    log_warn "  ⚠  HAPROXY_NO_VALIDATE=1 — пропускаю валидацию ${file} на свой риск"
    return 0
  fi
  log_error "  ❌ Генерация остановлена (fail-closed). Обход только явный: HAPROXY_NO_VALIDATE=1"
  return 1
}

# validate_duration <значение> <имя> — формат таймаута haproxy (число + us/ms/s/m/h/d).
validate_duration() {
  local val="$1" name="${2:-таймаут}"
  if [[ "$val" =~ ^[0-9]+(us|ms|s|m|h|d)$ ]]; then
    return 0
  fi
  log_error "  ❌ Некорректный ${name}: '${val}' (жди число+единицу: us/ms/s/m/h/d)" >&2
  return 1
}

# validate_host <хост> <имя> — хост из to=/bind= (без пробелов/пустоты; '*' только для bind).
validate_host() {
  local host="$1" name="${2:-хост}"
  if [ -z "$host" ]; then
    log_error "  ❌ Пустой ${name}" >&2
    return 1
  fi
  if [[ "$host" =~ [[:space:]] ]]; then
    log_error "  ❌ Пробел в ${name}: '${host}'" >&2
    return 1
  fi
  return 0
}

# validate_email <мыло> — строгий формат (только латиница/цифры, иначе ACME
# молча примет битый контакт вроде кириллицы).
validate_email() {
  local mail="$1"
  if [[ "$mail" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    return 0
  fi
  log_error "  ❌ Некорректный email: '${mail}' (жди user@example.com латиницей)" >&2
  return 1
}

# --- СЕРВИСЫ: профили compose (волна 1) ---
# Включённый набор хранится в .enabled_services (по умолчанию все три).
SVC_ALL="stream web acme"

svc_load_enabled() {
  if [ -f "$ENABLED_FILE" ]; then
    cat "$ENABLED_FILE"
  else
    printf "%s" "$SVC_ALL"
  fi
}

svc_is_enabled() {
  local svc="$1"
  local enabled
  enabled=$(svc_load_enabled)
  # shellcheck disable=SC2086
  for s in $enabled; do
    [ "$s" = "$svc" ] && return 0
  done
  return 1
}

svc_enable() {
  local svc="$1"
  local enabled
  enabled=$(svc_load_enabled)
  if svc_is_enabled "$svc"; then return 0; fi
  printf "%s %s" "$enabled" "$svc" | xargs -r > "$ENABLED_FILE"
}

svc_disable() {
  local svc="$1"
  local out=""
  local enabled
  enabled=$(svc_load_enabled)
  # shellcheck disable=SC2086
  for s in $enabled; do
    [ "$s" = "$svc" ] || out="${out} ${s}"
  done
  printf "%s" "$out" | xargs -r > "$ENABLED_FILE"
}

svc_container() {
  case "$1" in
    stream) printf "haproxy-stream" ;;
    web) printf "haproxy-web" ;;
    acme) printf "acme" ;;
    *) return 1 ;;
  esac
}

svc_running() {
  local cname
  cname=$(svc_container "$1") || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}\$" || return 1
}

# dc: docker compose с профилями включённых сервисов.
# Использование: dc up -d / dc restart / dc logs ... (как docker compose, но с профилями)
dc() {
  local profiles=()
  local enabled
  enabled=$(svc_load_enabled)
  # shellcheck disable=SC2086
  for s in $enabled; do
    case "$s" in
      stream|web|acme) profiles+=(--profile "$s") ;;
      *) log_warn "  ⚠  Неизвестный сервис в .enabled_services: $s (игнорирую)" ;;
    esac
  done
  cd "$HAPROXY_DIR" || die "❌ Не удалось перейти в ${HAPROXY_DIR}"
  # shellcheck disable=SC2086
  docker compose ${profiles[@]+"${profiles[@]}"} "$@"
}

# --- V2: разбор записей и опций ---
# Формат записи: "часть0:часть1[:ключ=знач...]", где часть0 — домен(ы, через пробел),
# часть1 — порт. Двоеточий внутри доменов не бывает, поэтому сплит по ':' безопасен.
# Результат — в ENTRY_DOMAINS, ENTRY_PORT, ENTRY_OPTS (массив).
parse_entry() {
  local entry="$1"
  IFS=':' read -ra _parts <<< "$entry"
  ENTRY_DOMAINS="${_parts[0]:-}"
  ENTRY_PORT="${_parts[1]:-}"
  ENTRY_OPTS=()
  local i
  for ((i = 2; i < ${#_parts[@]}; i++)); do
    ENTRY_OPTS+=("${_parts[i]}")
  done
}

# opt_value <ключ> <дефолт> [опции...] — значение опции или дефолт.
opt_value() {
  local key="$1" def="$2"
  shift 2
  local o k
  for o in "$@"; do
    # Голый токен без '=' — не опция, пропускаем (раньше возвращал мусор).
    [[ "$o" == *=* ]] || continue
    k="${o%%=*}"
    if [ "$k" = "$key" ]; then
      printf "%s" "${o#*=}"
      return 0
    fi
  done
  printf "%s" "$def"
}

# cfg_opt <ключ> <дефолт> — значение из GLOBAL_OPTS или дефолт.
cfg_opt() {
  local key="$1" def="$2"
  if declare -p GLOBAL_OPTS >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    opt_value "$key" "$def" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"}
  else
    printf "%s" "$def"
  fi
}

# tag_for_domain <домен> — базовый тег бэкенда (как в v1).
tag_for_domain() {
  printf "site_%s" "$(echo "$1" | tr '.' '_')"
}

# ff_list — forwardfor_backends без пробелов (иначе "bk_a, bk_b" не матчится).
ff_list() {
  local ff
  ff="$(cfg_opt forwardfor_backends "")"
  printf "%s" "${ff//[[:space:]]/}"
}

# check_proxy_sfx <proxy> <check_sfx> — суффикс server-строки для healthcheck-ов.
# Чек в PROXY-цель (acceptProxyProtocol/xver-сторона) шлется тоже с PROXY,
# иначе голый чек умрет и ящик вечно flagged down: backend_check=tcp вкупе
# с proxy=v1/v2 дает `check ... check-send-proxy`. При proxy=off — как было.
check_proxy_sfx() {
  local _proxy="$1" _chk="$2"
  if [ -n "$_chk" ] && [ "$_proxy" != "off" ]; then
    printf "%s check-send-proxy" "$_chk"
  else
    printf "%s" "$_chk"
  fi
}

# maybe_forwardfor <тег> — печатает "    option forwardfor", если bk_<тег>
# перечислен в forwardfor_backends (иначе ничего).
maybe_forwardfor() {
  if [[ ",$(ff_list)," == *",bk_$1,"* ]]; then
    printf "    option forwardfor\n"
  fi
}

# ACL-имена host_* обязаны быть уникальны в пределах фронтенда: повторное
# определение acl с тем же именем МОЛЧА затирает первое (бага haproxy-семантики).
# acl_name_for <тег> — кладёт уникальное имя в $ACL_NAME (_2, _3... при коллизии).
# Массив _ACL_USED сбрасывается в начале каждого generate_web_*.
acl_name_for() {
  local base="host_$1"
  local cand="$base"
  local n=1
  local u taken
  while true; do
    taken=false
    for u in ${_ACL_USED[@]+"${_ACL_USED[@]}"}; do
      [ "$u" = "$cand" ] && taken=true
    done
    if [ "$taken" = false ]; then
      break
    fi
    n=$((n + 1))
    cand="${base}_${n}"
  done
  _ACL_USED+=("$cand")
  ACL_NAME="$cand"
}

# --- V3: нейтральная модель stream/web (без слов reality/xray в ядре) ---
# STREAM_ROUTES: "sni=<список|default> to=<host:порт> [proxy=off|v1|v2] [name=<метка>] [log=on|off]"
#   sni-список: домены через пробел ("sni=a.com b.com to=...").
#   default: ровно одна запись "sni=default to=..." — явный дефолт в web.
#   log=off: не писать логи этого бэкенда (no log) — для шумных маршрутов.
# WEB_ROUTES: "host=<домен> to=<host:порт> [path=/prefix] [name=<метка>] [log=on|off]"
# Результат разбора — в S3_* / W3_* переменных. Возврат 1 = битая запись (fail-closed).
v3_in_legacy_file() {
  [ "${#STREAM_ROUTES[@]}" -gt 0 ] || [ "${#WEB_ROUTES[@]}" -gt 0 ]
}

# parse_stream_route <запись> — разбирает одну STREAM_ROUTES-запись.
parse_stream_route() {
  local entry="$1"
  S3_SNI=""
  S3_TO=""
  S3_PROXY="off"
  S3_NAME=""
  S3_LOG="on"
  S3_FRONTEND=""
  S3_USE=""
  local tok key val seen_other=false seen_keys=""
  # Без glob: read -ra сплитит как for, но не раскрывает */? в имена файлов.
  local -a _toks=()
  read -ra _toks <<< "$entry" || true
  local _ti
  for ((_ti = 0; _ti < ${#_toks[@]}; _ti++)); do
    tok="${_toks[$_ti]}"
    if [[ "$tok" == *=* ]]; then
      key="${tok%%=*}"
      val="${tok#*=}"
      if [[ " $seen_keys " == *" $key "* ]]; then
        log_error "  ❌ Дублирующийся ключ '${key}' в записи: '${entry}'" >&2
        return 1
      fi
      if [ -z "$val" ]; then
        log_error "  ❌ Пустое значение ключа '${key}' в записи: '${entry}'" >&2
        return 1
      fi
      seen_keys="${seen_keys} ${key}"
      case "$key" in
        sni) S3_SNI="$val" ;;
        to) S3_TO="$val"; seen_other=true ;;
        use) S3_USE="$val"; seen_other=true ;;
        proxy) S3_PROXY="$val"; seen_other=true ;;
        name) S3_NAME="$val"; seen_other=true ;;
        log) S3_LOG="$val"; seen_other=true ;;
        frontend) S3_FRONTEND="$val"; seen_other=true ;;
        *)
          log_error "  ❌ Неизвестный ключ '${key}' в stream-маршруте: '${entry}' (жди sni/to/use/proxy/name/log/frontend)" >&2
          return 1
          ;;
      esac
    else
      # Голый токен — продолжение sni-списка ("sni=a.com b.com to=...").
      # Разрешён только до первого ключа кроме sni.
      if [ "$seen_other" = true ]; then
        log_error "  ❌ Голый токен '${tok}' после to/proxy/name: '${entry}'" >&2
        return 1
      fi
      if [ -z "$S3_SNI" ]; then
        S3_SNI="$tok"
      else
        S3_SNI="${S3_SNI} ${tok}"
      fi
    fi
  done
  # Нормализация "sni=a.com..." префикса уже учтена; проверим обязательные поля.
  # Адрес: ровно один из to= (анонимный ящик) / use= (ссылка на именованный).
  if [ -z "$S3_SNI" ]; then
    log_error "  ❌ Битый stream-маршрут: '${entry}' (нужно 'sni=...')" >&2
    return 1
  fi
  if [ -n "$S3_TO" ] && [ -n "$S3_USE" ]; then
    log_error "  ❌ Stream-маршрут: to= и use= вместе нельзя: '${entry}'" >&2
    return 1
  fi
  if [ -z "$S3_TO" ] && [ -z "$S3_USE" ]; then
    log_error "  ❌ Битый stream-маршрут: '${entry}' (нужно to=host:порт или use=<имя ящика>)" >&2
    return 1
  fi
  if [ -n "$S3_USE" ]; then
    if [[ ! "$S3_USE" =~ ^[A-Za-z0-9_-]+$ ]]; then
      log_error "  ❌ use: только латиница/цифры/_/-, получил '${S3_USE}'" >&2
      return 1
    fi
    if [ -n "$S3_NAME" ]; then
      log_error "  ❌ Stream-маршрут: name= лишнее при use= (имя уже у ящика): '${entry}'" >&2
      return 1
    fi
    if [ "$S3_PROXY" != "off" ]; then
      log_error "  ❌ Stream-маршрут: proxy= живет на ящике, не в ссылке: '${entry}'" >&2
      return 1
    fi
    if [ "$S3_LOG" != "on" ]; then
      log_error "  ❌ Stream-маршрут: log= живет на ящике, не в ссылке: '${entry}'" >&2
      return 1
    fi
  fi
  # sni без префикса? parse выше кладет "sni=X" в S3_SNI="X" — ок.
  # Но запись вида "a.com to=..." (без sni=) даст S3_SNI="a.com" — запрещаем неявность:
  if [[ "$entry" != *sni=* ]]; then
    log_error "  ❌ Stream-маршрут без явного 'sni=': '${entry}'" >&2
    return 1
  fi
  case "$S3_PROXY" in
    off | v1 | v2) ;;
    *)
      log_error "  ❌ proxy: жди off/v1/v2, получил '${S3_PROXY}'" >&2
      return 1
      ;;
  esac
  if [ -n "$S3_NAME" ] && [[ ! "$S3_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ name: только латиница/цифры/_/- , получил '${S3_NAME}'" >&2
    return 1
  fi
  # Валидация to=host:порт (только для инлайн-маршрутов; у ссылок адреса нет)
  if [ -n "$S3_TO" ]; then
    local _h="${S3_TO%:*}"
    local _p="${S3_TO##*:}"
    if [ -z "$_h" ] || [ "$_h" = "$S3_TO" ]; then
      log_error "  ❌ to: жди host:порт, получил '${S3_TO}'" >&2
      return 1
    fi
    validate_host "$_h" "хост бэкенда" >&2 || return 1
    if ! validate_port "$_p" "порт бэкенда" >&2; then
      return 1
    fi
  fi
  if [ "$S3_SNI" != "default" ]; then
    local _d
    local -a _sni2_toks=()
    read -ra _sni2_toks <<< "$S3_SNI" || true
    local _di
    for ((_di = 0; _di < ${#_sni2_toks[@]}; _di++)); do
      _d="${_sni2_toks[$_di]}"
      if [ "$_d" = "default" ]; then
        log_error "  ❌ sni=default — отдельная запись, не часть списка: '${entry}'" >&2
        return 1
      fi
      validate_domain "$_d" >&2 || return 1
    done
  fi
  case "$S3_LOG" in
    on | off) ;;
    *)
      log_error "  ❌ log: жди on/off, получил '${S3_LOG}'" >&2
      return 1
      ;;
  esac
  if [ -n "$S3_FRONTEND" ] && [[ ! "$S3_FRONTEND" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ frontend: только латиница/цифры/_/-, получил '${S3_FRONTEND}'" >&2
    return 1
  fi
}

# parse_web_route <запись> — разбирает одну WEB_ROUTES-запись.
parse_web_route() {
  local entry="$1"
  W3_HOST=""
  W3_TO=""
  W3_PATH=""
  W3_NAME=""
  W3_LOG="on"
  W3_FRONTEND=""
  W3_USE=""
  local tok key val seen_keys=""
  # Без glob: read -ra сплитит как for, но не раскрывает */? в имена файлов.
  local -a _toks=()
  read -ra _toks <<< "$entry" || true
  local _ti
  for ((_ti = 0; _ti < ${#_toks[@]}; _ti++)); do
    tok="${_toks[$_ti]}"
    if [[ "$tok" != *=* ]]; then
      log_error "  ❌ Битый web-маршрут (голый токен '${tok}'): '${entry}'" >&2
      return 1
    fi
    key="${tok%%=*}"
    val="${tok#*=}"
    if [[ " $seen_keys " == *" $key "* ]]; then
      log_error "  ❌ Дублирующийся ключ '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    if [ -z "$val" ]; then
      log_error "  ❌ Пустое значение ключа '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    seen_keys="${seen_keys} ${key}"
    case "$key" in
      host) W3_HOST="$val" ;;
      to) W3_TO="$val" ;;
      use) W3_USE="$val" ;;
      path) W3_PATH="$val" ;;
      name) W3_NAME="$val" ;;
      log) W3_LOG="$val" ;;
      frontend) W3_FRONTEND="$val" ;;
      *)
        log_error "  ❌ Неизвестный ключ '${key}' в web-маршруте: '${entry}' (жди host/to/use/path/name/log/frontend)" >&2
        return 1
        ;;
    esac
  done
  if [ -z "$W3_HOST" ]; then
    log_error "  ❌ Битый web-маршрут: '${entry}' (нужно 'host=домен')" >&2
    return 1
  fi
  validate_domain "$W3_HOST" >&2 || return 1
  if [ -n "$W3_TO" ] && [ -n "$W3_USE" ]; then
    log_error "  ❌ Web-маршрут: to= и use= вместе нельзя: '${entry}'" >&2
    return 1
  fi
  if [ -z "$W3_TO" ] && [ -z "$W3_USE" ]; then
    log_error "  ❌ Битый web-маршрут: '${entry}' (нужно to=host:порт или use=<имя ящика>)" >&2
    return 1
  fi
  if [ -n "$W3_USE" ]; then
    if [[ ! "$W3_USE" =~ ^[A-Za-z0-9_-]+$ ]]; then
      log_error "  ❌ use: только латиница/цифры/_/-, получил '${W3_USE}'" >&2
      return 1
    fi
    if [ -n "$W3_NAME" ]; then
      log_error "  ❌ Web-маршрут: name= лишнее при use= (имя уже у ящика): '${entry}'" >&2
      return 1
    fi
    if [ "$W3_LOG" != "on" ]; then
      log_error "  ❌ Web-маршрут: log= живет на ящике, не в ссылке: '${entry}'" >&2
      return 1
    fi
  fi
  if [ -n "$W3_TO" ]; then
    local _h="${W3_TO%:*}"
    local _p="${W3_TO##*:}"
    if [ -z "$_h" ] || [ "$_h" = "$W3_TO" ]; then
      log_error "  ❌ to: жди host:порт, получил '${W3_TO}'" >&2
      return 1
    fi
    validate_host "$_h" "хост бэкенда" >&2 || return 1
    validate_port "$_p" "порт бэкенда" >&2 || return 1
  fi
  if [ -n "$W3_PATH" ] && [[ "$W3_PATH" != /* ]]; then
    log_error "  ❌ path должен начинаться с '/': '${W3_PATH}'" >&2
    return 1
  fi
  if [ -n "$W3_NAME" ] && [[ ! "$W3_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ name: только латиница/цифры/_/- , получил '${W3_NAME}'" >&2
    return 1
  fi
  case "$W3_LOG" in
    on | off) ;;
    *)
      log_error "  ❌ log: жди on/off, получил '${W3_LOG}'" >&2
      return 1
      ;;
  esac
  if [ -n "$W3_FRONTEND" ] && [[ ! "$W3_FRONTEND" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ frontend: только латиница/цифры/_/-, получил '${W3_FRONTEND}'" >&2
    return 1
  fi
}

# sanitize_name <метка> — безопасное имя для backend/acl (уже проверено парсером).
sanitize_name() {
  printf "%s" "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# --- ФРОНТЕНДЫ (именованные уши: name + bind, маршруты привязываются через frontend=) ---
# Формат: "name=<метка> bind=<host:порт>[ accept_proxy=off|on][ log=on|off]"
# accept_proxy=on: ухо принимает ТОЛЬКО соединения с PROXY-заголовком (транзит
# между серверами) — прямые клиенты умрут; вешать на доверенный адрес + файрвол.
# Пустые массивы = поведение как раньше (один фронтенд из bind_stream/bind_web).
# Результат — в F_NAME/F_BIND/F_ACCEPT/F_LOG. Возврат 1 = битая запись (fail-closed).
parse_frontend() {
  local entry="$1"
  F_NAME=""
  F_BIND=""
  F_ACCEPT="off"
  F_LOG="on"
  local tok key val seen_keys=""
  # Без glob: read -ra сплитит как for, но не раскрывает */? в имена файлов.
  local -a _toks=()
  read -ra _toks <<< "$entry" || true
  local _ti
  for ((_ti = 0; _ti < ${#_toks[@]}; _ti++)); do
    tok="${_toks[$_ti]}"
    if [[ "$tok" != *=* ]]; then
      log_error "  ❌ Битый фронтенд (голый токен '${tok}'): '${entry}'" >&2
      return 1
    fi
    key="${tok%%=*}"
    val="${tok#*=}"
    if [[ " $seen_keys " == *" $key "* ]]; then
      log_error "  ❌ Дублирующийся ключ '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    if [ -z "$val" ]; then
      log_error "  ❌ Пустое значение ключа '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    seen_keys="${seen_keys} ${key}"
    case "$key" in
      name) F_NAME="$val" ;;
      bind) F_BIND="$val" ;;
      accept_proxy) F_ACCEPT="$val" ;;
      log) F_LOG="$val" ;;
      *)
        log_error "  ❌ Неизвестный ключ '${key}' во фронтенде: '${entry}' (жди name/bind/accept_proxy/log)" >&2
        return 1
        ;;
    esac
  done
  if [ -z "$F_NAME" ] || [ -z "$F_BIND" ]; then
    log_error "  ❌ Битый фронтенд: '${entry}' (нужно 'name=<метка> bind=<host:порт>')" >&2
    return 1
  fi
  if [[ ! "$F_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ name фронтенда: только латиница/цифры/_/-, получил '${F_NAME}'" >&2
    return 1
  fi
  local _h="${F_BIND%:*}"
  local _p="${F_BIND##*:}"
  if [ -z "$_h" ] || [ "$_h" = "$F_BIND" ]; then
    log_error "  ❌ bind: жди host:порт, получил '${F_BIND}'" >&2
    return 1
  fi
  validate_host "$_h" "хост фронтенда" >&2 || return 1
  validate_port "$_p" "порт фронтенда" >&2 || return 1
  case "$F_ACCEPT" in
    off | on) ;;
    *)
      log_error "  ❌ accept_proxy: жди off/on, получил '${F_ACCEPT}'" >&2
      return 1
      ;;
  esac
  case "$F_LOG" in
    on | off) ;;
    *)
      log_error "  ❌ log: жди on/off, получил '${F_LOG}'" >&2
      return 1
      ;;
  esac
}

# frontend_names <массив...> — печатает имена фронтендов (по одному на строку).
frontend_names() {
  local entry
  for entry in "$@"; do
    parse_frontend "$entry" 2>/dev/null || return 1
    printf "%s\n" "$F_NAME"
  done
}

# --- БЭКЕНДЫ (именованные ящики: name + to + флаги; маршруты ссылаются через use=) ---
# Stream: "name=<метка> to=<host:порт>[ proxy=off|v1|v2][ log=on|off]"
# Web:    "name=<метка> to=<host:порт>[ log=on|off]"
# Результат — в B_NAME/B_TO/B_PROXY/B_LOG. Возврат 1 = битая запись (fail-closed).
parse_stream_backend() {
  local entry="$1"
  B_NAME=""
  B_TO=""
  B_PROXY="off"
  B_LOG="on"
  local tok key val seen_keys=""
  # Без glob: read -ra сплитит как for, но не раскрывает */? в имена файлов.
  local -a _toks=()
  read -ra _toks <<< "$entry" || true
  local _ti
  for ((_ti = 0; _ti < ${#_toks[@]}; _ti++)); do
    tok="${_toks[$_ti]}"
    if [[ "$tok" != *=* ]]; then
      log_error "  ❌ Битый stream-бэкенд (голый токен '${tok}'): '${entry}'" >&2
      return 1
    fi
    key="${tok%%=*}"
    val="${tok#*=}"
    if [[ " $seen_keys " == *" $key "* ]]; then
      log_error "  ❌ Дублирующийся ключ '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    if [ -z "$val" ]; then
      log_error "  ❌ Пустое значение ключа '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    seen_keys="${seen_keys} ${key}"
    case "$key" in
      name) B_NAME="$val" ;;
      to) B_TO="$val" ;;
      proxy) B_PROXY="$val" ;;
      log) B_LOG="$val" ;;
      *)
        log_error "  ❌ Неизвестный ключ '${key}' в stream-бэкенде: '${entry}' (жди name/to/proxy/log)" >&2
        return 1
        ;;
    esac
  done
  if [ -z "$B_NAME" ] || [ -z "$B_TO" ]; then
    log_error "  ❌ Битый stream-бэкенд: '${entry}' (нужно 'name=<метка> to=<host:порт>')" >&2
    return 1
  fi
  if [[ ! "$B_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ name бэкенда: только латиница/цифры/_/-, получил '${B_NAME}'" >&2
    return 1
  fi
  local _h="${B_TO%:*}"
  local _p="${B_TO##*:}"
  if [ -z "$_h" ] || [ "$_h" = "$B_TO" ]; then
    log_error "  ❌ to: жди host:порт, получил '${B_TO}'" >&2
    return 1
  fi
  validate_host "$_h" "хост бэкенда" >&2 || return 1
  validate_port "$_p" "порт бэкенда" >&2 || return 1
  case "$B_PROXY" in
    off | v1 | v2) ;;
    *)
      log_error "  ❌ proxy: жди off/v1/v2, получил '${B_PROXY}'" >&2
      return 1
      ;;
  esac
  case "$B_LOG" in
    on | off) ;;
    *)
      log_error "  ❌ log: жди on/off, получил '${B_LOG}'" >&2
      return 1
      ;;
  esac
}

parse_web_backend() {
  local entry="$1"
  B_NAME=""
  B_TO=""
  B_PROXY="off"
  B_LOG="on"
  local tok key val seen_keys=""
  # Без glob: read -ra сплитит как for, но не раскрывает */? в имена файлов.
  local -a _toks=()
  read -ra _toks <<< "$entry" || true
  local _ti
  for ((_ti = 0; _ti < ${#_toks[@]}; _ti++)); do
    tok="${_toks[$_ti]}"
    if [[ "$tok" != *=* ]]; then
      log_error "  ❌ Битый web-бэкенд (голый токен '${tok}'): '${entry}'" >&2
      return 1
    fi
    key="${tok%%=*}"
    val="${tok#*=}"
    if [[ " $seen_keys " == *" $key "* ]]; then
      log_error "  ❌ Дублирующийся ключ '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    if [ -z "$val" ]; then
      log_error "  ❌ Пустое значение ключа '${key}' в записи: '${entry}'" >&2
      return 1
    fi
    seen_keys="${seen_keys} ${key}"
    case "$key" in
      name) B_NAME="$val" ;;
      to) B_TO="$val" ;;
      log) B_LOG="$val" ;;
      proxy)
        log_error "  ❌ proxy — ключ stream-бэкендов, в web не нужен: '${entry}'" >&2
        return 1
        ;;
      *)
        log_error "  ❌ Неизвестный ключ '${key}' в web-бэкенде: '${entry}' (жди name/to/log)" >&2
        return 1
        ;;
    esac
  done
  if [ -z "$B_NAME" ] || [ -z "$B_TO" ]; then
    log_error "  ❌ Битый web-бэкенд: '${entry}' (нужно 'name=<метка> to=<host:порт>')" >&2
    return 1
  fi
  if [[ ! "$B_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "  ❌ name бэкенда: только латиница/цифры/_/-, получил '${B_NAME}'" >&2
    return 1
  fi
  local _h="${B_TO%:*}"
  local _p="${B_TO##*:}"
  if [ -z "$_h" ] || [ "$_h" = "$B_TO" ]; then
    log_error "  ❌ to: жди host:порт, получил '${B_TO}'" >&2
    return 1
  fi
  validate_host "$_h" "хост бэкенда" >&2 || return 1
  validate_port "$_p" "порт бэкенда" >&2 || return 1
  case "$B_LOG" in
    on | off) ;;
    *)
      log_error "  ❌ log: жди on/off, получил '${B_LOG}'" >&2
      return 1
      ;;
  esac
}

# --- РЕЗОЛВЕР ССЫЛОК use= (общее для stream/web; kind = stream|web) ---
# backend_exists <kind> <name> — 0 если именованный ящик существует.
backend_exists() {
  local kind="$1" name="$2"
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_BACKENDS; else local -n arr=WEB_BACKENDS; fi
  local entry
  for entry in ${arr[@]+"${arr[@]}"}; do
    if [ "$kind" = "stream" ]; then
      parse_stream_backend "$entry" 2>/dev/null || continue
    else
      parse_web_backend "$entry" 2>/dev/null || continue
    fi
    [ "$B_NAME" = "$name" ] && return 0
  done
  return 1
}

# backend_refs <kind> <name> — напечатать записи маршрутов, ссылающиеся на ящик.
backend_refs() {
  local kind="$1" name="$2"
  local entry
  if [ "$kind" = "stream" ]; then
    for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
      parse_stream_route "$entry" 2>/dev/null || continue
      [ "$S3_USE" = "$name" ] && printf "  • %s\n" "$entry"
    done
  else
    for entry in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
      parse_web_route "$entry" 2>/dev/null || continue
      [ "$W3_USE" = "$name" ] && printf "  • %s\n" "$entry"
    done
  fi
}

# validate_backend_refs <kind> — ссылки use= резолвятся, имена ящиков уникальны.
# Висячие ящики (без ссылающихся маршрутов) — варнинг, не ошибка.
validate_backend_refs() {
  local kind="$1"
  if [ "$kind" = "stream" ]; then local -n barr=STREAM_BACKENDS; else local -n barr=WEB_BACKENDS; fi
  local entry names=() n
  for entry in ${barr[@]+"${barr[@]}"}; do
    if [ "$kind" = "stream" ]; then
      parse_stream_backend "$entry" || return 1
    else
      parse_web_backend "$entry" || return 1
    fi
    for n in ${names[@]+"${names[@]}"}; do
      if [ "$n" = "$B_NAME" ]; then
        log_error "  ❌ Дублирующийся ${kind}-бэкенд '${B_NAME}'" >&2
        return 1
      fi
    done
    names+=("$B_NAME")
  done
  # Каждая ссылка use= обязана резолвиться (fail-closed: трафик в никуда недопустим).
  local scope_ref
  if [ "$kind" = "stream" ]; then
    for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
      parse_stream_route "$entry" || return 1
      scope_ref="$S3_USE"
      [ -z "$scope_ref" ] && continue
      backend_exists "$kind" "$scope_ref" || {
        log_error "  ❌ Stream-маршрут '${S3_SNI}' ссылается на неизвестный ящик '${scope_ref}'" >&2
        return 1
      }
    done
  else
    for entry in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
      parse_web_route "$entry" || return 1
      scope_ref="$W3_USE"
      [ -z "$scope_ref" ] && continue
      backend_exists "$kind" "$scope_ref" || {
        log_error "  ❌ Web-маршрут '${W3_HOST}' ссылается на неизвестный ящик '${scope_ref}'" >&2
        return 1
      }
    done
  fi
  # Висячие ящики — варнинг (секция без трафика безвредна).
  for n in ${names[@]+"${names[@]}"}; do
    if [ -z "$(backend_refs "$kind" "$n" || true)" ]; then
      log_warn "  ⚠  ${kind}-бэкенд '${n}' ни на что не ссылается (висячий)"
    fi
  done
}

# shadow_check_stream — дубли SNI в одной области с разным бэкендом = ошибка.
# Использует массивы v_sni/v_to/v_proxy/v_use/v_fe из generate_stream_v3.
# sni=default скипается (резолвится отдельно), sni-списки раскрываются подоменно.
# Тот же SNI на тот же бэкенд — варнинг (мертвый дубль безвреден, но пахнет копипастой).
shadow_check_stream() {
  local -a _keys=() _bes=()
  local i _di _j _d _key _be _found
  local -a _doms=()
  for ((i = 0; i < ${#v_sni[@]}; i++)); do
    if [ -n "${v_use[i]}" ]; then
      _be="use:${v_use[i]}"
    else
      _be="to:${v_to[i]}|proxy:${v_proxy[i]}"
    fi
    _doms=()
    read -ra _doms <<< "${v_sni[i]}" || true
    for ((_di = 0; _di < ${#_doms[@]}; _di++)); do
      _d="${_doms[$_di]}"
      [ "$_d" = "default" ] && continue
      _key="${_d}|${v_fe[i]}"
      _found=false
      for ((_j = 0; _j < ${#_keys[@]}; _j++)); do
        if [ "${_keys[$_j]}" = "$_key" ]; then
          _found=true
          if [ "${_bes[$_j]}" != "$_be" ]; then
            log_error "  ❌ SNI '${_d}' (область '${v_fe[i]:-все}') ведет в разные бэкенды — второе правило мертвое" >&2
            return 1
          else
            log_warn "  ⚠  SNI '${_d}' (область '${v_fe[i]:-все}') дублируется на тот же бэкенд"
          fi
        fi
      done
      if [ "$_found" = false ]; then
        _keys+=("$_key")
        _bes+=("$_be")
      fi
    done
  done
}

# shadow_check_web — дубли host+path в одной области с разным бэкендом = ошибка.
# Массивы w_domains/w_ports/w_paths + опционально w_use/w_fe (нет массивов = инлайн без области).
shadow_check_web() {
  local -a _keys=() _bes=()
  local e _j _key _be _found _fe _use
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    _fe="${w_fe[e]:-}"
    _use="${w_use[e]:-}"
    if [ -n "$_use" ]; then
      _be="use:${_use}"
    else
      _be="to:${w_domains[e]}:${w_ports[e]}"
    fi
    _key="${w_domains[e]}|${w_paths[e]}|${_fe}"
    _found=false
    for ((_j = 0; _j < ${#_keys[@]}; _j++)); do
      if [ "${_keys[$_j]}" = "$_key" ]; then
        _found=true
        if [ "${_bes[$_j]}" != "$_be" ]; then
          log_error "  ❌ Дублирующийся маршрут '${w_domains[e]}${w_paths[e]}' (область '${_fe:-все}') в разные бэкенды — второй мертвый" >&2
          return 1
        else
          log_warn "  ⚠  Маршрут '${w_domains[e]}${w_paths[e]}' (область '${_fe:-все}') дублируется"
        fi
      fi
    done
    if [ "$_found" = false ]; then
      _keys+=("$_key")
      _bes+=("$_be")
    fi
  done
}

# validate_frontends <какой: stream|web> — уникальность имен + валидность записей.
validate_frontends() {
  local kind="$1"
  local -a arr=()
  if [ "$kind" = "stream" ]; then
    arr=(${STREAM_FRONTENDS[@]+"${STREAM_FRONTENDS[@]}"})
  else
    arr=(${WEB_FRONTENDS[@]+"${WEB_FRONTENDS[@]}"})
  fi
  local entry names=() n
  for entry in ${arr[@]+"${arr[@]}"}; do
    parse_frontend "$entry" || return 1
    for n in ${names[@]+"${names[@]}"}; do
      if [ "$n" = "$F_NAME" ]; then
        log_error "  ❌ Дублирующийся ${kind}-фронтенд '${F_NAME}'" >&2
        return 1
      fi
    done
    names+=("$F_NAME")
  done
}

# route_in_frontend <scope> <frontend> — 0 если маршрут с областью scope
# виден во фронтенде frontend (пустая область = везде).
route_in_frontend() {
  local scope="$1" fe="$2"
  [ -z "$scope" ] || [ "$scope" = "$fe" ]
}

# --- CRUD ФРОНТЕНДОВ (общее для stream/web; kind = stream|web) ---
# frontend_exists <kind> <name> — 0 если фронтенд существует.
frontend_exists() {
  local kind="$1" name="$2"
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_FRONTENDS; else local -n arr=WEB_FRONTENDS; fi
  local entry
  for entry in ${arr[@]+"${arr[@]}"}; do
    parse_frontend "$entry" 2>/dev/null || continue
    [ "$F_NAME" = "$name" ] && return 0
  done
  return 1
}

# materialize_default_frontend <stream|web> — создать name=main из текущего
# bind_* в пустой массив. Идемпотентно: если фронтенды уже заданы — ничего
# не делает (код 0). Нужно, чтобы неявный одиночный режим стал явной
# сущностью, которую видно в списках и можно править через fe_edit.
materialize_default_frontend() {
  local kind="$1"
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_FRONTENDS; else local -n arr=WEB_FRONTENDS; fi
  [ "${#arr[@]}" -gt 0 ] && return 0
  local cur_bind="*:443" g seen_bind=false
  [ "$kind" = "web" ] && cur_bind="*:8443"
  for g in ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"}; do
    if [[ "$g" == bind_${kind}=* ]]; then
      if [ "$seen_bind" = false ]; then
        cur_bind="${g#bind_${kind}=}"
        seen_bind=true
      elif [ "${g#bind_${kind}=}" != "$cur_bind" ]; then
        log_warn "  ⚠  Дублирующийся bind_${kind} в GLOBAL_OPTS (беру первый: ${cur_bind})"
        break
      fi
    fi
  done
  arr+=("name=main bind=${cur_bind}")
  log_info "  ✓ Текущий bind (${cur_bind}) импортирован как фронтенд 'main'"
}

# frontend_add <kind> <name> <bind> [log=on] — добавить с валидацией.
# При создании первого фронтенда вида текущий bind_* авто-импортируется
# как name=main (старые ключи после этого игнорируются генератором).
frontend_add() {
  local kind="$1" name="$2" bind="$3" flog="${4:-on}" accept="${5:-off}"
  case "$accept" in
    off | on) ;;
    *) log_error "❌ accept_proxy: жди off/on"; return 1 ;;
  esac
  if [ "$accept" = "on" ] && [ "$kind" != "stream" ]; then
    log_error "❌ accept_proxy — только для stream-фронтендов (у web — глобальный web_accept_proxy)"
    return 1
  fi
  local rec="name=${name} bind=${bind}"
  [ "$accept" = "on" ] && rec="${rec} accept_proxy=on"
  [ "$flog" = "off" ] && rec="${rec} log=off"
  parse_frontend "$rec" || return 1
  if frontend_exists "$kind" "$name"; then
    log_error "❌ ${kind}-фронтенд '${name}' уже существует"
    return 1
  fi
  if [ "$name" != "main" ]; then
    materialize_default_frontend "$kind" || return 1
  fi
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_FRONTENDS; else local -n arr=WEB_FRONTENDS; fi
  arr+=("$rec")
  log_info "  ✓ ${kind}-фронтенд '${name}' добавлен"
}

# frontend_refs <kind> <name> — напечатать записи маршрутов, ссылающиеся на фронтенд.
frontend_refs() {
  local kind="$1" name="$2"
  local entry
  if [ "$kind" = "stream" ]; then
    for entry in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
      parse_stream_route "$entry" 2>/dev/null || continue
      [ "$S3_FRONTEND" = "$name" ] && printf "  • %s\n" "$entry"
    done
  else
    for entry in ${WEB_ROUTES[@]+"${WEB_ROUTES[@]}"}; do
      parse_web_route "$entry" 2>/dev/null || continue
      [ "$W3_FRONTEND" = "$name" ] && printf "  • %s\n" "$entry"
    done
  fi
}

# frontend_remove <kind> <name> — удалить, если никто не ссылается.
frontend_remove() {
  local kind="$1" name="$2"
  if ! frontend_exists "$kind" "$name"; then
    log_error "❌ ${kind}-фронтенд '${name}' не найден"
    return 1
  fi
  local refs
  refs=$(frontend_refs "$kind" "$name" || true)
  if [ -n "$refs" ]; then
    log_error "❌ Фронтенд '${name}' используется маршрутами:"
    printf "%s\n" "$refs" >&2
    log_error "  Сначала убери область у этих маршрутов (или удали их)"
    return 1
  fi
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_FRONTENDS; else local -n arr=WEB_FRONTENDS; fi
  local -a kept=()
  local entry
  for entry in "${arr[@]}"; do
    parse_frontend "$entry" 2>/dev/null || continue
    [ "$F_NAME" = "$name" ] || kept+=("$entry")
  done
  if [ "$kind" = "stream" ]; then STREAM_FRONTENDS=("${kept[@]+"${kept[@]}"}");
  else WEB_FRONTENDS=("${kept[@]+"${kept[@]}"}"); fi
  log_info "  ✓ ${kind}-фронтенд '${name}' удалён"
}

# resolve_stream_backend <имя> — печатает "to|proxy|log" именованного ящика.
# Возврат 1, если нет (validate_backend_refs обычно уже это проверил).
resolve_stream_backend() {
  local want="$1" entry
  for entry in ${STREAM_BACKENDS[@]+"${STREAM_BACKENDS[@]}"}; do
    parse_stream_backend "$entry" 2>/dev/null || continue
    if [ "$B_NAME" = "$want" ]; then
      printf "%s|%s|%s" "$B_TO" "$B_PROXY" "$B_LOG"
      return 0
    fi
  done
  return 1
}

# resolve_web_backend <имя> — печатает "to|log" именованного ящика.
resolve_web_backend() {
  local want="$1" entry
  for entry in ${WEB_BACKENDS[@]+"${WEB_BACKENDS[@]}"}; do
    parse_web_backend "$entry" 2>/dev/null || continue
    if [ "$B_NAME" = "$want" ]; then
      printf "%s|%s" "$B_TO" "$B_LOG"
      return 0
    fi
  done
  return 1
}

# --- CRUD БЭКЕНДОВ (общее для stream/web; kind = stream|web) ---
# backend_add <kind> <rec> — валидация + добавление готовой записи + проверка дублей.
backend_add() {
  local kind="$1" rec="$2"
  if [ "$kind" = "stream" ]; then
    parse_stream_backend "$rec" || return 1
    local -n arr=STREAM_BACKENDS
  else
    parse_web_backend "$rec" || return 1
    local -n arr=WEB_BACKENDS
  fi
  if backend_exists "$kind" "$B_NAME"; then
    log_error "❌ ${kind}-бэкенд '${B_NAME}' уже существует"
    return 1
  fi
  # Имя ящика не должно совпадать с автотегами инлайн-маршрутов — проверит генератор.
  arr+=("$rec")
  log_info "  ✓ ${kind}-бэкенд '${B_NAME}' добавлен"
}

# backend_remove <kind> <name> — удалить, если никто не ссылается.
backend_remove() {
  local kind="$1" name="$2"
  if ! backend_exists "$kind" "$name"; then
    log_error "❌ ${kind}-бэкенд '${name}' не найден"
    return 1
  fi
  local refs
  refs=$(backend_refs "$kind" "$name" || true)
  if [ -n "$refs" ]; then
    log_error "❌ Ящик '${name}' используется маршрутами:"
    printf "%s\n" "$refs" >&2
    log_error "  Сначала переведи эти маршруты на другой ящик (или удали их)"
    return 1
  fi
  if [ "$kind" = "stream" ]; then local -n arr=STREAM_BACKENDS; else local -n arr=WEB_BACKENDS; fi
  local -a kept=()
  local entry
  for entry in "${arr[@]}"; do
    if [ "$kind" = "stream" ]; then
      parse_stream_backend "$entry" 2>/dev/null || continue
    else
      parse_web_backend "$entry" 2>/dev/null || continue
    fi
    [ "$B_NAME" = "$name" ] || kept+=("$entry")
  done
  if [ "$kind" = "stream" ]; then STREAM_BACKENDS=("${kept[@]+"${kept[@]}"}");
  else WEB_BACKENDS=("${kept[@]+"${kept[@]}"}"); fi
  log_info "  ✓ ${kind}-бэкенд '${name}' удалён"
}

# convert_legacy_to_v3 — печатает v3-эквивалент текущих WEB_SITES/REALITY_SITES.
# Используется migrate.sh и тестами. Дефолт stream->web дописывается явно.
convert_legacy_to_v3() {
  local web_backend="${1:-127.0.0.1:8443}"
  local entry domains port opts proxy
  local i=1
  echo "STREAM_ROUTES=("
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    parse_entry "$entry" || return 1
    domains="$ENTRY_DOMAINS"
    port="$ENTRY_PORT"
    [ -n "$domains" ] && [ -n "$port" ] || { log_error "  ❌ Битая запись REALITY_SITES: '${entry}'" >&2; return 1; }
    # shellcheck disable=SC2086
    proxy="$(opt_value proxy off ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    printf '  "sni=%s to=127.0.0.1:%s proxy=%s name=sni-%d"\n' "$domains" "$port" "$proxy" "$i"
    i=$((i + 1))
  done
  printf '  "sni=default to=%s proxy=off name=web"\n' "$web_backend"
  echo ")"
  echo "WEB_ROUTES=("
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    parse_entry "$entry" || return 1
    domains="$ENTRY_DOMAINS"
    port="$ENTRY_PORT"
    [ -n "$domains" ] && [ -n "$port" ] || { log_error "  ❌ Битая запись WEB_SITES: '${entry}'" >&2; return 1; }
    # shellcheck disable=SC2086
    local epath
    epath="$(opt_value path "" ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    if [ -n "$epath" ]; then
      printf '  "host=%s to=127.0.0.1:%s path=%s"\n' "$domains" "$port" "$epath"
    else
      printf '  "host=%s to=127.0.0.1:%s"\n' "$domains" "$port"
    fi
  done
  echo ")"
}

# --- ГЕНЕРАЦИЯ КОНФИГОВ ---
# generate_stream_v3 — SNI-маршруты из STREAM_ROUTES + явный sni=default.
# Формат backend: bk_<name>, server <name> <to><proxy><check>.
# Пустые STREAM_FRONTENDS = один фронтенд ft_https (как раньше, побайтово).
# Иначе: по фронтенду ft_<name> на запись, ACL фильтруются областью frontend=,
# бэкенды общие (дедуп по имени), default резолвится на фронтенд.
generate_stream_v3() {
  local t_conn t_client t_server t_tunnel bind_stream
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  validate_duration "$t_conn" "timeout connect" || return 1
  validate_duration "$t_client" "timeout client" || return 1
  validate_duration "$t_server" "timeout server" || return 1
  if [ -n "$t_tunnel" ]; then
    validate_duration "$t_tunnel" "timeout tunnel" || return 1
  fi
  bind_stream=$(cfg_opt bind_stream "*:443")
  local check_sfx=""
  if [ "$(cfg_opt backend_check off)" = "tcp" ]; then
    check_sfx=" check inter 10s fall 2 rise 2"
  fi

  # Разбор всех записей: default отдельно, остальные — SNI-правила.
  # Маршруты со use= ссылаются на именованный ящик (адрес/флаги — на нём).
  local -a v_sni=() v_to=() v_proxy=() v_name=() v_log=() v_fe=() v_use=()
  local -a d_sni=() d_to=() d_proxy=() d_name=() d_log=() d_fe=() d_use=()
  local entry
  for entry in "${STREAM_ROUTES[@]}"; do
    parse_stream_route "$entry" || return 1
    if [ "$S3_SNI" = "default" ]; then
      d_sni+=("$S3_SNI")
      d_to+=("$S3_TO")
      d_proxy+=("$S3_PROXY")
      if [ -n "$S3_USE" ]; then
        d_name+=("$(sanitize_name "$S3_USE")")
      else
        d_name+=("${S3_NAME:-web}")
      fi
      d_log+=("$S3_LOG")
      d_fe+=("$S3_FRONTEND")
      d_use+=("$S3_USE")
    else
      v_sni+=("$S3_SNI")
      v_to+=("$S3_TO")
      v_proxy+=("$S3_PROXY")
      v_log+=("$S3_LOG")
      v_fe+=("$S3_FRONTEND")
      v_use+=("$S3_USE")
      if [ -n "$S3_USE" ]; then
        v_name+=("$(sanitize_name "$S3_USE")")
      elif [ -n "$S3_NAME" ]; then
        v_name+=("$(sanitize_name "$S3_NAME")")
      else
        v_name+=("s-$(( ${#v_name[@]} + 1 ))")
      fi
    fi
  done

  # frontend= должен ссылаться на существующий фронтенд (если фронтенды заданы —
  # вообще, иначе любая область = ошибка: не на что ссылаться).
  local -a fe_names=()
  if [ "${#STREAM_FRONTENDS[@]}" -gt 0 ]; then
    validate_frontends stream || return 1
    local fe
    for fe in "${STREAM_FRONTENDS[@]}"; do
      parse_frontend "$fe" || return 1
      fe_names+=("$F_NAME")
      if [ "$F_ACCEPT" = "on" ]; then
        # В stderr: stdout генератора пишется в файл конфига.
        log_warn "  ⚠  Stream-фронтенд '${F_NAME}' принимает ТОЛЬКО PROXY (accept-proxy): прямые клиенты умрут, вешай на доверенный адрес + файрвол."
      fi
    done
  fi
  local i scope found
  for ((i = 0; i < ${#v_fe[@]}; i++)); do
    scope="${v_fe[i]}"
    [ -z "$scope" ] && continue
    found=false
    local n
    for n in ${fe_names[@]+"${fe_names[@]}"}; do
      [ "$n" = "$scope" ] && found=true
    done
    if [ "$found" = false ]; then
      log_error "  ❌ Stream-маршрут '${v_sni[i]}' ссылается на неизвестный фронтенд '${scope}'" >&2
      return 1
    fi
  done
  for ((i = 0; i < ${#d_fe[@]}; i++)); do
    scope="${d_fe[i]}"
    [ -z "$scope" ] && continue
    found=false
    local n
    for n in ${fe_names[@]+"${fe_names[@]}"}; do
      [ "$n" = "$scope" ] && found=true
    done
    if [ "$found" = false ]; then
      log_error "  ❌ Stream-default ссылается на неизвестный фронтенд '${scope}'" >&2
      return 1
    fi
  done

  # Ссылки use= резолвятся в именованные ящики (битые — fail, висячие — warn).
  validate_backend_refs stream || return 1

  # Дубли SNI в одной области с разным бэкендом — fail (второе правило мертвое).
  shadow_check_stream || return 1

  # Имена бэкендов уникальны (иначе секции задвоятся и haproxy не стартует).
  # Именованные ящики + инлайн-имена + инлайн-defaults не должны пересекаться
  # (ссылки use= указывают на существующие — их не проверяем).
  local -a be_names=() done_sig=()
  local be
  for be in "${STREAM_BACKENDS[@]}"; do
    parse_stream_backend "$be" || return 1
    be_names+=("$(sanitize_name "$B_NAME")")
  done
  local -a inline_names=()
  for ((i = 0; i < ${#v_name[@]}; i++)); do
    [ -n "${v_use[i]}" ] && continue
    for n in ${be_names[@]+"${be_names[@]}"}; do
      if [ "$n" = "${v_name[i]}" ]; then
        log_error "  ❌ Имя stream-маршрута '${v_name[i]}' занято именованным ящиком" >&2
        return 1
      fi
    done
    for n in ${inline_names[@]+"${inline_names[@]}"}; do
      if [ "$n" = "${v_name[i]}" ]; then
        log_error "  ❌ Дублирующееся имя stream-бэкенда '${v_name[i]}'" >&2
        return 1
      fi
    done
    inline_names+=("${v_name[i]}")
    be_names+=("${v_name[i]}")
  done
  for ((i = 0; i < ${#d_name[@]}; i++)); do
    [ -n "${d_use[i]}" ] && continue
    local dn sig dup_sig=false
    dn="$(sanitize_name "${d_name[i]}")"
    sig="${dn}|${d_to[i]}|${d_proxy[i]}|${d_log[i]}"
    local s
    for s in ${done_sig[@]+"${done_sig[@]}"}; do
      [ "$s" = "$sig" ] && dup_sig=true
    done
    # Побайтово одинаковый default для нескольких фронтендов — ок (один backend).
    $dup_sig && continue
    for n in ${be_names[@]+"${be_names[@]}"}; do
      if [ "$n" = "$dn" ]; then
        log_error "  ❌ Имя stream-default '${dn}' занято маршрутом, ящиком или другим default" >&2
        return 1
      fi
    done
    be_names+=("$dn")
    done_sig+=("$sig")
  done

  if [ "${#STREAM_FRONTENDS[@]}" -eq 0 ]; then
    _stream_single_frontend "$t_conn" "$t_client" "$t_server" "$t_tunnel" "$bind_stream" "$check_sfx"
    return $?
  fi
  _stream_multi_frontends "$t_conn" "$t_client" "$t_server" "$t_tunnel" "$check_sfx"
}

# _stream_single_frontend — исторический одиночный ft_https (побайтово как раньше).
# Аргументы: t_conn t_client t_server t_tunnel bind_stream check_sfx.
# Использует массивы v_*/d_* из generate_stream_v3 (ровно один default, без областей).
_stream_single_frontend() {
  local t_conn="$1" t_client="$2" t_server="$3" t_tunnel="$4" bind_stream="$5" check_sfx="$6"
  if [ "${#d_to[@]}" -ne 1 ]; then
    log_error "  ❌ STREAM_ROUTES: нужна ровно одна запись 'sni=default ...' (нашлось: ${#d_to[@]})" >&2
    return 1
  fi
  local def_to="${d_to[0]}" def_proxy="${d_proxy[0]}" def_name="${d_name[0]}" def_log="${d_log[0]}"
  # Default-ссылка use=: адрес/флаги берутся с именованного ящика.
  if [ -n "${d_use[0]}" ]; then
    local rec rest
    rec=$(resolve_stream_backend "$def_name") || return 1
    def_to="${rec%%|*}"
    rest="${rec#*|}"
    def_proxy="${rest%%|*}"
    def_log="${rest#*|}"
  fi
  cat << EOF
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi
  cat << EOF

frontend ft_https
    bind $bind_stream
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

EOF
  case "$(cfg_opt stream_log_sni off)" in
    off) ;;
    on) printf '    log-format "%%ci:%%cp [%%t] %%ft %%b/%%s %%Tw/%%Tc/%%Tt %%B %%ts %%ac/%%fc/%%bc/%%sc/%%rc %%sq/%%bq SNI:%%{+Q}[req.ssl_sni]"\n' ;;
    *) log_warn "  ⚠  Неизвестный stream_log_sni (жди off/on), игнорирую" >&2 ;;
  esac

  local i acl bk
  for ((i = 0; i < ${#v_sni[@]}; i++)); do
    acl="is_s_$((i + 1))"
    bk="bk_${v_name[i]}"
    printf "    acl %s req.ssl_sni -i %s\n" "$acl" "${v_sni[i]}"
    printf "    use_backend %s if %s\n" "$bk" "$acl"
  done
  [ "${#v_sni[@]}" -gt 0 ] && echo ""

  # Дефолт — из явной записи sni=default (имя/прокси из записи).
  local def_sfx=""
  case "$def_proxy" in
    off) def_sfx="" ;;
    v1) def_sfx=" send-proxy" ;;
    v2) def_sfx=" send-proxy-v2" ;;
  esac
  # Совместимость GLOBAL_OPTS stream_web_proxy: если дефолт без proxy,
  # а опция задана — применяем её (миграция v2 без правок даёт тот же выхлоп).
  if [ "$def_proxy" = "off" ]; then
    case "$(cfg_opt stream_web_proxy off)" in
      off) ;;
      v1) def_sfx=" send-proxy" ;;
      v2) def_sfx=" send-proxy-v2" ;;
    esac
  fi
  printf "    default_backend bk_%s\n\n" "$(sanitize_name "$def_name")"
  emit_custom "stream-frontend-*.cfg"

  # Именованные ящики — общей секцией (ссылки use= на них уже резолвлены выше).
  local be
  for be in "${STREAM_BACKENDS[@]}"; do
    parse_stream_backend "$be" || return 1
    local bproxy_line=""
    case "$B_PROXY" in
      v2) bproxy_line=" send-proxy-v2" ;;
      v1) bproxy_line=" send-proxy" ;;
      off) bproxy_line="" ;;
    esac
    printf "backend bk_%s\n" "$(sanitize_name "$B_NAME")"
    printf "    mode tcp\n"
    [ "$B_LOG" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "$(sanitize_name "$B_NAME")" "$B_TO" "$bproxy_line" "$(check_proxy_sfx "$B_PROXY" "$check_sfx")"
    printf "\n"
  done

  local proxy_line
  for ((i = 0; i < ${#v_sni[@]}; i++)); do
    # Ссылки use=: ящик уже напечатан выше, инлайн-секция не нужна.
    [ -n "${v_use[i]}" ] && continue
    bk="bk_${v_name[i]}"
    proxy_line=""
    case "${v_proxy[i]}" in
      v2) proxy_line=" send-proxy-v2" ;;
      v1) proxy_line=" send-proxy" ;;
      off) proxy_line="" ;;
    esac
    printf "backend %s\n" "$bk"
    printf "    mode tcp\n"
    [ "${v_log[i]}" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "${v_name[i]}" "${v_to[i]}" "$proxy_line" "$(check_proxy_sfx "${v_proxy[i]}" "$check_sfx")"
    printf "\n"
  done

  # Секция default-бэкенда: при use= уже напечатана в блоке именованных выше.
  if [ -z "${d_use[0]}" ]; then
    printf "backend bk_%s\n" "$(sanitize_name "$def_name")"
    printf "    mode tcp\n"
    [ "$def_log" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "$(sanitize_name "$def_name")" "$def_to" "$def_sfx" "$(check_proxy_sfx "$def_proxy" "$check_sfx")"
  fi
  emit_custom "stream-backend-*.cfg"
}

# _stream_multi_frontends — по фронтенду ft_<name> на запись STREAM_FRONTENDS.
# Аргументы: t_conn t_client t_server t_tunnel check_sfx.
# Использует массивы v_*/d_*/fe из generate_stream_v3.
_stream_multi_frontends() {
  local t_conn="$1" t_client="$2" t_server="$3" t_tunnel="$4" check_sfx="$5"
  cat << EOF
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi

  # Резолв default на фронтенд: свой (scope=имя) важнее глобального (scope="").
  # Возвращает индекс в d_* через REPLY. 0 записей или >1 своей = ошибка.
  local fe_entry fe_name fe_bind fe_accept fe_log
  for fe_entry in "${STREAM_FRONTENDS[@]}"; do
    parse_frontend "$fe_entry" || return 1
    fe_name="$F_NAME"
    fe_bind="$F_BIND"
    fe_accept="$F_ACCEPT"
    fe_log="$F_LOG"
    echo ""
    local -a own=() glob=()
    local i
    for ((i = 0; i < ${#d_to[@]}; i++)); do
      if [ "${d_fe[i]}" = "$fe_name" ]; then
        own+=("$i")
      elif [ -z "${d_fe[i]}" ]; then
        glob+=("$i")
      fi
    done
    local di
    if [ "${#own[@]}" -gt 1 ]; then
      log_error "  ❌ Фронтенд '${fe_name}': больше одного своего default" >&2
      return 1
    elif [ "${#own[@]}" -eq 1 ]; then
      di="${own[0]}"
    elif [ "${#glob[@]}" -eq 1 ]; then
      di="${glob[0]}"
    elif [ "${#glob[@]}" -gt 1 ]; then
      log_error "  ❌ Больше одного глобального default — непонятно, какой для '${fe_name}'" >&2
      return 1
    else
      log_error "  ❌ Фронтенд '${fe_name}': нет default (ни своего, ни глобального)" >&2
      return 1
    fi
    local def_sfx=""
    if [ -n "${d_use[di]}" ]; then
      # Default-ссылка: прокси/адрес с именованного ящика.
      local rec rest
      rec=$(resolve_stream_backend "${d_name[di]}") || return 1
      rest="${rec#*|}"
      case "${rest%%|*}" in
        off) def_sfx="" ;;
        v1) def_sfx=" send-proxy" ;;
        v2) def_sfx=" send-proxy-v2" ;;
      esac
    else
      case "${d_proxy[di]}" in
        off) def_sfx="" ;;
        v1) def_sfx=" send-proxy" ;;
        v2) def_sfx=" send-proxy-v2" ;;
      esac
    fi
    if [ "$def_sfx" = "" ]; then
      case "$(cfg_opt stream_web_proxy off)" in
        off) ;;
        v1) def_sfx=" send-proxy" ;;
        v2) def_sfx=" send-proxy-v2" ;;
      esac
    fi
    cat << EOF
frontend ft_$(sanitize_name "$fe_name")
    bind $fe_bind$([ "$fe_accept" = "on" ] && printf " accept-proxy")
    mode tcp
EOF
    [ "$fe_log" = "off" ] && printf "    no log\n"
    cat << EOF
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

EOF
    case "$(cfg_opt stream_log_sni off)" in
      off) ;;
      on) printf '    log-format "%%ci:%%cp [%%t] %%ft %%b/%%s %%Tw/%%Tc/%%Tt %%B %%ts %%ac/%%fc/%%bc/%%sc/%%rc %%sq/%%bq SNI:%%{+Q}[req.ssl_sni]"\n' ;;
      *) log_warn "  ⚠  Неизвестный stream_log_sni (жди off/on), игнорирую" >&2 ;;
    esac
    local n=0
    for ((i = 0; i < ${#v_sni[@]}; i++)); do
      route_in_frontend "${v_fe[i]}" "$fe_name" || continue
      n=$((n + 1))
      printf "    acl is_s_%d req.ssl_sni -i %s\n" "$n" "${v_sni[i]}"
      printf "    use_backend bk_%s if is_s_%d\n" "${v_name[i]}" "$n"
    done
    [ "$n" -gt 0 ] && echo ""
    printf "    default_backend bk_%s\n" "$(sanitize_name "${d_name[di]}")"
    # Кастомные вставки фронта — в каждый фронтенд (задокументировано).
    emit_custom "stream-frontend-*.cfg"
  done
  echo ""

  # Общие бэкенды: именованные + маршрутные инлайн + по одному на default.
  local be
  for be in "${STREAM_BACKENDS[@]}"; do
    parse_stream_backend "$be" || return 1
    local bproxy_line=""
    case "$B_PROXY" in
      v2) bproxy_line=" send-proxy-v2" ;;
      v1) bproxy_line=" send-proxy" ;;
      off) bproxy_line="" ;;
    esac
    printf "backend bk_%s\n" "$(sanitize_name "$B_NAME")"
    printf "    mode tcp\n"
    [ "$B_LOG" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "$(sanitize_name "$B_NAME")" "$B_TO" "$bproxy_line" "$(check_proxy_sfx "$B_PROXY" "$check_sfx")"
    printf "\n"
  done
  local proxy_line
  for ((i = 0; i < ${#v_sni[@]}; i++)); do
    # Ссылки use=: ящик уже напечатан выше.
    [ -n "${v_use[i]}" ] && continue
    proxy_line=""
    case "${v_proxy[i]}" in
      v2) proxy_line=" send-proxy-v2" ;;
      v1) proxy_line=" send-proxy" ;;
      off) proxy_line="" ;;
    esac
    printf "backend bk_%s\n" "${v_name[i]}"
    printf "    mode tcp\n"
    [ "${v_log[i]}" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "${v_name[i]}" "${v_to[i]}" "$proxy_line" "$(check_proxy_sfx "${v_proxy[i]}" "$check_sfx")"
    printf "\n"
  done
  local -a done_def=()
  local fdi
  for ((fdi = 0; fdi < ${#d_to[@]}; fdi++)); do
    # Default-ссылка: ящик уже напечатан выше.
    [ -n "${d_use[fdi]}" ] && continue
    local dn
    dn="$(sanitize_name "${d_name[fdi]}")"
    local seen=false
    local dd
    for dd in ${done_def[@]+"${done_def[@]}"}; do
      [ "$dd" = "$dn" ] && seen=true
    done
    $seen && continue
    done_def+=("$dn")
    local dsfx=""
    case "${d_proxy[fdi]}" in
      off) dsfx="" ;;
      v1) dsfx=" send-proxy" ;;
      v2) dsfx=" send-proxy-v2" ;;
    esac
    if [ "${d_proxy[fdi]}" = "off" ]; then
      case "$(cfg_opt stream_web_proxy off)" in
        off) ;;
        v1) dsfx=" send-proxy" ;;
        v2) dsfx=" send-proxy-v2" ;;
      esac
    fi
    printf "backend bk_%s\n" "$dn"
    printf "    mode tcp\n"
    [ "${d_log[fdi]}" = "off" ] && printf "    no log\n"
    printf "    server %s %s%s%s\n" "$dn" "${d_to[fdi]}" "$dsfx" "$(check_proxy_sfx "${d_proxy[fdi]}" "$check_sfx")"
    printf "\n"
  done
  emit_custom "stream-backend-*.cfg"
}

# _web_multi_frontends — по фронтенду ft_<name> на запись WEB_FRONTENDS.
# Аргументы: t_conn t_client t_server t_tunnel blackhole accept_sfx deny_status check_sfx.
_web_multi_frontends() {
  local t_conn="$1" t_client="$2" t_server="$3" t_tunnel="$4"
  local blackhole="$5" accept_sfx="$6" deny_status="$7" check_sfx="$8"

  cat << EOF
global
    log stdout format raw local0
    maxconn 4096
    tune.ssl.default-dh-param 2048
    ca-base /etc/ssl/certs
    crt-base /etc/haproxy/certs

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi
  if [ "$blackhole" = "tarpit" ]; then
    printf "    timeout tarpit 10s\n"
  fi

  # Разбор маршрутов один раз (теги считаются по полному набору, как в одиночном пути).
  # Ссылки use= адреса не несут — бэкенд резолвится в w_be.
  local -a w_domains=() w_ports=() w_paths=() w_hosts=() w_log=() w_fe=() w_use=()
  local entry
  for entry in "${WEB_ROUTES[@]}"; do
    parse_web_route "$entry" || return 1
    w_domains+=("$W3_HOST")
    if [ -n "$W3_USE" ]; then
      w_ports+=("")
      w_hosts+=("")
    else
      w_ports+=("${W3_TO##*:}")
      w_hosts+=("${W3_TO%:*}")
    fi
    w_paths+=("$W3_PATH")
    w_log+=("$W3_LOG")
    w_fe+=("$W3_FRONTEND")
    w_use+=("$W3_USE")
  done

  # Дубли host+path в одной области с разным бэкендом — fail.
  shadow_check_web || return 1

  web_tag_for() {
    local dom="$1" port="$2" idx="$3"
    local count=0
    local j
    for ((j = 0; j < ${#w_domains[@]}; j++)); do
      [ -n "${w_use[j]}" ] && continue
      [ "${w_domains[j]}" = "$dom" ] && count=$((count + 1))
    done
    if [ "$count" -eq 1 ] && [ -z "${w_paths[idx]}" ]; then
      tag_for_domain "$dom"
    else
      printf "%s_%s" "$(tag_for_domain "$dom")" "$port"
    fi
  }

  # Резолв бэкенда записи + коллизии инлайн-тегов с именованными ящиками.
  local -a w_be=()
  local e
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    if [ -n "${w_use[e]}" ]; then
      w_be+=("$(sanitize_name "${w_use[e]}")")
    else
      w_be+=("$(web_tag_for "${w_domains[e]}" "${w_ports[e]}" "$e")")
    fi
  done
  local be
  for be in "${WEB_BACKENDS[@]}"; do
    parse_web_backend "$be" || return 1
    local bn
    bn="$(sanitize_name "$B_NAME")"
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ -n "${w_use[e]}" ] && continue
      if [ "${w_be[e]}" = "$bn" ]; then
        log_error "  ❌ Тег web-маршрута '${w_be[e]}' занят именованным ящиком" >&2
        return 1
      fi
    done
  done

  local n=0
  local fe_entry fe_name fe_bind fe_log
  for fe_entry in "${WEB_FRONTENDS[@]}"; do
    parse_frontend "$fe_entry" || return 1
    fe_name="$F_NAME"
    fe_bind="$F_BIND"
    fe_log="$F_LOG"
    # ACL-имена уникальны в пределах фронтенда — счётчик на каждый.
    _ACL_USED=()
    echo ""
    cat << EOF
frontend ft_$(sanitize_name "$fe_name")
    bind $fe_bind ssl crt /etc/haproxy/certs/$accept_sfx
    mode http
EOF
    [ "$fe_log" = "off" ] && printf "    no log\n"
    printf "\n"
    case "$(cfg_opt web_capture_headers off)" in
      off) ;;
      on)
        printf "    capture request header Host len 64\n"
        printf "    capture request header X-Forwarded-For len 128\n"
        ;;
      *) log_warn "  ⚠  Неизвестный web_capture_headers (жди off/on), игнорирую" >&2 ;;
    esac

    # Порядок доменов — по первому появлению среди записей ЭТОГО фронтенда.
    local -a order=()
    local d e seen
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      route_in_frontend "${w_fe[e]}" "$fe_name" || continue
      d="${w_domains[e]}"
      seen=false
      local o
      for o in ${order[@]+"${order[@]}"}; do
        [ "$o" = "$d" ] && seen=true
      done
      $seen || order+=("$d")
    done

    local o tag ptag
    for o in ${order[@]+"${order[@]}"}; do
      for ((e = 0; e < ${#w_domains[@]}; e++)); do
        route_in_frontend "${w_fe[e]}" "$fe_name" || continue
        [ "${w_domains[e]}" = "$o" ] || continue
        [ -n "${w_paths[e]}" ] || continue
        tag="${w_be[e]}"
        acl_name_for "$tag"
        ptag="path_${tag}_$((n + 1))"
        n=$((n + 1))
        printf "    acl %s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$ACL_NAME" "$o"
        printf "    acl %s path_beg %s\n" "$ptag" "${w_paths[e]}"
        printf "    use_backend bk_%s if %s %s\n" "$tag" "$ACL_NAME" "$ptag"
      done
      for ((e = 0; e < ${#w_domains[@]}; e++)); do
        route_in_frontend "${w_fe[e]}" "$fe_name" || continue
        [ "${w_domains[e]}" = "$o" ] || continue
        [ -z "${w_paths[e]}" ] || continue
        tag="${w_be[e]}"
        acl_name_for "$tag"
        printf "    acl %s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$ACL_NAME" "$o"
        printf "    use_backend bk_%s if %s\n" "$tag" "$ACL_NAME"
        printf "\n"
        break
      done
    done

    printf "    default_backend bk_blackhole\n"
    # Кастомные вставки фронта — в каждый фронтенд (задокументировано).
    emit_custom "web-frontend-*.cfg"
  done
  echo ""

  # Именованные ящики — общей секцией (ссылки use= на них уже резолвлены выше).
  local be2
  for be2 in "${WEB_BACKENDS[@]}"; do
    parse_web_backend "$be2" || return 1
    printf "backend bk_%s\n" "$(sanitize_name "$B_NAME")"
    printf "    mode http\n"
    [ "$B_LOG" = "off" ] && printf "    no log\n"
    maybe_forwardfor "$(sanitize_name "$B_NAME")"
    printf "    server %s %s%s\n" "$(sanitize_name "$B_NAME")" "$B_TO" "$check_sfx"
    printf "\n"
  done

  # Общие бэкенды: один на уникальную пару (домен, порт).
  local -a done_be=()
  local key found
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    # Ссылки use=: ящик уже напечатан выше.
    [ -n "${w_use[e]}" ] && continue
    key="${w_domains[e]}:${w_ports[e]}"
    found=false
    local k
    for k in ${done_be[@]+"${done_be[@]}"}; do
      [ "$k" = "$key" ] && found=true
    done
    $found && continue
    done_be+=("$key")
    tag="${w_be[e]}"
    printf "backend bk_%s\n" "$tag"
    printf "    mode http\n"
    local be_quiet=true
    local j
    for ((j = 0; j < ${#w_domains[@]}; j++)); do
      if [ "${w_domains[j]}:${w_ports[j]}" = "$key" ] && [ "${w_log[j]}" != "off" ]; then
        be_quiet=false
        break
      fi
    done
    $be_quiet && printf "    no log\n"
    maybe_forwardfor "$tag"
    printf "    server %s %s:%s%s\n" "$tag" "${w_hosts[e]}" "${w_ports[e]}" "$check_sfx"
    printf "\n"
  done

  if [ "$blackhole" = "tarpit" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request tarpit\n"
  elif [ "$deny_status" != "403" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request deny deny_status %s\n" "$deny_status"
  else
    printf "backend bk_blackhole\n    mode http\n    http-request deny\n"
  fi
  emit_custom "web-backend-*.cfg"
}

# generate_web_v3 — Host-маршруты из WEB_ROUTES (порядок и теги как в v2).
# Пустые WEB_FRONTENDS = один фронтенд ft_https_terminated (как раньше, побайтово).
# Иначе: по фронтенду ft_<name> на запись, ACL фильтруются областью frontend=,
# бэкенды и blackhole общие.
generate_web_v3() {
  local t_conn t_client t_server t_tunnel bind_web blackhole
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  validate_duration "$t_conn" "timeout connect" || return 1
  validate_duration "$t_client" "timeout client" || return 1
  validate_duration "$t_server" "timeout server" || return 1
  if [ -n "$t_tunnel" ]; then
    validate_duration "$t_tunnel" "timeout tunnel" || return 1
  fi
  bind_web=$(cfg_opt bind_web "*:8443")
  blackhole=$(cfg_opt blackhole "deny")
  case "$blackhole" in
    deny | tarpit) ;;
    *)
      log_warn "  ⚠  Неизвестный blackhole='${blackhole}' (жди deny/tarpit), использую deny" >&2
      blackhole="deny"
      ;;
  esac
  local accept_sfx="" deny_status check_sfx=""
  if [ "$(cfg_opt web_accept_proxy off)" = "on" ]; then
    accept_sfx=" accept-proxy"
  fi
  deny_status=$(cfg_opt blackhole_deny_status 403)
  if ! [[ "$deny_status" =~ ^[0-9]+$ ]] || [ "$deny_status" -lt 100 ] || [ "$deny_status" -gt 599 ]; then
    log_error "  ❌ blackhole_deny_status: жди код 100-599, получил '${deny_status}'" >&2
    return 1
  fi
  if [ "$(cfg_opt backend_check off)" = "tcp" ]; then
    check_sfx=" check inter 10s fall 2 rise 2"
  fi

  # Области frontend= должны ссылаться на существующие фронтенды.
  if [ "${#WEB_FRONTENDS[@]}" -gt 0 ]; then
    validate_frontends web || return 1
  fi
  local entry scope found
  for entry in "${WEB_ROUTES[@]}"; do
    parse_web_route "$entry" || return 1
    scope="$W3_FRONTEND"
    [ -z "$scope" ] && continue
    if [ "${#WEB_FRONTENDS[@]}" -eq 0 ]; then
      log_error "  ❌ Web-маршрут '${W3_HOST}' ссылается на фронтенд '${scope}', а фронтенды не заданы" >&2
      return 1
    fi
    found=false
    local fe
    for fe in "${WEB_FRONTENDS[@]}"; do
      parse_frontend "$fe" || return 1
      [ "$F_NAME" = "$scope" ] && found=true
    done
    if [ "$found" = false ]; then
      log_error "  ❌ Web-маршрут '${W3_HOST}' ссылается на неизвестный фронтенд '${scope}'" >&2
      return 1
    fi
  done

  # Ссылки use= резолвятся в именованные ящики (битые — fail, висячие — warn).
  validate_backend_refs web || return 1

  if [ "${#WEB_FRONTENDS[@]}" -gt 0 ]; then
    _web_multi_frontends "$t_conn" "$t_client" "$t_server" "$t_tunnel" "$blackhole" "$accept_sfx" "$deny_status" "$check_sfx"
    return $?
  fi

  cat << EOF
global
    log stdout format raw local0
    maxconn 4096
    tune.ssl.default-dh-param 2048
    ca-base /etc/ssl/certs
    crt-base /etc/haproxy/certs

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi
  if [ "$blackhole" = "tarpit" ]; then
    printf "    timeout tarpit 10s\n"
  fi
  cat << EOF

frontend ft_https_terminated
    bind $bind_web ssl crt /etc/haproxy/certs/$accept_sfx
    mode http

EOF
  case "$(cfg_opt web_capture_headers off)" in
    off) ;;
    on)
      printf "    capture request header Host len 64\n"
      printf "    capture request header X-Forwarded-For len 128\n"
      ;;
    *) log_warn "  ⚠  Неизвестный web_capture_headers (жди off/on), игнорирую" >&2 ;;
  esac

  # Разбор v3-записей в те же w_* массивы, что у legacy-генератора.
  # Ссылки use= адреса не несут (w_ports/w_hosts пусты) — бэкенд резолвится в w_be.
  local -a w_domains=() w_ports=() w_paths=() w_hosts=() w_log=() w_use=()
  local entry
  for entry in "${WEB_ROUTES[@]}"; do
    parse_web_route "$entry" || return 1
    w_domains+=("$W3_HOST")
    if [ -n "$W3_USE" ]; then
      w_ports+=("")
      w_hosts+=("")
    else
      w_ports+=("${W3_TO##*:}")
      w_hosts+=("${W3_TO%:*}")
    fi
    w_paths+=("$W3_PATH")
    w_log+=("$W3_LOG")
    w_use+=("$W3_USE")
  done

  # Дубли host+path с разным бэкендом — fail (второе правило мертвое).
  shadow_check_web || return 1

  local -a order=()
  local d e seen
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    d="${w_domains[e]}"
    seen=false
    local o
    for o in ${order[@]+"${order[@]}"}; do
      [ "$o" = "$d" ] && seen=true
    done
    $seen || order+=("$d")
  done

  web_tag_for() {
    local dom="$1" port="$2" idx="$3"
    local count=0
    local j
    for ((j = 0; j < ${#w_domains[@]}; j++)); do
      # Ссылки use= ящиков не создают — на теги инлайн не влияют.
      [ -n "${w_use[j]}" ] && continue
      [ "${w_domains[j]}" = "$dom" ] && count=$((count + 1))
    done
    if [ "$count" -eq 1 ] && [ -z "${w_paths[idx]}" ]; then
      tag_for_domain "$dom"
    else
      printf "%s_%s" "$(tag_for_domain "$dom")" "$port"
    fi
  }

  # Резолв бэкенда записи: ссылка → имя ящика, инлайн → детерминированный тег.
  local -a w_be=()
  local e
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    if [ -n "${w_use[e]}" ]; then
      w_be+=("$(sanitize_name "${w_use[e]}")")
    else
      w_be+=("$(web_tag_for "${w_domains[e]}" "${w_ports[e]}" "$e")")
    fi
  done

  # Коллизия инлайн-тега с именованным ящиком — fail (секции бы задвоились).
  local be
  for be in "${WEB_BACKENDS[@]}"; do
    parse_web_backend "$be" || return 1
    local bn
    bn="$(sanitize_name "$B_NAME")"
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ -n "${w_use[e]}" ] && continue
      if [ "${w_be[e]}" = "$bn" ]; then
        log_error "  ❌ Тег web-маршрута '${w_be[e]}' занят именованным ящиком" >&2
        return 1
      fi
    done
  done

  local o tag ptag n=0
  _ACL_USED=()
  for o in ${order[@]+"${order[@]}"}; do
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ "${w_domains[e]}" = "$o" ] || continue
      [ -n "${w_paths[e]}" ] || continue
      tag="${w_be[e]}"
      acl_name_for "$tag"
      ptag="path_${tag}_$((n + 1))"
      n=$((n + 1))
      printf "    acl %s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$ACL_NAME" "$o"
      printf "    acl %s path_beg %s\n" "$ptag" "${w_paths[e]}"
      printf "    use_backend bk_%s if %s %s\n" "$tag" "$ACL_NAME" "$ptag"
    done
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ "${w_domains[e]}" = "$o" ] || continue
      [ -z "${w_paths[e]}" ] || continue
      tag="${w_be[e]}"
      acl_name_for "$tag"
      printf "    acl %s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$ACL_NAME" "$o"
      printf "    use_backend bk_%s if %s\n" "$tag" "$ACL_NAME"
      printf "\n"
      break
    done
  done

  cat << 'EOF'
    default_backend bk_blackhole

EOF
  emit_custom "web-frontend-*.cfg"

  # Именованные ящики — общей секцией (ссылки use= на них уже резолвлены выше).
  for be in "${WEB_BACKENDS[@]}"; do
    parse_web_backend "$be" || return 1
    printf "backend bk_%s\n" "$(sanitize_name "$B_NAME")"
    printf "    mode http\n"
    [ "$B_LOG" = "off" ] && printf "    no log\n"
    maybe_forwardfor "$(sanitize_name "$B_NAME")"
    printf "    server %s %s%s\n" "$(sanitize_name "$B_NAME")" "$B_TO" "$check_sfx"
    printf "\n"
  done

  local -a done_be=()
  local key found
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    # Ссылки use=: ящик уже напечатан выше, инлайн-секция не нужна.
    [ -n "${w_use[e]}" ] && continue
    key="${w_domains[e]}:${w_ports[e]}"
    found=false
    local k
    for k in ${done_be[@]+"${done_be[@]}"}; do
      [ "$k" = "$key" ] && found=true
    done
    $found && continue
    done_be+=("$key")
    tag="${w_be[e]}"
    printf "backend bk_%s\n" "$tag"
    printf "    mode http\n"
    # no log — только если ВСЕ записи этого бэкенда просили тишину
    # (иначе один тихий path-маршрут заглушил бы общий хост).
    local be_quiet=true
    local j
    for ((j = 0; j < ${#w_domains[@]}; j++)); do
      if [ "${w_domains[j]}:${w_ports[j]}" = "$key" ] && [ "${w_log[j]}" != "off" ]; then
        be_quiet=false
        break
      fi
    done
    $be_quiet && printf "    no log\n"
    maybe_forwardfor "$tag"
    printf "    server %s %s:%s%s\n" "$tag" "${w_hosts[e]}" "${w_ports[e]}" "$check_sfx"
    printf "\n"
  done

  if [ "$blackhole" = "tarpit" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request tarpit\n"
  elif [ "$deny_status" != "403" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request deny deny_status %s\n" "$deny_status"
  else
    printf "backend bk_blackhole\n    mode http\n    http-request deny\n"
  fi
  emit_custom "web-backend-*.cfg"
}

generate_stream_config() {
  # V3-ветка: нейтральные SNI-маршруты (ядро без reality).
  if v3_in_legacy_file; then
    if [ "${#STREAM_ROUTES[@]}" -gt 0 ]; then
      generate_stream_v3
      return $?
    fi
  fi
  local t_conn t_client t_server t_tunnel bind_stream
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  validate_duration "$t_conn" "timeout connect" || return 1
  validate_duration "$t_client" "timeout client" || return 1
  validate_duration "$t_server" "timeout server" || return 1
  if [ -n "$t_tunnel" ]; then
    validate_duration "$t_tunnel" "timeout tunnel" || return 1
  fi
  bind_stream=$(cfg_opt bind_stream "*:443")
  # Волна 3: PROXY в web-бэкенд + healthcheck-суффиксы server-строк.
  local swp swp_sfx check_sfx=""
  swp=$(cfg_opt stream_web_proxy off)
  case "$swp" in
    off) swp_sfx="" ;;
    v1) swp_sfx=" send-proxy" ;;
    v2) swp_sfx=" send-proxy-v2" ;;
    *) log_error "  ❌ stream_web_proxy: жди off/v1/v2" >&2; return 1 ;;
  esac
  if [ "$(cfg_opt backend_check off)" = "tcp" ]; then
    check_sfx=" check inter 10s fall 2 rise 2"
  fi

  cat << EOF
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi
  cat << EOF

frontend ft_https
    bind $bind_stream
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

EOF
  # Волна 4: SNI в stream-лог (opt-in stream_log_sni=on; дефолт off = как было).
  case "$(cfg_opt stream_log_sni off)" in
    off) ;;
    on) printf '    log-format "%%ci:%%cp [%%t] %%ft %%b/%%s %%Tw/%%Tc/%%Tt %%B %%ts %%ac/%%fc/%%bc/%%sc/%%rc %%sq/%%bq SNI:%%{+Q}[req.ssl_sni]"\n' ;;
    *) log_warn "  ⚠  Неизвестный stream_log_sni (жди off/on), игнорирую" >&2 ;;
  esac

  # V2: каждая REALITY-запись — свой ACL и свой backend (порт и PROXY из записи).
  # Одна запись без опций даёт байт-в-байт вывод v1 (обратная совместимость).
  local -a r_domains=() r_ports=() r_proxy=()
  local entry
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    parse_entry "$entry"
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Битая запись REALITY_SITES: '${entry}' (нужно 'домены:порт[:опции]')"
      return 1
    fi
    if ! validate_port "$ENTRY_PORT" "порт xray"; then
      return 1
    fi
    r_domains+=("$ENTRY_DOMAINS")
    r_ports+=("$ENTRY_PORT")
    # shellcheck disable=SC2086
    r_proxy+=("$(opt_value proxy off ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})")
  done

  # Дубли доменов с разным портом — fail (первое правило затеняет остальные).
  {
    local -a _rd=() _rk=()
    local _ri _rdi _rdom _rkey _rj _rfound
    local -a _rdoms=()
    for ((_ri = 0; _ri < ${#r_domains[@]}; _ri++)); do
      _rdoms=()
      read -ra _rdoms <<< "${r_domains[$_ri]}" || true
      for ((_rdi = 0; _rdi < ${#_rdoms[@]}; _rdi++)); do
        _rdom="${_rdoms[$_rdi]}"
        _rkey="$_rdom"
        _rfound=false
        for ((_rj = 0; _rj < ${#_rk[@]}; _rj++)); do
          if [ "${_rk[$_rj]}" = "$_rkey" ]; then
            _rfound=true
            if [ "${_rd[$_rj]}" != "${r_ports[$_ri]}" ]; then
              log_error "  ❌ Домен '${_rdom}' ведет в разные порты — второе правило мертвое" >&2
              return 1
            fi
          fi
        done
        if [ "$_rfound" = false ]; then
          _rk+=("$_rkey")
          _rd+=("${r_ports[$_ri]}")
        fi
      done
    done
  }

  local total=${#r_domains[@]}
  local i acl bk proxy_line
  if [ "$total" -eq 1 ] && [ "${r_proxy[0]}" = "off" ]; then
    # Legacy-вид одиночной записи (как v1)
    printf "    acl is_reality req.ssl_sni -i %s\n" "${r_domains[0]}"
    echo "    use_backend bk_xray if is_reality"
    echo ""
  else
    for ((i = 0; i < total; i++)); do
      acl="is_reality_$((i + 1))"
      bk="bk_xray_$((i + 1))"
      printf "    acl %s req.ssl_sni -i %s\n" "$acl" "${r_domains[i]}"
      printf "    use_backend %s if %s\n" "$bk" "$acl"
    done
    [ "$total" -gt 0 ] && echo ""
  fi

  cat << 'EOF'
    default_backend bk_haproxy_web

EOF
  # Волна 1: кастомные вставки фронта (если есть custom/stream-frontend-*.cfg)
  emit_custom "stream-frontend-*.cfg"

  if [ "$total" -eq 1 ] && [ "${r_proxy[0]}" = "off" ]; then
    printf "backend bk_xray\n"
    printf "    mode tcp\n"
    printf "    server xray 127.0.0.1:%s%s\n" "${r_ports[0]}" "$check_sfx"
    printf "\n"
  else
    for ((i = 0; i < total; i++)); do
      bk="bk_xray_$((i + 1))"
      proxy_line=""
      case "${r_proxy[i]}" in
        v2) proxy_line=" send-proxy-v2" ;;
        v1) proxy_line=" send-proxy" ;;
        off) proxy_line="" ;;
        *)
          log_warn "  ⚠  Неизвестный proxy='${r_proxy[i]}' (жди v1/v2/off), пропускаю" >&2
          proxy_line=""
          ;;
      esac
      printf "backend %s\n" "$bk"
      printf "    mode tcp\n"
      printf "    server xray 127.0.0.1:%s%s%s\n" "${r_ports[i]}" "$proxy_line" "$(check_proxy_sfx "${r_proxy[i]}" "$check_sfx")"
      printf "\n"
    done
  fi

  cat << EOF
backend bk_haproxy_web
    mode tcp
    server haproxy_web 127.0.0.1:8443${swp_sfx}${check_sfx}
EOF
  # Волна 1: кастомные вставки бэкендов (если есть custom/stream-backend-*.cfg)
  emit_custom "stream-backend-*.cfg"
}

generate_web_config() {
  # V3-ветка: Host-маршруты из WEB_ROUTES.
  if v3_in_legacy_file; then
    if [ "${#WEB_ROUTES[@]}" -gt 0 ]; then
      generate_web_v3
      return $?
    fi
  fi
  local t_conn t_client t_server t_tunnel bind_web blackhole
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  validate_duration "$t_conn" "timeout connect" || return 1
  validate_duration "$t_client" "timeout client" || return 1
  validate_duration "$t_server" "timeout server" || return 1
  if [ -n "$t_tunnel" ]; then
    validate_duration "$t_tunnel" "timeout tunnel" || return 1
  fi
  bind_web=$(cfg_opt bind_web "*:8443")
  blackhole=$(cfg_opt blackhole "deny")
  case "$blackhole" in
    deny | tarpit) ;;
    *)
      log_warn "  ⚠  Неизвестный blackhole='${blackhole}' (жди deny/tarpit), использую deny" >&2
      blackhole="deny"
      ;;
  esac
  # Волна 3: accept-proxy на bind, deny_status для blackhole, healthcheck-суффиксы.
  local accept_sfx="" deny_status check_sfx=""
  if [ "$(cfg_opt web_accept_proxy off)" = "on" ]; then
    accept_sfx=" accept-proxy"
  fi
  deny_status=$(cfg_opt blackhole_deny_status 403)
  if ! [[ "$deny_status" =~ ^[0-9]+$ ]] || [ "$deny_status" -lt 100 ] || [ "$deny_status" -gt 599 ]; then
    log_error "  ❌ blackhole_deny_status: жди код 100-599, получил '${deny_status}'" >&2
    return 1
  fi
  if [ "$(cfg_opt backend_check off)" = "tcp" ]; then
    check_sfx=" check inter 10s fall 2 rise 2"
  fi

  cat << EOF
global
    log stdout format raw local0
    maxconn 4096
    tune.ssl.default-dh-param 2048
    ca-base /etc/ssl/certs
    crt-base /etc/haproxy/certs

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect $t_conn
    timeout client  $t_client
    timeout server  $t_server
EOF
  if [ -n "$t_tunnel" ]; then
    printf "    timeout tunnel %s\n" "$t_tunnel"
  fi
  if [ "$blackhole" = "tarpit" ]; then
    printf "    timeout tarpit 10s\n"
  fi
  cat << EOF

frontend ft_https_terminated
    bind $bind_web ssl crt /etc/haproxy/certs/$accept_sfx
    mode http

EOF
  # Волна 4: capture заголовков (opt-in web_capture_headers=on; дефолт off).
  case "$(cfg_opt web_capture_headers off)" in
    off) ;;
    on)
      printf "    capture request header Host len 64\n"
      printf "    capture request header X-Forwarded-For len 128\n"
      ;;
    *) log_warn "  ⚠  Неизвестный web_capture_headers (жди off/on), игнорирую" >&2 ;;
  esac

  # V2: разбор WEB-записей. Формат: "домен:порт[:path=/prefix][:опции...]".
  # Один домен без path => legacy-вид v1 (байт-в-байт). Несколько записей
  # на домен: path-правила первыми, затем общее host-правило.
  local -a w_domains=() w_ports=() w_paths=()
  local entry
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    parse_entry "$entry"
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Битая запись WEB_SITES: '${entry}' (нужно 'домен:порт[:опции]')"
      return 1
    fi
    if ! validate_domain "$ENTRY_DOMAINS"; then
      return 1
    fi
    if ! validate_port "$ENTRY_PORT" "порт бэкенда"; then
      return 1
    fi
    # shellcheck disable=SC2086
    local epath
    epath="$(opt_value path "" ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    if [ -n "$epath" ] && [[ "$epath" != /* ]]; then
      log_error "  ❌ path должен начинаться с '/': '${epath}' (запись '${entry}')"
      return 1
    fi
    w_domains+=("$ENTRY_DOMAINS")
    w_ports+=("$ENTRY_PORT")
    w_paths+=("$epath")
  done

  # Дубли домен+path с разным портом — fail (второе правило мертвое).
  shadow_check_web || return 1

  # Порядок доменов — по первому появлению; path-правила внутри домена — первыми.
  local -a order=()
  local d e seen
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    d="${w_domains[e]}"
    seen=false
    local o
    for o in ${order[@]+"${order[@]}"}; do
      [ "$o" = "$d" ] && seen=true
    done
    $seen || order+=("$d")
  done

  # Тег бэкенда: legacy (без порта), если у домена ровно одна запись без path.
  # Иначе — с суффиксом порта (детерминированно).
  web_tag_for() {
    local dom="$1" port="$2" idx="$3"
    local count=0
    local j
    for ((j = 0; j < ${#w_domains[@]}; j++)); do
      [ "${w_domains[j]}" = "$dom" ] && count=$((count + 1))
    done
    if [ "$count" -eq 1 ] && [ -z "${w_paths[idx]}" ]; then
      tag_for_domain "$dom"
    else
      printf "%s_%s" "$(tag_for_domain "$dom")" "$port"
    fi
  }

  local o tag ptag n=0
  for o in ${order[@]+"${order[@]}"}; do
    # Сначала path-правила этого домена
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ "${w_domains[e]}" = "$o" ] || continue
      [ -n "${w_paths[e]}" ] || continue
      tag=$(web_tag_for "$o" "${w_ports[e]}" "$e")
      ptag="path_${tag}_$((n + 1))"
      n=$((n + 1))
      printf "    acl host_%s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$tag" "$o"
      printf "    acl %s path_beg %s\n" "$ptag" "${w_paths[e]}"
      printf "    use_backend bk_%s if host_%s %s\n" "$tag" "$tag" "$ptag"
    done
    # Затем общее host-правило (первая беspath-запись домена)
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ "${w_domains[e]}" = "$o" ] || continue
      [ -z "${w_paths[e]}" ] || continue
      tag=$(web_tag_for "$o" "${w_ports[e]}" "$e")
      printf "    acl host_%s hdr(host),regsub(:[0-9]+$,) -i %s\n" "$tag" "$o"
      printf "    use_backend bk_%s if host_%s\n" "$tag" "$tag"
      printf "\n"
      break
    done
  done

  cat << 'EOF'
    default_backend bk_blackhole

EOF
  # Волна 1: кастомные вставки фронта (если есть custom/web-frontend-*.cfg)
  emit_custom "web-frontend-*.cfg"

  # Бэкенды: один на уникальную пару (домен, порт).
  local -a done_be=()
  local key found
  for ((e = 0; e < ${#w_domains[@]}; e++)); do
    key="${w_domains[e]}:${w_ports[e]}"
    found=false
    local k
    for k in ${done_be[@]+"${done_be[@]}"}; do
      [ "$k" = "$key" ] && found=true
    done
    $found && continue
    done_be+=("$key")
    tag=$(web_tag_for "${w_domains[e]}" "${w_ports[e]}" "$e")
    printf "backend bk_%s\n" "$tag"
    printf "    mode http\n"
    # Волна 4: option forwardfor точечно (forwardfor_backends="bk_a,bk_b").
    maybe_forwardfor "$tag"
    printf "    server %s 127.0.0.1:%s%s\n" "$tag" "${w_ports[e]}" "$check_sfx"
    printf "\n"
  done

  if [ "$blackhole" = "tarpit" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request tarpit\n"
  elif [ "$deny_status" != "403" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request deny deny_status %s\n" "$deny_status"
  else
    printf "backend bk_blackhole\n    mode http\n    http-request deny\n"
  fi
  # Волна 1: кастомные вставки бэкендов (если есть custom/web-backend-*.cfg)
  emit_custom "web-backend-*.cfg"
}

# Волна 3: топологические sanity-проверки (PROXY-парность и шумные опции).
# Только варнинги (топологию целиком генератор не видит), кроме битых значений.
# Вызывать ПОСЛЕ загрузки массивов, ДО генерации. Возврат 1 = фатально.
check_proxy_parity() {
  local stream_web accept_web checks xver
  stream_web=$(cfg_opt stream_web_proxy off)
  accept_web=$(cfg_opt web_accept_proxy off)
  checks=$(cfg_opt backend_check off)
  xver=$(cfg_opt xray_xver off)
  case "$stream_web" in
    off | v1 | v2) ;;
    *) log_error "  ❌ stream_web_proxy: жди off/v1/v2, получил '${stream_web}'"; return 1 ;;
  esac
  case "$accept_web" in
    off | on) ;;
    *) log_error "  ❌ web_accept_proxy: жди off/on, получил '${accept_web}'"; return 1 ;;
  esac
  case "$checks" in
    off | tcp) ;;
    *) log_error "  ❌ backend_check: жди off/tcp, получил '${checks}'"; return 1 ;;
  esac
  case "$xver" in
    off | v2) ;;
    *) log_error "  ❌ xray_xver: жди off/v2, получил '${xver}'"; return 1 ;;
  esac
  if [ "$accept_web" = "on" ] && [ "$stream_web" = "off" ] && [ "$xver" = "off" ]; then
    log_warn "  ⚠  PROXY-рассинхрон: web ждёт PROXY (web_accept_proxy=on), а никто его не шлёт (ни stream, ни Xray xver) — ВСЕ соединения в web умрут. Включи stream_web_proxy=v1|v2 или сверь xray_xver."
  fi
  if [ "$stream_web" != "off" ] && [ "$accept_web" = "off" ]; then
    log_warn "  ⚠  PROXY-рассинхрон: stream шлёт PROXY в web, а web его не читает — флуд 'not a PROXY header'. Включи web_accept_proxy=on."
  fi
  # Зеркало Xray-стороны (xray_xver): fallback xver=2 шлет PROXY в web-таргет.
  if [ "$xver" = "v2" ] && [ "$accept_web" = "off" ]; then
    log_warn "  ⚠  PROXY-рассинхрон: Xray шлёт PROXY в web-таргет (xray_xver=v2, realitySettings.xver), а web его не читает — весь fallback умрет. Включи web_accept_proxy=on."
  fi
  if [ "$xver" = "off" ] && [ "$accept_web" = "on" ] && [ "$stream_web" = "off" ]; then
    log_warn "  ⚠  web ждёт PROXY, а Xray xver выключен и stream молчит: сверь, кто должен слать (xray_xver vs stream_web_proxy)."
  fi
  if [ "$checks" = "tcp" ]; then
    log_warn "  ⚠  backend_check=tcp: healthcheck-коннекты будут шуметь в логах бэкендов (Xray пишет parse-ошибку на каждый голый чек). Включено осознанно — ок."
  fi
  # Напоминание про Xray-сторону (генератор её не видит и проверить не может)
  local entry p
  for entry in ${REALITY_SITES[@]+"${REALITY_SITES[@]}"}; do
    parse_entry "$entry"
    # shellcheck disable=SC2086
    p="$(opt_value proxy off ${ENTRY_OPTS[@]+"${ENTRY_OPTS[@]}"})"
    if [ "$p" != "off" ]; then
      log_info "  ℹ  REALITY '${ENTRY_DOMAINS}' шлёт PROXY (${p}): Xray должен его читать (tcpSettings.acceptProxyProtocol), иначе рассинхрон."
      break
    fi
  done
  # V3: то же для нейтральных stream-маршрутов (без xray-специфики в тексте).
  # У ссылок use= эффективный proxy берется с ящика.
  local s3
  for s3 in ${STREAM_ROUTES[@]+"${STREAM_ROUTES[@]}"}; do
    parse_stream_route "$s3" 2>/dev/null || return 1
    local eff_proxy="$S3_PROXY" eff_to="$S3_TO"
    if [ -n "$S3_USE" ]; then
      local rec rest
      rec=$(resolve_stream_backend "$S3_USE" 2>/dev/null) || continue
      eff_to="${rec%%|*}"
      rest="${rec#*|}"
      eff_proxy="${rest%%|*}"
    fi
    if [ "$eff_proxy" != "off" ]; then
      log_info "  ℹ  Stream-маршрут '${S3_SNI}' шлёт PROXY (${eff_proxy}): бэкенд ${eff_to} должен его читать, иначе рассинхрон."
      break
    fi
  done
  return 0
}

generate_configs() {
  # generate_configs [--no-validate] — собрать stream/web из sites.conf.
  # Дефолт: строго валидировать (fail-closed). --no-validate: писать без проверки,
  # с громким варнингом (явный выбор оператора, для скриптов есть еще
  # HAPROXY_NO_VALIDATE=1). Бэкап pre-generate — в обоих путях.
  local _skip_validate=false
  if [ "${1:-}" = "--no-validate" ]; then
    _skip_validate=true
  elif [ -n "${1:-}" ]; then
    log_error "  ❌ generate_configs: неизвестный флаг '$1' (жди --no-validate)"
    return 1
  fi
  printf "  ${CYAN}📝 Генерирую конфиги...${NC}\n"

  # Загружаем данные из sites.conf
  if [ -f "$SITES_CONF" ]; then
    WEB_SITES=()
    REALITY_SITES=()
    GLOBAL_OPTS=()
    STREAM_ROUTES=()
    WEB_ROUTES=()
    STREAM_FRONTENDS=()
    WEB_FRONTENDS=()
    STREAM_BACKENDS=()
    WEB_BACKENDS=()
    if ! source_sites_file "$SITES_CONF" 2>/dev/null; then
      log_error "  ❌ Ошибка чтения ${SITES_CONF}"
      return 1
    fi
  fi

  # Волна 3: sanity-проверки до любых записей (битые значения роняют генерацию)
  if ! check_proxy_parity; then
    return 1
  fi

  # Волна 1: генерация во временные файлы + валидация + атомарное перемещение.
  # Сломанный конфиг никогда не попадает в stream/haproxy.cfg и web/haproxy.cfg
  # (кроме явного --no-validate — тогда риск на операторе).
  # Бэкап — только после успешной генерации/валидации, чтобы неудачи не жрали ротацию.
  local tmp_stream tmp_web
  tmp_stream=$(mktemp)
  tmp_web=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_stream' '$tmp_web'" RETURN

  if ! generate_stream_config > "$tmp_stream"; then
    log_error "  ❌ Ошибка генерации stream-конфига (старый файл не тронут)"
    return 1
  fi

  if ! generate_web_config > "$tmp_web"; then
    log_error "  ❌ Ошибка генерации web-конфига (старый файл не тронут)"
    return 1
  fi

  if [ "$_skip_validate" = true ]; then
    log_warn "  ⚠  Пропускаю проверку haproxy -c (явный --no-validate) — риск на операторе: рестарт с битым cfg = crash-loop :443"
  else
    if ! validate_cfg "$tmp_stream" "haproxy-stream"; then
      log_error "  ❌ stream-конфиг не прошёл валидацию (старый файл не тронут)"
      return 1
    fi

    if ! validate_cfg "$tmp_web" "haproxy-web"; then
      log_error "  ❌ web-конфиг не прошёл валидацию (старый файл не тронут)"
      return 1
    fi
  fi

  # Волна 1: бэкап текущего состояния перед перезаписью.
  backup_now "pre-generate" >/dev/null

  mkdir -p "${HAPROXY_DIR}/stream" "${HAPROXY_DIR}/web"
  mv "$tmp_stream" "${HAPROXY_DIR}/stream/haproxy.cfg"
  mv "$tmp_web" "${HAPROXY_DIR}/web/haproxy.cfg"

  log_info "  ✅ Конфиги обновлены (бэкап предыдущего — в .backup/)"
}

# Волна 2: предпросмотр — что изменит перегенерация, не трогая живые файлы.
# Возврат: 0 — различий нет, 1 — есть различия (показывает diff),
# 2 — ошибка (битый sites.conf/генерация; diff не показан).
# ВАЖНО: 1 при любом числе различающихся файлов (раньше возвращалось их число
# и diff обоих файлов маскировался под ошибку).
preview_configs() {
  if [ ! -f "$SITES_CONF" ]; then
    log_error "❌ sites.conf не найден"
    return 2
  fi
  WEB_SITES=()
  REALITY_SITES=()
  GLOBAL_OPTS=()
  STREAM_ROUTES=()
  WEB_ROUTES=()
  STREAM_FRONTENDS=()
  WEB_FRONTENDS=()
  STREAM_BACKENDS=()
  WEB_BACKENDS=()
  if ! source_sites_file "$SITES_CONF" 2>/dev/null; then
    log_error "  ❌ Ошибка чтения ${SITES_CONF}"
    return 2
  fi
  # Волна 3: те же sanity-проверки, что при генерации
  check_proxy_parity || return 2
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  generate_stream_config > "$tmpdir/stream.cfg" || return 2
  generate_web_config > "$tmpdir/web.cfg" || return 2
  local diffs=0
  local live
  for live in "stream:$tmpdir/stream.cfg:${HAPROXY_DIR}/stream/haproxy.cfg" \
              "web:$tmpdir/web.cfg:${HAPROXY_DIR}/web/haproxy.cfg"; do
    local name="${live%%:*}"
    local rest="${live#*:}"
    local newf="${rest%%:*}"
    local oldf="${rest#*:}"
    if [ ! -f "$oldf" ]; then
      printf "  ${YELLOW}~ %s: живого файла нет, будет создан${NC}\n" "$name"
      diffs=$((diffs + 1))
    elif ! diff -u "$oldf" "$newf"; then
      diffs=$((diffs + 1))
    else
      printf "  ${GREEN}= %s: без изменений${NC}\n" "$name"
    fi
  done
  if [ "$diffs" -gt 0 ]; then
    return 1
  fi
  return 0
}
