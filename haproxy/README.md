# HAProxy

TLS-прокси для маршрутизации трафика по SNI.

## Структура

```
haproxy/
├── compose.yml
├── stream/
│   └── haproxy.cfg
└── web/
    ├── haproxy.cfg
    └── certs/
```

## Сервисы

| Сервис | Описание |
|--------|----------|
| `haproxy-stream` | HAProxy Alpine, L4 прокси на порту 443 (SNI-маршрутизация) |
| `haproxy-web` | HAProxy Alpine, веб-сервер на порту 8443 (SSL-терминация) |
| `acme` | Автоматическое обновление TLS-сертификатов |

## Как работает

```
Клиент:443 → haproxy-stream (L4, SNI) → haproxy-web:8443 (SSL termination) → бэкенд
```

- Слушает `*:443`
- Инспектирует SNI из ClientHello
- Если SNI = `google.com` / `www.google.com` → пробрасывает на `127.0.0.1:10443` (xray, L4)
- Всё остальное → haproxy-web:8443 (L7 + SSL termination)
- В haproxy-web: известные домены → бэкенды, неизвестные → blackhole (HTTP 403)

## Подготовка сервера

HAProxy запущен от root в контейнере (`user: root` в compose) — это позволяет биндить порт 443 без дополнительных настроек.

Альтернатива — убрать `user: root` и разрешить привилегированные порты на хосте:

```bash
sysctl -w net.ipv4.ip_unprivileged_port_start=443
```

## Запуск

```bash
docker compose up -d
```

## Получение сертификата

Из директории `haproxy/`:

Выпуск сертификата:

```bash
docker compose exec acme acme.sh --issue -d "example.com" --standalone --httpport 80 --email "mailname@example.com"
```

Деплой в HAProxy (объединяет key + fullchain в один PEM):

```bash
docker compose exec acme acme.sh --deploy -d "example.com" --deploy-hook haproxy
```

ENV переменные для deploy hook заданы в compose.yml:
- `DEPLOY_HAPROXY_PEM_PATH=/etc/haproxy/certs` — путь для PEM-файлов
- `DEPLOY_HAPROXY_RELOAD` — перезапуск haproxy-web через Docker socket API

При автоматическом обновлении (каждые 30 дней) deploy выполнится автоматически.

## Конфигурация

**Конфиги HAProxy:**
- `stream/haproxy.cfg` — L4 прокси, SNI-маршрутизация на порту 443
- `web/haproxy.cfg` — веб-сервер, SSL-терминация на порту 8443, маршрутизация по host

**Volumes:**
- `acme:/acme.sh` — внутренние данные acme.sh (аккаунт, сертификаты)
- `./web/certs:/etc/haproxy/certs` — выпущенные сертификаты (PEM-файлы)

**Сеть:** все сервисы используют `network_mode: host`

**ENV для acme:**
- `DEPLOY_HAPROXY_PEM_PATH=/etc/haproxy/certs` — путь для PEM-файлов
- `DEPLOY_HAPROXY_RELOAD` — перезапуск haproxy-web через Docker socket API
