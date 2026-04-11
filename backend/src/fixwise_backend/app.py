from __future__ import annotations

import json
import logging
import platform
import time
from contextlib import asynccontextmanager
from datetime import datetime, UTC
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pydantic import ValidationError

from .ai import AIProvider, build_ai_provider
from .auth import (
    AuthResponse,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    get_current_user_id,
    login_user,
    refresh_tokens,
    register_user,
    require_auth,
)
from .config import Settings, get_settings
from .logging_config import RequestIdMiddleware, setup_logging
from .database import Database
from .encryption import decrypt_api_key, encrypt_api_key, mask_api_key
from .models import (
    APIKeyRequest,
    EndSessionMessage,
    ErrorMessage,
    FrameMessage,
    PromptMessage,
    ResponseMessage,
    SafetyBlockMessage,
    parse_client_message,
)
from .pdf_report import generate_fix_report
from .rate_limit import (
    InMemoryRateLimiter,
    RateLimitPolicy,
    client_identifier_from_request,
    client_identifier_from_websocket,
    raise_for_rate_limit,
)
from .safety import check_safety
from .session_manager import SessionManager


logger = logging.getLogger("fixwise")


def create_app(
    settings: Settings | None = None,
    provider: AIProvider | None = None,
    session_manager: SessionManager | None = None,
    database: Database | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    resolved_settings.validate()
    resolved_session_manager = session_manager or SessionManager()
    ai_provider = provider or build_ai_provider(resolved_settings)
    db = database or Database(resolved_settings.database_path or ":memory:")
    rate_limiter = InMemoryRateLimiter()

    startup_time: float = 0.0

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        nonlocal startup_time
        startup_time = time.monotonic()
        logger.info(
            "FixWise backend starting with %s provider.",
            ai_provider.provider_name,
        )
        await db.connect()
        yield
        await db.close()
        logger.info("FixWise backend shutting down.")

    app = FastAPI(
        title=resolved_settings.app_name,
        version=resolved_settings.app_version,
        lifespan=lifespan,
    )
    app.state.settings = resolved_settings
    app.state.session_manager = resolved_session_manager
    app.state.ai_provider = ai_provider
    app.state.db = db
    app.state.rate_limiter = rate_limiter

    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(resolved_settings.allowed_origins),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    setup_logging(resolved_settings.environment)
    app.add_middleware(RequestIdMiddleware)

    # ── Health ─────────────────────────────────────────────

    def http_rate_limit_dependency(scope: str, max_requests: int):
        async def dependency(request: Request) -> None:
            retry_after = rate_limiter.hit(
                key=f"http:{scope}:{client_identifier_from_request(request)}",
                policy=RateLimitPolicy(
                    max_requests=max_requests,
                    window_seconds=resolved_settings.rate_limit_window_seconds,
                ),
            )
            if retry_after is not None:
                raise_for_rate_limit(retry_after, scope)

        return dependency

    async def _check_db() -> bool:
        """Execute a lightweight query to verify database connectivity."""
        try:
            cursor = await db.db.execute("SELECT 1")
            await cursor.fetchone()
            return True
        except Exception:
            return False

    @app.get("/health")
    async def health() -> dict:
        db_ok = await _check_db()
        uptime = round(time.monotonic() - startup_time, 1) if startup_time else 0
        live_ready = bool(resolved_settings.openai_api_key)
        return {
            "status": "ok" if db_ok else "degraded",
            "name": resolved_settings.app_name,
            "version": resolved_settings.app_version,
            "uptime_seconds": uptime,
            "timestamp": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            "python_version": platform.python_version(),
            "provider": ai_provider.provider_name,
            "liveReady": live_ready,
            "desiredMode": resolved_settings.ai_mode,
            "liveConfigured": live_ready,
            "ai": {
                "mode": resolved_settings.ai_mode,
                "provider": ai_provider.provider_name,
                "liveReady": live_ready,
                "model": resolved_settings.openai_model,
            },
            "database": {
                "status": "connected" if db_ok else "unreachable",
            },
            "sessions": {
                "active": len(resolved_session_manager.sessions),
            },
            "environment": resolved_settings.environment,
        }

    @app.get("/ready")
    async def ready():
        if await _check_db():
            return {"status": "ok"}
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"status": "unavailable", "reason": "database unreachable"},
        )

    # ── Auth Routes ────────────────────────────────────────

    @app.post("/api/auth/register", response_model=AuthResponse)
    async def register(
        req: RegisterRequest,
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        return await register_user(req, db)

    @app.post("/api/auth/login", response_model=AuthResponse)
    async def login(
        req: LoginRequest,
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        return await login_user(req, db)

    @app.post("/api/auth/refresh", response_model=AuthResponse)
    async def refresh(
        req: RefreshRequest,
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        return await refresh_tokens(req, db)

    @app.get("/api/auth/me")
    async def get_me(
        _: None = Depends(
            http_rate_limit_dependency("session", resolved_settings.session_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        api_key_row = await db.get_api_key(user_id)
        return {
            "id": user.id,
            "email": user.email,
            "displayName": user.display_name,
            "tier": user.tier,
            "hasApiKey": api_key_row is not None,
            "apiKeyMask": api_key_row.key_mask if api_key_row else None,
        }

    # ── BYOK API Key Management ────────────────────────────

    @app.put("/api/settings/api-key")
    async def save_api_key(
        req: APIKeyRequest,
        _: None = Depends(
            http_rate_limit_dependency("settings", resolved_settings.settings_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        key = req.apiKey.strip()
        if not key.startswith("sk-") or len(key) < 43:
            raise HTTPException(status_code=400, detail="Invalid API key format.")

        # Validate with a lightweight OpenAI call
        try:
            import httpx
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    "https://api.openai.com/v1/models",
                    headers={"Authorization": f"Bearer {key}"},
                    timeout=10.0,
                )
                if resp.status_code == 401:
                    raise HTTPException(status_code=400, detail="API key is invalid or revoked.")
                if resp.status_code != 200:
                    raise HTTPException(
                        status_code=400,
                        detail=f"Could not validate key (OpenAI returned {resp.status_code}).",
                    )
        except httpx.RequestError:
            raise HTTPException(status_code=502, detail="Could not reach OpenAI to validate key.")

        encrypted = encrypt_api_key(user_id, key)
        key_mask = mask_api_key(key)
        await db.store_api_key(user_id=user_id, encrypted_key=encrypted, key_mask=key_mask)

        return {"maskedKey": key_mask, "valid": True}

    @app.delete("/api/settings/api-key")
    async def delete_api_key(
        _: None = Depends(
            http_rate_limit_dependency("settings", resolved_settings.settings_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        deleted = await db.delete_api_key(user_id)
        if not deleted:
            raise HTTPException(status_code=404, detail="No API key found.")
        return {"status": "deleted"}

    @app.get("/api/settings/api-key")
    async def get_api_key_status(
        _: None = Depends(
            http_rate_limit_dependency("settings", resolved_settings.settings_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        row = await db.get_api_key(user_id)
        if not row:
            return {"hasKey": False, "maskedKey": None}
        return {"hasKey": True, "maskedKey": row.key_mask}

    # ── Session History ────────────────────────────────────

    @app.get("/api/sessions")
    async def list_sessions(
        _: None = Depends(
            http_rate_limit_dependency("session", resolved_settings.session_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        sessions = await db.list_sessions(user_id)
        return {
            "sessions": [
                {
                    "id": s.id,
                    "status": s.status,
                    "stepCount": s.step_count,
                    "startedAt": s.started_at,
                    "endedAt": s.ended_at,
                    "reportUrl": s.report_url,
                }
                for s in sessions
            ]
        }

    @app.get("/api/sessions/{session_id}")
    async def get_session_detail(
        session_id: str,
        _: None = Depends(
            http_rate_limit_dependency("session", resolved_settings.session_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        session = await db.get_session(session_id)
        if not session or session.user_id != user_id:
            raise HTTPException(status_code=404, detail="Session not found.")

        steps = await db.get_session_steps(session_id)
        return {
            "id": session.id,
            "status": session.status,
            "stepCount": session.step_count,
            "startedAt": session.started_at,
            "endedAt": session.ended_at,
            "reportUrl": session.report_url,
            "steps": [
                {
                    "stepNumber": step.step_number,
                    "text": step.ai_response_text,
                    "safetyWarning": step.safety_warning,
                    "hasFrame": step.frame_thumbnail is not None,
                    "createdAt": step.created_at,
                }
                for step in steps
            ],
        }

    @app.get("/api/sessions/{session_id}/report")
    async def get_fix_report_endpoint(
        session_id: str,
        _: None = Depends(
            http_rate_limit_dependency("session", resolved_settings.session_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        session = await db.get_session(session_id)
        if not session or session.user_id != user_id:
            raise HTTPException(status_code=404, detail="Session not found.")

        if session.status != "completed":
            raise HTTPException(status_code=400, detail="Report only available for completed sessions.")

        steps = await db.get_session_steps(session_id)
        pdf_bytes = generate_fix_report(session, steps)

        return Response(
            content=pdf_bytes,
            media_type="application/pdf",
            headers={
                "Content-Disposition": f'attachment; filename="fixwise-report-{session_id[:8]}.pdf"'
            },
        )

    # ── WebSocket Session ──────────────────────────────────

    @app.websocket("/ws/session")
    async def websocket_session(websocket: WebSocket):
        client_id = client_identifier_from_websocket(websocket)
        connect_retry_after = rate_limiter.hit(
            key=f"ws:connect:{client_id}",
            policy=RateLimitPolicy(
                max_requests=resolved_settings.websocket_connect_rate_limit_requests,
                window_seconds=resolved_settings.rate_limit_window_seconds,
            ),
        )
        await websocket.accept()

        if connect_retry_after is not None:
            await websocket.send_json(
                ErrorMessage(
                    message=f"Rate limit exceeded for websocket connections. Retry in {connect_retry_after} seconds."
                ).model_dump(mode="json")
            )
            await websocket.close(code=1013)
            return

        # Extract user from query param or default to demo
        token = websocket.query_params.get("token")
        user_id = "demo_user"
        if token:
            try:
                from .auth import decode_token
                payload = decode_token(token)
                user_id = payload.get("sub", "demo_user")
            except Exception:
                pass

        # Ensure demo user exists in DB for unauthenticated sessions
        existing = await db.get_user_by_id(user_id)
        if not existing:
            try:
                await db.create_user(
                    user_id=user_id, email=f"{user_id}@fixwise.local",
                    password_hash="none",
                )
            except Exception:
                pass  # User may already exist from a concurrent connection

        session_id: str | None = None

        try:
            while True:
                raw_payload = await websocket.receive_text()
                try:
                    message = validate_message_payload(raw_payload)
                except ValueError as exc:
                    await websocket.send_json(
                        ErrorMessage(message=str(exc)).model_dump(mode="json")
                    )
                    continue

                if isinstance(message, FrameMessage):
                    # Lazily create DB session on first frame
                    if session_id is None:
                        session_id = message.sessionId
                        await db.create_session(session_id=session_id, user_id=user_id)

                    resolved_session_manager.store_frame(
                        session_id=message.sessionId,
                        frame_b64=message.frame,
                        metadata=message.frameMetadata,
                        captured_at=message.timestamp,
                    )
                    continue

                if isinstance(message, PromptMessage):
                    prompt_retry_after = rate_limiter.hit(
                        key=f"ws:prompt:{client_id}",
                        policy=RateLimitPolicy(
                            max_requests=resolved_settings.websocket_prompt_rate_limit_requests,
                            window_seconds=resolved_settings.rate_limit_window_seconds,
                        ),
                    )
                    if prompt_retry_after is not None:
                        await websocket.send_json(
                            ErrorMessage(
                                sessionId=message.sessionId,
                                message=f"Rate limit exceeded for websocket prompts. Retry in {prompt_retry_after} seconds.",
                            ).model_dump(mode="json")
                        )
                        continue

                    if session_id is None:
                        session_id = message.sessionId
                        await db.create_session(session_id=session_id, user_id=user_id)

                    safety_issue = check_safety(message.text)
                    if safety_issue:
                        await websocket.send_json(
                            SafetyBlockMessage(
                                sessionId=message.sessionId,
                                reason=safety_issue,
                                recommendation="Contact a licensed professional for this type of work.",
                            ).model_dump(mode="json", by_alias=True)
                        )
                        continue

                    latest_frame = resolved_session_manager.get_latest_frame(message.sessionId)
                    if latest_frame is None:
                        await websocket.send_json(
                            ErrorMessage(
                                sessionId=message.sessionId,
                                message="A frame must be sent before a prompt can be analyzed.",
                            ).model_dump(mode="json")
                        )
                        continue

                    # Resolve AI provider: prefer user's BYOK key
                    active_provider = ai_provider
                    if user_id != "demo_user":
                        api_key_row = await db.get_api_key(user_id)
                        if api_key_row:
                            try:
                                user_key = decrypt_api_key(user_id, api_key_row.encrypted_key)
                                from .ai import OpenAIVisionProvider
                                active_provider = OpenAIVisionProvider(
                                    api_key=user_key,
                                    model=resolved_settings.openai_model,
                                )
                            except Exception:
                                logger.warning("Failed to decrypt BYOK key for user %s", user_id)

                    try:
                        ai_response = await active_provider.analyze(
                            frame_b64=latest_frame.base64_jpeg,
                            prompt=message.text,
                            session_id=message.sessionId,
                        )
                    except Exception as exc:
                        logger.exception("AI provider failed during prompt handling.")
                        await websocket.send_json(
                            ErrorMessage(
                                sessionId=message.sessionId,
                                message=f"Unable to analyze prompt right now: {exc}",
                            ).model_dump(mode="json")
                        )
                        continue

                    step_number = resolved_session_manager.next_step(message.sessionId)

                    # Persist step to database
                    await db.add_session_step(
                        session_id=message.sessionId,
                        step_number=step_number,
                        ai_response_text=ai_response.text,
                        frame_thumbnail=latest_frame.base64_jpeg if latest_frame else None,
                        annotations_json=json.dumps(
                            [a.model_dump(mode="json", by_alias=True) for a in ai_response.annotations]
                        ) if ai_response.annotations else None,
                        safety_warning=ai_response.safetyWarning,
                    )
                    await db.increment_step_count(message.sessionId)

                    await websocket.send_json(
                        ResponseMessage(
                            sessionId=message.sessionId,
                            text=ai_response.text,
                            audio=None,
                            annotations=ai_response.annotations,
                            stepNumber=step_number,
                            safetyWarning=ai_response.safetyWarning,
                        ).model_dump(mode="json", by_alias=True)
                    )
                    continue

                if isinstance(message, EndSessionMessage):
                    if session_id:
                        await db.end_session(session_id)
                    resolved_session_manager.end_session(message.sessionId)
                    await websocket.close(code=1000)
                    break

        except WebSocketDisconnect:
            logger.info("Client disconnected from session websocket.")
            if session_id:
                await db.end_session(session_id)
        finally:
            if session_id:
                resolved_session_manager.end_session(session_id)

    return app


def validate_message_payload(payload: Any):
    if isinstance(payload, str):
        try:
            decoded = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise ValueError("Invalid JSON payload.") from exc
    elif isinstance(payload, dict):
        decoded = payload
    else:
        raise ValueError("Message body must be JSON text or a decoded object.")

    try:
        return parse_client_message(decoded)
    except ValidationError as exc:
        raise ValueError(exc.errors()[0]["msg"]) from exc


app = create_app()
