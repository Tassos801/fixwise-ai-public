# FixWise

FixWise is a private-beta AI assistant for guided, camera-first troubleshooting. The repository contains the production backend, the companion web dashboard, and the native iPhone app used for beta testing.

## Repo Structure

- `backend/` - FastAPI backend for auth, sessions, reports, and BYOK settings.
- `web/fixwise-dashboard/` - React + Vite companion dashboard for account, history, and reports.
- `ios/FixWise/` - Native iOS app for the beta experience on iPhone.
- `docs/` - Release notes, architecture notes, and rollout guidance.
- `render.yaml` - Render blueprint for the current private-beta deploy path.

## Local Validation

Run the checks that match the shipped surfaces before sending changes out to beta:

- Backend tests:
  ```bash
  cd backend
  python -m pytest -q
  ```

- Web build:
  ```bash
  cd web/fixwise-dashboard
  npm ci
  npm run build
  ```

- iOS simulator build and tests:
  ```bash
  xcodebuild -project ios/FixWise/FixWise.xcodeproj \
    -scheme FixWise \
    -destination 'platform=iOS Simulator,name=iPhone 17' test
  ```

## Private-Beta Deploy Path

The current deploy path is defined in `render.yaml`:

- `fixwise-backend`: Python web service with a persistent disk for the SQLite database and production environment variables.
- `fixwise-dashboard`: static site built from the web app and served as the beta companion dashboard.

To deploy, use the Render blueprint in this repo and configure the required secret environment variables in Render. The blueprint intentionally does not hardcode live service URLs in this README.

## Notes

- The beta release is intentionally single-region and single-instance.
- Billing and plan-upgrade UI is out of scope for this pass.
- The iPhone app is the primary beta surface; the web dashboard is the companion portal.
