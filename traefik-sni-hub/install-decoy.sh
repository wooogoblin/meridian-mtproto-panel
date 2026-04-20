#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
SERVICE_DIR="${INSTALL_DIR}/services/decoy"
MTPROTO_DIR="${INSTALL_DIR}/services/mtproto"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/SergeyNakhankov/vpntools/master/traefik-sni-hub}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
fail()  { echo -e "${RED}✘${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || fail "Сначала установи Traefik (install.sh)"

# ─── Повторный запуск ───────────────────────────────────────────────
if [[ -f "${SERVICE_DIR}/docker-compose.yml" ]]; then
    echo -e "${RED}⚠  Decoy уже установлен в ${SERVICE_DIR}${NC}"
    if read -rp "Переустановить? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
        cd "$SERVICE_DIR" && docker compose down 2>/dev/null || true
    else
        fail "Decoy уже установлен."
    fi
fi

# ─── Домен ──────────────────────────────────────────────────────────
if [[ -z "${DECOY_DOMAIN:-}" ]]; then
    # Если mtproto уже установлен — предложить его домен
    SUGGESTED=""
    if [[ -f "${MTPROTO_DIR}/.env" ]]; then
        SUGGESTED=$(grep EE_DOMAIN "${MTPROTO_DIR}/.env" | cut -d= -f2 | sed 's/:.*$//')
    fi

    echo ""
    echo -e "${BOLD} Введи домен для сайта-заглушки:${NC}"
    echo -e "  Домен должен быть привязан к IP этого сервера (A-запись)."
    if [[ -n "$SUGGESTED" ]]; then
        echo -e "  MTProto использует: ${CYAN}${SUGGESTED}${NC}"
        read -rp "  Домен (Enter = ${SUGGESTED}): " DECOY_DOMAIN < /dev/tty
        DECOY_DOMAIN="${DECOY_DOMAIN:-$SUGGESTED}"
    else
        read -rp "  Домен: " DECOY_DOMAIN < /dev/tty
    fi
    [[ -n "$DECOY_DOMAIN" ]] || fail "Домен не может быть пустым"
else
    ok "Домен (из env): ${BOLD}${DECOY_DOMAIN}${NC}"
fi

# ─── Проверяем DNS ──────────────────────────────────────────────────
info "Проверяю DNS для ${DECOY_DOMAIN}…"
RESOLVED_IP=$(dig +short "$DECOY_DOMAIN" 2>/dev/null | tail -1)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || echo "")
USE_SELF_SIGNED=false

if [[ -z "$RESOLVED_IP" ]]; then
    echo -e "  ${YELLOW}⚠  DNS не резолвится.${NC}"
    USE_SELF_SIGNED=true
elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    echo -e "  ${YELLOW}⚠  DNS → ${RESOLVED_IP}, IP сервера → ${SERVER_IP}. Не совпадает.${NC}"
    USE_SELF_SIGNED=true
else
    ok "DNS ОК: ${DECOY_DOMAIN} → ${RESOLVED_IP}"
fi

if [[ "$USE_SELF_SIGNED" == true ]]; then
    if read -rp "  Продолжить с self-signed сертификатом? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
    else
        fail "DNS не готов."
    fi
fi

# ─── Email для LE ───────────────────────────────────────────────────
CERTBOT_EMAIL=""
if [[ "$USE_SELF_SIGNED" == false ]]; then
    if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
        CERTBOT_EMAIL="$LETSENCRYPT_EMAIL"
    else
        read -rp "  Email для Let's Encrypt (Enter = без email): " CERTBOT_EMAIL < /dev/tty || true
    fi
fi

# ─── Структура ──────────────────────────────────────────────────────
mkdir -p "${SERVICE_DIR}/html" "${SERVICE_DIR}/certs"

# ─── Скачиваем файлы из репозитория ─────────────────────────────────
info "Скачиваю фронтенд…"
curl -sSL "${REPO_BASE}/decoy/index.html" -o "${SERVICE_DIR}/html/index.html" \
    || fail "Не удалось скачать index.html"
ok "index.html"

info "Скачиваю конфигурацию nginx…"
curl -sSL "${REPO_BASE}/decoy/nginx.conf" -o "${SERVICE_DIR}/nginx.conf" \
    || fail "Не удалось скачать nginx.conf"
ok "nginx.conf"

# ─── Сертификат ─────────────────────────────────────────────────────
if [[ "$USE_SELF_SIGNED" == true ]]; then
    info "Генерирую self-signed сертификат…"
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${SERVICE_DIR}/certs/privkey.pem" \
        -out "${SERVICE_DIR}/certs/fullchain.pem" \
        -subj "/CN=${DECOY_DOMAIN}" \
        2>/dev/null
    ok "Self-signed сертификат создан"
else
    info "Получаю Let's Encrypt сертификат…"

    EMAIL_FLAG="--register-unsafely-without-email"
    [[ -n "$CERTBOT_EMAIL" ]] && EMAIL_FLAG="--email ${CERTBOT_EMAIL}"

    if docker run --rm \
        -p 80:80 \
        -v "${SERVICE_DIR}/certs:/etc/letsencrypt" \
        certbot/certbot certonly \
            --standalone \
            --agree-tos \
            --no-eff-email \
            ${EMAIL_FLAG} \
            -d "${DECOY_DOMAIN}"; then

        ln -sf "live/${DECOY_DOMAIN}/fullchain.pem" "${SERVICE_DIR}/certs/fullchain.pem"
        ln -sf "live/${DECOY_DOMAIN}/privkey.pem" "${SERVICE_DIR}/certs/privkey.pem"
        ok "Let's Encrypt сертификат получен"

        CRON_CMD="0 3 * * 0 docker run --rm -p 80:80 -v ${SERVICE_DIR}/certs:/etc/letsencrypt certbot/certbot renew --standalone && cd ${SERVICE_DIR} && docker compose restart decoy"
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -
        ok "Cron для обновления сертификата добавлен"
    else
        echo -e "${YELLOW}⚠  Let's Encrypt не удался, генерирую self-signed…${NC}"
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${SERVICE_DIR}/certs/privkey.pem" \
            -out "${SERVICE_DIR}/certs/fullchain.pem" \
            -subj "/CN=${DECOY_DOMAIN}" \
            2>/dev/null
        ok "Self-signed сертификат создан (fallback)"
        USE_SELF_SIGNED=true
    fi
fi

# ─── .env ───────────────────────────────────────────────────────────
echo "DECOY_DOMAIN=${DECOY_DOMAIN}" > "${SERVICE_DIR}/.env"

# ─── docker-compose.yml ────────────────────────────────────────────
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

networks:
  proxy:
    external: true
DEOF

# ─── Traefik catch-all ──────────────────────────────────────────────
cat > "${INSTALL_DIR}/traefik/dynamic/decoy.yml" << 'TCPYML'
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

ok "Конфигурация создана"

# ─── Запуск ─────────────────────────────────────────────────────────
cd "$SERVICE_DIR"

info "Starting decoy…"
docker compose up -d --remove-orphans

sleep 2

if docker ps --format '{{.Names}}' | grep -q decoy; then
    ok "Decoy запущен"
else
    fail "Decoy не запустился. Проверь: cd ${SERVICE_DIR} && docker compose logs"
fi

# ─── Подхватываем MTProto ───────────────────────────────────────────
MTPROTO_RECONFIGURED=false
if [[ -f "${MTPROTO_DIR}/.env" ]]; then
    source "${MTPROTO_DIR}/.env"
    # Извлекаем домен без порта
    CURRENT_DOMAIN=$(echo "${EE_DOMAIN}" | sed 's/:.*$//')

    if [[ "$CURRENT_DOMAIN" == "$DECOY_DOMAIN" && "$EE_DOMAIN" != "${DECOY_DOMAIN}:8443" ]]; then
        info "MTProto использует тот же домен (${CURRENT_DOMAIN}) → переключаю на локальный decoy…"
        sed -i "s|^EE_DOMAIN=.*|EE_DOMAIN=${DECOY_DOMAIN}:8443|" "${MTPROTO_DIR}/.env"
        cd "${MTPROTO_DIR}" && docker compose up -d --force-recreate
        sleep 2
        if docker ps --format '{{.Names}}' | grep -q mtproto; then
            ok "MTProto перенастроен → domain fronting на локальный nginx"
            MTPROTO_RECONFIGURED=true
        else
            echo -e "${YELLOW}⚠  MTProto не перезапустился. Проверь: cd ${MTPROTO_DIR} && docker compose logs${NC}"
        fi
    elif [[ "$CURRENT_DOMAIN" != "$DECOY_DOMAIN" ]]; then
        echo -e "  ${YELLOW}⚠  MTProto использует другой домен (${CURRENT_DOMAIN}). Decoy не подключен к нему.${NC}"
    else
        ok "MTProto уже использует локальный decoy"
    fi
fi

# ─── Результат ──────────────────────────────────────────────────────
CERT_TYPE="Let's Encrypt"
[[ "$USE_SELF_SIGNED" == true ]] && CERT_TYPE="Self-signed"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Сайт-заглушка готов!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Домен:       ${BOLD}${DECOY_DOMAIN}${NC}"
echo -e "  Сертификат:  ${CERT_TYPE}"
echo -e "  Страница:    ${BOLD}https://${DECOY_DOMAIN}${NC}"
if [[ "$MTPROTO_RECONFIGURED" == true ]]; then
    echo -e "  MTProto:     ${GREEN}переключен на локальный decoy${NC}"
fi
echo ""
echo -e "  Traefik роутинг:"
echo -e "    Известный SNI  → сервис (MTProto и др.)"
echo -e "    Любой другой   → ${BOLD}Meridian login${NC}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Управление:"
echo "    cd ${SERVICE_DIR}"
echo "    docker compose logs -f       # логи"
echo "    docker compose restart       # перезапуск"
echo ""