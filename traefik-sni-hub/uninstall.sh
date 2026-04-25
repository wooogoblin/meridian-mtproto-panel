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

if [[ ! -d "$INSTALL_DIR" ]]; then
    fail "Каталог ${INSTALL_DIR} не найден — нечего удалять."
fi

echo ""
echo -e "${RED}${BOLD} Полное удаление: Traefik + все сервисы${NC}"
echo -e "  Каталог: ${INSTALL_DIR}"
echo ""

if [[ -t 0 ]]; then
    read -rp "Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

# Останавливаем все сервисы
for svc_dir in "${INSTALL_DIR}"/services/*/; do
    if [[ -f "${svc_dir}docker-compose.yml" ]]; then
        svc_name=$(basename "$svc_dir")
        info "Останавливаю ${svc_name}…"
        cd "$svc_dir"
        docker compose down -v --remove-orphans 2>/dev/null || true
    fi
done

# Останавливаем Traefik
info "Останавливаю traefik…"
cd "$INSTALL_DIR"
docker compose down -v --remove-orphans 2>/dev/null || true

# Удаляем сеть
info "Удаляю Docker-сеть proxy…"
docker network rm proxy 2>/dev/null || true

# Удаляю каталог
info "Удаляю ${INSTALL_DIR}…"
cd /
rm -rf "$INSTALL_DIR"

ok "Всё удалено."
echo ""