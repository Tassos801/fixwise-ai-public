# FixWise AI — System Architecture

## 1. High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        iOS CLIENT (Swift/SwiftUI/ARKit)            │
│                                                                     │
│  ┌──────────┐    ┌──────────────┐    ┌───────────────────────┐     │
│  │ ARKit    │───>│ Frame        │───>│ Base64 Encoder        │     │
│  │ Camera   │    │ Sampler      │    │ (512x512 JPEG, q=0.7) │     │
│  │ Session  │    │ (adaptive    │    └───────────┬───────────┘     │
│  └──────────┘    │  1-3 FPS)    │                │                  │
│                  └──────────────┘                │                  │
│  ┌──────────────────────┐                       │                  │
│  │ Speech Detection     │    ┌──────────────────▼────────────┐     │
│  │ (on-device wake-word)│───>│ WebSocket Client              │     │
│  └──────────────────────┘    │ (sends frames + audio chunks) │     │
│                              └──────────────┬────────────────┘     │
│  ┌──────────────────────┐                   │                      │
│  │ AR Annotation        │<──────────────────┼──── (receives        │
│  │ Renderer (SceneKit)  │                   │      annotations +   │
│  └──────────────────────┘                   │      audio stream)   │
│  ┌──────────────────────┐                   │                      │
│  │ Audio Player         │<──────────────────┘                      │
│  │ (AVAudioEngine)      │                                          │
│  └──────────────────────┘                                          │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ WSS (TLS 1.3)
                                  │
┌─────────────────────────────────▼───────────────────────────────────┐
│                        BACKEND (FastAPI + WebSocket)                │
│                                                                     │
│  ┌────────────────┐  ┌─────────────────┐  ┌──────────────────┐    │
│  │ WS Session     │  │ Auth Middleware  │  │ Rate Limiter     │    │
│  │ Manager        │  │ (JWT + BYOK)    │  │ (per-user,       │    │
│  │                │  │                 │  │  per-tier)        │    │
│  └───────┬────────┘  └─────────────────┘  └──────────────────┘    │
│          │                                                         │
│  ┌───────▼────────────────────────────────────────────────────┐   │
│  │                    Session Orchestrator                     │   │
│  │                                                            │   │
│  │  1. Receive frame + audio from client                      │   │
│  │  2. Apply safety filter (pre-check prompt)                 │   │
│  │  3. Route to OpenAI Vision API (frame analysis)            │   │
│  │  4. Route to OpenAI Realtime API (voice interaction)       │   │
│  │  5. Parse AI response for annotations + text               │   │
│  │  6. Log step to session store (frame + response)           │   │
│  │  7. Send annotations + audio stream back to client         │   │
│  └───────┬──────────────────────────────────┬─────────────────┘   │
│          │                                  │                      │
│  ┌───────▼────────┐              ┌──────────▼──────────┐          │
│  │ OpenAI Gateway │              │ Session Store       │          │
│  │ (key routing,  │              │ (PostgreSQL +       │          │
│  │  retry, budget) │              │  Redis cache)       │          │
│  └───────┬────────┘              └──────────┬──────────┘          │
│          │                                  │                      │
└──────────┼──────────────────────────────────┼──────────────────────┘
           │                                  │
    ┌──────▼──────┐                  ┌────────▼────────┐
    │ OpenAI API  │                  │ AWS S3          │
    │ - GPT-4o    │                  │ (frames, PDFs)  │
    │   Vision    │                  └────────┬────────┘
    │ - Realtime  │                           │
    │   Voice API │                  ┌────────▼────────┐
    └─────────────┘                  │ PDF Generator   │
                                     │ (async worker)  │
                                     └─────────────────┘
```

## 2. Detailed Component Architecture

### 2.1 iOS Client Architecture (MVVM + Services)

```
FixWise/
├── App/
│   └── FixWiseApp.swift              # App entry point
├── Views/
│   ├── CameraSessionView.swift       # Main AR camera view
│   ├── AnnotationOverlayView.swift   # SwiftUI overlay for AR annotations
│   ├── SessionControlsView.swift     # Voice indicator, end session button
│   └── OnboardingView.swift          # Disclaimer + permissions
├── Services/
│   ├── CameraService.swift           # ARSession delegate, frame extraction
│   ├── WebSocketService.swift        # WS connection to backend
│   ├── VoiceService.swift            # Wake-word detection + audio capture
│   ├── AnnotationService.swift       # Parse annotation JSON, manage AR anchors
│   └── AudioPlaybackService.swift    # Play AI voice responses
├── Models/
│   ├── SessionState.swift            # Session lifecycle state machine
│   ├── Annotation.swift              # Annotation data models
│   └── APIModels.swift               # Request/response codables
└── AR/
    └── ARAnnotationRenderer.swift    # SceneKit node creation for annotations
```

### 2.2 Backend Architecture (FastAPI)

```
backend/
├── src/
│   ├── main.py                       # FastAPI app + WebSocket endpoint
│   ├── routes/
│   │   ├── auth.py                   # Login, register, JWT
│   │   ├── sessions.py               # Session history, fix reports
│   │   └── subscription.py           # Tier management, BYOK key storage
│   ├── services/
│   │   ├── openai_gateway.py         # OpenAI API client (Vision + Realtime)
│   │   ├── session_orchestrator.py   # Core session logic
│   │   ├── safety_filter.py          # Pre/post safety checks
│   │   ├── frame_processor.py        # Frame validation, resizing
│   │   └── pdf_generator.py          # Fix Report PDF creation
│   ├── middleware/
│   │   ├── auth.py                   # JWT verification
│   │   └── rate_limiter.py           # Tier-based rate limiting
│   └── utils/
│       ├── encryption.py             # BYOK key encryption/decryption
│       └── config.py                 # Environment config
├── requirements.txt
└── Dockerfile
```

### 2.3 Web Dashboard (React)

```
web/fixwise-dashboard/
├── src/
│   ├── components/
│   │   ├── APIKeyInput.tsx           # BYOK key input + validation
│   │   ├── SessionHistory.tsx        # Past session list
│   │   ├── FixReportViewer.tsx       # PDF viewer/download
│   │   └── SubscriptionManager.tsx   # Tier selection, billing
│   ├── services/
│   │   └── api.ts                    # Backend API client
│   └── pages/
│       ├── Dashboard.tsx             # Main dashboard
│       └── Settings.tsx              # Account settings, API key
```

---

## 3. Communication Protocols

### 3.1 Client <-> Backend: WebSocket

**Why WebSocket over WebRTC:**
- WebRTC is designed for peer-to-peer media streaming with complex NAT traversal. Our architecture is client-to-server, making WebRTC's STUN/TURN overhead unnecessary.
- We're sending **sampled JPEG frames** (not a continuous video stream), so we don't need WebRTC's media codecs or jitter buffers.
- WebSocket over TLS provides sufficient performance for our 1-3 FPS frame rate with < 100KB per frame.
- Audio is handled by OpenAI's Realtime API WebSocket — we relay through our backend, not stream raw audio peer-to-peer.

**WebRTC would be needed if:** we ever add multi-user collaborative sessions or require continuous HD video streaming. Not in MVP scope.

### 3.2 WebSocket Message Protocol

```
Client -> Server:
{
  "type": "frame",
  "sessionId": "uuid",
  "timestamp": 1712300000,
  "frame": "<base64 JPEG>",
  "frameMetadata": {
    "width": 512,
    "height": 512,
    "sceneDelta": 0.15  // pixel change ratio from previous frame
  }
}

{
  "type": "audio",
  "sessionId": "uuid",
  "timestamp": 1712300000,
  "audio": "<base64 PCM 16-bit 24kHz>",
  "isWakeWordTriggered": true
}

Server -> Client:
{
  "type": "response",
  "sessionId": "uuid",
  "text": "Turn the red valve counterclockwise...",
  "audio": "<base64 audio chunk or streaming indicator>",
  "annotations": [ ... ],
  "stepNumber": 3,
  "safetyWarning": null
}

{
  "type": "safety_block",
  "sessionId": "uuid",
  "reason": "This task involves high-voltage electrical work...",
  "recommendation": "Contact a licensed electrician."
}
```

---

## 4. Latency & Token Optimization Strategy

### 4.1 Adaptive Frame Sampling

```
Scene Change Detection (on-device):
  - Compare current frame to previous using pixel-level mean absolute difference
  - If delta < 0.05: IDLE — sample at 1 FPS
  - If delta 0.05–0.15: ACTIVE — sample at 2 FPS
  - If delta > 0.15: HIGH ACTIVITY — sample at 3 FPS
  - Never exceed 3 FPS to cap costs

Frame Optimization:
  - Resize to 512x512 (sufficient for GPT-4o Vision)
  - JPEG quality 0.7 (~40-80KB per frame)
  - Skip sending if delta < 0.02 (no meaningful change)
```

### 4.2 Token Budget Management

```
Per-session token budget:
  - System prompt: ~500 tokens (cached, sent once)
  - Per-frame Vision analysis: ~300 tokens input, ~200 tokens output
  - Voice interaction: ~100 tokens input, ~150 tokens output per exchange
  - At 1 FPS for 15 min session: ~900 frames
  - With skip logic (avg 40% skip): ~540 frames analyzed
  - Estimated cost per session: ~$0.80-$1.50 (GPT-4o pricing)

Optimization:
  - Cache system prompt across frames (OpenAI prompt caching)
  - Send frame only with active question or significant scene change
  - Batch 2-3 frames in a single Vision request when possible
  - Use GPT-4o-mini for safety pre-screening (cheaper)
```

### 4.3 Latency Budget Breakdown

```
Target: < 2 seconds end-to-end (frame capture to audio playback start)

  Frame capture + encode:     ~50ms  (on-device)
  WebSocket transmission:     ~80ms  (assuming ~60KB frame, good connection)
  Backend processing:         ~30ms  (validation, routing)
  OpenAI Vision API:          ~800ms (P50 for GPT-4o with image)
  OpenAI Realtime/TTS:        ~400ms (streaming first audio chunk)
  WebSocket return:           ~50ms
  Audio playback start:       ~20ms
  ─────────────────────────────────
  Total:                     ~1430ms (P50)
```

---

## 5. State Management

### 5.1 Session State Machine

```
        ┌──────────┐
        │  IDLE    │ (app open, no session)
        └────┬─────┘
             │ user taps "Start Session"
        ┌────▼─────┐
        │CONNECTING│ (WS handshake + auth)
        └────┬─────┘
             │ WS connected + auth verified
        ┌────▼─────┐
        │ ACTIVE   │◄────────────────────┐
        └────┬─────┘                     │
             │                           │
     ┌───────┼───────┐                  │
     │       │       │                  │
  ┌──▼──┐ ┌─▼──┐ ┌──▼───┐             │
  │VOICE│ │IDLE│ │FRAME │  (sub-states) │
  │LISTEN│ │WAIT│ │SEND  │             │
  └──┬──┘ └─┬──┘ └──┬───┘             │
     │       │       │                  │
     └───────┼───────┘                  │
             │ AI response received      │
             ├──────────────────────────┘
             │ user taps "End" or timeout
        ┌────▼─────┐
        │ ENDING   │ (flush logs, generate report)
        └────┬─────┘
             │
        ┌────▼─────┐
        │COMPLETED │ (show report link)
        └──────────┘
```

### 5.2 Connection Resilience

- **Reconnection:** Exponential backoff (1s, 2s, 4s, 8s, max 30s) on WS disconnect.
- **Session Resume:** Backend keeps session state in Redis for 5 minutes after disconnect. Client sends `sessionId` on reconnect to resume.
- **Graceful Degradation:** If WS drops during active guidance, the last AI response and annotations remain visible. Voice mode falls back to tap-to-talk.

---

## 6. Security Architecture

### 6.1 Authentication Flow

```
1. User registers via web portal or iOS app (email + password)
2. Backend issues JWT (access token: 15 min, refresh token: 7 days)
3. iOS stores tokens in Keychain
4. Every WS connection and REST call includes JWT in header
5. Backend validates JWT signature + expiry on every request
```

### 6.2 BYOK Key Security

```
1. User inputs OpenAI API key in web portal or iOS settings
2. Client sends key over TLS to backend
3. Backend encrypts key with AES-256-GCM using a per-user derived key
   (derived from user ID + server master key via HKDF)
4. Encrypted key stored in PostgreSQL
5. Key decrypted in-memory only during active session
6. Key NEVER logged, NEVER included in error reports
7. User can rotate/delete key at any time
```

---

## 7. Infrastructure (MVP)

| Component | Service | Justification |
|-----------|---------|---------------|
| Backend | AWS ECS Fargate (2 instances) | Auto-scaling, no server management |
| Database | AWS RDS PostgreSQL | Managed, reliable |
| Cache | AWS ElastiCache Redis | Session state, rate limiting |
| Storage | AWS S3 | Frames, Fix Report PDFs |
| CDN | CloudFront | Serve Fix Report PDFs |
| Monitoring | Datadog or CloudWatch | Latency tracking, error rates |
| CI/CD | GitHub Actions | Build, test, deploy |

---

## 8. Additional Libraries Needed

### iOS
| Library | Purpose |
|---------|---------|
| **Starscream** | WebSocket client (more robust than URLSessionWebSocketTask) |
| **KeychainAccess** | Simplified Keychain API for token/key storage |
| **Lottie** | Animated UI indicators (listening state, processing) |

### Backend (Python)
| Library | Purpose |
|---------|---------|
| **FastAPI + uvicorn** | Async web framework + ASGI server |
| **websockets** | WebSocket support in FastAPI |
| **openai** | Official OpenAI Python SDK |
| **Pillow** | Frame validation and resizing |
| **ReportLab** or **WeasyPrint** | PDF generation for Fix Reports |
| **cryptography** | AES-256-GCM encryption for BYOK keys |
| **PyJWT** | JWT token handling |
| **redis-py** | Redis client for session state |
| **SQLAlchemy** | ORM for PostgreSQL |
| **boto3** | AWS S3 uploads |

### Web (React)
| Library | Purpose |
|---------|---------|
| **React Router** | Page routing |
| **Zustand** or **Jotai** | Lightweight state management |
| **Tailwind CSS** | Styling |
| **React Query (TanStack)** | API data fetching/caching |
| **Stripe.js** | Payment integration |

**WebRTC Verdict:** Not needed for MVP. WebSocket is sufficient for sampled frame + audio relay. Revisit if adding peer-to-peer features.
