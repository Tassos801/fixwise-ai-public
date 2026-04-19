# FixWise Hosted Voice Assistant Beta

## Scope

This beta is optimized around one primary path:

- the native iPhone app is the main product
- the public Render backend is the default runtime
- the web dashboard is a signed-in companion for history, reports, and optional provider-key management

This pass is intentionally guest-first, voice-first, and hosted-first. Local laptop backends remain available only as an advanced developer override.

## Hosted Runtime

### Backend

- Service: `fixwise-backend`
- Runtime: Python web service on Render
- Default provider: `gemma`
- Default AI mode: `live`
- Required secrets:
  - `FIXWISE_JWT_SECRET`
  - `FIXWISE_MASTER_KEY`
  - `GEMMA_API_KEY`
- Optional secrets:
  - `OPENAI_API_KEY` only if you intentionally switch the provider
- Required config:
  - `FIXWISE_AI_MODE=live`
  - `FIXWISE_AI_PROVIDER=gemma`
  - `FIXWISE_ENVIRONMENT=production`
  - `FIXWISE_ALLOWED_ORIGINS`
  - `FIXWISE_DATABASE_PATH=/opt/render/project/src/backend/fixwise.db`

Important runtime rule:

- production must never silently fall back to mock guidance
- if the hosted Gemma key is missing or invalid, `/health` should report `availability=unavailable`
- guidance requests should fail clearly instead of pretending to be live

### Web Companion

- Service: `fixwise-dashboard`
- Runtime: Render static site
- Build env:
  - `VITE_API_BASE_URL=https://<backend-host>`

## User Experience Goals

The intended beta flow is:

1. fresh install on iPhone
2. permissions granted
3. hosted backend check succeeds
4. guest identity is created automatically
5. user enters a live voice session without touching advanced settings

FixWise account sign-in remains optional. It unlocks:

- synced history
- report access in the web dashboard
- optional BYOK provider-key management

Guests should still be able to start live sessions immediately.

## Beta Smoke Checks

Run these after every hosted deploy:

1. `GET /health` returns `200` and includes:
   - expected environment
   - provider/model details
   - `availability`
   - live readiness state
2. `POST /api/auth/guest` returns a new guest identity and token pair.
3. Register a normal account, log in, refresh the session, and confirm `/api/auth/me` works.
4. Confirm guests cannot save a provider key, while signed-in users can save and remove one.
5. Launch the iPhone app and verify it reaches guest-ready state without visiting Settings.
6. Start a live session on iPhone and verify:
   - WebSocket connection
   - readiness card
   - transcript updates
   - follow-up chips
   - response audio and text
7. End the session and confirm:
   - recap screen appears on iPhone
   - signed-in users can view history/report in the web companion

## Physical Device Checklist

1. Install the beta build on iPhone.
2. Confirm camera, microphone, and speech recognition permissions.
3. Confirm the app points to the hosted backend by default.
4. Verify guest setup completes automatically on first launch.
5. Start one session on Wi-Fi and one session on cellular or hotspot.
6. Interrupt connectivity once and confirm reconnect copy is understandable and non-scary.
7. If signed in, verify the same account can view history and reports in the web dashboard.

## Notes

- Billing, subscriptions, and public-scale infrastructure stay out of scope for this pass.
- Guest history is device-local in this beta pass.
- Signed-in account history remains server-backed and visible in the companion web portal.
