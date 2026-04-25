import os
from pathlib import Path

import docker
import toml

TOML_PATH = Path(os.environ.get("TOML_PATH", "/teleproxy/config.toml"))
CONTAINER_NAME = "mtproto"


def read_toml() -> dict:
    if TOML_PATH.exists():
        return toml.loads(TOML_PATH.read_text())
    return {}


def write_toml(data: dict) -> None:
    TOML_PATH.parent.mkdir(parents=True, exist_ok=True)
    TOML_PATH.write_text(toml.dumps(data))


def reload_teleproxy() -> bool:
    try:
        client = docker.from_env()
        container = client.containers.get(CONTAINER_NAME)
        container.kill(signal="HUP")
        return True
    except Exception:
        return False


def get_secrets(data: dict) -> list[dict]:
    return data.get("secret", [])


def add_secret(data: dict, entry: dict) -> None:
    data.setdefault("secret", []).append(entry)


def remove_secret(data: dict, secret_value: str) -> bool:
    before = len(data.get("secret", []))
    data["secret"] = [s for s in data.get("secret", []) if s.get("key") != secret_value]
    return len(data["secret"]) < before


def update_secret_limit(data: dict, secret_value: str, max_connections: int) -> bool:
    for s in data.get("secret", []):
        if s.get("key") == secret_value:
            s["limit"] = max_connections
            return True
    return False
