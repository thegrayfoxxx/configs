#!/bin/sh

cd "$(dirname "$0")/.."

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│         🔄 ОБНОВЛЕНИЕ КОНФИГОВ НОДЫ        │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

echo -e "  ${CYAN}📥 Скачиваю свежие конфиги...${NC}"
curl -sL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o /tmp/crowdsec-node.tar.gz

echo -e "  ${CYAN}📦 Обновляю файлы...${NC}"
tar xzf /tmp/crowdsec-node.tar.gz \
  --strip=3 \
  --wildcards \
  '*/crowdsec/crowdsec_node/compose-example.yml' \
  '*/crowdsec/crowdsec_node/.env.example' \
  '*/crowdsec/crowdsec_node/config/*' \
  '*/crowdsec/crowdsec_node/update.sh'

# Перемещаем скрипты в scripts/
mkdir -p scripts
[ -f update.sh ] && mv update.sh scripts/
chmod +x scripts/update.sh 2>/dev/null

rm -f /tmp/crowdsec-node.tar.gz

echo ""
echo -e "  ${GREEN}✅ Готово${NC}"
echo ""
echo -e "  ${YELLOW}⚠️  Не забудь скопировать шаблон, если нужно:${NC}"
echo -e "     ${CYAN}cp compose-example.yml compose.yml${NC}"
echo -e "     ${CYAN}cp .env.example .env${NC}"
