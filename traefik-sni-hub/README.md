# Traefik SNI Hub

Модульный стек для обхода блокировок на одном VPS, одном порту (443).

## Что это

Набор скриптов для быстрого развёртывания инструментов обхода блокировок на VPS. Вся система строится вокруг **Traefik** — реверс-прокси, который принимает входящие подключения на порт 443 и распределяет их по сервисам на основе **SNI** (Server Name Indication). Снаружи трафик выглядит как обычный HTTPS.

Каждый сервис — отдельный скрипт. Ставится одной командой, не ломает остальные.

## Что входит

| Скрипт | Что ставит | Зачем |
|---|---|---|
| `install.sh` | Traefik | Базовый SNI-роутер на порту 443. Без него ничего не работает. |
| `install-mtproto.sh` | MTProto Proxy (Fake TLS) | Прокси для Telegram. Маскирует трафик под обычный HTTPS к выбранному домену. Работает только для Telegram — остальной трафик не затрагивается. |
| `install-decoy.sh` | Сайт-заглушка (nginx) | Логин-форма, которая отдаётся при любом незнакомом SNI или прямом заходе по IP. Делает сервер неотличимым от обычного VPS с админкой. Let's Encrypt сертификат из коробки. |

## Как это работает

```
Telegram   → :443 → Traefik → (SNI = tg.example.com) → MTProto Proxy → Telegram серверы
DPI-проба  → :443 → Traefik → (SNI = любой другой)   → nginx         → страница логина
```

Traefik читает SNI из TLS ClientHello и направляет соединение в нужный контейнер. TLS при этом **не терминируется** — Traefik работает в режиме passthrough.

Для стороннего наблюдателя (DPI / ТСПУ) это обычное HTTPS-соединение с легитимным доменом.

## Установка

```bash
REPO="https://raw.githubusercontent.com/wooogoblin/vpntools/master/traefik-sni-hub"

# 1. Traefik (база) — ставится первым
curl -sSL ${REPO}/install.sh | sudo bash

# 2. MTProto Proxy для Telegram
curl -sSL ${REPO}/install-mtproto.sh | sudo bash

# 3. Сайт-заглушка (рекомендуется)
curl -sSL ${REPO}/install-decoy.sh | sudo bash
```

При установке MTProto скрипт предложит выбрать домен маскировки (SNI) в интерактивном меню, либо ввести свой.

## Выбор SNI-домена

SNI — это домен, который будет виден в TLS-хендшейке. DPI видит его и думает, что вы заходите на обычный сайт.

**Свой домен (рекомендуется).** Если у вас есть домен, привязанный к этому же VPS — лучший вариант. IP совпадает с DNS-записью, никаких подозрений. Идеально подходит субдомен, например `tg.example.com`.

**Популярные RU-домены** (`ya.ru`, `sberbank.ru`, `gosuslugi.ru` и др.). Работает, но IP вашего VPS не совпадёт с реальным IP этих сайтов. Продвинутый DPI теоретически может это заметить, на практике пока не проверяют.

Скрипт поддерживает оба варианта — выберите в меню при установке или передайте через переменную:

```bash
curl -sSL ${REPO}/install-mtproto.sh | sudo FAKE_TLS_DOMAIN=tg.example.com bash
```

## Удаление

```bash
REPO="https://raw.githubusercontent.com/wooogoblin/vpntools/master/traefik-sni-hub"

# Только MTProto (Traefik останется)
curl -sSL ${REPO}/uninstall-mtproto.sh | sudo bash

# Только заглушку
curl -sSL ${REPO}/uninstall-decoy.sh | sudo bash

# Всё целиком (Traefik + все сервисы)
curl -sSL ${REPO}/uninstall.sh | sudo bash
```

## Управление

```bash
# Логи Traefik
cd /opt/mtproto-proxy && docker compose logs -f

# Логи MTProto
cd /opt/mtproto-proxy/services/mtproto && docker compose logs -f

# Обновить образы
cd /opt/mtproto-proxy && docker compose pull && docker compose up -d
cd /opt/mtproto-proxy/services/mtproto && docker compose pull && docker compose up -d
```

## Структура на сервере

```
/opt/mtproto-proxy/
├── docker-compose.yml              # Traefik
├── traefik/
│   ├── static.yml                  # Точка входа :443
│   └── dynamic/
│       ├── mtproto.yml             # SNI-роут → MTProto
│       └── decoy.yml               # Catch-all → заглушка
└── services/
    ├── mtproto/
    │   ├── docker-compose.yml      # Контейнер mtg
    │   └── .env                    # Секрет + порт
    └── decoy/
        ├── docker-compose.yml      # Контейнер nginx
        ├── nginx.conf
        ├── certs/                  # TLS-сертификат
        └── html/
            └── index.html          # Страница логина
```

## Добавить свой сервис

Архитектура модульная — каждый сервис живёт в отдельном `install-<n>.sh`. Чтобы добавить новый:

1. Создать `services/<n>/docker-compose.yml` с `networks: proxy: external: true`
2. Положить SNI-роут в `traefik/dynamic/<n>.yml`
3. Запустить `docker compose up -d`

Traefik подхватывает новые файлы в `dynamic/` автоматически.

## Требования

- Linux (Ubuntu 20.04+ / Debian 11+)
- Порт 443 свободен
- root-доступ

Docker и docker-compose-plugin устанавливаются автоматически при необходимости.