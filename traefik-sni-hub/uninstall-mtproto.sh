#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
SERVICE_DIR="${INSTALL_DIR}/services/mtproto"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
fail()  { echo -e "${RED}✘${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"

if [[ ! -d "$SERVICE_DIR" ]]; then
    fail "MTProto не установлен (${SERVICE_DIR} не найден)."
fi

info "Останавливаю mtproto…"
cd "$SERVICE_DIR"
docker compose down -v --remove-orphans 2>/dev/null || true

info "Удаляю образ…"
docker rmi ghcr.io/teleproxy/teleproxy:latest 2>/dev/null || true

info "Удаляю конфиги…"
rm -f "${INSTALL_DIR}/traefik/dynamic/mtproto.yml"
rm -rf "$SERVICE_DIR"

ok "MTProto удалён. Traefik продолжает работать."
echo ""