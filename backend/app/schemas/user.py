from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.domain.enums import UserRole
from app.schemas.common import ORMModel

UsernameStr = Annotated[
    str,
    Field(
        min_length=3,
        max_length=64,
        pattern=r"^[A-Za-z0-9_.\-]+$",
        description="Login name, e.g. a Rescue ID such as `dis_comm`.",
    ),
]
PasswordStr = Annotated[str, Field(min_length=8, max_length=128, description="8-128 characters.")]
NameStr = Annotated[str, Field(max_length=120)]
PhoneStr = Annotated[str, Field(max_length=32, pattern=r"^[0-9+()\-\s]{3,32}$")]


class UserPublic(ORMModel):
    id: uuid.UUID
    username: str
    email: str | None
    full_name: str | None
    phone: str | None
    role: UserRole
    is_active: bool
    created_at: datetime
    last_login_at: datetime | None


class UserCreate(BaseModel):
    """Administrator creates any account, including RESCUE_TEAM and ADMIN."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "username": "rescuer_01",
                    "password": "use-a-long-passphrase",
                    "full_name": "Rescue Member One",
                    "role": "RESCUE_TEAM",
                }
            ]
        }
    )

    username: UsernameStr
    password: PasswordStr
    email: EmailStr | None = None
    full_name: NameStr | None = None
    phone: PhoneStr | None = None
    role: UserRole = UserRole.AFFECTED_PERSON


class UserUpdate(BaseModel):
    email: EmailStr | None = None
    full_name: NameStr | None = None
    phone: PhoneStr | None = None
    role: UserRole | None = None
    is_active: bool | None = None
    password: PasswordStr | None = None
