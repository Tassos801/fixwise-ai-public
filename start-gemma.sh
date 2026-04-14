#!/bin/bash
# Start FixWise backend configured for Gemma 4 via Google AI Studio.
# Usage: GEMMA_API_KEY=your-key ./start-gemma.sh
#
# Get a free API key at: https://aistudio.google.com/apikey

set -euo pipefail

if [ -z "${GEMMA_API_KEY:-}" ]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  GEMMA_API_KEY is not set.                              ║"
    echo "║                                                         ║"
    echo "║  Get a free key at:                                     ║"
    echo "║    https://aistudio.google.com/apikey                   ║"
    echo "║                                                         ║"
    echo "║  Then run:                                              ║"
    echo "║    GEMMA_API_KEY=AIza... ./start-gemma.sh               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    exit 1
fi

LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  FixWise AI — Gemma 4 Backend                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Provider:  Gemma 4 (31B IT) via Google AI Studio       ║"
echo "║  Local IP:  $LOCAL_IP                              ║"
echo "║  API:       http://$LOCAL_IP:8000                  ║"
echo "║  Health:    http://$LOCAL_IP:8000/health           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  In the iOS app Settings, set Backend URL to:           ║"
echo "║    http://$LOCAL_IP:8000                           ║"
echo "╚══════════════════════════════════════════════════════════╝"

cd "$(dirname "$0")/backend"

export FIXWISE_AI_MODE=live
export FIXWISE_AI_PROVIDER=gemma
export FIXWISE_ENVIRONMENT=development
export FIXWISE_ALLOWED_ORIGINS="*"
export GEMMA_API_KEY

exec uvicorn fixwise_backend.app:app --host 0.0.0.0 --port 8000 --reload
