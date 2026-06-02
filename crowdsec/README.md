Команда для регистрации агента по паролю на LAPI
Генерация пароля: openssl rand -base64 32

docker exec crowdsec-lapi cscli machines add --name agent-name --password SuperSecurePassword123! --force

Команда для регистрации баунсера в LAPI

docker exec crowdsec-lapi cscli bouncers add --name bouncer-name
