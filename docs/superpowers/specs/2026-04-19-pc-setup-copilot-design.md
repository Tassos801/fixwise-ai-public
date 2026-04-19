# PC Setup Copilot Design

## Goal

Add a deeper Machines & Tech AI layer that makes FixWise behave like a live PC/device setup copilot instead of a generic camera chatbot.

## Scope

V1 focuses on PC/device setup with connector guidance, a lightweight progress checklist, and basic troubleshooting triggers. It covers display cables, USB-C/USB-A, Ethernet, PCIe power, motherboard/CPU power, fan headers, front-panel headers, RAM/storage/GPU seating, and device setup checks.

Out of scope: full parts compatibility analysis, automatic manual lookup, shopping, sealed PSU repair, and guaranteed pin-level motherboard header accuracy when labels are not visible.

## Product Behavior

When the selected mode is Machines & Tech, the backend keeps a structured task state for the session:

- setup type: PC build, display setup, network setup, peripheral setup, or unknown
- phase: identify, connect, verify, troubleshoot, or complete
- checklist: small list of active/pending/done/blocked setup steps
- visible components: ports, cables, slots, headers, or devices visible in the frame
- troubleshooting focus: no display, no power, not detected, network issue, or none

The iOS app shows this as a compact live copilot panel above the follow-up chips. The panel should never dominate the camera view; it summarizes the current phase, active step, and progress.

## Architecture

Backend model responses may include `taskState`. A deterministic PC setup brain fills in a fallback state for Machines & Tech prompts when the model omits it, then stores the latest state in `SessionManager`. The websocket response includes `taskState` so iOS can render it immediately.

iOS decodes `taskState`, stores it in `SessionState`, and renders a small glass panel with phase, active step, checklist progress, and troubleshooting focus.

## Testing

Backend tests cover task-state parsing, fallback task-state generation, session memory storage, and websocket response payloads. iOS tests cover websocket decoding and `SessionState` storage.
