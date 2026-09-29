# xray-direct — Xray на :443, haproxy-web только как таргет

> Управляем только HAProxy. Xray/nginx/static — отдельно, тут только стык (порты/домены).

Xray (`VLESS + reality + vision`) слушает `:443` напрямую. Не-reality трафик
Xray заворачивает в fallback-таргет — наш `haproxy-web` на `127.0.0.1:8443`
с настоящим LE-сертификатом, а тот уже отдает заглушку. Stream-сервис выключен.

## Схема

```mermaid
flowchart LR
    CLIENT["Клиент:443"] --> XRAY["Xray<br/>:443 reality"]
    XRAY -->|reality-клиент| OK["Xray OK"]
    XRAY -->|fallback| WEB["web/ft_https_terminated<br/>127.0.0.1:8443 TLS"]
    WEB -->|Host = таргет| STUB["bk_stub<br/>заглушка"]
    WEB -->|чужой Host| BH["bk_blackhole"]
```

## Что получишь

- `WEB_ROUTES`: одна запись `host=STUB_DOMAIN → stub`.
- `GLOBAL_OPTS`: `bind_web=127.0.0.1:8443` (только loopback — наружу его не видно),
  таймауты по профилю, без PROXY-пары (Xray-fallback PROXY не шлет, `xver:0`).

## Требования со стороны Xray (важно!)

1. Inbound: `bind *:443`, `serverNames=[STUB_DOMAIN]`, `target=127.0.0.1:8443`
   (raw TCP fallback, SNI сохраняется — web отдаст правильный серт).
2. Если включишь в Xray `xver` (PROXY в таргет) — включи и тут `web_accept_proxy=on`
   руками (пресет его не ставит). Оба флага сразу, иначе рассинхрон.
3. LE-сертификат для `STUB_DOMAIN` выпускается как обычно через `:80`
   (`:443` занят Xray — выпуску не мешает, нужен только `:80`).
4. Заглушка за web — обычный nginx/static на `127.0.0.1:STUB_PORT`.

## Проверки после применения

- Браузер без ключа → заглушка 200 (через Xray-fallback → web).
- Клиент с ключом ходит.
- `haproxy -c` зелёный; stream-контейнер остановлен/выключен.
