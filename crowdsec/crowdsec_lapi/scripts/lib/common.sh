# shellcheck shell=bash
# Общие утилиты для скриптов CrowdSec LAPI Manager

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- ОЧИСТКА ЭКРАНА ---
clear_screen() {
  tput clear 2>/dev/null || true
}

# --- ЛОГГЕРЫ ---
log_info()  { printf "${GREEN}%s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
log_error() { printf "${RED}%s${NC}\n" "$*"; }
die()       { log_error "$*"; exit 1; }

# --- ШАПКИ МЕНЮ ---
print_header() {
  local title="$1"
  local icon="${2:-🛠️}"
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│  ${icon}  %-37s│${NC}\n" "$title"
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

# --- ПРОВЕРКА КОНТЕЙНЕРА LAPI ---
lapi_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec-lapi'
}

require_lapi() {
  if ! lapi_is_running; then
    die "❌ Контейнер crowdsec-lapi не запущен. Сначала: docker compose up -d"
  fi
}
