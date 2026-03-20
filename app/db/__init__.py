import os

from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from .base import Base, SessionLocal, engine  # noqa

MINIMAL_DB_IMPORT = os.getenv("MARZBAN_MINIMAL_APP_IMPORT") == "1" or os.getenv("MARZBAN_MINIMAL_DB_IMPORT") == "1"


class GetDB:  # Context Manager
    def __init__(self):
        self.db = SessionLocal()

    def __enter__(self):
        return self.db

    def __exit__(self, exc_type, exc_value, traceback):
        if isinstance(exc_value, SQLAlchemyError):
            self.db.rollback()  # rollback on exception

        self.db.close()


def get_db():  # Dependency
    with GetDB() as db:
        yield db


__all__ = [
    "GetDB",
    "get_db",
    "Base",
    "Session",
]

if not MINIMAL_DB_IMPORT:
    from .crud import (create_admin, create_notification_reminder,  # noqa
                       create_user, delete_notification_reminder, get_admin,
                       get_admins, get_jwt_secret_key, get_notification_reminder,
                       get_or_create_inbound, get_system_usage,
                       get_tls_certificate, get_user, get_user_by_id, get_users,
                       get_users_count, remove_admin, remove_user, revoke_user_sub,
                       set_owner, update_admin, update_user, update_user_status, reset_user_by_next,
                       update_user_sub, start_user_expire, get_admin_by_id,
                       get_admin_by_telegram_id)

    from .models import JWT, System, User  # noqa

    __all__.extend([
        "get_or_create_inbound",
        "get_user",
        "get_user_by_id",
        "get_users",
        "get_users_count",
        "create_user",
        "remove_user",
        "update_user",
        "update_user_status",
        "start_user_expire",
        "update_user_sub",
        "reset_user_by_next",
        "revoke_user_sub",
        "set_owner",
        "get_system_usage",
        "get_jwt_secret_key",
        "get_tls_certificate",
        "get_admin",
        "create_admin",
        "update_admin",
        "remove_admin",
        "get_admins",
        "get_admin_by_id",
        "get_admin_by_telegram_id",
        "create_notification_reminder",
        "get_notification_reminder",
        "delete_notification_reminder",
        "User",
        "System",
        "JWT",
    ])
