#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
SERVICE_DIR="${INSTALL_DIR}/services/panel"
DATA_DIR="/opt/meridian"

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

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"

if [[ ! -d "$SERVICE_DIR" && ! -d "$DATA_DIR" ]]; then
    fail "Панель не установлена."
fi

echo ""
echo -e "${RED}${BOLD} Удаление Meridian Panel${NC}"
echo -e "  Директории: ${SERVICE_DIR} и ${DATA_DIR}"
echo -e "  ${YELLOW}MTProto и Traefik останутся работать${NC}"
echo ""

if [[ -t 0 ]]; then
    read -rp "Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

# ─── Останавливаем контейнеры ───────────────────────────────────────────────
if [[ -f "${SERVICE_DIR}/docker-compose.yml" ]]; then
    info "Останавливаю контейнеры панели…"
    cd "$SERVICE_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    ok "Контейнеры остановлены"
fi

# Подчищаем образ backend (если есть)
info "Удаляю образ meridian-backend…"
docker image rm -f panel-meridian-backend 2>/dev/null || true
docker image rm -f panel_meridian-backend 2>/dev/null || true

# ─── Удаляем Traefik catch-all ──────────────────────────────────────────────
if [[ -f "${INSTALL_DIR}/traefik/dynamic/decoy.yml" ]]; then
    info "Удаляю Traefik catch-all (decoy.yml)…"
    rm -f "${INSTALL_DIR}/traefik/dynamic/decoy.yml"
    ok "Catch-all удалён (Traefik подхватит автоматически)"
fi

# ─── Удаляем cron для certbot renew ─────────────────────────────────────────
if crontab -l 2>/dev/null | grep -q "certbot renew"; then
    info "Удаляю cron для обновления сертификата…"
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab - || true
    ok "Cron удалён"
fi

# ─── Удаляем директории ─────────────────────────────────────────────────────
if [[ -d "$SERVICE_DIR" ]]; then
    info "Удаляю ${SERVICE_DIR}…"
    rm -rf "$SERVICE_DIR"
fi

if [[ -d "$DATA_DIR" ]]; then
    info "Удаляю ${DATA_DIR} (config.json, users.json, venv)…"
    rm -rf "$DATA_DIR"
fi

ok "Панель удалена"

# ─── Предупреждение про MTProto в TOML-режиме ───────────────────────────────
if [[ -f "${INSTALL_DIR}/services/mtproto/data/config.toml" ]]; then
    echo ""
    warn "MTProto остался в TOML-режиме (${INSTALL_DIR}/services/mtproto/data/config.toml)."
    warn "Без панели управлять пользователями придётся вручную через TOML + SIGHUP."
    echo ""
fi

if [[ -d "${INSTALL_DIR}/certs" ]]; then
    echo ""
    ok "Сертификат сохранён в ${INSTALL_DIR}/certs/ — при переустановке панели будет использован повторно."
    echo ""
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Готово.${NC} Traefik и MTProto продолжают работать."
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
