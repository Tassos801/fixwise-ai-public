# PC Setup Copilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add structured PC/device setup intelligence to Machines & Tech sessions.

**Architecture:** Extend the backend response schema with task state, add a deterministic PC setup brain for fallback and state continuity, thread the state through the websocket response, then decode and render it in the iOS live camera session.

**Tech Stack:** Python/FastAPI/Pydantic, XCTest/SwiftUI, existing websocket JSON protocol.

---

### Task 1: Backend Contract and Brain

**Files:**
- Modify: `backend/src/fixwise_backend/models.py`
- Create: `backend/src/fixwise_backend/pc_setup_brain.py`
- Modify: `backend/src/fixwise_backend/session_manager.py`
- Modify: `backend/src/fixwise_backend/app.py`
- Test: `backend/tests/test_session_manager.py`
- Test: `backend/tests/test_websocket_flow.py`
- Test: `backend/tests/test_pc_setup_brain.py`

- [ ] Write failing tests for task-state parsing, fallback generation, session storage, and websocket payloads.
- [ ] Add `TaskChecklistItem`, `DetectedComponent`, and `TaskState` Pydantic models.
- [ ] Add optional `taskState` to `AIResponse` and `ResponseMessage`.
- [ ] Add `enrich_pc_setup_response()` to create a Machines & Tech fallback state when the model omits one.
- [ ] Store the latest task state in `SessionManager` and include it in context.
- [ ] Call the brain before recording/sending assistant turns.
- [ ] Run backend tests.

### Task 2: Prompt Contract

**Files:**
- Modify: `backend/src/fixwise_backend/guidance_modes.py`
- Test: `backend/tests/test_provider_selection.py`

- [ ] Update the Machines & Tech prompt to ask for `taskState` during PC/device setup.
- [ ] Keep the shared JSON contract backward compatible.
- [ ] Run provider-selection tests.

### Task 3: iOS Decode and State

**Files:**
- Modify: `ios/FixWise/FixWise/Services/WebSocketService.swift`
- Modify: `ios/FixWise/FixWise/Models/SessionState.swift`
- Test: `ios/FixWise/FixWiseTests/VerticalSliceTests.swift`

- [ ] Write failing XCTest coverage for decoding and storing `taskState`.
- [ ] Add Swift value types for task state, checklist items, and visible components.
- [ ] Pass decoded task state into `SessionState.didReceiveResponse`.
- [ ] Reset task state on session reset/start.

### Task 4: iOS Live Copilot Panel

**Files:**
- Modify: `ios/FixWise/FixWise/Views/CameraSessionView.swift`

- [ ] Add a compact live copilot panel above follow-up chips when task state exists.
- [ ] Show phase, active checklist item, progress count, and troubleshooting focus.
- [ ] Keep the panel one level deep and camera-first.
- [ ] Run the iOS test target or at least an Xcode build if simulator tooling is available.
