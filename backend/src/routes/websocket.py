from __future__ import annotations

import json
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from src.models import EndSessionMessage, FrameMessage, PromptMessage, parse_client_message
from src.services.safety_filter import evaluate_prompt


logger = logging.getLogger("fixwise.websocket")
router = APIRouter()


@router.websocket("/ws/session")
async def websocket_session(websocket: WebSocket) -> None:
    await websocket.accept()

    session_manager = websocket.app.state.session_manager
    guidance_service = websocket.app.state.guidance_service

    try:
        while True:
            raw_message = await websocket.receive_text()

            try:
                message = json.loads(raw_message)
            except json.JSONDecodeError:
                await _send_error(websocket, "Invalid JSON payload.")
                continue

            try:
                parsed_message = parse_client_message(message)
            except ValidationError as exc:
                await _send_error(websocket, exc.errors()[0]["msg"])
                continue

            if isinstance(parsed_message, FrameMessage):
                session_manager.store_frame(
                    session_id=parsed_message.sessionId,
                    frame_b64=parsed_message.frame,
                    metadata=(
                        parsed_message.frameMetadata.model_dump(mode="json")
                        if parsed_message.frameMetadata is not None
                        else None
                    ),
                )
                continue

            if isinstance(parsed_message, PromptMessage):
                session_id = parsed_message.sessionId
                prompt = parsed_message.text.strip()

                if not prompt:
                    await _send_error(websocket, "Prompt text cannot be empty.")
                    continue

                safety_decision = evaluate_prompt(prompt)
                if safety_decision.blocked:
                    await websocket.send_json(
                        {
                            "type": "safety_block",
                            "sessionId": session_id,
                            "reason": safety_decision.reason,
                            "recommendation": safety_decision.recommendation,
                        }
                    )
                    continue

                session = session_manager.get_or_create(session_id)
                if not session.latest_frame:
                    await _send_error(
                        websocket,
                        "A frame must be sent before guidance can be requested.",
                    )
                    continue

                guidance = await guidance_service.generate(
                    prompt=prompt,
                    frame_b64=session.latest_frame,
                )

                response_safety = evaluate_prompt(guidance.text)
                if response_safety.blocked:
                    await websocket.send_json(
                        {
                            "type": "safety_block",
                            "sessionId": session_id,
                            "reason": response_safety.reason,
                            "recommendation": response_safety.recommendation,
                        }
                    )
                    continue

                step_number = session_manager.next_step(session_id)
                await websocket.send_json(
                    {
                        "type": "response",
                        "sessionId": session_id,
                        "text": guidance.text,
                        "audio": None,
                        "annotations": [annotation.to_dict() for annotation in guidance.annotations],
                        "stepNumber": step_number,
                        "safetyWarning": guidance.safety_warning,
                    }
                )
                continue

            if isinstance(parsed_message, EndSessionMessage):
                session_manager.end(parsed_message.sessionId)
                break

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")


async def _send_error(websocket: WebSocket, detail: str) -> None:
    await websocket.send_json({"type": "error", "detail": detail})
