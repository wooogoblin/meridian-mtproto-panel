#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
MTG_PORT="${MTG_PORT:-2443}"
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
    # Если домен передан через env — используем его
    if [[ -n "${FAKE_TLS_DOMAIN:-}" ]]; then
        ok "SNI домен (из env): ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
        return
    fi

    echo ""
    echo -e "${BOLD} Выбери домен маскировки (SNI):${NC}"
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
    echo "    7) google.com"
    echo "    8) microsoft.com"
    echo ""
    echo -e "  ${YELLOW}0) Ввести свой домен (рекомендуется)${NC}"
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
        7) FAKE_TLS_DOMAIN="google.com" ;;
        8) FAKE_TLS_DOMAIN="microsoft.com" ;;
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
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || fail "Сначала установи Traefik: curl -sSL https://raw.githubusercontent.com/wooogoblin/vpntools/master/traefik-sni-hub/install.sh | sudo bash"
docker ps --format '{{.Names}}' | grep -q traefik || fail "Traefik не запущен. Запусти: cd ${INSTALL_DIR} && docker compose up -d"

# ─── xxd ────────────────────────────────────────────────────────────
command -v xxd &>/dev/null || fail "xxd не найден. Установи: apt install xxd"

# ─── Повторный запуск ───────────────────────────────────────────────
if [[ -f "${SERVICE_DIR}/docker-compose.yml" ]]; then
    echo -e "${RED}⚠  MTProto уже установлен в ${SERVICE_DIR}${NC}"
    if [[ -f "${SERVICE_DIR}/.env" ]]; then
        OLD_SECRET=$(grep MTG_SECRET "${SERVICE_DIR}/.env" | cut -d= -f2)
        echo -e "  Текущий секрет: ${OLD_SECRET}"
    fi
    if read -rp "Перегенерировать секрет и переустановить? [y/N] " ans < /dev/tty 2>/dev/null; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
    else
        fail "MTProto уже установлен. Удали сначала: curl -sSL https://raw.githubusercontent.com/wooogoblin/vpntools/master/traefik-sni-hub/uninstall-mtproto.sh | sudo bash"
    fi
fi

# ─── Выбор домена маскировки ─────────────────────────────────────────
select_sni

# ─── Генерация секрета ──────────────────────────────────────────────
info "Генерация Fake TLS секрета для: ${BOLD}${FAKE_TLS_DOMAIN}${NC}"

HEX_SECRET=$(openssl rand -hex 16)
DOMAIN_HEX=$(printf '%s' "$FAKE_TLS_DOMAIN" | xxd -p | tr -d '\n')
MTG_SECRET="ee${HEX_SECRET}${DOMAIN_HEX}"

ok "Секрет сгенерирован"

# ─── docker-compose для mtproto ─────────────────────────────────────
mkdir -p "$SERVICE_DIR"

cat > "${SERVICE_DIR}/.env" <<EOF
MTG_SECRET=${MTG_SECRET}
MTG_PORT=${MTG_PORT}
EOF

cat > "${SERVICE_DIR}/docker-compose.yml" <<'EOF'
services:
  mtproto:
    image: nineseconds/mtg:2
    container_name: mtproto
    restart: unless-stopped
    command: simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:${MTG_PORT:-2443} ${MTG_SECRET}
    expose:
      - "${MTG_PORT:-2443}"
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
          - address: "mtproto:${MTG_PORT}"
TCPYML

ok "Конфигурация создана"

# ─── Запуск ─────────────────────────────────────────────────────────
cd "$SERVICE_DIR"

info "Pulling mtg…"
docker compose pull --quiet

info "Starting mtproto…"
docker compose up -d --remove-orphans

sleep 2

if docker ps --format '{{.Names}}' | grep -q mtproto; then
    ok "MTProto запущен"
else
    fail "MTProto не запустился. Проверь: cd ${SERVICE_DIR} && docker compose logs"
fi

# ─── Результат ──────────────────────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "YOUR_IP")

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} MTProto Proxy готов!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Сервер:      ${BOLD}${SERVER_IP}${NC}"
echo -e "  Порт:        ${BOLD}443${NC}"
echo -e "  Fake TLS:    ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
echo -e "  Секрет:      ${MTG_SECRET}"
echo ""
echo -e "  ${CYAN}Ссылка для Telegram:${NC}"
echo ""
echo -e "  ${BOLD}tg://proxy?server=${SERVER_IP}&port=443&secret=${MTG_SECRET}${NC}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Управление:"
echo "    cd ${SERVICE_DIR}"
echo "    docker compose logs -f       # логи"
echo "    docker compose restart       # перезапуск"
echo ""