#!/bin/bash
# Backward compatible shim for the relocated supabase migration script.
# Delegates to scripts/main/supabase_migration.sh with all original args.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/main/supabase_migration.sh"

if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "[ERROR] Expected migration script not found at $TARGET_SCRIPT" >&2
    exit 1
fi

exec "$TARGET_SCRIPT" "$@"

