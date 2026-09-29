# twin-frontends — два stream-уха + один web

Сценарий для разделения трафика: публичное ухо (`public`, интернет)
и внутреннее (`internal`, офис/loopback) слушают разные адреса, у каждого
свои SNI-маршруты. Маршрут без `frontend=` слышен в оба уха; глобальный
`sni=default` страхует оба фронтенда.

## Схема

```mermaid
flowchart LR
    PUB["Интернет:443"] --> FE_PUB["stream/ft_public<br/>bind *:443"]
    OFF["Офис/loopback"] --> FE_INT["stream/ft_internal<br/>bind 127.0.0.1:4443"]
    FE_PUB -->|SNI = public| BP["bk_pub<br/>127.0.0.1:10443"]
    FE_INT -->|SNI = internal| BI["bk_int<br/>127.0.0.1:10444"]
    FE_PUB -->|sni=default| WEB["web/ft_main<br/>терминация"]
    FE_INT -->|sni=default| WEB
    WEB -->|Host| SITES["bk_* сайтов"]
    WEB -->|чужой Host| BH["bk_blackhole<br/>403"]
```

## Что получишь

* `STREAM_FRONTENDS`: `public` + `internal` с разными bind.
* `WEB_FRONTENDS`: один `main`.
* `STREAM_ROUTES`: публичный и внутренний маршруты со своей областью
  + глобальный `sni=default → web` (резолвится на оба фронтенда).
* `WEB_ROUTES`: сайты из визарда (видны везде — области нет).

## Проверки после применения

* SNI публичного маршрута на внутреннем адресе — нет совпадения,
  падает в дефолт (а не в чужой backend).
* `haproxy -c` зелёный (раздел 6 меню).
