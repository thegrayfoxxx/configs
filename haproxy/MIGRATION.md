# Миграция sites.conf v1/v2 → v3

v3 — нейтральная модель: `STREAM_ROUTES` (SNI → backend) + `WEB_ROUTES`
(Host → backend) + явный `sni=default`. Слов `reality/xray` в формате
и скриптах больше нет — конкретика живет только в `presets/`.

Семантика сохраняется 1:1: SNI/порты/PROXY/path мапятся как есть, дефолт
`stream → web` дописывается явно из `bind_web`. Проверено e2e-тестом
(`test_migrate.sh`: мигрированный v1-файл генерирует конфиги с той же
семантикой — те же SNI, порты и бэкенды).

Файлы v1/v2 продолжают читаться (автоконверсия в памяти при `load`),
но любой `save` пишет уже v3. Миграция лишь фиксирует это в файле.

## За 3 команды

```bash
cd haproxy
./scripts/commands/migrate.sh --dry-run   # 1. посмотреть, что получится (ничего не пишет)
./haproxy.sh → раздел 6 → пункт 3 (миграция)  # 2. применить (спросит подтверждение, сделает бэкап pre-migrate-v3)
./haproxy.sh → раздел 6 → пункт 1 (перегенерировать) # 3. применить конфиги (покажет diff, спросит подтверждение)
```

## Что меняется в файле

До (v1/v2):

```bash
ACME_EMAIL="mail@example.com"
WEB_SITES=( "site.com:8080" )
REALITY_SITES=( "vpn.com:10443" )
```

После (v3) — то же плюс явный default и новые имена массивов:

```bash
ACME_EMAIL="mail@example.com"
STREAM_ROUTES=(
  "sni=vpn.com to=127.0.0.1:10443 proxy=off name=sni-1"
  "sni=default to=127.0.0.1:8443 proxy=off name=web"
)
WEB_ROUTES=(
  "host=site.com to=127.0.0.1:8080"
)
GLOBAL_OPTS=(
  "timeout_connect=5s"
  "timeout_client=50s"
  "timeout_server=50s"
  "bind_stream=*:443"
  "bind_web=*:8443"
  "blackhole=deny"
)
```

Имена бэкендов в сгенерированных `haproxy.cfg` меняются
(`bk_xray` → `bk_sni-1`, `bk_haproxy_web` → `bk_web`) — это косметика,
маршрутизация та же. Проверь разделом 6 (diff покажет только переименования).

## Откат

Миграция кладёт бэкап в `.backup/<дата>-pre-migrate-v3/`. Откат: раздел 6
(«Конфиги и бэкапы», пункт 5 «Бэкапы и откат») → выбрать `pre-migrate-v3` →
перезапустить сервисы (раздел 5).

## Дальше (опционально)

После миграции можно точечно включать фичи правкой `GLOBAL_OPTS`
(примеры — в `sites.conf.example`): таймауты `1h`, `bind_web=127.0.0.1`,
`tarpit`, PROXY-пару, path-правила (`host=... path=/prefix`),
per-entry PROXY (`proxy=v2` в записи — бэкенд должен его читать!).

## Фронтенды и бэкенды (без миграции)

Именованные фронтенды (`STREAM_FRONTENDS`/`WEB_FRONTENDS`) и ящики
(`STREAM_BACKENDS`/`WEB_BACKENDS`) — аддитивные фичи: файлы без этих массивов
работают как раньше (один фронтенд из `bind_*`, адреса инлайн через `to=`),
миграция не нужна. Подробности — разделы «Фронтенды» и «Бэкенды» в `README.md`,
готовые сценарии — пресеты `web-direct`, `xray-direct`, `stream-vision`
(старые `twin-frontends`, `reality-selfsteal`, `xhttp-path-split`, `multi-site-l7`,
`xhttp-selfsteal` удалены: `twin` делается через `frontend=` вручную, остальные покрыты
опциями `WEB_MODE`/`SELFSTEAL` новых баз; при вводе старого имени пресет подскажет новое).
