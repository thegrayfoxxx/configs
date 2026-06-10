#!/bin/sh

cd "$(dirname "$0")"

echo "Скачиваю свежие конфиги..."
curl -sL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o /tmp/crowdsec-node.tar.gz

echo "Обновляю файлы..."
tar xzf /tmp/crowdsec-node.tar.gz \
  --strip=3 \
  --wildcards \
  '*/crowdsec/crowdsec_node/compose-example.yml' \
  '*/crowdsec/crowdsec_node/.env.example' \
  '*/crowdsec/crowdsec_node/config/*' \
  '*/crowdsec/crowdsec_node/update.sh'

chmod +x update.sh 2>/dev/null

rm -f /tmp/crowdsec-node.tar.gz

echo "Готово."
