#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
MTPROTO_DIR="${INSTALL_DIR}/services/mtproto"
SERVICE_DIR="${INSTALL_DIR}/services/panel"
DATA_DIR="/opt/meridian"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/SergeyNakhankov/vpntools/master/traefik-sni-hub}"

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
    read -rp "  Продолжить с self-signed сертификатом? [y/N] " ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

# ─── Email для LE ───────────────────────────────────────────────────────────
CERTBOT_EMAIL=""
if [[ "$USE_SELF_SIGNED" == false ]]; then
    if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
        CERTBOT_EMAIL="$LETSENCRYPT_EMAIL"
    else
        read -rp "  Email для Let's Encrypt (Enter = без email): " CERTBOT_EMAIL < /dev/tty || true
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
mkdir -p "${SERVICE_DIR}/html/panel" "${SERVICE_DIR}/certs" "${SERVICE_DIR}/backend" "${DATA_DIR}"

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

# ─── Конвертируем MTProto env → TOML ────────────────────────────────────────
TOML_PATH="${MTPROTO_DIR}/teleproxy.toml"
if [[ ! -f "$TOML_PATH" ]]; then
    info "Конвертирую MTProto секрет в TOML…"
    DOMAIN_HEX=$(printf '%s' "$DECOY_DOMAIN" | xxd -p | tr -d '\n')
    FULL_SECRET="ee${SECRET}${DOMAIN_HEX}"
    EE_DOMAIN_FOR_TOML="${DECOY_DOMAIN}:8443"

    "$VENV_PY" -c "
import toml
data = {
    'server': {
        'port': int('${PROXY_PORT:-2443}'),
        'stats_port': 8888,
        'ee_domain': '${EE_DOMAIN_FOR_TOML}',
    },
    'secret': [
        {
            'secret': '${FULL_SECRET}',
            'max_connections': 15,
        }
    ],
}
with open('${TOML_PATH}', 'w') as f:
    toml.dump(data, f)
" || fail "Не удалось сгенерировать teleproxy.toml"
    ok "teleproxy.toml создан"
else
    ok "teleproxy.toml уже существует"
fi

# ─── Обновляем MTProto docker-compose для работы с TOML ────────────────────
cat > "${MTPROTO_DIR}/docker-compose.yml" <<DEOF
services:
  mtproto:
    image: ghcr.io/teleproxy/teleproxy:latest
    container_name: mtproto
    restart: unless-stopped
    environment:
      - PORT=${PROXY_PORT:-2443}
      - STATS_PORT=8888
    volumes:
      - ./teleproxy.toml:/etc/teleproxy/config.toml:ro
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
ok "MTProto docker-compose обновлён для TOML"

# ─── Скачиваем backend ──────────────────────────────────────────────────────
info "Скачиваю backend…"
BACKEND_DIR="${SERVICE_DIR}/backend"
for f in Dockerfile requirements.txt main.py auth.py users.py teleproxy_config.py; do
    curl -sSL "${REPO_BASE}/panel/backend/${f}" -o "${BACKEND_DIR}/${f}" \
        || fail "Не удалось скачать ${f}"
done
ok "Backend файлы скачаны"

# ─── Скачиваем фронтенд (pre-built dist) ────────────────────────────────────
info "Скачиваю панель (pre-built)…"
PANEL_DIST_URL="${REPO_BASE}/panel/dist"
PANEL_HTML="${SERVICE_DIR}/html"

# Скачиваем login-страницу
curl -sSL "${REPO_BASE}/panel/login/index.html" -o "${PANEL_HTML}/index.html" \
    || fail "Не удалось скачать index.html"

# Скачиваем dist/index.html панели
mkdir -p "${PANEL_HTML}/panel"
curl -sSL "${PANEL_DIST_URL}/index.html" -o "${PANEL_HTML}/panel/index.html" \
    || fail "Не удалось скачать panel/index.html"

# Скачиваем assets по именам из Vite manifest
mkdir -p "${PANEL_HTML}/panel/assets"
MANIFEST=$(curl -sSL "${PANEL_DIST_URL}/.vite/manifest.json" 2>/dev/null || true)
if [[ -z "$MANIFEST" ]]; then
    fail "Не удалось получить Vite manifest. Убедись что dist/ собран и запушен в репо."
fi
MANIFEST_TMP=$(mktemp)
echo "$MANIFEST" > "$MANIFEST_TMP"
ASSET_FILES=$("$VENV_PY" - "$MANIFEST_TMP" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
files = []
for v in m.values():
    files.append(v['file'])
    files.extend(v.get('css', []))
print('\n'.join(set(files)))
PYEOF
)
rm -f "$MANIFEST_TMP"
while IFS= read -r asset_file; do
    [[ -z "$asset_file" ]] && continue
    dest="${PANEL_HTML}/panel/${asset_file}"
    mkdir -p "$(dirname "$dest")"
    curl -sSL "${PANEL_DIST_URL}/${asset_file}" -o "$dest" \
        || warn "Не удалось скачать ${asset_file}"
done <<< "$ASSET_FILES"

ok "Фронтенд скачан"

# ─── Сертификат ─────────────────────────────────────────────────────────────
if [[ "$USE_SELF_SIGNED" == true ]]; then
    info "Генерирую self-signed сертификат…"
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${SERVICE_DIR}/certs/privkey.pem" \
        -out "${SERVICE_DIR}/certs/fullchain.pem" \
        -subj "/CN=${DECOY_DOMAIN}" 2>/dev/null
    ok "Self-signed сертификат создан"
else
    info "Получаю Let's Encrypt сертификат…"
    EMAIL_FLAG="--register-unsafely-without-email"
    [[ -n "$CERTBOT_EMAIL" ]] && EMAIL_FLAG="--email ${CERTBOT_EMAIL}"

    if docker run --rm \
        -p 80:80 \
        -v "${SERVICE_DIR}/certs:/etc/letsencrypt" \
        certbot/certbot certonly \
            --standalone --agree-tos --no-eff-email \
            ${EMAIL_FLAG} -d "${DECOY_DOMAIN}"; then

        ln -sf "live/${DECOY_DOMAIN}/fullchain.pem" "${SERVICE_DIR}/certs/fullchain.pem"
        ln -sf "live/${DECOY_DOMAIN}/privkey.pem" "${SERVICE_DIR}/certs/privkey.pem"
        ok "Let's Encrypt сертификат получен"

        CRON_CMD="0 3 * * 0 docker run --rm -p 80:80 -v ${SERVICE_DIR}/certs:/etc/letsencrypt certbot/certbot renew --standalone && cd ${SERVICE_DIR} && docker compose restart decoy"
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -
        ok "Cron для обновления сертификата добавлен"
    else
        warn "Let's Encrypt не удался, генерирую self-signed…"
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${SERVICE_DIR}/certs/privkey.pem" \
            -out "${SERVICE_DIR}/certs/fullchain.pem" \
            -subj "/CN=${DECOY_DOMAIN}" 2>/dev/null
        ok "Self-signed сертификат создан (fallback)"
        USE_SELF_SIGNED=true
    fi
fi

# ─── Скачиваем nginx.conf ───────────────────────────────────────────────────
curl -sSL "${REPO_BASE}/panel/login/nginx.conf" -o "${SERVICE_DIR}/nginx.conf" \
    || fail "Не удалось скачать nginx.conf"
ok "nginx.conf скачан"

# ─── .env ───────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "")
cat > "${SERVICE_DIR}/.env" <<EOF
DECOY_DOMAIN=${DECOY_DOMAIN}
EE_DOMAIN_RAW=${DECOY_DOMAIN}
SERVER_IP=${SERVER_IP}
DATA_DIR=${DATA_DIR}
TOML_PATH=${MTPROTO_DIR}/teleproxy.toml
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
      - ./certs:/etc/nginx/certs:ro
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
      - ${MTPROTO_DIR}/teleproxy.toml:/teleproxy/teleproxy.toml
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
docker compose build --quiet

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
