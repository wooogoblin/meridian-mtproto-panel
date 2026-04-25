from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt
import jwt

ALGORITHM = "HS256"


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()


def verify_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode(), hashed.encode())


def create_token(username: str, secret: str, expires_hours: int = 24) -> str:
    payload = {
        "sub": username,
        "exp": datetime.now(timezone.utc) + timedelta(hours=expires_hours),
    }
    return jwt.encode(payload, secret, algorithm=ALGORITHM)


def decode_token(token: str, secret: str) -> Optional[str]:
    try:
        payload = jwt.decode(token, secret, algorithms=[ALGORITHM])
        return payload["sub"]
    except jwt.PyJWTError:
        return None
