# FixWise AI — Product Requirements Document

**Version:** 1.0
**Date:** 2026-04-05
**Author:** Architecture Team
**Status:** Draft — MVP Scope

---

## 1. Executive Summary

FixWise AI is a multimodal, AI-powered live video assistance platform that connects a user's smartphone camera to advanced vision and voice AI models. Users point their camera at a task (home repair, car mechanics, PC building), and the AI provides real-time spoken guidance with spatial AR annotations overlaid on the live camera feed.

**Core Value Proposition:** Hands-free, expert-level guidance for physical tasks — like having a master technician looking over your shoulder.

---

## 2. Target Users

| Persona | Description |
|---------|-------------|
| DIY Homeowner | Needs guidance on plumbing, electrical (non-high-voltage), appliance repair |
| Car Enthusiast | Oil changes, brake pad replacement, diagnostic interpretation |
| PC Builder | First-time builders needing component identification and assembly guidance |
| Field Technician | Professional needing a second opinion or documentation for compliance |

---

## 3. Core Features

### 3.1 Live Camera + AI Vision Pipeline

**Priority:** P0 (MVP)

- User opens the app and points their camera at the task area.
- The system samples frames from the camera feed (adaptive: 1 FPS idle, up to 3 FPS during active guidance).
- Frames are base64-encoded, resized to 512x512 (or 768x768 max), and sent to OpenAI GPT-4o Vision via the backend relay.
- AI analyzes the scene and responds with spoken guidance and optional spatial annotation coordinates.

**Acceptance Criteria:**
- End-to-end latency from frame capture to audio response start: < 2 seconds (P50), < 3 seconds (P95).
- Frame sampling is adaptive based on scene change detection (pixel diff threshold).

### 3.2 Hands-Free Voice Mode

**Priority:** P0 (MVP)

- Continuous audio listening via on-device speech detection.
- Wake-word activation ("Hey FixWise") using on-device keyword spotting (Apple Speech framework).
- After wake-word detection, audio is streamed to OpenAI Realtime API via WebSocket for low-latency transcription and response.
- Fallback: tap-to-talk button for noisy environments.

**Acceptance Criteria:**
- Wake-word detection works offline (on-device).
- Voice-to-response latency: < 1.5 seconds after wake-word.
- Audio plays through device speaker; supports Bluetooth audio.

### 3.3 Spatial AR Annotations

**Priority:** P0 (MVP)

- The AI returns structured annotation data (type, coordinates, label) alongside its text/voice response.
- The iOS client uses ARKit to anchor annotations in 3D space on detected surfaces.
- Supported annotation types: circle highlight, arrow pointer, text label, bounding box.

**Annotation Response Schema:**
```json
{
  "annotations": [
    {
      "type": "circle",
      "label": "Turn this valve counterclockwise",
      "x": 0.45,
      "y": 0.62,
      "radius": 0.08,
      "color": "#FF6B35"
    },
    {
      "type": "arrow",
      "label": "Insert cable here",
      "from": { "x": 0.3, "y": 0.5 },
      "to": { "x": 0.5, "y": 0.7 },
      "color": "#00D4AA"
    }
  ]
}
```

- Coordinates are normalized (0.0–1.0) relative to the captured frame dimensions.
- ARKit raycasting converts 2D normalized coords to 3D world anchors on detected planes.

**Acceptance Criteria:**
- Annotations appear within 500ms of AI response receipt.
- Annotations persist in 3D space as user moves the camera.
- Annotations auto-dismiss after 10 seconds or on next AI response.

### 3.4 Auto-Documentation ("Fix Report")

**Priority:** P1 (MVP+)

- Backend captures key frames at each AI interaction step.
- AI responses are logged with timestamps.
- On session end, a PDF "Fix Report" is generated containing:
  - Timestamped steps with frame thumbnails
  - AI guidance text for each step
  - Parts/tools mentioned
  - Safety warnings issued
- PDF is stored in cloud storage (S3) and accessible from the web dashboard.

**Acceptance Criteria:**
- PDF generated within 30 seconds of session end.
- Report includes all steps with images and text.
- Downloadable from web portal and shareable via link.

### 3.5 BYOK & Subscription Tiers

**Priority:** P0 (MVP)

| Tier | Price | Details |
|------|-------|---------|
| Free | $0 | 3 sessions/month, 5 min each. Requires own OpenAI key (BYOK). |
| Pro | $19.99/mo | Unlimited sessions, 30 min each. Platform-managed AI key. Fix Reports included. |
| Enterprise | Custom | Team accounts, priority support, custom safety rules. |

- BYOK flow: User enters their OpenAI API key in the web portal or iOS settings. Key is encrypted at rest (AES-256) and transmitted only over TLS. Backend validates the key with a lightweight API call before accepting it.
- Subscription flow: Apple StoreKit 2 for iOS in-app purchases. Stripe for web subscriptions. Backend validates receipts/webhooks.

---

## 4. Safety & Liability Guardrails

### 4.1 Prohibited Task Categories

The AI system prompt enforces hard refusals for:

- **High-voltage electrical work** (anything involving breaker panels, mains wiring, 240V circuits)
- **Structural modifications** (load-bearing walls, foundation work)
- **Gas line work** (natural gas, propane connections)
- **Asbestos/lead paint disturbance**
- **Any task requiring licensed professional certification**

### 4.2 System Prompt Safety Layer

```
You are FixWise AI, a hands-on task guidance assistant. You MUST:
1. REFUSE to guide any task involving high-voltage electricity (>50V),
   gas lines, structural load-bearing elements, or hazardous materials.
2. When refusing, explain WHY it's dangerous and recommend a licensed professional.
3. Begin every session by assessing if the task is within safe guidance scope.
4. Proactively warn about safety equipment (gloves, goggles, masks) when relevant.
5. If uncertain about safety, err on the side of caution and recommend professional help.
```

### 4.3 Disclaimer

Every session starts with an on-screen and spoken disclaimer:
> "FixWise AI provides general guidance only. It is not a substitute for a licensed professional. You assume all responsibility for actions taken based on AI guidance."

User must acknowledge this before the session begins.

---

## 5. Non-Functional Requirements

| Requirement | Target |
|-------------|--------|
| Availability | 99.5% uptime (excl. OpenAI dependency) |
| Concurrent Users (MVP) | 500 simultaneous sessions |
| Data Retention | Session data retained 90 days (Free), 1 year (Pro) |
| Encryption | TLS 1.3 in transit, AES-256 at rest |
| BYOK Key Storage | Encrypted with per-user derived key, never logged |
| iOS Minimum | iOS 17.0 (ARKit 6 required) |
| Device Support | iPhone 12+ (LiDAR preferred but not required) |

---

## 6. Success Metrics (MVP)

| Metric | Target |
|--------|--------|
| Session Completion Rate | > 70% of started sessions reach "task complete" |
| Voice Interaction Success | > 85% of voice commands correctly interpreted |
| AR Annotation Accuracy | > 80% of annotations point to the correct object |
| User Retention (Week 1) | > 40% of new users return within 7 days |
| Average Session Duration | 8–15 minutes |

---

## 7. Out of Scope (MVP)

- Multi-user collaborative sessions
- Android client
- Offline AI inference
- Video recording/playback within the app
- Integration with parts ordering/e-commerce
- Community/social features
