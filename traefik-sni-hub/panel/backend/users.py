import json
import os
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import teleproxy_config

DATA_PATH = Path(os.environ.get("DATA_DIR", "/data")) / "users.json"


def _load_meta() -> list[dict]:
    if DATA_PATH.exists():
        return json.loads(DATA_PATH.read_text())
    return []


def _save_meta(users: list[dict]) -> None:
    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    DATA_PATH.write_text(json.dumps(users, indent=2))


def _next_id(meta: list[dict]) -> int:
    return max((m["id"] for m in meta), default=0) + 1


def _domain_hex() -> str:
    domain = os.environ.get("EE_DOMAIN_RAW", "")
    return domain.encode().hex()


def _build_full_secret(raw: str) -> str:
    return f"ee{raw}{_domain_hex()}"


def _raw_key(full_secret: str) -> str:
    """Extract plain 32-char hex from ee<32hex><domain_hex>."""
    if full_secret.startswith("ee") and len(full_secret) >= 34:
        return full_secret[2:34]
    return full_secret


def _toml_entry_for(meta_user: dict, max_conn: int) -> dict:
    return {"key": _raw_key(meta_user["secret"]), "label": meta_user.get("label", "user"), "limit": max_conn}


def _merge(meta: list[dict], env: dict, conn_stats: dict[str, int] | None = None) -> list[dict]:
    secret_map = {s["key"]: s for s in teleproxy_config.get_secrets(env)}
    if conn_stats is None:
        conn_stats = {}
    result = []
    for m in meta:
        env_entry = secret_map.get(_raw_key(m["secret"]), {})
        result.append({
            "id":       m["id"],
            "label":    m["label"],
            "secret":   m["secret"],
            "maxConn":  env_entry.get("limit", 15),
            "conn":     conn_stats.get(m["label"], 0),
            "active":   m.get("active", True),
            "created":  m["created"],
            "lastSeen": m.get("lastSeen", "never"),
        })
    return result


def list_users() -> list[dict]:
    meta = _load_meta()
    env  = teleproxy_config.read_env()
    conn_stats = teleproxy_config.fetch_conn_stats()
    users = _merge(meta, env, conn_stats)

    # Update lastSeen for users with active connections
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    meta_by_id = {m["id"]: m for m in meta}
    changed = False
    for u in users:
        if u["conn"] > 0:
            m = meta_by_id.get(u["id"])
            if m and m.get("lastSeen") != now:
                m["lastSeen"] = now
                u["lastSeen"] = now
                changed = True
    if changed:
        _save_meta(meta)

    return users


def create_user(label: str, max_conn: int) -> dict:
    meta = _load_meta()
    env  = teleproxy_config.read_env()

    raw         = secrets.token_hex(16)
    full_secret = _build_full_secret(raw)
    new_id      = _next_id(meta)

    entry = {
        "id":       new_id,
        "label":    label,
        "secret":   full_secret,
        "active":   True,
        "created":  datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "lastSeen": "never",
    }
    meta.append(entry)
    _save_meta(meta)

    teleproxy_config.add_secret(env, {"key": raw, "label": label, "limit": max_conn})
    teleproxy_config.write_env(env)
    teleproxy_config.write_toml(env)
    teleproxy_config.reload_teleproxy()

    return {**entry, "maxConn": max_conn, "conn": 0}


def update_user(user_id: int, active: Optional[bool] = None, max_conn: Optional[int] = None) -> Optional[dict]:
    meta = _load_meta()
    env  = teleproxy_config.read_env()

    entry = next((m for m in meta if m["id"] == user_id), None)
    if entry is None:
        return None

    raw_key      = _raw_key(entry["secret"])
    current_slot = next((s for s in teleproxy_config.get_secrets(env) if s["key"] == raw_key), {})
    current_max  = current_slot.get("limit", max_conn or 15)

    if active is not None:
        entry["active"] = active
        if not active:
            teleproxy_config.remove_secret(env, raw_key)
        elif not current_slot:
            teleproxy_config.add_secret(env, _toml_entry_for(entry, max_conn or current_max))

    if max_conn is not None:
        teleproxy_config.update_secret_limit(env, raw_key, max_conn)
        current_max = max_conn

    _save_meta(meta)
    teleproxy_config.write_env(env)
    teleproxy_config.write_toml(env)
    teleproxy_config.reload_teleproxy()

    return {
        "id":       entry["id"],
        "label":    entry["label"],
        "secret":   entry["secret"],
        "maxConn":  current_max,
        "conn":     0,
        "active":   entry["active"],
        "created":  entry["created"],
        "lastSeen": entry.get("lastSeen", "never"),
    }


def delete_user(user_id: int) -> bool:
    meta = _load_meta()
    env  = teleproxy_config.read_env()

    entry = next((m for m in meta if m["id"] == user_id), None)
    if entry is None:
        return False

    _save_meta([m for m in meta if m["id"] != user_id])
    teleproxy_config.remove_secret(env, _raw_key(entry["secret"]))
    teleproxy_config.write_env(env)
    teleproxy_config.write_toml(env)
    teleproxy_config.reload_teleproxy()
    return True


def sync_all_to_toml() -> None:
    """Ensure .env has all active users from users.json, then write TOML + SIGHUP.

    Called on backend startup. Handles the case where users.json has entries
    not yet reflected in .env (e.g. first start after panel reinstall).
    """
    meta    = _load_meta()
    env     = teleproxy_config.read_env()
    existing = {s["key"] for s in teleproxy_config.get_secrets(env)}
    changed  = False

    for m in meta:
        if not m.get("active", True):
            continue
        raw_key = _raw_key(m["secret"])
        if raw_key not in existing:
            teleproxy_config.add_secret(env, _toml_entry_for(m, 15))
            changed = True

    if changed:
        teleproxy_config.write_env(env)

    teleproxy_config.write_toml(env)
    teleproxy_config.reload_teleproxy()
