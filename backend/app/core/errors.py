"""Error types and the centralized handlers that turn them into the
`{"success": false, "error": {...}}` envelope. No stack trace ever reaches
a client; details are logged server-side."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger("app.errors")


class AppError(Exception):
    status_code = 400
    code = "BAD_REQUEST"

    def __init__(
        self,
        message: str,
        *,
        code: str | None = None,
        status_code: int | None = None,
        details: Any = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        if code:
            self.code = code
        if status_code:
            self.status_code = status_code
        self.details = details
        self.headers = headers


class NotFoundError(AppError):
    status_code = 404
    code = "NOT_FOUND"


class ConflictError(AppError):
    status_code = 409
    code = "CONFLICT"


class InvalidTransitionError(AppError):
    status_code = 409
    code = "INVALID_STATUS_TRANSITION"


class AuthenticationError(AppError):
    status_code = 401
    code = "AUTHENTICATION_FAILED"

    def __init__(self, message: str = "Authentication required.", **kwargs: Any):
        kwargs.setdefault("headers", {"WWW-Authenticate": "Bearer"})
        super().__init__(message, **kwargs)


class AuthorizationError(AppError):
    status_code = 403
    code = "FORBIDDEN"


class InvalidInputError(AppError):
    status_code = 422
    code = "VALIDATION_ERROR"


class RateLimitedError(AppError):
    status_code = 429
    code = "RATE_LIMITED"


class ServiceUnavailableError(AppError):
    status_code = 503
    code = "SERVICE_UNAVAILABLE"


_HTTP_CODES = {
    400: "BAD_REQUEST",
    401: "AUTHENTICATION_FAILED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    405: "METHOD_NOT_ALLOWED",
    409: "CONFLICT",
    413: "PAYLOAD_TOO_LARGE",
    415: "UNSUPPORTED_MEDIA_TYPE",
    429: "RATE_LIMITED",
}


def error_body(
    code: str, message: str, details: Any = None, request_id: str | None = None
) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if details is not None:
        error["details"] = details
    if request_id:
        error["request_id"] = request_id
    return {"success": False, "error": error}


def _request_id(request: Request) -> str | None:
    return getattr(request.state, "request_id", None)


def _safe_validation_details(exc: RequestValidationError) -> list[dict[str, Any]]:
    # Pydantic includes the offending `input` (which could be a password)
    # and internal `ctx`; only the location/message/type are returned.
    return [
        {
            "field": ".".join(str(p) for p in err.get("loc", ()) if p != "body"),
            "message": err.get("msg", "Invalid value"),
            "type": err.get("type", "value_error"),
        }
        for err in exc.errors()
    ]


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(request: Request, exc: AppError) -> JSONResponse:
        if exc.status_code >= 500:
            logger.error("app_error", extra={"code": exc.code, "error": exc.message})
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(exc.code, exc.message, exc.details, _request_id(request)),
            headers=exc.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content=error_body(
                "VALIDATION_ERROR",
                "The request data is invalid.",
                _safe_validation_details(exc),
                _request_id(request),
            ),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _HTTP_CODES.get(exc.status_code, "HTTP_ERROR")
        message = exc.detail if isinstance(exc.detail, str) else "Request failed."
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(code, message, request_id=_request_id(request)),
            headers=getattr(exc, "headers", None),
        )

    @app.exception_handler(OperationalError)
    async def _db_unavailable(request: Request, exc: OperationalError) -> JSONResponse:
        logger.exception("database_unavailable")
        return JSONResponse(
            status_code=503,
            content=error_body(
                "DATABASE_UNAVAILABLE",
                "The database is temporarily unavailable. Retry later.",
                request_id=_request_id(request),
            ),
        )

    @app.exception_handler(SQLAlchemyError)
    async def _db_error(request: Request, exc: SQLAlchemyError) -> JSONResponse:
        logger.exception("database_error")
        return JSONResponse(
            status_code=500,
            content=error_body(
                "DATABASE_ERROR",
                "A database error occurred.",
                request_id=_request_id(request),
            ),
        )

    @app.exception_handler(Exception)
    async def _unexpected(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("unhandled_error")
        return JSONResponse(
            status_code=500,
            content=error_body(
                "INTERNAL_ERROR",
                "An unexpected error occurred.",
                request_id=_request_id(request),
            ),
        )
