from __future__ import annotations

import json
import logging
import platform
import sqlite3
import time
from contextlib import asynccontextmanager
from datetime import datetime, UTC
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pydantic import ValidationError

from .ai import (
    AIProvider,
    ProviderConfigurationError,
    _frame_needs_closer_view,
    _make_closer_frame_response,
    build_ai_provider,
    validate_ai_api_key,
)
from .auth import (
    AuthResponse,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    create_guest_user,
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
from .guidance_modes import normalize_guidance_mode, suggest_guidance_mode
from .tts import generate_tts_audio_base64
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
from .pc_setup_brain import enrich_pc_setup_response
from .pdf_report import generate_fix_report
from .rate_limit import (
    InMemoryRateLimiter,
    RateLimitPolicy,
    client_identifier_from_request,
    client_identifier_from_websocket,
    raise_for_rate_limit,
)
from .safety import check_safety
from .security_headers import SecurityHeadersMiddleware
from .session_manager import SessionManager
from .tier_enforcement import check_session_duration, check_session_quota


logger = logging.getLogger("fixwise")


def _is_guest_user(user_id: str) -> bool:
    return user_id.startswith("guest-")


def _availability_label(settings: Settings, ai_provider: AIProvider) -> str:
    if ai_provider.provider_name == "unavailable":
        return "unavailable"
    if ai_provider.provider_name == "mock":
        return "degraded"
    if settings.environment == "production" and settings.ai_mode == "auto" and not settings.active_ai_api_key:
        return "unavailable"
    return "live"


def _assistant_response_payload(response: ResponseMessage) -> dict[str, Any]:
    return response.model_dump(mode="json", by_alias=True)


def create_app(
    settings: Settings | None = None,
    provider: AIProvider | None = None,
    session_manager: SessionManager | None = None,
    database: Database | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    resolved_settings.validate()
    enforce_tier_limits = resolved_settings.environment == "production"
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
    app.add_middleware(SecurityHeadersMiddleware, environment=resolved_settings.environment)

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

    def _auth_response_payload(auth_response: AuthResponse) -> dict[str, Any]:
        """Return a response payload that works for both camelCase and snake_case clients."""
        payload = auth_response.model_dump(mode="json")
        user = payload.get("user")
        if isinstance(user, dict):
            user["displayName"] = user.get("display_name")
            user["isGuest"] = user.get("is_guest", False)
        return payload

    @app.get("/health")
    async def health() -> dict:
        db_ok = await _check_db()
        uptime = round(time.monotonic() - startup_time, 1) if startup_time else 0
        live_ready = bool(resolved_settings.active_ai_api_key)
        availability = _availability_label(resolved_settings, ai_provider)
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
            "desiredProvider": resolved_settings.ai_provider,
            "liveConfigured": live_ready,
            "availability": availability,
            "ai": {
                "mode": resolved_settings.ai_mode,
                "provider": ai_provider.provider_name,
                "configuredProvider": resolved_settings.ai_provider,
                "liveReady": live_ready,
                "model": resolved_settings.active_ai_model,
                "availability": availability,
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
        auth_response = await register_user(req, db)
        return JSONResponse(content=_auth_response_payload(auth_response))

    @app.post("/api/auth/login", response_model=AuthResponse)
    async def login(
        req: LoginRequest,
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        auth_response = await login_user(req, db)
        return JSONResponse(content=_auth_response_payload(auth_response))

    @app.post("/api/auth/refresh", response_model=AuthResponse)
    async def refresh(
        req: RefreshRequest,
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        auth_response = await refresh_tokens(req, db)
        return JSONResponse(content=_auth_response_payload(auth_response))

    @app.post("/api/auth/guest", response_model=AuthResponse)
    async def guest(
        _: None = Depends(
            http_rate_limit_dependency("auth", resolved_settings.auth_rate_limit_requests)
        ),
    ):
        auth_response = await create_guest_user(db)
        return JSONResponse(content=_auth_response_payload(auth_response))

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
            "display_name": user.display_name,
            "displayName": user.display_name,
            "tier": user.tier,
            "is_guest": _is_guest_user(user.id) or user.tier == "guest",
            "isGuest": _is_guest_user(user.id) or user.tier == "guest",
            "hasApiKey": api_key_row is not None,
            "apiKeyMask": api_key_row.key_mask if api_key_row else None,
            "apiKeyProvider": resolved_settings.ai_provider if api_key_row else None,
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
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            raise HTTPException(status_code=403, detail="Guest sessions cannot save API keys.")
        key = req.apiKey.strip()
        if len(key) < 20:
            raise HTTPException(status_code=400, detail="API key is too short.")

        try:
            await validate_ai_api_key(resolved_settings, key)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except ConnectionError as exc:
            raise HTTPException(status_code=502, detail=str(exc))

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
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            raise HTTPException(status_code=403, detail="Guest sessions cannot save API keys.")
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
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            return {"hasKey": False, "maskedKey": None}
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
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            raise HTTPException(status_code=403, detail="Guest sessions are local to the device.")
        sessions = await db.list_sessions(user_id)
        sessions_with_preview: list[dict[str, Any]] = []
        for session in sessions:
            steps = await db.get_session_steps(session.id)
            last_step = steps[-1] if steps else None
            sessions_with_preview.append(
                {
                    "id": session.id,
                    "status": session.status,
                    "stepCount": session.step_count,
                    "selectedMode": session.selected_mode,
                    "summary": session.summary,
                    "lastNextAction": session.last_next_action,
                    "confidence": last_step.confidence if last_step else None,
                    "thumbnailDataUrl": last_step.frame_thumbnail if last_step else None,
                    "startedAt": session.started_at,
                    "endedAt": session.ended_at,
                    "reportUrl": session.report_url,
                }
            )
        return {
            "sessions": sessions_with_preview
        }

    @app.get("/api/sessions/{session_id}")
    async def get_session_detail(
        session_id: str,
        _: None = Depends(
            http_rate_limit_dependency("session", resolved_settings.session_rate_limit_requests)
        ),
        user_id: str = Depends(require_auth),
    ):
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            raise HTTPException(status_code=403, detail="Guest sessions are local to the device.")
        session = await db.get_session(session_id)
        if not session or session.user_id != user_id:
            raise HTTPException(status_code=404, detail="Session not found.")

        steps = await db.get_session_steps(session_id)
        return {
            "id": session.id,
            "status": session.status,
            "stepCount": session.step_count,
            "selectedMode": session.selected_mode,
            "summary": session.summary,
            "lastNextAction": session.last_next_action,
            "startedAt": session.started_at,
            "endedAt": session.ended_at,
            "reportUrl": session.report_url,
            "steps": [
                {
                    "stepNumber": step.step_number,
                    "text": step.ai_response_text,
                    "safetyWarning": step.safety_warning,
                    "mode": step.mode,
                    "hasFrame": step.frame_thumbnail is not None,
                    "nextAction": step.next_action,
                    "needsCloserFrame": bool(step.needs_closer_frame) if step.needs_closer_frame is not None else False,
                    "followUpPrompts": json.loads(step.follow_up_prompts_json) if step.follow_up_prompts_json else [],
                    "confidence": step.confidence or "medium",
                    "thumbnailDataUrl": step.frame_thumbnail,
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
        user = await db.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found.")
        if _is_guest_user(user.id) or user.tier == "guest":
            raise HTTPException(status_code=403, detail="Guest sessions are local to the device.")
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

        token = websocket.query_params.get("token")
        identity_kind = "guest"
        user_id: str | None = None
        token_was_authenticated = False
        if token:
            try:
                from .auth import decode_token

                payload = decode_token(token)
                if payload.get("type") == "access":
                    user_id = payload.get("sub")
                    identity_kind = payload.get("kind", "account")
                    token_was_authenticated = identity_kind != "guest"
            except Exception:
                user_id = None

        if not user_id:
            user_id = f"guest-conn-{uuid4()}"
            identity_kind = "guest"

        # Authenticated users were created at registration/refresh time, so skip
        # the bootstrap round-trip in the common case. Only ad-hoc guest IDs
        # need the insert, and a freshly minted UUID can never collide.
        if not token_was_authenticated:
            try:
                await db.create_user(
                    user_id=user_id,
                    email=f"{user_id}@fixwise.local",
                    password_hash="guest-bootstrap",
                    display_name="Guest" if identity_kind == "guest" else None,
                    tier="guest" if identity_kind == "guest" else "free",
                )
            except sqlite3.IntegrityError:
                pass  # Concurrent connection inserted the same row first

        session_id: str | None = None
        session_closed = False

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
                        # Enforce tier session quota
                        if enforce_tier_limits and not _is_guest_user(user_id):
                            user_row = await db.get_user_by_id(user_id)
                            user_tier = user_row.tier if user_row else "free"
                            try:
                                await check_session_quota(db, user_id, user_tier)
                            except HTTPException as exc:
                                await websocket.send_json(
                                    ErrorMessage(
                                        sessionId=message.sessionId,
                                        message=exc.detail,
                                    ).model_dump(mode="json")
                                )
                                await websocket.close(code=1008)
                                return
                        await db.create_session(session_id=session_id, user_id=user_id)

                    resolved_session_manager.store_frame(
                        session_id=message.sessionId,
                        frame_b64=message.frame,
                        metadata=message.frameMetadata,
                        captured_at=message.timestamp,
                        user_id=user_id,
                    )
                    continue

                if isinstance(message, PromptMessage):
                    selected_mode = normalize_guidance_mode(message.mode)

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
                        await db.create_session(
                            session_id=session_id,
                            user_id=user_id,
                            selected_mode=selected_mode,
                        )
                    else:
                        await db.update_session_mode(message.sessionId, selected_mode)

                    resolved_session_manager.record_user_turn(
                        message.sessionId,
                        message.text,
                        mode=selected_mode,
                        user_id=user_id,
                    )

                    # Check session duration limit
                    if enforce_tier_limits and session_id and not _is_guest_user(user_id):
                        db_session = await db.get_session(session_id)
                        if db_session and db_session.started_at:
                            user_row = await db.get_user_by_id(user_id)
                            user_tier = user_row.tier if user_row else "free"
                            remaining = check_session_duration(db_session.started_at, user_tier)
                            if remaining is not None and remaining <= 0:
                                await db.end_session(session_id)
                                await websocket.send_json(
                                    ErrorMessage(
                                        sessionId=message.sessionId,
                                        message="Session duration limit reached. Please start a new session or upgrade your plan.",
                                    ).model_dump(mode="json")
                                )
                                await websocket.close(code=1008)
                                return
                            elif remaining is not None:
                                # Warn client about approaching limit
                                await websocket.send_json(
                                    ErrorMessage(
                                        sessionId=message.sessionId,
                                        message=f"Warning: {remaining} seconds remaining in this session.",
                                    ).model_dump(mode="json")
                                )

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

                    session_context = resolved_session_manager.build_context(message.sessionId)
                    suggested_mode = suggest_guidance_mode(
                        message.text,
                        task_summary=session_context.task_summary if session_context else None,
                        active_mode=selected_mode,
                    )

                    if _frame_needs_closer_view(latest_frame.metadata):
                        ai_response = _make_closer_frame_response(
                            prompt=message.text,
                            frame_metadata=latest_frame.metadata,
                        )
                    else:
                        # Resolve AI provider: prefer user's BYOK key
                        active_provider = ai_provider
                        if not _is_guest_user(user_id):
                            api_key_row = await db.get_api_key(user_id)
                            if api_key_row:
                                try:
                                    user_key = decrypt_api_key(user_id, api_key_row.encrypted_key)
                                    active_provider = build_ai_provider(
                                        resolved_settings,
                                        api_key_override=user_key,
                                    )
                                except Exception:
                                    logger.warning("Failed to decrypt BYOK key for user %s", user_id)

                        try:
                            ai_response = await active_provider.analyze(
                                frame_b64=latest_frame.base64_jpeg,
                                frame_metadata=latest_frame.metadata,
                                prompt=message.text,
                                mode=selected_mode,
                                session_id=message.sessionId,
                                session_context=session_context,
                            )
                        except ProviderConfigurationError as exc:
                            logger.warning("AI provider unavailable: %s", exc)
                            await websocket.send_json(
                                ErrorMessage(
                                    sessionId=message.sessionId,
                                    message=f"AI provider unavailable: {exc}",
                                ).model_dump(mode="json")
                            )
                            continue
                        except Exception as exc:
                            logger.exception("AI provider failed during prompt handling.")
                            err_str = str(exc).lower()
                            if "rate" in err_str or "quota" in err_str or "429" in err_str:
                                user_message = "AI is busy right now. Please wait a moment and try again."
                            else:
                                user_message = f"Unable to analyze prompt right now: {exc}"
                            await websocket.send_json(
                                ErrorMessage(
                                    sessionId=message.sessionId,
                                    message=user_message,
                                ).model_dump(mode="json")
                            )
                            continue

                    ai_response = enrich_pc_setup_response(
                        response=ai_response,
                        prompt=message.text,
                        mode=selected_mode,
                        existing_task_state=session_context.task_state if session_context else None,
                    )
                    resolved_session_manager.record_assistant_turn(
                        message.sessionId,
                        text=ai_response.text,
                        next_action=ai_response.nextAction,
                        needs_closer_frame=ai_response.needsCloserFrame,
                        follow_up_prompts=ai_response.followUpPrompts,
                        confidence=ai_response.confidence,
                        task_state=ai_response.taskState,
                        mode=selected_mode,
                        user_id=user_id,
                    )
                    refreshed_context = resolved_session_manager.build_context(message.sessionId)

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
                        mode=selected_mode,
                        next_action=ai_response.nextAction,
                        needs_closer_frame=ai_response.needsCloserFrame,
                        follow_up_prompts_json=json.dumps(ai_response.followUpPrompts) if ai_response.followUpPrompts else None,
                        confidence=ai_response.confidence,
                    )
                    await db.increment_step_count(message.sessionId)
                    audio_b64 = await generate_tts_audio_base64(
                        settings=resolved_settings,
                        text=ai_response.text,
                    )

                    await websocket.send_json(
                        ResponseMessage(
                            sessionId=message.sessionId,
                            text=ai_response.text,
                            audio=audio_b64,
                            annotations=ai_response.annotations,
                            stepNumber=step_number,
                            safetyWarning=ai_response.safetyWarning,
                            nextAction=ai_response.nextAction,
                            needsCloserFrame=ai_response.needsCloserFrame,
                            followUpPrompts=ai_response.followUpPrompts,
                            confidence=ai_response.confidence,
                            mode=selected_mode,
                            suggestedMode=suggested_mode,
                            summary=refreshed_context.task_summary if refreshed_context else None,
                            taskState=ai_response.taskState,
                        ).model_dump(mode="json", by_alias=True)
                    )
                    continue

                if isinstance(message, EndSessionMessage):
                    if session_id:
                        session_record = resolved_session_manager.end_session(message.sessionId)
                        await db.end_session(
                            session_id,
                            summary=session_record.task_summary if session_record else None,
                            last_next_action=session_record.last_next_action if session_record else None,
                        )
                        session_closed = True
                    await websocket.close(code=1000)
                    break

        except WebSocketDisconnect:
            logger.info("Client disconnected from session websocket.")
            if session_id and not session_closed:
                session_record = resolved_session_manager.end_session(session_id)
                await db.end_session(
                    session_id,
                    summary=session_record.task_summary if session_record else None,
                    last_next_action=session_record.last_next_action if session_record else None,
                )
                session_closed = True
        finally:
            if session_id and not session_closed:
                session_record = resolved_session_manager.end_session(session_id)
                if session_record:
                    await db.end_session(
                        session_id,
                        summary=session_record.task_summary,
                        last_next_action=session_record.last_next_action,
                    )

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
