#!/bin/sh

cd "$(dirname "$0")"

echo "Скачиваю свежие конфиги..."
curl -sL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o /tmp/crowdsec-lapi.tar.gz

echo "Обновляю файлы..."
tar xzf /tmp/crowdsec-lapi.tar.gz \
  --strip=3 \
  --wildcards \
  '*/crowdsec/crowdsec_lapi/compose-example.yml' \
  '*/crowdsec/crowdsec_lapi/.env.example' \
  '*/crowdsec/crowdsec_lapi/setup-node.sh' \
  '*/crowdsec/crowdsec_lapi/update.sh' \
  '*/crowdsec/crowdsec_lapi/config/*'

chmod +x setup-node.sh update.sh 2>/dev/null

rm -f /tmp/crowdsec-lapi.tar.gz

echo "Готово."
