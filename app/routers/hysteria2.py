import secrets

from fastapi import APIRouter
from pydantic import BaseModel

from app.db import GetDB, crud
from app.hysteria2 import is_enabled
from app.models.proxy import ProxyTypes
from app.models.user import UserResponse, UserStatus
from config import HYSTERIA2_AUTH_SECRET

router = APIRouter(tags=["Hysteria2"], prefix="/api/hysteria2", include_in_schema=False)


class Hysteria2AuthRequest(BaseModel):
    addr: str = ""
    auth: str = ""
    tx: int | None = None


class Hysteria2AuthResponse(BaseModel):
    ok: bool
    id: str | None = None


def _validate_secret(auth_secret: str | None) -> bool:
    if not HYSTERIA2_AUTH_SECRET:
        return auth_secret in (None, "")
    return bool(auth_secret) and secrets.compare_digest(auth_secret, HYSTERIA2_AUTH_SECRET)


def _authenticate(payload: Hysteria2AuthRequest, auth_secret: str | None = None) -> Hysteria2AuthResponse:
    if not is_enabled() or not _validate_secret(auth_secret):
        return Hysteria2AuthResponse(ok=False)

    username, _, password = payload.auth.partition(":")
    if not username or not password:
        return Hysteria2AuthResponse(ok=False)

    with GetDB() as db:
        dbuser = crud.get_user(db, username)
        if not dbuser or dbuser.status not in (UserStatus.active, UserStatus.on_hold):
            return Hysteria2AuthResponse(ok=False)

        user = UserResponse.model_validate(dbuser)
        settings = user.proxies.get(ProxyTypes.Hysteria2)
        if not settings:
            return Hysteria2AuthResponse(ok=False)

        if not secrets.compare_digest(settings.password, password):
            return Hysteria2AuthResponse(ok=False)

        return Hysteria2AuthResponse(ok=True, id=user.username)


@router.post("/auth", response_model=Hysteria2AuthResponse)
def auth_without_secret(payload: Hysteria2AuthRequest):
    return _authenticate(payload)


@router.post("/{auth_secret}/auth", response_model=Hysteria2AuthResponse)
def auth_with_secret(auth_secret: str, payload: Hysteria2AuthRequest):
    return _authenticate(payload, auth_secret=auth_secret)
