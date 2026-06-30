#!/bin/bash
# shellcheck shell=bash
# Общие утилиты для скриптов HAProxy Manager

# --- ЦВЕТА ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# --- ПУТИ ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAPROXY_DIR="$(cd "${LIB_DIR}/../.." && pwd)"
SITES_CONF="${HAPROXY_DIR}/sites.conf"

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
  if [ -n "$icon" ]; then
    printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
    printf "${CYAN}│${NC}  ${icon}  %s\n" "$title"
    printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  else
    printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
    printf "${CYAN}│${NC}  %s\n" "$title"
    printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  fi
  printf "\n"
}

print_status_box() {
  local green_on="${GREEN}●${NC}"
  local red_off="${RED}●${NC}"

  # Контейнеры
  local stream_status="$red_off"
  local web_status="$red_off"
  local acme_status="$red_off"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-stream' && stream_status="$green_on"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-web' && web_status="$green_on"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'acme' && acme_status="$green_on"

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
    for pem in "${HAPROXY_DIR}/web/certs"/*.pem; do
      [ -f "$pem" ] || continue
      cert_count=$((cert_count + 1))
      local expiry=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
      local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
      local now_epoch=$(date +%s)
      local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      if [ $days_left -lt 30 ]; then
        cert_info="${YELLOW}⚠ $(basename "$pem" .pem) истекает через ${days_left}d${NC}"
      fi
    done
  fi

  # Рисуем рамку
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│${NC}  Сервисы: %b stream  %b web  %b acme\n" "$stream_status" "$web_status" "$acme_status"
  printf "${CYAN}│${NC}  Конфиг:  ${GREEN}%d${NC} сайтов  ${GREEN}%d${NC} reality\n" "$site_count" "$reality_count"
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

# --- ПРОВЕРКА КОНТЕЙНЕРОВ ---
haproxy_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy-stream'
}

require_haproxy() {
  if ! haproxy_is_running; then
    log_error "❌ Контейнеры HAProxy не запущены. Сначала: docker compose up -d"
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

interactive_setup() {
  clear_screen
  print_header "НАСТРОЙКА HAProxy" "⚙️"
  printf "  ${YELLOW}Файл sites.conf не найден. Создадим его.${NC}\n\n"

  # Email
  printf "  ${CYAN}📧 Email для сертификатов:${NC} "
  read -r acme_email < /dev/tty

  # Reality
  printf "\n  ${CYAN}🔐 Reality (xray)${NC}\n"
  printf "  ${CYAN}   Домены через пробел:${NC} "
  read -r reality_domains < /dev/tty

  local reality_port="10443"
  if [ -n "$reality_domains" ]; then
    printf "  ${CYAN}   Порт [10443]:${NC} "
    read -r reality_port < /dev/tty
    [ -z "$reality_port" ] && reality_port="10443"
  fi

  # Web sites
  printf "\n  ${CYAN}🌐 Веб-сайты${NC}\n"
  local web_sites=()
  while true; do
    printf "  ${CYAN}   Домен (Enter = готово):${NC} "
    read -r domain < /dev/tty
    [ -z "$domain" ] && break

    printf "  ${CYAN}   Порт бэкенда:${NC} "
    read -r port < /dev/tty
    if [ -z "$port" ]; then
      printf "  ${RED}   ✗ Порт обязателен${NC}\n"
      continue
    fi
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
  } > "$SITES_CONF"

  printf "\n"
  log_info "  ✓ sites.conf создан"
  log_warn "  ⚠  Проверь: ${CYAN}${SITES_CONF}${NC}"
  printf "\n"
  read -p "[Enter] для продолжения..." < /dev/tty
}

load_sites() {
  ensure_sites_conf
  source "$SITES_CONF"
}

save_sites() {
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
}

# --- ГЕНЕРАЦИЯ КОНФИГОВ ---
generate_stream_config() {
  cat << 'EOF'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend ft_https
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

EOF

  # Reality ACLs
  local first=true
  for entry in "${REALITY_SITES[@]+"${REALITY_SITES[@]}"}"; do
    local domains="${entry%%:*}"
    printf "    acl is_reality req.ssl_sni -i %s\n" "$domains"
    first=false
  done

  if [ "$first" = false ]; then
    echo "    use_backend bk_xray if is_reality"
    echo ""
  fi

  cat << 'EOF'
    default_backend bk_haproxy_web

backend bk_xray
    mode tcp
    server xray 127.0.0.1:10443

backend bk_haproxy_web
    mode tcp
    server haproxy_web 127.0.0.1:8443
EOF
}

generate_web_config() {
  cat << 'EOF'
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
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend ft_https_terminated
    bind *:8443 ssl crt /etc/haproxy/certs/
    mode http

EOF

  # Site ACLs
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    local domain="${entry%%:*}"
    local port="${entry##*:}"
    local tag="site_$(echo "$domain" | tr '.' '_')"
    printf "    acl host_%s hdr(host) -i %s\n" "$tag" "$domain"
    printf "    use_backend bk_%s if host_%s\n" "$tag" "$tag"
    printf "\n"
  done

  cat << 'EOF'
    default_backend bk_blackhole

EOF

  # Site backends
  for entry in "${WEB_SITES[@]+"${WEB_SITES[@]}"}"; do
    local domain="${entry%%:*}"
    local port="${entry##*:}"
    local tag="site_$(echo "$domain" | tr '.' '_')"
    printf "backend bk_%s\n" "$tag"
    printf "    mode http\n"
    printf "    server %s 127.0.0.1:%s\n" "$tag" "$port"
    printf "\n"
  done

  cat << 'EOF'
backend bk_blackhole
    mode http
    http-request deny
EOF
}

generate_configs() {
  printf "  ${CYAN}📝 Генерирую конфиги...${NC}\n"

  generate_stream_config > "${HAPROXY_DIR}/stream/haproxy.cfg"
  generate_web_config > "${HAPROXY_DIR}/web/haproxy.cfg"

  log_info "  ✅ Конфиги обновлены"
}
