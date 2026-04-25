#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
PROXY_PORT="${PROXY_PORT:-2443}"
SERVICE_DIR="${INSTALL_DIR}/services/mtproto"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
fail()  { echo -e "${RED}✘${NC} $*" >&2; exit 1; }

# ─── Выбор SNI ──────────────────────────────────────────────────────
select_sni() {
    if [[ -n "${FAKE_TLS_DOMAIN:-}" ]]; then
        ok "SNI домен (из env): ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
        return
    fi

    echo ""
    echo -e "${BOLD} Выбери домен маскировки (SNI):${NC}"
    echo ""
    echo -e "  При неудачной валидации (DPI-проба, браузер) Teleproxy"
    echo -e "  прозрачно проксирует соединение на реальный сайт этого домена."
    echo ""
    echo -e "  ${CYAN}Популярные RU-домены:${NC}"
    echo "    1) ya.ru"
    echo "    2) sberbank.ru"
    echo "    3) gosuslugi.ru"
    echo "    4) mail.ru"
    echo "    5) wildberries.ru"
    echo "    6) ozon.ru"
    echo ""
    echo -e "  ${CYAN}Международные:${NC}"
    echo "    7) www.google.com"
    echo "    8) www.microsoft.com"
    echo ""
    echo -e "  ${YELLOW}0) Ввести свой домен${NC}"
    echo ""

    local choice
    read -rp "  Выбор (Enter = 1): " choice < /dev/tty || choice="1"
    choice="${choice:-1}"

    case "$choice" in
        1) FAKE_TLS_DOMAIN="ya.ru" ;;
        2) FAKE_TLS_DOMAIN="sberbank.ru" ;;
        3) FAKE_TLS_DOMAIN="gosuslugi.ru" ;;
        4) FAKE_TLS_DOMAIN="mail.ru" ;;
        5) FAKE_TLS_DOMAIN="wildberries.ru" ;;
        6) FAKE_TLS_DOMAIN="ozon.ru" ;;
        7) FAKE_TLS_DOMAIN="www.google.com" ;;
        8) FAKE_TLS_DOMAIN="www.microsoft.com" ;;
        0)
            read -rp "  Введи домен: " FAKE_TLS_DOMAIN < /dev/tty
            [[ -n "$FAKE_TLS_DOMAIN" ]] || fail "Домен не может быть пустым"
            ;;
        *) fail "Неверный выбор: $choice" ;;
    esac

    ok "SNI домен: ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
}

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"

# ─── Проверяем что Traefik установлен ───────────────────────────────
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || fail "Сначала установи Traefik (install.sh)"
docker ps --format '{{.Names}}' | grep -q traefik || fail "Traefik не запущен. Запусти: cd ${INSTALL_DIR} && docker compose up -d"

# ─── Повторный запуск ───────────────────────────────────────────────
if [[ -f "${SERVICE_DIR}/docker-compose.yml" ]]; then
    echo -e "${RED}⚠  MTProto уже установлен в ${SERVICE_DIR}${NC}"
    if [[ -f "${SERVICE_DIR}/.env" ]]; then
        source "${SERVICE_DIR}/.env"
        echo -e "  Текущий домен: ${EE_DOMAIN:-не задан}"
    fi
    # Если панель уже переключила MTProto на TOML — предупреждаем
    if [[ -f "${SERVICE_DIR}/data/config.toml" ]]; then
        echo -e "  ${YELLOW}⚠  Панель установлена и MTProto работает в TOML-режиме.${NC}"
        echo -e "  ${YELLOW}   После переустановки MTProto запусти install-panel.sh повторно.${NC}"
    fi
    if read -rp "Переустановить? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
        cd "$SERVICE_DIR" && docker compose down 2>/dev/null || true
    else
        fail "MTProto уже установлен."
    fi
fi

# ─── Выбор домена маскировки ────────────────────────────────────────
select_sni

# ─── Проверяем панель (для domain fronting) ─────────────────────────
PANEL_DIR="${INSTALL_DIR}/services/panel"
EE_DOMAIN_VALUE="${FAKE_TLS_DOMAIN}"

if [[ -f "${PANEL_DIR}/.env" ]]; then
    PANEL_DOMAIN=$(grep DECOY_DOMAIN "${PANEL_DIR}/.env" | cut -d= -f2)
    if [[ "$PANEL_DOMAIN" == "$FAKE_TLS_DOMAIN" ]]; then
        EE_DOMAIN_VALUE="${FAKE_TLS_DOMAIN}:8443"
        ok "Панель найдена (${PANEL_DOMAIN}) → domain fronting на локальный nginx"
    else
        echo -e "  ${YELLOW}⚠  Панель установлена для ${PANEL_DOMAIN}, а SNI = ${FAKE_TLS_DOMAIN}${NC}"
        echo -e "  Domain fronting пойдёт на внешний ${FAKE_TLS_DOMAIN}"
    fi
fi

# ─── Генерация секрета ──────────────────────────────────────────────
info "Генерация секрета…"
HEX_SECRET=$(openssl rand -hex 16)
ok "Секрет сгенерирован"

# ─── Структура ──────────────────────────────────────────────────────
mkdir -p "${SERVICE_DIR}"

# ─── .env ───────────────────────────────────────────────────────────
cat > "${SERVICE_DIR}/.env" <<EOF
SECRET=${HEX_SECRET}
EE_DOMAIN=${EE_DOMAIN_VALUE}
PROXY_PORT=${PROXY_PORT}
EOF

# ─── docker-compose.yml ────────────────────────────────────────────
cat > "${SERVICE_DIR}/docker-compose.yml" <<'EOF'
services:
  mtproto:
    image: ghcr.io/teleproxy/teleproxy:latest
    container_name: mtproto
    restart: unless-stopped
    env_file: .env
    environment:
      - PORT=${PROXY_PORT:-2443}
      - STATS_PORT=8888
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
EOF

# ─── Traefik роут ───────────────────────────────────────────────────
cat > "${INSTALL_DIR}/traefik/dynamic/mtproto.yml" <<TCPYML
tcp:
  routers:
    mtproto:
      entryPoints:
        - tcp443
      rule: "HostSNI(\`${FAKE_TLS_DOMAIN}\`)"
      service: mtproto-svc
      tls:
        passthrough: true

  services:
    mtproto-svc:
      loadBalancer:
        servers:
          - address: "mtproto:${PROXY_PORT}"
TCPYML

ok "Конфигурация создана"

# ─── Запуск ─────────────────────────────────────────────────────────
cd "$SERVICE_DIR"

info "Pulling teleproxy…"
docker compose pull --quiet

info "Starting teleproxy…"
docker compose up -d --remove-orphans

info "Ожидание запуска…"
sleep 5

if docker ps --format '{{.Names}}' | grep -q mtproto; then
    ok "Teleproxy запущен"
else
    echo ""
    echo -e "${RED}Логи:${NC}"
    docker logs mtproto --tail 20
    fail "Teleproxy не запустился."
fi

# ─── Извлекаем ссылку из логов ──────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "YOUR_IP")

# Teleproxy выводит ссылку в логах
TG_LINK=$(docker logs mtproto 2>&1 | grep -oP 'https://t\.me/proxy\?[^\s]+' | head -1 || true)

# Если ссылка не найдена — собираем вручную
if [[ -z "$TG_LINK" ]]; then
    DOMAIN_HEX=$(printf '%s' "$FAKE_TLS_DOMAIN" | xxd -p | tr -d '\n')
    FULL_SECRET="ee${HEX_SECRET}${DOMAIN_HEX}"
    TG_LINK="tg://proxy?server=${SERVER_IP}&port=443&secret=${FULL_SECRET}"
fi

# Также формируем tg:// ссылку
DOMAIN_HEX=$(printf '%s' "$FAKE_TLS_DOMAIN" | xxd -p | tr -d '\n')
FULL_SECRET="ee${HEX_SECRET}${DOMAIN_HEX}"
TG_LINK_ALT="tg://proxy?server=${SERVER_IP}&port=443&secret=${FULL_SECRET}"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} MTProto Proxy (Teleproxy) готов!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Сервер:      ${BOLD}${SERVER_IP}${NC}"
echo -e "  Порт:        ${BOLD}443${NC}"
echo -e "  Fake TLS:    ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
echo -e "  Движок:      Teleproxy (C, DRS + domain fronting)"
echo ""
echo -e "  ${CYAN}Ссылка для Telegram:${NC}"
echo ""
echo -e "  ${BOLD}${TG_LINK_ALT}${NC}"
echo ""
if [[ -n "$TG_LINK" && "$TG_LINK" != "$TG_LINK_ALT" ]]; then
    echo -e "  Или: ${TG_LINK}"
    echo ""
fi
echo -e "  ${CYAN}Защита от DPI:${NC}"
echo -e "    ✔ Dynamic Record Sizing (имитация TLS slow-start)"
echo -e "    ✔ Domain fronting (проброс на ${FAKE_TLS_DOMAIN})"
echo -e "    ✔ Anti-replay"
echo -e "    ✔ ServerHello фрагментация"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Следующий шаг — панель управления:"
echo "    curl -sSL ${REPO_BASE:-https://raw.githubusercontent.com/wooogoblin/vpntools/panel/traefik-sni-hub}/install-panel.sh | sudo bash"
echo ""
echo "  Управление:"
echo "    cd ${SERVICE_DIR}"
echo "    docker compose logs -f       # логи"
echo "    docker compose restart       # перезапуск"
echo ""