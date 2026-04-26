import asyncio
import json
import os
import time
from collections import defaultdict
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Optional

from fastapi import Cookie, Depends, FastAPI, HTTPException, Request, Response
from pydantic import BaseModel

import auth
import users as users_module

CONFIG_PATH = Path(os.environ.get("DATA_DIR", "/data")) / "config.json"


async def _sync_users_delayed():
    # Wait for teleproxy to start and regenerate config.toml from env vars,
    # then re-apply any panel users that aren't in the freshly generated TOML.
    await asyncio.sleep(15)
    try:
        users_module.sync_all_to_toml()
    except Exception:
        pass


@asynccontextmanager
async def _lifespan(app: FastAPI):
    asyncio.create_task(_sync_users_delayed())
    yield


app = FastAPI(lifespan=_lifespan, docs_url=None, redoc_url=None, openapi_url=None)


# ─── Config ───────────────────────────────────────────────────────────────────

def load_config() -> dict:
    return json.loads(CONFIG_PATH.read_text())


# ─── Fail2ban (in-memory) ─────────────────────────────────────────────────────

_attempts: dict[str, list[float]] = defaultdict(list)
MAX_ATTEMPTS = 5
BLOCK_SECONDS = 900  # 15 min


def _client_ip(request: Request) -> str:
    xri = request.headers.get("x-real-ip")
    return xri.strip() if xri else (request.client.host or "unknown")


def _check_rate_limit(ip: str) -> None:
    now = time.time()
    _attempts[ip] = [t for t in _attempts[ip] if now - t < BLOCK_SECONDS]
    if len(_attempts[ip]) >= MAX_ATTEMPTS:
        raise HTTPException(status_code=429, detail="Too many failed attempts. Try again in 15 minutes.")


def _record_failure(ip: str) -> None:
    _attempts[ip].append(time.time())


def _clear_attempts(ip: str) -> None:
    _attempts.pop(ip, None)


# ─── Auth dependency ──────────────────────────────────────────────────────────

def get_current_user(token: Annotated[Optional[str], Cookie()] = None) -> str:
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        cfg = load_config()
    except Exception:
        raise HTTPException(status_code=500, detail="Server configuration error")
    username = auth.decode_token(token, cfg["jwt_secret"])
    if not username:
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    return username


AuthUser = Annotated[str, Depends(get_current_user)]


# ─── Auth routes ──────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str
    remember: bool = False


@app.post("/api/v1/auth/login")
async def login(body: LoginRequest, request: Request, response: Response):
    ip = _client_ip(request)
    _check_rate_limit(ip)

    try:
        cfg = load_config()
    except Exception:
        raise HTTPException(status_code=500, detail="Server configuration error")

    if body.username != cfg["username"] or not auth.verify_password(body.password, cfg["password_hash"]):
        _record_failure(ip)
        raise HTTPException(status_code=401, detail="Invalid username or password.")

    _clear_attempts(ip)
    expires_hours = 720 if body.remember else 24
    token = auth.create_token(cfg["username"], cfg["jwt_secret"], expires_hours=expires_hours)

    response.set_cookie(
        "token", token,
        httponly=True,
        secure=True,
        samesite="strict",
        max_age=expires_hours * 3600,
    )
    return {"ok": True}


@app.post("/api/v1/auth/logout")
async def logout(response: Response):
    response.delete_cookie("token", httponly=True, secure=True, samesite="strict")
    return {"ok": True}


@app.get("/api/v1/auth/me")
async def me(user: AuthUser):
    return {"username": user}


# ─── Users ────────────────────────────────────────────────────────────────────

class CreateUserRequest(BaseModel):
    label: str
    maxConn: int


class UpdateUserRequest(BaseModel):
    active: Optional[bool] = None
    maxConn: Optional[int] = None
    label: Optional[str] = None


@app.get("/api/v1/users")
async def list_users(user: AuthUser):
    return users_module.list_users()


@app.post("/api/v1/users", status_code=201)
async def create_user(body: CreateUserRequest, user: AuthUser):
    label = body.label.strip()
    if not label or not all(c.isalnum() or c in "-_" for c in label):
        raise HTTPException(status_code=400, detail="Label: letters, digits, - and _ only")
    if not 1 <= body.maxConn <= 100:
        raise HTTPException(status_code=400, detail="maxConn must be between 1 and 100")
    return users_module.create_user(label, body.maxConn)


@app.put("/api/v1/users/{user_id}")
async def update_user(user_id: int, body: UpdateUserRequest, user: AuthUser):
    if body.maxConn is not None and not 1 <= body.maxConn <= 100:
        raise HTTPException(status_code=400, detail="maxConn must be between 1 and 100")
    if body.label is not None:
        lbl = body.label.strip()
        if not lbl or not all(c.isalnum() or c in "-_" for c in lbl):
            raise HTTPException(status_code=400, detail="Label: letters, digits, - and _ only")
    result = users_module.update_user(user_id, active=body.active, max_conn=body.maxConn, label=body.label.strip() if body.label else None)
    if result is None:
        raise HTTPException(status_code=404, detail="User not found")
    return result


@app.delete("/api/v1/users/{user_id}", status_code=204)
async def delete_user(user_id: int, user: AuthUser):
    if not users_module.delete_user(user_id):
        raise HTTPException(status_code=404, detail="User not found")


# ─── Stats ────────────────────────────────────────────────────────────────────

@app.get("/api/v1/stats")
async def stats(user: AuthUser):
    all_users = users_module.list_users()
    return {
        "activeUsers": sum(1 for u in all_users if u["active"]),
        "totalConn": sum(u["conn"] for u in all_users),
        "totalUsers": len(all_users),
    }


# ─── Config (server identity for link building) ───────────────────────────────

@app.get("/api/v1/config")
async def config(user: AuthUser):
    return {
        "serverIp": os.environ.get("SERVER_IP", ""),
        "domain":   os.environ.get("EE_DOMAIN_RAW", ""),
    }
