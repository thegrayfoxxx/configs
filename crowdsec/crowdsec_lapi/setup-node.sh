#!/bin/sh

cd "$(dirname "$0")"

if [ -n "$1" ]; then
  NODE_NAME="$1"
else
  printf "Имя ноды (например, us6): "
  read -r NODE_NAME
fi

AGENT_NAME="$NODE_NAME-agent"
BOUNCER_NAME="$NODE_NAME-bouncer"

if [ -f .env ]; then
  API_URL=$(grep -oP '^API_URL=\K.*' .env)
fi

if [ -z "$API_URL" ]; then
  API_URL=$(grep -oP '^API_URL=\K.*' .env.example 2>/dev/null || echo "https://crowdsec.example.com")
fi

AGENT_PASSWORD=$(openssl rand -base64 32)
TZ_CMD='$(timedatectl show --property=Timezone --value)'

echo "Регистрирую агента '$AGENT_NAME'..."
docker exec crowdsec-lapi cscli machines add "$AGENT_NAME" \
  --password "$AGENT_PASSWORD" \
  --force

echo "Регистрирую баунсера '$BOUNCER_NAME'..."
API_KEY=$(docker exec crowdsec-lapi cscli bouncers add "$BOUNCER_NAME" -o raw)

ENV_CMD="printf '%s\n' \"API_URL=$API_URL\" \"TZ=$TZ_CMD\" \"AGENT_USERNAME=$AGENT_NAME\" \"AGENT_PASSWORD=$AGENT_PASSWORD\" \"API_KEY=$API_KEY\" > .env"

echo ""
echo "========================================"
echo "  Скопируй подходящий вариант и выполни"
echo "  на ноде:"
echo "========================================"
echo ""

echo "--- 1. С нуля (на ноде ещё ничего нет) ---"
echo ""
echo "curl -L https://github.com/thegrayfoxxx/configs/archive/main.tar.gz | tar xz --wildcards --strip=2 '*/crowdsec/crowdsec_node' && cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $ENV_CMD && docker compose up -d"
echo ""

echo "--- 2. Репозиторий уже скачан (есть папка crowdsec_node) ---"
echo ""
echo "cd crowdsec_node && cp compose-example.yml compose.yml && cp .env.example .env && $ENV_CMD && docker compose up -d"
echo ""

echo "--- 3. Всё уже есть, нужно только обновить .env и перезапустить ---"
echo ""
echo "cd crowdsec_node && $ENV_CMD && docker compose up -d"
echo ""
