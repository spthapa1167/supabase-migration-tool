#!/bin/bash
# Backward compatible shim for the clone script in scripts/main/.
# Delegates to scripts/main/supabase_clone.sh with all original args.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/main/supabase_clone.sh"

if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "[ERROR] Expected clone script not found at $TARGET_SCRIPT" >&2
    exit 1
fi

exec "$TARGET_SCRIPT" "$@"
