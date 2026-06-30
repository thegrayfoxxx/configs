# HAProxy

TLS-прокси для маршрутизации трафика по SNI.

## Структура

```
haproxy/
├── haproxy.sh              # главное меню
├── compose.yml
├── sites.conf              # конфигурация (создать из sites.conf.example)
├── sites.conf.example      # шаблон конфигурации
├── stream/
│   ├── haproxy.cfg         # генерируется из sites.conf
│   └── haproxy.cfg.example # шаблон
├── web/
│   ├── haproxy.cfg         # генерируется из sites.conf
│   ├── haproxy.cfg.example # шаблон
│   └── certs/
└── scripts/
    ├── lib/common.sh       # общая библиотека
    ├── site.sh             # управление сайтами
    ├── reality.sh          # управление reality
    ├── cert.sh             # управление сертификатами
    └── update.sh           # обновление из репозитория
```

## Быстрый старт

```bash
cd haproxy
./haproxy.sh
```

При первом запуске скрипт интерактивно создаст `sites.conf`:

## Меню haproxy.sh

В шапке отображается статус:
- Контейнеры (stream / web / acme)
- Количество сайтов и reality
- Количество сертификатов и сроки истечения

| Пункт | Действие |
|-------|----------|
| `1` | Управление сайтами (добавить/удалить/список) |
| `2` | Управление Reality (добавить/удалить/список) |
| `3` | Управление сертификатами (выпуск/деплой/проверка) |
| `4` | Статус сервисов |
| `5` | Перезапустить все сервисы |
| `6` | Логи |
| `7` | Обновить конфиги из репозитория |

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

### sites.conf

Конфигурация хранится в `sites.conf`. Конфиги HAProxy генерируются автоматически при добавлении/удалении сайтов и reality.

```bash
ACME_EMAIL="mailname@example.com"

# Сайты (L7, SSL termination через haproxy-web)
WEB_SITES=(
  "site1.com:11443"
  "example.com:8080"
)

# Reality (L4, напрямую на xray)
REALITY_SITES=(
  "google.com www.google.com:10443"
)
```

### Конфиги HAProxy

- `stream/haproxy.cfg` — генерируется из `sites.conf`
- `web/haproxy.cfg` — генерируется из `sites.conf`
- `*.example` — шаблоны для справки

### Управление сайтами

```bash
./haproxy.sh  # → пункт 1
```

При добавлении сайта автоматически:
1. Обновляется `sites.conf`
2. Генерируются `stream/haproxy.cfg` и `web/haproxy.cfg`
3. Выпускается SSL-сертификат
4. Деплой сертификата в HAProxy
5. Перезапуск сервисов

### Управление Reality

```bash
./haproxy.sh  # → пункт 2
```

При добавлении reality автоматически:
1. Обновляется `sites.conf`
2. Генерируются `stream/haproxy.cfg` и `web/haproxy.cfg`
3. Перезапуск сервисов

### Volumes

- `acme:/acme.sh` — внутренние данные acme.sh (аккаунт, сертификаты)
- `./web/certs:/etc/haproxy/certs` — выпущенные сертификаты (PEM-файлы)

### Сеть

Все сервисы используют `network_mode: host`

### ENV для acme

- `DEPLOY_HAPROXY_PEM_PATH=/etc/haproxy/certs` — путь для PEM-файлов
- `DEPLOY_HAPROXY_RELOAD` — перезапуск haproxy-web через Docker socket API
