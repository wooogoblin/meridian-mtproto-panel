import os
from pathlib import Path

import docker

ENV_PATH  = Path(os.environ.get("MTPROTO_ENV_PATH", "/mtproto/.env"))
TOML_PATH = Path(os.environ.get("TOML_PATH", "/teleproxy/config.toml"))
CONTAINER_NAME = "mtproto"


# ─── .env read/write ──────────────────────────────────────────────────────────

def read_env() -> dict:
    if not ENV_PATH.exists():
        return {}
    result = {}
    for line in ENV_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, _, v = line.partition('=')
        result[k.strip()] = v.strip()
    return result


def write_env(env: dict) -> None:
    ENV_PATH.write_text(''.join(f"{k}={v}\n" for k, v in env.items()))


# ─── Secrets in .env ──────────────────────────────────────────────────────────

def get_secrets(env: dict) -> list[dict]:
    secrets = []
    for i in range(1, 17):
        key = env.get(f"SECRET_{i}", "").strip()
        if key:
            secrets.append({
                "key":   key,
                "label": env.get(f"SECRET_LABEL_{i}", "").strip(),
                "limit": int(env.get(f"SECRET_LIMIT_{i}", "15") or "15"),
                "slot":  i,
            })
    return secrets


def add_secret(env: dict, entry: dict) -> None:
    used = {i for i in range(1, 17) if env.get(f"SECRET_{i}", "").strip()}
    slot = next((i for i in range(1, 17) if i not in used), None)
    if slot is None:
        raise ValueError("Maximum 16 secrets reached")
    env[f"SECRET_{slot}"] = entry["key"]
    if entry.get("label"):
        env[f"SECRET_LABEL_{slot}"] = entry["label"]
    env[f"SECRET_LIMIT_{slot}"] = str(entry.get("limit", 15))


def remove_secret(env: dict, key: str) -> bool:
    for i in range(1, 17):
        if env.get(f"SECRET_{i}", "").strip() == key:
            env.pop(f"SECRET_{i}", None)
            env.pop(f"SECRET_LABEL_{i}", None)
            env.pop(f"SECRET_LIMIT_{i}", None)
            return True
    return False


def update_secret_limit(env: dict, key: str, limit: int) -> bool:
    for i in range(1, 17):
        if env.get(f"SECRET_{i}", "").strip() == key:
            env[f"SECRET_LIMIT_{i}"] = str(limit)
            return True
    return False


def update_secret_label(env: dict, key: str, label: str) -> bool:
    for i in range(1, 17):
        if env.get(f"SECRET_{i}", "").strip() == key:
            env[f"SECRET_LABEL_{i}"] = label
            return True
    return False


# ─── TOML (hot-reload via SIGHUP) ─────────────────────────────────────────────

def write_toml(env: dict) -> None:
    """Write config.toml from env state. Called after any secret change + SIGHUP."""
    lines = [
        f"port = {env.get('PORT', 2443)}",
        f"stats_port = {env.get('STATS_PORT', 8888)}",
        "http_stats = true",
        "workers = 1",
        "maxconn = 10000",
        'user = "teleproxy"',
        "",
    ]
    ee_domain = env.get("EE_DOMAIN", "")
    if ee_domain:
        lines.append(f'domain = "{ee_domain}"')
        lines.append("")
    for s in get_secrets(env):
        lines.append("[[secret]]")
        lines.append(f'key = "{s["key"]}"')
        if s.get("label"):
            lines.append(f'label = "{s["label"]}"')
        lines.append(f'limit = {s["limit"]}')
        lines.append("")
    TOML_PATH.parent.mkdir(parents=True, exist_ok=True)
    TOML_PATH.write_text('\n'.join(lines))


# ─── Reload ───────────────────────────────────────────────────────────────────

def reload_teleproxy() -> bool:
    try:
        client = docker.from_env()
        container = client.containers.get(CONTAINER_NAME)
        container.kill(signal="HUP")
        return True
    except Exception:
        return False


# ─── Live connection stats ────────────────────────────────────────────────────

def fetch_conn_stats() -> dict[str, int]:
    """Return {label: current_connections} from teleproxy Prometheus /metrics. Falls back to {}."""
    import re
    from urllib.request import urlopen
    try:
        with urlopen("http://mtproto:8888/metrics", timeout=2) as resp:
            text = resp.read().decode()
    except Exception:
        return {}
    result: dict[str, int] = {}
    for line in text.splitlines():
        if not line.startswith('teleproxy_secret_connections{'):
            continue
        m = re.match(r'teleproxy_secret_connections\{secret="([^"]+)"\}\s+(\d+)', line)
        if m:
            result[m.group(1)] = int(m.group(2))
    return result
