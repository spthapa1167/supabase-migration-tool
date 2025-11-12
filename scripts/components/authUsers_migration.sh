#!/usr/bin/env bash

# Thin wrapper that delegates auth user migration to the Node.js implementation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_SCRIPT="${PROJECT_ROOT}/utils/auth-users-migrate.js"

if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] node command not found. Please install Node.js." >&2
    exit 1
fi

cd "$PROJECT_ROOT"
exec node "$NODE_SCRIPT" "$@"


