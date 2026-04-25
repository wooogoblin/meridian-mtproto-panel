# Traefik SNI Hub

Модульный стек для обхода блокировок на одном VPS, одном порту (443).

## Что это

Набор скриптов для быстрого развёртывания инструментов обхода блокировок на VPS. Вся система строится вокруг **Traefik** — реверс-прокси, который принимает входящие подключения на порт 443 и распределяет их по сервисам на основе **SNI** (Server Name Indication). Снаружи трафик выглядит как обычный HTTPS.

Каждый сервис — отдельный скрипт. Ставится одной командой, не ломает остальные.

## Что входит

| Скрипт | Что ставит | Зачем |
|---|---|---|
| `install.sh` | Traefik | Базовый SNI-роутер на порту 443. Без него ничего не работает. |
| `install-mtproto.sh` | [Teleproxy](https://github.com/teleproxy/teleproxy) (Fake TLS) | Прокси для Telegram. DPI-устойчивая маскировка: Dynamic Record Sizing, domain fronting, anti-replay, ServerHello фрагментация. |
| `install-panel.sh` | Meridian Panel (nginx + Python backend) | Веб-панель управления пользователями. Страница авторизации отдаётся при любом незнакомом SNI или прямом заходе по IP — сервер выглядит как обычный VPS с админкой. |

## Как это работает

```
Telegram   → :443 → Traefik → (SNI = tg.example.com) → Teleproxy → Telegram серверы
DPI-проба  → :443 → Traefik → (SNI = tg.example.com) → Teleproxy → реальный сайт (domain fronting)
Браузер    → :443 → Traefik → (SNI = любой другой)   → nginx     → страница входа в панель
```

Traefik читает SNI из TLS ClientHello и направляет соединение в нужный контейнер. TLS при этом **не терминируется** — Traefik работает в режиме passthrough.

Teleproxy дополнительно защищает от обнаружения: Dynamic Record Sizing имитирует реальный TLS slow-start, domain fronting прозрачно проксирует невалидные подключения на настоящий сайт, anti-replay отсекает повторные хендшейки.

## Установка

```bash
REPO="https://raw.githubusercontent.com/SergeyNakhankov/vpntools/master/traefik-sni-hub"

# 1. Traefik (база) — обязательно первым
curl -sSL ${REPO}/install.sh | sudo bash

# 2. MTProto прокси для Telegram
curl -sSL ${REPO}/install-mtproto.sh | sudo bash

# 3. Панель управления (страница входа + веб-интерфейс + backend)
curl -sSL ${REPO}/install-panel.sh | sudo bash
```

Порядок важен: Traefik → MTProto → Панель.

`install-panel.sh` автоматически:
- переводит Teleproxy с `.env`-конфига на TOML (мультипользовательский режим)
- настраивает domain fronting на локальный nginx
- генерирует логин и пароль, выводит их **один раз**

## Выбор SNI-домена

SNI — это домен, который будет виден в TLS-хендшейке. DPI видит его и думает, что вы заходите на обычный сайт.

**Свой домен (рекомендуется).** Если у вас есть домен, привязанный к этому же VPS — лучший вариант. IP совпадает с DNS-записью, никаких подозрений. Идеально подходит субдомен, например `tg.example.com`.

**Популярные RU-домены** (`ya.ru`, `sberbank.ru`, `gosuslugi.ru` и др.). Работает, но IP вашего VPS не совпадёт с реальным IP этих сайтов. Продвинутый DPI теоретически может это заметить.

Скрипт поддерживает оба варианта — выберите в меню при установке или передайте через переменную:

```bash
curl -sSL ${REPO}/install-mtproto.sh | sudo FAKE_TLS_DOMAIN=tg.example.com bash
```

## Панель управления

После установки панель доступна по адресу `https://<ваш-домен>/panel/`.

**Сброс пароля:**
```bash
curl -sSL ${REPO}/install-panel.sh | sudo bash -s -- --reset-password
```

**Что умеет панель:**
- Добавлять и удалять пользователей (каждый получает уникальный MTProto-секрет)
- Включать / отключать пользователей без перезапуска контейнера (SIGHUP hot-reload)
- Показывать количество активных соединений
- Генерировать `tg://` ссылки и секреты для каждого пользователя

## Удаление

```bash
REPO="https://raw.githubusercontent.com/SergeyNakhankov/vpntools/master/traefik-sni-hub"

# Только MTProto (Traefik и панель останутся)
curl -sSL ${REPO}/uninstall-mtproto.sh | sudo bash

# Только панель (Traefik и MTProto останутся)
curl -sSL ${REPO}/uninstall-panel.sh | sudo bash

# Всё целиком (Traefik + все сервисы + данные панели)
curl -sSL ${REPO}/uninstall.sh | sudo bash
```

## Управление

```bash
# Логи Traefik
cd /opt/mtproto-proxy && docker compose logs -f

# Логи MTProto
cd /opt/mtproto-proxy/services/mtproto && docker compose logs -f

# Логи панели
cd /opt/mtproto-proxy/services/panel && docker compose logs -f meridian-backend
cd /opt/mtproto-proxy/services/panel && docker compose logs -f decoy

# Перезапуск
cd /opt/mtproto-proxy/services/panel && docker compose restart
```

## Структура репозитория

```
traefik-sni-hub/
├── panel/
│   ├── login/
│   │   ├── index.html          # Страница входа (Meridian login)
│   │   └── nginx.conf          # nginx: login + панель SPA + proxy → backend
│   ├── src/                    # React SPA (Vite)
│   ├── dist/                   # Pre-built фронтенд (коммитится в репо)
│   └── backend/                # FastAPI + uvicorn
│       ├── Dockerfile
│       ├── requirements.txt
│       ├── main.py
│       ├── auth.py
│       ├── users.py
│       └── teleproxy_config.py
├── install.sh                  # Traefik
├── install-mtproto.sh          # MTProto (Teleproxy)
├── install-panel.sh            # Панель управления
├── uninstall-mtproto.sh
├── uninstall-panel.sh
├── uninstall.sh
└── README.md
```

## Структура на сервере

```
/opt/mtproto-proxy/
├── docker-compose.yml              # Traefik
├── traefik/
│   ├── static.yml                  # Точка входа :443
│   └── dynamic/
│       ├── mtproto.yml             # SNI-роут → Teleproxy
│       └── decoy.yml               # Catch-all → панель
└── services/
    ├── mtproto/
    │   ├── docker-compose.yml      # Контейнер Teleproxy
    │   ├── .env                    # PROXY_PORT (после миграции на TOML)
    │   └── teleproxy.toml          # Секреты пользователей (после install-panel.sh)
    └── panel/
        ├── docker-compose.yml      # decoy (nginx) + meridian-backend (FastAPI)
        ├── nginx.conf
        ├── .env                    # SERVER_IP, EE_DOMAIN_RAW, DATA_DIR, TOML_PATH
        ├── certs/                  # TLS-сертификат
        ├── html/
        │   ├── index.html          # Страница входа
        │   └── panel/              # React SPA
        └── backend/                # Python-файлы backend

/opt/meridian/
├── config.json                     # { username, password_hash, jwt_secret }
├── users.json                      # Метаданные пользователей панели
└── .venv/                          # Изолированный Python venv (bcrypt, toml)
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

Скрипты сами доставляют недостающие пакеты:
- `install.sh` — Docker + docker-compose-plugin + xxd
- `install-panel.sh` — python3, python3-pip, python3-venv, build-essential, curl, dnsutils, openssl + изолированный venv в `/opt/meridian/.venv` с `bcrypt` и `toml` (никакого глобального pip)
