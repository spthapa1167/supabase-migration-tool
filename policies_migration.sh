#!/bin/bash
# Compatibility shim: delegates to the relocated policies migration script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/components/policies_migration.sh"

if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "[ERROR] Expected policies migration script not found at $TARGET_SCRIPT" >&2
    exit 1
fi

exec "$TARGET_SCRIPT" "$@"

