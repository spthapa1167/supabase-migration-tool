#!/bin/bash
# Supabase Clone Script
# Clone one Supabase environment into another (destructive on the target)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: supabase_clone.sh <source_env> <target_env> [--auto-confirm] [additional flags]

Examples:
  supabase_clone.sh prod backup
  supabase_clone.sh prod backup --auto-confirm

Notes:
  - Performs a full clone (schema + data + auth users + storage + edge functions + secrets structure)
  - Target environment will be replaced with source state (destructive!)
  - Automatically takes a backup of the target before cloning
  - Additional flags are forwarded to supabase_migration.sh
EOF
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV="$1"
TARGET_ENV="$2"
shift 2

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

if [ "$SOURCE_ENV" = "$TARGET_ENV" ]; then
    echo "[ERROR] Source and target environments must differ." >&2
    exit 1
fi

EXTRA_FLAGS=()
if [ $# -gt 0 ]; then
    EXTRA_FLAGS=("$@")
fi

cd "$PROJECT_ROOT"

echo "==================================================================="
echo " Supabase Clone"
echo " Source: $SOURCE_ENV"
echo " Target: $TARGET_ENV"
echo " Mode  : FULL clone (schema, data, auth users, storage, edge functions, secrets)"
echo "==================================================================="
echo
echo "This operation is destructive on the target environment."
echo "A pre-clone backup of the target will be created automatically."
echo

if [ ${#EXTRA_FLAGS[@]} -gt 0 ]; then
    "$PROJECT_ROOT/scripts/supabase_migration.sh" "$SOURCE_ENV" "$TARGET_ENV" \
        --mode full \
        --users \
        --files \
        --replace-data \
        --backup \
        "${EXTRA_FLAGS[@]}"
else
    "$PROJECT_ROOT/scripts/supabase_migration.sh" "$SOURCE_ENV" "$TARGET_ENV" \
        --mode full \
        --users \
        --files \
        --replace-data \
        --backup
fi


