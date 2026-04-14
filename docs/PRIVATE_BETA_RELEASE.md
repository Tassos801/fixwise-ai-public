# FixWise Private Beta Release

## Scope

This release targets a private iPhone beta with:

- the native iOS app as the primary user surface
- one hosted backend instance
- one hosted companion web portal for account, history, and report access

This pass does not include public-scale infrastructure, billing, or multi-instance failover.

## Deployment Notes

The repository is not currently attached to a Git remote, so the included `render.yaml` is a ready-to-use Blueprint but cannot be deployed through Render's Git-backed flow until the project is pushed to GitHub, GitLab, or Bitbucket.

## Render Services

### Backend

- Service: `fixwise-backend`
- Runtime: Python
- Plan: `starter`
- Persistent disk mounted at `/data`
- Required secrets:
  - `FIXWISE_JWT_SECRET`
  - `FIXWISE_MASTER_KEY`
  - `OPENAI_API_KEY` when `FIXWISE_AI_PROVIDER=openai`
  - `GEMMA_API_KEY` when `FIXWISE_AI_PROVIDER=gemma`
- Required config:
  - `FIXWISE_AI_PROVIDER=openai|gemma`
  - `FIXWISE_ALLOWED_ORIGINS`
  - `FIXWISE_DATABASE_PATH=/data/fixwise.db`
  - `FIXWISE_ENVIRONMENT=production`

### Web Companion

- Service: `fixwise-dashboard`
- Runtime: Static
- Build env:
  - `VITE_API_BASE_URL=https://<backend-host>`

## Beta Smoke Checks

Run these after every staging or beta deploy:

1. `GET /health` returns `200` and reports the expected environment, AI provider, and model state.
2. Register a new user, log in, refresh the session, and confirm `/api/auth/me` works.
3. Save and remove a BYOK key from the web portal.
4. Launch the iOS app, confirm the backend configuration points to public `https://` and `wss://` URLs, then complete onboarding.
5. Start a live session on iPhone, verify WebSocket connection, starter prompts, prompt submission, and AI response rendering.
6. End the session and confirm the web portal shows session history and allows report download.

## Physical Device Checklist

1. Install the beta build on iPhone.
2. Confirm camera, microphone, and speech recognition permissions.
3. Confirm the app is not pointed at localhost.
4. Sign in with a beta account.
5. Start one session over Wi-Fi and one session over cellular or hotspot.
6. Interrupt connectivity once and confirm reconnect/resume behavior is understandable.
7. Verify the same account can see session history and the generated report in the web portal.
