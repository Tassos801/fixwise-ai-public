"""Structured logging and request-ID middleware for FixWise AI."""

from __future__ import annotations

import contextvars
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

# ── Context var for the current request ID ────────────────────

_request_id_ctx: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "request_id", default=None
)


def get_request_id() -> str | None:
    """Return the request ID for the current context, or ``None``."""
    return _request_id_ctx.get()


# ── Request-ID middleware ─────────────────────────────────────


class RequestIdMiddleware(BaseHTTPMiddleware):
    """Generate a unique request ID, store it in *contextvars*, and echo it
    back as the ``X-Request-Id`` response header."""

    async def dispatch(self, request: Request, call_next: Any) -> Response:
        request_id = uuid.uuid4().hex
        token = _request_id_ctx.set(request_id)
        try:
            response: Response = await call_next(request)
            response.headers["X-Request-Id"] = request_id
            return response
        finally:
            _request_id_ctx.reset(token)


# ── Log filter that injects request_id ────────────────────────


class RequestIdFilter(logging.Filter):
    """Attach ``request_id`` to every log record so formatters can use it."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = get_request_id() or "-"  # type: ignore[attr-defined]
        return True


# ── JSON formatter for production ─────────────────────────────


class JSONFormatter(logging.Formatter):
    """Emit each log record as a single JSON object."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "request_id": getattr(record, "request_id", "-"),
            "module": record.module,
        }
        if record.exc_info and record.exc_info[1] is not None:
            log_entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_entry)


# ── Public setup function ─────────────────────────────────────

_DEV_FORMAT = "%(asctime)s %(levelname)s [%(request_id)s] %(name)s: %(message)s"


def setup_logging(environment: str) -> None:
    """Configure the root ``fixwise`` logger.

    * **production** -- structured JSON on stdout.
    * **development** (or anything else) -- human-readable coloured output.
    """
    root_logger = logging.getLogger("fixwise")
    root_logger.setLevel(logging.INFO)

    # Avoid duplicate handlers when called more than once (e.g. tests).
    if root_logger.handlers:
        return

    handler = logging.StreamHandler()

    # Always attach the request-id filter.
    handler.addFilter(RequestIdFilter())

    if environment == "production":
        handler.setFormatter(JSONFormatter())
    else:
        handler.setFormatter(logging.Formatter(_DEV_FORMAT))

    root_logger.addHandler(handler)
