from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.schemas.user import NameStr, PasswordStr, PhoneStr, UserPublic, UsernameStr


class RegisterRequest(BaseModel):
    """Public self-registration always creates an AFFECTED_PERSON account.
    Rescue-team and administrator accounts are created by an administrator."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "username": "priya_k",
                    "password": "a-long-passphrase",
                    "full_name": "Priya K",
                    "phone": "+91 98765 43210",
                }
            ]
        }
    )

    username: UsernameStr
    password: PasswordStr
    email: EmailStr | None = None
    full_name: NameStr | None = None
    phone: PhoneStr | None = None


class LoginRequest(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [{"username": "dis_comm", "password": "your-password"}]
        }
    )

    username: str = Field(
        min_length=1, max_length=255, description="Username or email address."
    )
    password: str = Field(min_length=1, max_length=128)


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime
    expires_in: int = Field(description="Seconds until the token expires.")
    user: UserPublic
