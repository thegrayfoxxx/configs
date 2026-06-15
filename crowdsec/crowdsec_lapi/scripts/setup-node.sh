#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CSCLI="docker exec crowdsec-lapi cscli"

cd "$(dirname "$0")" || exit 1

# ─── ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ─────────────────────────────────

detect_api_url() {
  local url=""
  if [ -f ../.env ]; then
    url=$(grep -o '^API_URL=.*' ../.env 2>/dev/null | cut -d= -f2-)
  fi
  if [ -z "$url" ] && [ -f ../.env.example ]; then
    url=$(grep -o '^API_URL=.*' ../.env.example 2>/dev/null | cut -d= -f2-)
  fi
  if [ -z "$url" ]; then
    log_warn "  ⚠️  API_URL не найден ни в .env, ни в .env.example"
    log_warn "  ⚠️   Используется: https://crowdsec.example.com"
    log_warn "  ⚠️   Не забудь изменить в команде для ноды!"
    url="https://crowdsec.example.com"
  fi
  printf "%s" "$url"
}

register_agent() {
  local name="$1"
  local password="$2"

  printf "  ${CYAN}📝 Регистрирую агента '%s'...${NC}\n" "$name"
  if ! $CSCLI machines add "$name" --password "$password" --force > /dev/null 2>&1; then
    die "❌ Ошибка регистрации агента. Проверь что LAPI запущен и доступен."
  fi
  log_info "    ✅ Агент зарегистрирован"
}

register_bouncer() {
  local name="$1"

  printf "  ${CYAN}📝 Регистрирую баунсера '%s'...${NC}\n" "$name" >&2
  local api_key
  api_key=$($CSCLI bouncers add "$name" -o raw 2>/dev/null)
  if [ -z "$api_key" ]; then
    die "❌ Ошибка регистрации баунсера"
  fi
  log_info "    ✅ Баунсер зарегистрирован" >&2
  printf "%s" "$api_key"
}

build_env_cmd() {
  local api_url="$1" tz_cmd="$2" agent_name="$3" agent_pass="$4" api_key="$5"
  printf "printf '%%s\\\n' \"API_URL=%s\" \"TZ=%s\" \"AGENT_USERNAME=%s\" \"AGENT_PASSWORD=%s\" \"API_KEY=%s\" > .env" \
    "$api_url" "$tz_cmd" "$agent_name" "$agent_pass" "$api_key"
}

print_instructions() {
  local env_cmd="$1"

  printf "\n"
  printf "${GREEN}┌────────────────────────────────────────────────────────────┐${NC}\n"
  printf "${GREEN}│  ✅  Готово! Скопируй подходящий вариант на ноду           │${NC}\n"
  printf "${GREEN}└────────────────────────────────────────────────────────────┘${NC}\n"
  printf "\n"

  printf "${YELLOW}═══ 1. С НУЛЯ (на ноде ещё ничего нет) ═══${NC}\n"
  printf "\n"
  printf "%b\n" "${CYAN}curl -L https://github.com/thegrayfoxxx/configs/archive/main.tar.gz | tar xz --wildcards --strip=2 '*/crowdsec/crowdsec_node' && cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $env_cmd && docker compose up -d${NC}"
  printf "\n"
  printf "\n"

  printf "${YELLOW}═══ 2. РЕПОЗИТОРИЙ УЖЕ СКАЧАН ═══${NC}\n"
  printf "\n"
  printf "%b\n" "${CYAN}cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $env_cmd && docker compose up -d${NC}"
  printf "\n"
  printf "\n"

  printf "${YELLOW}═══ 3. ТОЛЬКО ОБНОВИТЬ .ENV ═══${NC}\n"
  printf "\n"
  printf "%b\n" "${CYAN}cd crowdsec_node && $env_cmd && docker compose up -d${NC}"
  printf "\n"
  printf "\n"
}

# ─── MAIN ─────────────────────────────────────────────────────

clear_screen
print_header "РЕГИСТРАЦИЯ УДАЛЁННОЙ НОДЫ" "🖥️"

# Проверка зависимостей
require_cmd openssl
require_lapi || exit 1

# Имя ноды
if [ -n "${1:-}" ]; then
  NODE_NAME="$1"
else
  printf "  ${CYAN}👉 Имя ноды (например, us6):${NC} "
  read -r NODE_NAME < /dev/tty
fi
[ -z "$NODE_NAME" ] && NODE_NAME="node"
NODE_NAME="${NODE_NAME//$'\r'/}"

AGENT_NAME="$NODE_NAME-agent"
BOUNCER_NAME="$NODE_NAME-bouncer"

# API URL
API_URL=$(detect_api_url)

# Генерация пароля
AGENT_PASSWORD=$(openssl rand -base64 32)
TZ_CMD='$(timedatectl show --property=Timezone --value)'

# Регистрация
printf "\n"
register_agent "$AGENT_NAME" "$AGENT_PASSWORD"

printf "\n"
API_KEY=$(register_bouncer "$BOUNCER_NAME")

# Команда для .env
ENV_CMD=$(build_env_cmd "$API_URL" "$TZ_CMD" "$AGENT_NAME" "$AGENT_PASSWORD" "$API_KEY")

# Вывод инструкций
print_instructions "$ENV_CMD"
