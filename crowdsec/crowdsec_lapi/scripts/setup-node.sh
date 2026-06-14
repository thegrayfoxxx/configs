#!/bin/bash
set -u

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CSCLI="docker exec crowdsec-lapi cscli"

cd "$(dirname "$0")"

echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│         🖥️  РЕГИСТРАЦИЯ УДАЛЁННОЙ НОДЫ     │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

# --- ПРОВЕРКА LAPI ---
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec-lapi'; then
  echo -e "  ${RED}❌ Контейнер crowdsec-lapi не запущен${NC}"
  echo -e "  Сначала запусти LAPI: ${CYAN}docker compose up -d${NC}"
  exit 1
fi

# --- ИМЯ НОДЫ ---
if [ -n "${1:-}" ]; then
  NODE_NAME="$1"
else
  echo -ne "  ${CYAN}👉 Имя ноды (например, us6):${NC} "
  read -r NODE_NAME < /dev/tty
fi

[ -z "$NODE_NAME" ] && NODE_NAME="node"
NODE_NAME="${NODE_NAME//$'\r'/}"

AGENT_NAME="$NODE_NAME-agent"
BOUNCER_NAME="$NODE_NAME-bouncer"

# --- API_URL ---
if [ -f ../.env ]; then
  API_URL=$(grep -oP '^API_URL=\K.*' ../.env)
fi
if [ -z "$API_URL" ]; then
  if [ -f ../.env.example ]; then
    API_URL=$(grep -oP '^API_URL=\K.*' ../.env.example)
  fi
fi
if [ -z "$API_URL" ]; then
  echo -e "  ${YELLOW}⚠️  API_URL не найден ни в .env, ни в .env.example${NC}"
  echo -e "  ${YELLOW}   Используется: ${CYAN}https://crowdsec.example.com${NC}"
  echo -e "  ${YELLOW}   Не забудь изменить в команде для ноды!${NC}"
  API_URL="https://crowdsec.example.com"
fi

AGENT_PASSWORD=$(openssl rand -base64 32)
TZ_CMD='$(timedatectl show --property=Timezone --value)'

# --- РЕГИСТРАЦИЯ ---
echo ""
echo -e "  ${CYAN}📝 Регистрирую агента '${AGENT_NAME}'...${NC}"
if ! $CSCLI machines add "$AGENT_NAME" --password "$AGENT_PASSWORD" --force > /dev/null 2>&1; then
  echo -e "  ${RED}❌ Ошибка регистрации агента${NC}"
  echo -e "  Проверь что LAPI запущен и доступен"
  exit 1
fi
echo -e "  ${GREEN}  ✅ Агент зарегистрирован${NC}"

echo ""
echo -e "  ${CYAN}📝 Регистрирую баунсера '${BOUNCER_NAME}'...${NC}"
API_KEY=$($CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null)
if [ -z "$API_KEY" ]; then
  echo -e "  ${RED}❌ Ошибка регистрации баунсера${NC}"
  exit 1
fi
echo -e "  ${GREEN}  ✅ Баунсер зарегистрирован${NC}"

ENV_CMD="printf '%s\n' \"API_URL=$API_URL\" \"TZ=$TZ_CMD\" \"AGENT_USERNAME=$AGENT_NAME\" \"AGENT_PASSWORD=$AGENT_PASSWORD\" \"API_KEY=$API_KEY\" > .env"

echo ""
echo -e "${GREEN}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  ✅  Готово! Скопируй подходящий вариант на ноду           │${NC}"
echo -e "${GREEN}└────────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${YELLOW}═══ 1. С НУЛЯ (на ноде ещё ничего нет) ═══${NC}"
echo ""
echo -e "${CYAN}curl -L https://github.com/thegrayfoxxx/configs/archive/main.tar.gz | tar xz --wildcards --strip=2 '*/crowdsec/crowdsec_node' && cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $ENV_CMD && docker compose up -d${NC}"
echo ""

echo -e "${YELLOW}═══ 2. РЕПОЗИТОРИЙ УЖЕ СКАЧАН ═══${NC}"
echo ""
echo -e "${CYAN}cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $ENV_CMD && docker compose up -d${NC}"
echo ""

echo -e "${YELLOW}═══ 3. ТОЛЬКО ОБНОВИТЬ .ENV ═══${NC}"
echo ""
echo -e "${CYAN}cd crowdsec_node && $ENV_CMD && docker compose up -d${NC}"
echo ""
