#!/bin/bash
# Helper script to restart the Supabase Migration Tool UI server.
# Kills any process currently bound to the configured port
# and then launches `npm start dev` from the project root.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PORT=3000
PORT="${PORT:-$DEFAULT_PORT}"

echo "[INFO] Starting Supabase Migration Tool UI (PORT=${PORT})"

cd "$PROJECT_ROOT"

# Kill any processes currently using the port
if command -v lsof >/dev/null 2>&1; then
    PIDS="$(lsof -ti tcp:$PORT || true)"
    if [[ -n "${PIDS}" ]]; then
        echo "[INFO] Terminating existing process(es) on port ${PORT}: ${PIDS}"
        for pid in ${PIDS}; do
            kill "$pid" 2>/dev/null || true
        done
        sleep 1
    else
        echo "[INFO] No existing process detected on port ${PORT}"
    fi
else
    echo "[WARN] 'lsof' not found; skipping automatic port cleanup"
fi

echo "[INFO] Launching UI server..."
exec npm start dev



