#!/usr/bin/env bash
# Обновляет только фронтенд (login + panel dist) без переустановки панели.
# Учётные данные, сертификат и backend не затрагиваются.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-proxy}"
SERVICE_DIR="${INSTALL_DIR}/services/panel"
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

[[ $EUID -eq 0 ]] || fail "Запусти от root: curl ... | sudo bash"
[[ -f "${SERVICE_DIR}/docker-compose.yml" ]] || fail "Панель не установлена (${SERVICE_DIR}/docker-compose.yml не найден). Сначала запусти install-panel.sh."
docker ps --format '{{.Names}}' | grep -q decoy || fail "Контейнер decoy не запущен. Запусти: cd ${SERVICE_DIR} && docker compose up -d"

PANEL_HTML="${SERVICE_DIR}/html"
PANEL_DIST_URL="${REPO_BASE}/panel/dist"

# ─── Login-страница ──────────────────────────────────────────────────────────
info "Обновляю login-страницу…"
curl -fsSL "${REPO_BASE}/panel/login/index.html" -o "${PANEL_HTML}/index.html" \
    || fail "Не удалось скачать login/index.html"
ok "login/index.html обновлён"

# ─── Panel dist/index.html ───────────────────────────────────────────────────
info "Скачиваю panel/index.html…"
mkdir -p "${PANEL_HTML}/panel"
TMP_INDEX=$(mktemp)
curl -fsSL "${PANEL_DIST_URL}/index.html" -o "$TMP_INDEX" \
    || fail "Не удалось скачать panel/dist/index.html. Убедись что dist собран и запушен."

# ─── Определяем новые и старые ассеты ───────────────────────────────────────
mkdir -p "${PANEL_HTML}/panel/assets"

NEW_ASSETS=$(grep -oE 'assets/[A-Za-z0-9._-]+\.(js|css)' "$TMP_INDEX" | sort -u || true)
[[ -n "$NEW_ASSETS" ]] || fail "В новом panel/index.html не найдено ассетов. Проверь: ${PANEL_DIST_URL}/index.html"

OLD_ASSETS=$(find "${PANEL_HTML}/panel/assets" -maxdepth 1 -type f \( -name "*.js" -o -name "*.css" \) \
    -printf "assets/%f\n" 2>/dev/null | sort -u || true)

# ─── Скачиваем новые ассеты ──────────────────────────────────────────────────
info "Скачиваю ассеты ($(echo "$NEW_ASSETS" | wc -l | tr -d ' ') файла)…"
while IFS= read -r asset_file; do
    [[ -z "$asset_file" ]] && continue
    dest="${PANEL_HTML}/panel/${asset_file}"
    curl -fsSL "${PANEL_DIST_URL}/${asset_file}" -o "$dest" \
        || fail "Не удалось скачать ${asset_file}"
    ok "  ${asset_file}"
done <<< "$NEW_ASSETS"

# Публикуем новый index.html только после успешной загрузки всех ассетов
cp "$TMP_INDEX" "${PANEL_HTML}/panel/index.html"
rm -f "$TMP_INDEX"
ok "panel/index.html обновлён"

# ─── Удаляем устаревшие ассеты ───────────────────────────────────────────────
if [[ -n "$OLD_ASSETS" ]]; then
    while IFS= read -r old_file; do
        [[ -z "$old_file" ]] && continue
        if ! grep -qF "$old_file" <<< "$NEW_ASSETS"; then
            rm -f "${PANEL_HTML}/panel/${old_file}"
            warn "  Удалён устаревший: ${old_file}"
        fi
    done <<< "$OLD_ASSETS"
fi

# ─── nginx reload ────────────────────────────────────────────────────────────
info "Перезагружаю nginx…"
docker exec decoy nginx -s reload >/dev/null 2>&1 \
    || fail "nginx -s reload не удался. Проверь: docker logs decoy"
ok "nginx перезагружен"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Фронтенд обновлён!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Новые ассеты:"
while IFS= read -r f; do
    echo -e "    ${CYAN}${f}${NC}"
done <<< "$NEW_ASSETS"
echo ""
