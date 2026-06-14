#!/bin/sh

cd "$(dirname "$0")/.."

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│           🔄 ОБНОВЛЕНИЕ КОНФИГОВ            │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

echo -e "  ${CYAN}📥 Скачиваю свежие конфиги...${NC}"
curl -sL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o /tmp/crowdsec-lapi.tar.gz

echo -e "  ${CYAN}📦 Обновляю файлы...${NC}"
tar xzf /tmp/crowdsec-lapi.tar.gz \
  --strip=3 \
  --wildcards \
  '*/crowdsec/crowdsec_lapi/compose-example.yml' \
  '*/crowdsec/crowdsec_lapi/.env.example' \
  '*/crowdsec/crowdsec_lapi/config/*' \
  '*/crowdsec/crowdsec_lapi/setup-node.sh' \
  '*/crowdsec/crowdsec_lapi/update.sh' \
  '*/crowdsec/crowdsec_lapi/traffic-guard.sh' \
  '*/crowdsec/crowdsec_lapi/traffic-guard.cfg' \
  '*/crowdsec/crowdsec_lapi/blocklists/*'

mkdir -p scripts
for f in setup-node.sh update.sh traffic-guard.sh traffic-guard.cfg; do
  [ -f "$f" ] && mv "$f" scripts/
done
[ -d blocklists ] && mv blocklists scripts/

chmod +x scripts/*.sh 2>/dev/null
rm -f /tmp/crowdsec-lapi.tar.gz

echo ""
echo -e "  ${GREEN}✅ Готово${NC}"
echo ""
echo -e "  ${YELLOW}⚠️  Не забудь скопировать шаблон:${NC}"
echo -e "     ${CYAN}cp compose-example.yml compose.yml${NC}"
