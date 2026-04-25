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
    """Extract plain 32-char hex from ee<32hex><domain_hex>.
    Teleproxy stores secrets as plain hex; ee-encoding is handled via EE_DOMAIN env."""
    if full_secret.startswith("ee") and len(full_secret) >= 34:
        return full_secret[2:34]
    return full_secret


def _toml_entry_for(meta_user: dict, max_conn: int) -> dict:
    return {"key": _raw_key(meta_user["secret"]), "label": meta_user.get("label", "user"), "limit": max_conn}


def _merge(meta: list[dict], toml_data: dict) -> list[dict]:
    secret_map = {s["key"]: s for s in teleproxy_config.get_secrets(toml_data)}
    result = []
    for m in meta:
        toml_entry = secret_map.get(_raw_key(m["secret"]), {})
        result.append({
            "id": m["id"],
            "label": m["label"],
            "secret": m["secret"],
            "maxConn": toml_entry.get("limit", 0),
            "conn": 0,
            "active": m.get("active", True),
            "created": m["created"],
            "lastSeen": m.get("lastSeen", "never"),
        })
    return result


def list_users() -> list[dict]:
    return _merge(_load_meta(), teleproxy_config.read_toml())


def create_user(label: str, max_conn: int) -> dict:
    meta = _load_meta()
    toml_data = teleproxy_config.read_toml()

    raw = secrets.token_hex(16)
    full_secret = _build_full_secret(raw)
    new_id = _next_id(meta)

    entry = {
        "id": new_id,
        "label": label,
        "secret": full_secret,
        "active": True,
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "lastSeen": "never",
    }
    meta.append(entry)
    _save_meta(meta)

    teleproxy_config.add_secret(toml_data, _toml_entry_for(entry, max_conn))
    teleproxy_config.write_toml(toml_data)
    teleproxy_config.reload_teleproxy()

    return {**entry, "maxConn": max_conn, "conn": 0}


def update_user(user_id: int, active: Optional[bool] = None, max_conn: Optional[int] = None) -> Optional[dict]:
    meta = _load_meta()
    toml_data = teleproxy_config.read_toml()

    entry = next((m for m in meta if m["id"] == user_id), None)
    if entry is None:
        return None

    # Resolve current maxConn before potentially modifying TOML
    current_max = next(
        (s.get("limit", 15) for s in teleproxy_config.get_secrets(toml_data) if s.get("key") == _raw_key(entry["secret"])),
        max_conn or 15,
    )

    if active is not None:
        entry["active"] = active
        if not active:
            teleproxy_config.remove_secret(toml_data, _raw_key(entry["secret"]))
        else:
            existing = any(s.get("key") == _raw_key(entry["secret"]) for s in teleproxy_config.get_secrets(toml_data))
            if not existing:
                teleproxy_config.add_secret(toml_data, _toml_entry_for(entry, max_conn or current_max))

    if max_conn is not None:
        teleproxy_config.update_secret_limit(toml_data, _raw_key(entry["secret"]), max_conn)
        current_max = max_conn

    _save_meta(meta)
    teleproxy_config.write_toml(toml_data)
    teleproxy_config.reload_teleproxy()

    return {
        "id": entry["id"],
        "label": entry["label"],
        "secret": entry["secret"],
        "maxConn": current_max,
        "conn": 0,
        "active": entry["active"],
        "created": entry["created"],
        "lastSeen": entry.get("lastSeen", "never"),
    }


def delete_user(user_id: int) -> bool:
    meta = _load_meta()
    toml_data = teleproxy_config.read_toml()

    entry = next((m for m in meta if m["id"] == user_id), None)
    if entry is None:
        return False

    _save_meta([m for m in meta if m["id"] != user_id])
    teleproxy_config.remove_secret(toml_data, _raw_key(entry["secret"]))
    teleproxy_config.write_toml(toml_data)
    teleproxy_config.reload_teleproxy()
    return True
