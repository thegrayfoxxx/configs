#!/bin/sh

cd "$(dirname "$0")"

echo "Скачиваю свежие конфиги..."
curl -sL https://github.com/thegrayfoxxx/configs/archive/main.tar.gz -o /tmp/crowdsec-lapi.tar.gz

echo "Обновляю файлы..."
tar xzf /tmp/crowdsec-lapi.tar.gz \
  --strip=2 \
  --wildcards \
  '*/crowdsec/crowdsec_lapi/compose.yml' \
  '*/crowdsec/crowdsec_lapi/.env.example'

rm -f /tmp/crowdsec-lapi.tar.gz

echo "Готово."
