#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
SERVICE_DIR="${INSTALL_DIR}/services/decoy"

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
    echo ""
    echo -e "${BOLD} Введи домен для сайта-заглушки:${NC}"
    echo -e "  Домен должен быть привязан к IP этого сервера (A-запись)."
    echo -e "  Пример: ${CYAN}example.com${NC} или ${CYAN}panel.example.com${NC}"
    echo ""
    read -rp "  Домен: " DECOY_DOMAIN < /dev/tty
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
    echo -e "  ${YELLOW}⚠  DNS не резолвится. Let's Encrypt не выдаст сертификат.${NC}"
    echo -e "  Создай A-запись ${DECOY_DOMAIN} → ${SERVER_IP} и подожди 2-5 минут."
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

# ─── Email для Let's Encrypt ────────────────────────────────────────
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

# ─── HTML ───────────────────────────────────────────────────────────
info "Создаю страницу…"
cat > "${SERVICE_DIR}/html/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sign In</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e1e4e8;height:100vh;display:flex;align-items:center;justify-content:center}
        .c{width:100%;max-width:380px;padding:0 20px}
        .logo{text-align:center;margin-bottom:32px}
        .logo-icon{width:48px;height:48px;background:#2563eb;border-radius:12px;display:inline-flex;align-items:center;justify-content:center;margin-bottom:16px}
        .logo-icon svg{width:24px;height:24px;fill:#fff}
        .logo h1{font-size:20px;font-weight:600;color:#f0f0f0}
        .logo p{font-size:14px;color:#6b7280;margin-top:4px}
        .fg{margin-bottom:16px}
        .fg label{display:block;font-size:13px;font-weight:500;color:#9ca3af;margin-bottom:6px}
        .fg input{width:100%;padding:10px 14px;background:#1a1d27;border:1px solid #2d3140;border-radius:8px;color:#e1e4e8;font-size:14px;outline:none;transition:border-color .2s}
        .fg input:focus{border-color:#2563eb}
        .fg input::placeholder{color:#4b5563}
        .rr{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px;font-size:13px}
        .rr label{display:flex;align-items:center;gap:8px;color:#9ca3af;cursor:pointer}
        .rr input[type=checkbox]{accent-color:#2563eb}
        .rr a{color:#2563eb;text-decoration:none}
        .rr a:hover{text-decoration:underline}
        .btn{width:100%;padding:10px;background:#2563eb;color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:500;cursor:pointer;transition:background .2s}
        .btn:hover{background:#1d4ed8}
        .err{display:none;background:#1c1215;border:1px solid #5c2131;color:#f87171;padding:10px 14px;border-radius:8px;font-size:13px;margin-bottom:16px}
        .ft{text-align:center;margin-top:32px;font-size:12px;color:#4b5563}
    </style>
</head>
<body>
<div class="c">
    <div class="logo">
        <div class="logo-icon"><svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg></div>
        <h1>Dashboard</h1>
        <p>Sign in to your account</p>
    </div>
    <div class="err" id="e">Invalid credentials. Please try again.</div>
    <form onsubmit="return h(event)">
        <div class="fg"><label>Email</label><input type="email" placeholder="admin@example.com" required></div>
        <div class="fg"><label>Password</label><input type="password" id="p" placeholder="••••••••" required></div>
        <div class="rr"><label><input type="checkbox"> Remember me</label><a href="#">Forgot password?</a></div>
        <button class="btn">Sign in</button>
    </form>
    <div class="ft">&copy; 2026 All rights reserved.</div>
</div>
<script>function h(e){e.preventDefault();document.getElementById('e').style.display='block';document.getElementById('p').value='';return false}</script>
</body>
</html>
HTMLEOF

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

        # Cron для обновления
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

# ─── nginx.conf ─────────────────────────────────────────────────────
cat > "${SERVICE_DIR}/nginx.conf" << 'NGINXEOF'
server {
    listen 8443 ssl;
    http2 on;
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    root /usr/share/nginx/html;
    index index.html;
    location / { try_files $uri $uri/ =404; }
    server_tokens off;
}
NGINXEOF

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

# ─── Сохраняем домен ───────────────────────────────────────────────
echo "DECOY_DOMAIN=${DECOY_DOMAIN}" > "${SERVICE_DIR}/.env"

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
echo ""
echo -e "  Traefik роутинг:"
echo -e "    Известный SNI  → сервис (MTProto и др.)"
echo -e "    Любой другой   → ${BOLD}логин-форма${NC}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""