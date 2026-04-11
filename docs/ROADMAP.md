# FixWise AI — 4-Week MVP Implementation Roadmap

## Week 1: Foundation & Camera Pipeline

### Days 1–2: Project Setup
- [ ] Initialize iOS Xcode project with SwiftUI lifecycle, ARKit capabilities
- [ ] Initialize FastAPI backend with project structure, Docker setup
- [ ] Initialize React dashboard with Vite + Tailwind + React Router
- [ ] Set up PostgreSQL schema (users, sessions, session_steps, api_keys)
- [ ] Set up Redis for session state caching
- [ ] Configure CI/CD pipeline (GitHub Actions: lint, test, build)

### Days 3–4: iOS Camera + Frame Pipeline
- [ ] Implement ARKit session with camera feed display
- [ ] Build frame sampler (adaptive FPS based on scene change detection)
- [ ] Implement frame resize (512x512) and base64 JPEG encoding
- [ ] Build WebSocket client service (connect, send frames, receive responses)
- [ ] Unit test frame encoding and scene change detection

### Day 5: Backend WebSocket + OpenAI Integration
- [ ] Implement WebSocket endpoint in FastAPI
- [ ] Build OpenAI Gateway service (Vision API call with base64 frame)
- [ ] Wire up: receive frame from WS -> call OpenAI Vision -> return text response
- [ ] End-to-end test: iOS sends frame -> backend -> OpenAI -> response displayed on iOS

**Week 1 Milestone:** Camera feed visible, frames sent to backend, AI text response returned and displayed.

---

## Week 2: Voice + AR Annotations

### Days 1–2: Voice Pipeline
- [ ] Implement on-device wake-word detection using Apple Speech framework
- [ ] Build audio capture service (PCM 16-bit, 24kHz)
- [ ] Integrate OpenAI Realtime API WebSocket relay in backend
- [ ] Wire audio streaming: iOS captures -> backend relays -> OpenAI -> audio response
- [ ] Implement audio playback service (AVAudioEngine) for AI responses

### Days 3–4: AR Annotation System
- [ ] Define annotation JSON schema and Swift Codable models
- [ ] Modify OpenAI system prompt to return structured annotation coordinates
- [ ] Build annotation parser in iOS (JSON -> ARKit anchor positions)
- [ ] Implement AR annotation renderer (circles, arrows, labels using SceneKit)
- [ ] ARKit raycasting: convert 2D normalized coords to 3D world positions on planes

### Day 5: Integration Testing
- [ ] End-to-end: voice question -> AI analyzes current frame + audio -> spoken response + AR annotations
- [ ] Test annotation persistence as camera moves
- [ ] Test reconnection logic (WS drop + resume)

**Week 2 Milestone:** Fully interactive session — user speaks, AI responds with voice + AR overlays.

---

## Week 3: Auth, BYOK, Subscriptions & Safety

### Days 1–2: Authentication & BYOK
- [ ] Implement user registration/login (FastAPI + JWT)
- [ ] Build iOS login/register screens
- [ ] Implement BYOK key encryption (AES-256-GCM) and storage
- [ ] Build React API Key Input component with validation
- [ ] Build iOS Settings screen for API key input
- [ ] Backend: route OpenAI calls through user's key when BYOK, platform key otherwise

### Days 3–4: Subscription Tiers
- [ ] Implement StoreKit 2 in-app purchase flow (iOS)
- [ ] Implement Stripe checkout (web dashboard)
- [ ] Build tier-based rate limiting middleware (sessions/month, duration caps)
- [ ] Backend receipt/webhook validation (Apple + Stripe)
- [ ] Build React Subscription Manager component

### Day 5: Safety Guardrails
- [ ] Implement safety system prompt with prohibited task categories
- [ ] Build safety pre-filter (GPT-4o-mini check before full analysis)
- [ ] Implement safety_block WebSocket message type
- [ ] iOS: display safety block UI (warning modal + professional recommendation)
- [ ] Test with adversarial prompts (high-voltage, gas line, structural queries)

**Week 3 Milestone:** Complete auth flow, BYOK working, subscriptions active, safety blocks functioning.

---

## Week 4: Fix Reports, Dashboard & Polish

### Days 1–2: Auto-Documentation & Fix Reports
- [ ] Backend: log key frames + AI responses per session step to PostgreSQL + S3
- [ ] Build async PDF generator worker (triggered on session end)
- [ ] PDF template: timestamped steps, frame thumbnails, AI text, safety warnings
- [ ] Store PDF in S3, save URL to session record
- [ ] iOS: "Session Complete" screen with Fix Report download link

### Days 3–4: Web Dashboard
- [ ] Build Dashboard page (session history list, status indicators)
- [ ] Build Fix Report Viewer (embedded PDF + download)
- [ ] Build Settings page (profile, API key management, subscription)
- [ ] Connect all React components to backend REST APIs
- [ ] Responsive design pass (mobile web support)

### Day 5: Testing & Launch Prep
- [ ] Full end-to-end QA pass (happy path + error paths)
- [ ] Performance profiling (latency P50/P95, memory usage on iOS)
- [ ] Security audit (BYOK encryption, JWT validation, input sanitization)
- [ ] App Store submission preparation (screenshots, description, privacy policy)
- [ ] Deploy backend to AWS ECS + configure CloudFront

**Week 4 Milestone:** MVP feature-complete. Ready for TestFlight beta.

---

## Post-MVP Priorities

1. **Android client** (React Native or Kotlin)
2. **Session replay** (watch recorded sessions with annotations)
3. **Multi-language support** (Spanish, French, German)
4. **Parts identification + ordering** (detect parts, suggest Amazon/Home Depot links)
5. **Collaborative sessions** (technician + remote expert via WebRTC)
6. **Offline mode** (on-device model for basic guidance without connectivity)
