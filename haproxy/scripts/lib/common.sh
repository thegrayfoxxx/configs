#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
# Общие утилиты для скриптов HAProxy Manager

# --- ЦВЕТА ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# --- ПУТИ ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HAPROXY_DIR_OVERRIDE нужен тестам: подменяет корень проекта на временную копию
HAPROXY_DIR="${HAPROXY_DIR_OVERRIDE:-$(cd "${LIB_DIR}/../.." && pwd)}"
SITES_CONF="${HAPROXY_DIR}/sites.conf"
# V2: массивы всегда инициализированы (v1-файлы их не задают — тогда пусто).
WEB_SITES=()
REALITY_SITES=()
GLOBAL_OPTS=()
# Волна 1: локальное состояние (не в git, см. .gitignore)
BACKUP_DIR="${HAPROXY_DIR}/.backup"
CUSTOM_DIR="${HAPROXY_DIR}/custom"
ENABLED_FILE="${HAPROXY_DIR}/.enabled_services"
BACKUP_KEEP=10

# --- ОЧИСТКА ЭКРАНА ---
clear_screen() {
  printf '\033[2J\033[H\033[3J'
}

# --- ЛОГГЕРЫ ---
log_info()  { printf "${GREEN}%s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
log_error() { printf "${RED}%s${NC}\n" "$*"; }
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

  # Сайты и Reality
  local site_count=0
  local reality_count=0
  if [ -f "$SITES_CONF" ]; then
    WEB_SITES=()
    REALITY_SITES=()
    source "$SITES_CONF" 2>/dev/null
    site_count=${#WEB_SITES[@]}
    reality_count=${#REALITY_SITES[@]}
  fi

  # Сертификаты
  local cert_count=0
  local cert_info=""
  if [ -d "${HAPROXY_DIR}/web/certs" ]; then
    shopt -s nullglob
    for pem in "${HAPROXY_DIR}/web/certs"/*.pem; do
      cert_count=$((cert_count + 1))
      local expiry=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
      local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
      local now_epoch=$(date +%s)
      local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      if [ $days_left -lt 30 ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem) истекает через ${days_left}d${NC}"
      fi
    done
    shopt -u nullglob
  fi

  # Рисуем рамку
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│${NC}  Сервисы: %b stream  %b web  %b acme\n" "$stream_status" "$web_status" "$acme_status"
  printf "${CYAN}│${NC}  Профили: ${GREEN}%s${NC}\n" "$(svc_load_enabled)"
  printf "${CYAN}│${NC}  Конфиг:  ${GREEN}%d${NC} сайтов  ${GREEN}%d${NC} reality\n" "$site_count" "$reality_count"

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

# --- ПРОВЕРКА КОНТЕЙНЕРОВ ---
haproxy_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-stream' || return 1
}

require_haproxy() {
  if ! haproxy_is_running; then
    log_error "❌ Контейнеры HAProxy не запущены. Сначала: docker compose up -d"
    return 1
  fi
}

# --- БЕЗОПАСНЫЙ DOCKER COMPOSE (через dc: с профилями включённых сервисов) ---
safe_docker_compose() {
  if ! dc "$@"; then
    log_error "❌ docker compose ${1*} завершился с ошибкой"
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
  read -r setup_choice < /dev/tty

  if [ "$setup_choice" = "1" ]; then
    interactive_setup
  fi
}

ensure_configs() {
  local stream_cfg="${HAPROXY_DIR}/stream/haproxy.cfg"
  local web_cfg="${HAPROXY_DIR}/web/haproxy.cfg"

  # Если конфигов нет — генерируем
  if [ ! -f "$stream_cfg" ] || [ ! -f "$web_cfg" ]; then
    printf "  ${YELLOW}⚠  Конфиги HAProxy не найдены.${NC}\n"
    printf "  ${GREEN}1.${NC} Сгенерировать\n"
    printf "  ${RED}2.${NC} Пропустить\n\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r gen_choice < /dev/tty
    if [ "$gen_choice" = "1" ]; then
      generate_configs
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
      printf "  ${RED}2.${NC} Пропустить\n\n"
      printf "${CYAN}👉 Пункт:${NC} "
      read -r regen_choice < /dev/tty
      if [ "$regen_choice" = "1" ]; then
        generate_configs
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
    read -r acme_email < /dev/tty
    if [ -n "$acme_email" ] && [[ "$acme_email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
      break
    fi
    printf "  ${RED}   ✗ Введи корректный email (например, user@example.com)${NC}\n"
  done

  # Reality
  printf "\n  ${CYAN}🔐 Reality (xray)${NC}\n"
  printf "  ${CYAN}   Домены через пробел:${NC} "
  read -r reality_domains < /dev/tty

  local reality_port="10443"
  if [ -n "$reality_domains" ]; then
    while true; do
      printf "  ${CYAN}   Порт [10443]:${NC} "
      read -r reality_port < /dev/tty
      [ -z "$reality_port" ] && reality_port="10443"
      if validate_port "$reality_port" "порт xray" 2>/dev/null; then
        break
      fi
    done
  fi

  # Web sites
  printf "\n  ${CYAN}🌐 Веб-сайты${NC}\n"
  local web_sites=()
  while true; do
    printf "  ${CYAN}   Домен (Enter = готово):${NC} "
    read -r domain < /dev/tty
    [ -z "$domain" ] && break

    if ! validate_domain "$domain" 2>/dev/null; then
      continue
    fi

    while true; do
      printf "  ${CYAN}   Порт бэкенда:${NC} "
      read -r port < /dev/tty
      if [ -z "$port" ]; then
        printf "  ${RED}   ✗ Порт обязателен${NC}\n"
        continue
      fi
      if validate_port "$port" "порт бэкенда" 2>/dev/null; then
        break
      fi
    done

    web_sites+=("${domain}:${port}")
    printf "  ${GREEN}   ✓ %s → :%s${NC}\n" "$domain" "$port"
  done

  # Сохраняем
  {
    echo "# HAProxy конфигурация"
    echo "# Создан $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "ACME_EMAIL=\"${acme_email}\""
    echo ""
    echo "# Сайты (L7, SSL termination через haproxy-web)"
    echo "WEB_SITES=("
    for site in "${web_sites[@]+"${web_sites[@]}"}"; do
      echo "  \"${site}\""
    done
    echo ")"
    echo ""
    echo "# Reality (L4, напрямую на xray)"
    echo "REALITY_SITES=("
    if [ -n "$reality_domains" ]; then
      echo "  \"${reality_domains}:${reality_port}\""
    fi
    echo ")"
    echo ""
    echo "# Глобальные опции (v2): значения по умолчанию = текущее поведение"
    echo "GLOBAL_OPTS=("
    echo "  \"timeout_connect=5s\""
    echo "  \"timeout_client=50s\""
    echo "  \"timeout_server=50s\""
    echo "  \"bind_stream=*:443\""
    echo "  \"bind_web=*:8443\""
    echo "  \"blackhole=deny\""
    echo ")"
  } > "$SITES_CONF"

  printf "\n"
  log_info "  ✓ sites.conf создан"

  # Генерируем конфиги если есть данные
  if [ ${#web_sites[@]} -gt 0 ] || [ -n "$reality_domains" ]; then
    WEB_SITES=("${web_sites[@]+"${web_sites[@]}"}")
    REALITY_SITES=()
    [ -n "$reality_domains" ] && REALITY_SITES+=("${reality_domains}:${reality_port}")
    generate_configs
  fi

  log_warn "  ⚠  Проверь: ${CYAN}${SITES_CONF}${NC}"
  printf "\n"
  read -p "[Enter] для продолжения..." < /dev/tty
}

load_sites() {
  ensure_sites_conf
  WEB_SITES=()
  REALITY_SITES=()
  GLOBAL_OPTS=()
  if ! source "$SITES_CONF"; then
    die "❌ Ошибка чтения ${SITES_CONF}. Проверь синтаксис файла."
  fi
}

save_sites() {
  # Волна 1: бэкап перед перезаписью sites.conf
  [ -f "$SITES_CONF" ] && backup_now "pre-save" >/dev/null
  cat > "$SITES_CONF" << EOF
# HAProxy конфигурация
# Генерируется скриптами, можно редактировать вручную

ACME_EMAIL="${ACME_EMAIL:-}"

# Сайты (L7, SSL termination через haproxy-web)
# формат: "домен:порт_бэкенда"
WEB_SITES=(
$(printf '  "%s"\n' "${WEB_SITES[@]+"${WEB_SITES[@]}"}")
)

# Reality (L4, напрямую на xray)
# формат: "домены:порт_xray"
REALITY_SITES=(
$(printf '  "%s"\n' "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}")
)
EOF
  # V2: глобальные опции — пишем только если заданы (v1-файл остаётся v1-чистым)
  if [ "${#GLOBAL_OPTS[@]}" -gt 0 ]; then
    {
      echo ""
      echo "# Глобальные опции (v2)"
      echo "GLOBAL_OPTS=("
      printf '  "%s"\n' "${GLOBAL_OPTS[@]}"
      echo ")"
    } >> "$SITES_CONF"
  fi
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
  old=$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort | head -n -"$BACKUP_KEEP")
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
}

# --- ВАЛИДАЦИЯ КОНФИГОВ (волна 1) ---
# Проверяет haproxy-конфиг. Возврат: 0 ок/проверка невозможна, 1 битый конфиг.
validate_cfg() {
  local file="$1"
  if ! command -v haproxy >/dev/null 2>&1; then
    log_warn "  ⚠  haproxy не найден — пропускаю валидацию ${file}"
    return 0
  fi
  if haproxy -c -V -f "$file" >/dev/null 2>&1; then
    return 0
  fi
  log_error "  ❌ Битый конфиг: ${file}"
  haproxy -c -V -f "$file" 2>&1 | head -20
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
  printf "%s %s" "$enabled" "$svc" | xargs > "$ENABLED_FILE"
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
  printf "%s" "$out" | xargs > "$ENABLED_FILE"
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

# --- ГЕНЕРАЦИЯ КОНФИГОВ ---
generate_stream_config() {
  local t_conn t_client t_server t_tunnel bind_stream
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  bind_stream=$(cfg_opt bind_stream "*:443")

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

  # V2: каждая REALITY-запись — свой ACL и свой backend (порт и PROXY из записи).
  # Одна запись без опций даёт байт-в-байт вывод v1 (обратная совместимость).
  local -a r_domains=() r_ports=() r_proxy=()
  local entry
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    parse_entry "$entry"
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Бигая запись REALITY_SITES: '${entry}' (нужно 'домены:порт[:опции]')"
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
    printf "    server xray 127.0.0.1:%s\n" "${r_ports[0]}"
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
      printf "    server xray 127.0.0.1:%s%s\n" "${r_ports[i]}" "$proxy_line"
      printf "\n"
    done
  fi

  cat << EOF
backend bk_haproxy_web
    mode tcp
    server haproxy_web 127.0.0.1:8443
EOF
  # Волна 1: кастомные вставки бэкендов (если есть custom/stream-backend-*.cfg)
  emit_custom "stream-backend-*.cfg"
}

generate_web_config() {
  local t_conn t_client t_server t_tunnel bind_web blackhole
  t_conn=$(cfg_opt timeout_connect 5s)
  t_client=$(cfg_opt timeout_client 50s)
  t_server=$(cfg_opt timeout_server 50s)
  t_tunnel=$(cfg_opt timeout_tunnel "")
  bind_web=$(cfg_opt bind_web "*:8443")
  blackhole=$(cfg_opt blackhole "deny")
  case "$blackhole" in
    deny | tarpit) ;;
    *)
      log_warn "  ⚠  Неизвестный blackhole='${blackhole}' (жди deny/tarpit), использую deny" >&2
      blackhole="deny"
      ;;
  esac

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
    bind $bind_web ssl crt /etc/haproxy/certs/
    mode http

EOF

  # V2: разбор WEB-записей. Формат: "домен:порт[:path=/prefix][:опции...]".
  # Один домен без path => legacy-вид v1 (байт-в-байт). Несколько записей
  # на домен: path-правила первыми, затем общее host-правило.
  local -a w_domains=() w_ports=() w_paths=()
  local entry
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    parse_entry "$entry"
    if [ -z "$ENTRY_DOMAINS" ] || [ -z "$ENTRY_PORT" ]; then
      log_error "  ❌ Бигая запись WEB_SITES: '${entry}' (нужно 'домен:порт[:опции]')"
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
      printf "    acl host_%s hdr(host) -i %s\n" "$tag" "$o"
      printf "    acl %s path_beg %s\n" "$ptag" "${w_paths[e]}"
      printf "    use_backend bk_%s if host_%s %s\n" "$tag" "$tag" "$ptag"
    done
    # Затем общее host-правило (первая беspath-запись домена)
    for ((e = 0; e < ${#w_domains[@]}; e++)); do
      [ "${w_domains[e]}" = "$o" ] || continue
      [ -z "${w_paths[e]}" ] || continue
      tag=$(web_tag_for "$o" "${w_ports[e]}" "$e")
      printf "    acl host_%s hdr(host) -i %s\n" "$tag" "$o"
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
    printf "    server %s 127.0.0.1:%s\n" "$tag" "${w_ports[e]}"
    printf "\n"
  done

  if [ "$blackhole" = "tarpit" ]; then
    printf "backend bk_blackhole\n    mode http\n    http-request tarpit\n"
  else
    printf "backend bk_blackhole\n    mode http\n    http-request deny\n"
  fi
  # Волна 1: кастомные вставки бэкендов (если есть custom/web-backend-*.cfg)
  emit_custom "web-backend-*.cfg"
}

generate_configs() {
  printf "  ${CYAN}📝 Генерирую конфиги...${NC}\n"

  # Загружаем данные из sites.conf
  if [ -f "$SITES_CONF" ]; then
    WEB_SITES=()
    REALITY_SITES=()
    GLOBAL_OPTS=()
    if ! source "$SITES_CONF" 2>/dev/null; then
      log_error "  ❌ Ошибка чтения ${SITES_CONF}"
      return 1
    fi
  fi

  # Волна 1: бэкап текущего состояния до перезаписи
  backup_now "pre-generate" >/dev/null

  # Волна 1: генерация во временные файлы + валидация + атомарное перемещение.
  # Сломанный конфиг никогда не попадает в stream/haproxy.cfg и web/haproxy.cfg.
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

  if ! validate_cfg "$tmp_stream"; then
    log_error "  ❌ stream-конфиг не прошёл валидацию (старый файл не тронут)"
    return 1
  fi

  if ! validate_cfg "$tmp_web"; then
    log_error "  ❌ web-конфиг не прошёл валидацию (старый файл не тронут)"
    return 1
  fi

  mkdir -p "${HAPROXY_DIR}/stream" "${HAPROXY_DIR}/web"
  mv "$tmp_stream" "${HAPROXY_DIR}/stream/haproxy.cfg"
  mv "$tmp_web" "${HAPROXY_DIR}/web/haproxy.cfg"

  log_info "  ✅ Конфиги обновлены (бэкап предыдущего — в .backup/)"
}

# Волна 2: предпросмотр — что изменит перегенерация, не трогая живые файлы.
# Возврат: 0 — различий нет, 1 — есть различия (показывает diff).
preview_configs() {
  if [ ! -f "$SITES_CONF" ]; then
    log_error "❌ sites.conf не найден"
    return 1
  fi
  WEB_SITES=()
  REALITY_SITES=()
  GLOBAL_OPTS=()
  if ! source "$SITES_CONF" 2>/dev/null; then
    log_error "  ❌ Ошибка чтения ${SITES_CONF}"
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  generate_stream_config > "$tmpdir/stream.cfg" || return 1
  generate_web_config > "$tmpdir/web.cfg" || return 1
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
  return "$diffs"
}
