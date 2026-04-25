#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
fail()  { echo -e "${RED}✘${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"

# ─── Docker ─────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Docker не найден — устанавливаю…"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
    ok "Docker установлен"
else
    ok "Docker: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
    info "docker compose plugin не найден — устанавливаю…"

    # Пробуем из текущих репо
    if ! apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1; then
        # Добавляем официальный репо Docker
        info "Добавляю официальный репозиторий Docker…"
        apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
            || fail "Не удалось установить docker-compose-plugin"
    fi

    docker compose version &>/dev/null || fail "docker compose plugin установлен, но не работает"
    ok "docker compose plugin установлен"
else
    ok "Docker Compose: $(docker compose version --short)"
fi

# xxd нужен для генерации секретов сервисов
if ! command -v xxd &>/dev/null; then
    info "Устанавливаю xxd…"
    apt-get update -qq && apt-get install -y -qq xxd >/dev/null 2>&1 \
        || yum install -y -q vim-common >/dev/null 2>&1 \
        || fail "Не удалось установить xxd. Поставь вручную: apt install xxd"
    ok "xxd установлен"
fi

# ─── Порт 443 ──────────────────────────────────────────────────────
if ss -tlnp | grep -q ':443 '; then
    echo -e "${RED}⚠  Порт 443 занят:${NC}"
    ss -tlnp | grep ':443 '
    if [[ -t 0 ]]; then
        read -rp "Продолжить? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Отменено."
    else
        fail "Порт 443 занят. Освободи и запусти снова."
    fi
fi

# ─── Структура ──────────────────────────────────────────────────────
info "Установка в ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/services"

# ─── docker-compose.yml (Traefik) ──────────────────────────────────
cat > "${INSTALL_DIR}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./traefik/static.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
    networks:
      - proxy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    name: proxy
EOF

# ─── traefik/static.yml ────────────────────────────────────────────
cat > "${INSTALL_DIR}/traefik/static.yml" <<'EOF'
entryPoints:
  tcp443:
    address: ":443"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

log:
  level: WARN

accessLog: {}
EOF

# ─── Запуск ─────────────────────────────────────────────────────────
cd "$INSTALL_DIR"

info "Pulling traefik…"
docker compose pull --quiet

info "Starting traefik…"
docker compose up -d --remove-orphans

sleep 2

if docker ps --format '{{.Names}}' | grep -q traefik; then
    ok "Traefik запущен"
else
    fail "Traefik не запустился. Проверь: cd ${INSTALL_DIR} && docker compose logs"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Traefik установлен и слушает :443${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Каталог:  ${INSTALL_DIR}"
echo ""
echo "  Следующие шаги:"
echo "    curl -sSL .../install-mtproto.sh | sudo bash   # MTProto прокси"
echo "    curl -sSL .../install-panel.sh   | sudo bash   # Панель управления + авторизация"
echo ""