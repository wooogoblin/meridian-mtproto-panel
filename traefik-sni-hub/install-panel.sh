#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
MTPROTO_DIR="${INSTALL_DIR}/services/mtproto"
SERVICE_DIR="${INSTALL_DIR}/services/panel"
DATA_DIR="/opt/meridian"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/wooogoblin/vpntools/panel/traefik-sni-hub}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "${RED}✘${NC} $*" >&2; exit 1; }

# ─── Зависимости ────────────────────────────────────────────────────────────
VENV_DIR="${DATA_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python"
PIP_OPTS="--default-timeout=60 --retries=3 --prefer-binary"

install_system_deps() {
    info "Проверяю системные зависимости…"
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y >/dev/null 2>&1 || fail "apt-get update не удался"

    # Минимум — без компилятора. build-tools поставим только если wheel не найдётся.
    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        curl \
        dnsutils \
        openssl \
        xxd \
        || fail "Не удалось установить системные пакеты"

    ok "Системные зависимости готовы"
}

install_build_tools() {
    info "Устанавливаю инструменты сборки (нужен компилятор для wheel-less пакета)…"
    apt-get install -y python3-dev build-essential \
        || fail "Не удалось установить build-essential/python3-dev"
    ok "Build-tools установлены"
}

setup_venv() {
    if [[ ! -x "$VENV_PY" ]]; then
        info "Создаю Python venv в ${VENV_DIR}…"
        mkdir -p "${DATA_DIR}"
        python3 -m venv "$VENV_DIR" || fail "Не удалось создать venv"
    fi

    "$VENV_PY" -m pip install --upgrade pip ${PIP_OPTS} >/dev/null \
        || fail "Не удалось обновить pip в venv"

    ok "venv готов: ${VENV_DIR}"
}

# Ставит Python пакет: сначала только-wheel (быстро, без компилятора),
# при отсутствии wheel дотягивает build-tools и собирает из исходников.
install_py_pkg() {
    local pkg="$1"
    "$VENV_PY" -c "import ${pkg}" 2>/dev/null && return 0

    info "Устанавливаю Python пакет: ${pkg} (wheel-only)"
    if "$VENV_PY" -m pip install ${PIP_OPTS} --only-binary=:all: "${pkg}"; then
        ok "${pkg} установлен (wheel)"
        return 0
    fi

    warn "Wheel для ${pkg} не найден — собираю из исходников"
    install_build_tools
    "$VENV_PY" -m pip install ${PIP_OPTS} "${pkg}" \
        || fail "Не удалось установить ${pkg}"
    ok "${pkg} установлен (compiled)"
}

# ─── --reset-password ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--reset-password" ]]; then
    [[ $EUID -eq 0 ]] || fail "Запусти от root"
    [[ -f "${DATA_DIR}/config.json" ]] || fail "Панель не установлена. Сначала запусти install-panel.sh"
    [[ -x "$VENV_PY" ]] || fail "Python venv не найден (${VENV_DIR}). Переустанови панель."

    NEW_USER=$(openssl rand -hex 4)
    NEW_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    NEW_HASH=$(MERIDIAN_PASS="$NEW_PASS" "$VENV_PY" -c "import bcrypt,os; print(bcrypt.hashpw(os.environ['MERIDIAN_PASS'].encode(), bcrypt.gensalt(12)).decode())")

    "$VENV_PY" -c "
import json
d = json.load(open('${DATA_DIR}/config.json'))
d['username'] = '${NEW_USER}'
d['password_hash'] = '${NEW_HASH}'
json.dump(d, open('${DATA_DIR}/config.json','w'), indent=2)
"
    docker restart meridian-backend 2>/dev/null || true

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD} Пароль сброшен!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Логин:   ${BOLD}${NEW_USER}${NC}"
    echo -e "  Пароль:  ${BOLD}${NEW_PASS}${NC}"
    echo ""
    echo -e "  ${YELLOW}Сохрани — больше не показывается!${NC}"
    echo ""
    exit 0
fi

# ─── Проверки ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || fail "Сначала установи Traefik (install.sh)"
[[ -f "${MTPROTO_DIR}/.env" ]] || fail "Сначала установи MTProto (install-mtproto.sh)"
docker ps --format '{{.Names}}' | grep -q traefik || fail "Traefik не запущен"
docker ps --format '{{.Names}}' | grep -q mtproto  || fail "MTProto не запущен"

# ─── Установка зависимостей ─────────────────────────────────────────────────
install_system_deps
setup_venv
install_py_pkg bcrypt
install_py_pkg toml

# ─── Повторный запуск ───────────────────────────────────────────────────────
if [[ -f "${SERVICE_DIR}/docker-compose.yml" ]]; then
    echo -e "${RED}⚠  Панель уже установлена в ${SERVICE_DIR}${NC}"
    if read -rp "Переустановить? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
        cd "$SERVICE_DIR" && docker compose down 2>/dev/null || true
    else
        fail "Панель уже установлена."
    fi
fi

# ─── Домен из MTProto ────────────────────────────────────────────────────────
source "${MTPROTO_DIR}/.env"
# EE_DOMAIN может быть "domain:8443" или просто "domain"
DECOY_DOMAIN=$(echo "${EE_DOMAIN}" | sed 's/:.*$//')
ok "Домен: ${BOLD}${DECOY_DOMAIN}${NC}"

# RAW_KEY = plain 32-char hex; EE_SECRET = ee<hex><domain_hex> для tg:// ссылок
RAW_KEY="$SECRET"
DOMAIN_HEX=$(printf '%s' "$DECOY_DOMAIN" | xxd -p | tr -d '\n')
EE_SECRET="ee${RAW_KEY}${DOMAIN_HEX}"
ok "Секрет: ${BOLD}${RAW_KEY:0:8}…${NC}"

# ─── Проверяем DNS ──────────────────────────────────────────────────────────
info "Проверяю DNS для ${DECOY_DOMAIN}…"
RESOLVED_IP=$(dig +short "$DECOY_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | tail -1 || true)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "")
USE_SELF_SIGNED=false

if [[ -z "$RESOLVED_IP" ]]; then
    warn "DNS не резолвится."
    USE_SELF_SIGNED=true
elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    warn "DNS → ${RESOLVED_IP}, IP сервера → ${SERVER_IP}. Не совпадает."
    USE_SELF_SIGNED=true
else
    ok "DNS ОК: ${DECOY_DOMAIN} → ${RESOLVED_IP}"
fi

if [[ "$USE_SELF_SIGNED" == true ]]; then
    if [[ -e /dev/tty ]] && read -rp "  Продолжить с self-signed сертификатом? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
    else
        warn "Нет интерактивного терминала — продолжаю с self-signed автоматически"
    fi
fi

# ─── Email для LE ───────────────────────────────────────────────────────────
CERTBOT_EMAIL=""
if [[ "$USE_SELF_SIGNED" == false ]]; then
    if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
        CERTBOT_EMAIL="$LETSENCRYPT_EMAIL"
    elif [[ -e /dev/tty ]]; then
        read -rp "  Email для Let's Encrypt (Enter = без email): " CERTBOT_EMAIL < /dev/tty 2>/dev/null || true
    fi
fi

# ─── Генерация credentials ──────────────────────────────────────────────────
info "Генерирую учётные данные администратора…"

ADMIN_USER=$(openssl rand -hex 4)
ADMIN_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)
ADMIN_HASH=$(MERIDIAN_PASS="$ADMIN_PASS" "$VENV_PY" -c "import bcrypt,os; print(bcrypt.hashpw(os.environ['MERIDIAN_PASS'].encode(), bcrypt.gensalt(12)).decode())")
JWT_SECRET=$(openssl rand -hex 32)

ok "Credentials сгенерированы"

# ─── Структура ──────────────────────────────────────────────────────────────
CERTS_DIR="${INSTALL_DIR}/certs"
mkdir -p "${SERVICE_DIR}/html/panel" "${SERVICE_DIR}/backend" "${DATA_DIR}" "${CERTS_DIR}"

# ─── Сохраняем config.json ──────────────────────────────────────────────────
"$VENV_PY" -c "
import json
cfg = {
    'username': '${ADMIN_USER}',
    'password_hash': '${ADMIN_HASH}',
    'jwt_secret': '${JWT_SECRET}',
}
json.dump(cfg, open('${DATA_DIR}/config.json', 'w'), indent=2)
" || fail "Не удалось создать config.json"
chmod 600 "${DATA_DIR}/config.json"
ok "config.json создан"

# ─── Инициализируем users.json (если не существует) ─────────────────────────
# Teleproxy генерирует config.toml сам из env-переменных при каждом старте.
# Мы только инициализируем метаданные пользователей для панели.
# data/ создаём заранее, чтобы Docker не смонтировал config.toml как директорию.
mkdir -p "${MTPROTO_DIR}/data"
[[ -f "${MTPROTO_DIR}/data/config.toml" ]] || touch "${MTPROTO_DIR}/data/config.toml"
USERS_JSON="${DATA_DIR}/users.json"
if [[ ! -f "$USERS_JSON" ]]; then
    info "Инициализирую users.json с дефолтным пользователем…"
    "$VENV_PY" -c "
import json
from datetime import datetime, timezone
users = [{
    'id': 1,
    'label': 'default',
    'secret': '${EE_SECRET}',
    'active': True,
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%d'),
    'lastSeen': 'never',
}]
json.dump(users, open('${USERS_JSON}', 'w'), indent=2)
" || warn "Не удалось создать users.json"
    ok "users.json инициализирован"
else
    ok "users.json уже существует"
fi

# ─── Обновляем MTProto docker-compose ───────────────────────────────────────
# SECRET и EE_DOMAIN передаём через env: start.sh генерирует config.toml из них при каждом
# старте контейнера. data/ монтируется для персистентности proxy-multi.conf и SIGHUP-reload.
cat > "${MTPROTO_DIR}/docker-compose.yml" <<DEOF
services:
  mtproto:
    image: ghcr.io/teleproxy/teleproxy:latest
    container_name: mtproto
    restart: unless-stopped
    environment:
      - PORT=${PROXY_PORT:-2443}
      - STATS_PORT=8888
      - SECRET=${RAW_KEY}
      - EE_DOMAIN=${DECOY_DOMAIN}:8443
    volumes:
      - ./data:/opt/teleproxy/data
    expose:
      - "${PROXY_PORT:-2443}"
    networks:
      - proxy
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
DEOF
ok "MTProto docker-compose обновлён"

# ─── Скачиваем backend ──────────────────────────────────────────────────────
info "Скачиваю backend…"
BACKEND_DIR="${SERVICE_DIR}/backend"
for f in Dockerfile requirements.txt main.py auth.py users.py teleproxy_config.py; do
    curl -fsSL "${REPO_BASE}/panel/backend/${f}" -o "${BACKEND_DIR}/${f}" \
        || fail "Не удалось скачать ${f}"
done
ok "Backend файлы скачаны"

# ─── Скачиваем фронтенд (pre-built dist) ────────────────────────────────────
info "Скачиваю панель (pre-built)…"
PANEL_DIST_URL="${REPO_BASE}/panel/dist"
PANEL_HTML="${SERVICE_DIR}/html"

# Скачиваем login-страницу
curl -fsSL "${REPO_BASE}/panel/login/index.html" -o "${PANEL_HTML}/index.html" \
    || fail "Не удалось скачать index.html"

# Скачиваем dist/index.html панели
mkdir -p "${PANEL_HTML}/panel"
curl -fsSL "${PANEL_DIST_URL}/index.html" -o "${PANEL_HTML}/panel/index.html" \
    || fail "Не удалось скачать panel/index.html. Убедись что panel/dist/ собран и запушен в репо: cd panel && npm run build"

# Имена ассетов берём из самого index.html — Vite жёстко прописывает туда хешированные пути
mkdir -p "${PANEL_HTML}/panel/assets"
ASSET_FILES=$(grep -oE 'assets/[A-Za-z0-9._-]+\.(js|css)' "${PANEL_HTML}/panel/index.html" | sort -u || true)
if [[ -z "$ASSET_FILES" ]]; then
    fail "В panel/index.html не найдено ассетов. Проверь содержимое: ${PANEL_HTML}/panel/index.html"
fi

while IFS= read -r asset_file; do
    [[ -z "$asset_file" ]] && continue
    dest="${PANEL_HTML}/panel/${asset_file}"
    mkdir -p "$(dirname "$dest")"
    curl -fsSL "${PANEL_DIST_URL}/${asset_file}" -o "$dest" \
        || fail "Не удалось скачать ${asset_file}"
done <<< "$ASSET_FILES"

ok "Фронтенд скачан ($(echo "$ASSET_FILES" | wc -l) файла)"

# ─── Сертификат ─────────────────────────────────────────────────────────────
CERT_FILE="${CERTS_DIR}/fullchain.pem"
KEY_FILE="${CERTS_DIR}/privkey.pem"

# Проверяем существующий сертификат: есть ли файл и не истекает ли он в ближайшие 30 дней
CERT_VALID=false
if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    if openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" 2>/dev/null; then
        CERT_VALID=true
        CERT_SUBJECT=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null | sed 's/.*CN=//' | tr -d ' ')
        CERT_EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
        ok "Сертификат уже существует (CN=${CERT_SUBJECT}, до ${CERT_EXPIRY}) — пропускаю certbot"
    else
        warn "Сертификат истекает менее чем через 30 дней — обновляю"
    fi
fi

if [[ "$CERT_VALID" == false ]]; then
    if [[ "$USE_SELF_SIGNED" == true ]]; then
        info "Генерирую self-signed сертификат…"
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=${DECOY_DOMAIN}" 2>/dev/null
        ok "Self-signed сертификат создан"
    else
        info "Получаю Let's Encrypt сертификат…"
        EMAIL_FLAG="--register-unsafely-without-email"
        [[ -n "$CERTBOT_EMAIL" ]] && EMAIL_FLAG="--email ${CERTBOT_EMAIL}"

        if docker run --rm \
            -p 80:80 \
            -v "${CERTS_DIR}:/etc/letsencrypt" \
            certbot/certbot certonly \
                --standalone --agree-tos --no-eff-email \
                ${EMAIL_FLAG} -d "${DECOY_DOMAIN}"; then

            ln -sf "live/${DECOY_DOMAIN}/fullchain.pem" "$CERT_FILE"
            ln -sf "live/${DECOY_DOMAIN}/privkey.pem" "$KEY_FILE"
            ok "Let's Encrypt сертификат получен"
        else
            warn "Let's Encrypt не удался, генерирую self-signed…"
            openssl req -x509 -nodes -days 3650 \
                -newkey rsa:2048 \
                -keyout "$KEY_FILE" \
                -out "$CERT_FILE" \
                -subj "/CN=${DECOY_DOMAIN}" 2>/dev/null
            ok "Self-signed сертификат создан (fallback)"
            USE_SELF_SIGNED=true
        fi
    fi
fi

# ─── Cron для автопродления LE-сертификата ──────────────────────────────────
# Устанавливается всегда при наличии LE-сертификата (в т.ч. при переустановке).
if [[ "$USE_SELF_SIGNED" == false ]]; then
    CRON_CMD="0 3 * * 0 docker run --rm -p 80:80 -v ${CERTS_DIR}:/etc/letsencrypt certbot/certbot renew --standalone && docker compose -f ${SERVICE_DIR}/docker-compose.yml restart decoy"
    EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v "certbot renew" || true)
    { [[ -n "$EXISTING_CRON" ]] && printf '%s\n' "$EXISTING_CRON"; printf '%s\n' "$CRON_CMD"; } | crontab -
    ok "Cron для обновления сертификата установлен"
fi

# ─── Скачиваем nginx.conf ───────────────────────────────────────────────────
curl -fsSL "${REPO_BASE}/panel/login/nginx.conf" -o "${SERVICE_DIR}/nginx.conf" \
    || fail "Не удалось скачать nginx.conf"
ok "nginx.conf скачан"

# ─── .env ───────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "")
cat > "${SERVICE_DIR}/.env" <<EOF
DECOY_DOMAIN=${DECOY_DOMAIN}
EE_DOMAIN_RAW=${DECOY_DOMAIN}
SERVER_IP=${SERVER_IP}
DATA_DIR=/data
TOML_PATH=/teleproxy/config.toml
EOF

# ─── docker-compose.yml ─────────────────────────────────────────────────────
cat > "${SERVICE_DIR}/docker-compose.yml" <<DEOF
services:
  decoy:
    image: nginx:alpine
    container_name: decoy
    restart: unless-stopped
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${CERTS_DIR}:/etc/nginx/certs:ro
    expose:
      - "8443"
    networks:
      proxy:
        aliases:
          - ${DECOY_DOMAIN}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  meridian-backend:
    build: ./backend
    container_name: meridian-backend
    restart: unless-stopped
    env_file: .env
    volumes:
      - ${DATA_DIR}:/data
      - ${MTPROTO_DIR}/data/config.toml:/teleproxy/config.toml
      - /var/run/docker.sock:/var/run/docker.sock
    expose:
      - "8000"
    networks:
      - proxy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
DEOF
ok "docker-compose.yml создан"

# ─── Traefik catch-all ──────────────────────────────────────────────────────
cat > "${INSTALL_DIR}/traefik/dynamic/decoy.yml" <<'TCPYML'
tcp:
  routers:
    decoy-catchall:
      entryPoints:
        - tcp443
      rule: "HostSNI(`*`)"
      service: decoy-svc
      priority: 1
      tls:
        passthrough: true

  services:
    decoy-svc:
      loadBalancer:
        servers:
          - address: "decoy:8443"
TCPYML
ok "Traefik catch-all настроен"

# ─── Запуск панели ──────────────────────────────────────────────────────────
cd "$SERVICE_DIR"

info "Сборка backend-образа…"
docker compose build || fail "Сборка backend-образа не удалась (см. вывод выше)"

info "Запуск панели…"
docker compose up -d --remove-orphans
sleep 3

# ─── Перезапускаем MTProto с TOML ───────────────────────────────────────────
info "Перезапускаю MTProto с TOML-конфигом…"
cd "${MTPROTO_DIR}"
docker compose up -d --force-recreate
sleep 3

if docker ps --format '{{.Names}}' | grep -q mtproto; then
    ok "MTProto запущен с TOML"
else
    warn "MTProto не запустился. Проверь: cd ${MTPROTO_DIR} && docker compose logs"
fi

if docker ps --format '{{.Names}}' | grep -q decoy && docker ps --format '{{.Names}}' | grep -q meridian-backend; then
    ok "Панель запущена"
else
    echo -e "${RED}Логи:${NC}"
    docker logs decoy           --tail 10 2>/dev/null || true
    docker logs meridian-backend --tail 10 2>/dev/null || true
    fail "Что-то не запустилось. Проверь логи выше."
fi

CERT_TYPE="Let's Encrypt"
[[ "$USE_SELF_SIGNED" == true ]] && CERT_TYPE="Self-signed (браузер покажет предупреждение)"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Meridian Panel готов!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Адрес:   ${BOLD}https://${DECOY_DOMAIN}/panel/${NC}"
echo -e "  Сертификат: ${CERT_TYPE}"
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  Логин:   ${BOLD}${ADMIN_USER}${YELLOW}                             │${NC}"
echo -e "${YELLOW}│  Пароль:  ${BOLD}${ADMIN_PASS}${YELLOW}                     │${NC}"
echo -e "${YELLOW}│                                             │${NC}"
echo -e "${YELLOW}│  Сохрани — больше не показывается!          │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────┘${NC}"
echo ""
echo "  Сброс пароля:"
echo "    curl -sSL ${REPO_BASE}/install-panel.sh | sudo bash -s -- --reset-password"
echo ""
echo "  Управление:"
echo "    cd ${SERVICE_DIR}"
echo "    docker compose logs -f meridian-backend   # логи бэкенда"
echo "    docker compose logs -f decoy              # логи nginx"
echo "    docker compose restart                    # перезапуск"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
