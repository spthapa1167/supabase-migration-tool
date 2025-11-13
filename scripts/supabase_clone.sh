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
AUTO_PROCEED=false
if [ $# -gt 0 ]; then
    EXTRA_FLAGS=("$@")
    for flag in "${EXTRA_FLAGS[@]}"; do
        case "$flag" in
            --auto-confirm|--yes|-y)
                AUTO_PROCEED=true
                ;;
        esac
    done
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

if [ "$AUTO_PROCEED" != "true" ]; then
    read -p "Proceed with cloning $SOURCE_ENV → $TARGET_ENV? [y/N]: " confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$confirm" != "y" ] && [ "$confirm" != "yes" ]; then
        echo "[INFO] Clone cancelled by user."
        exit 0
    fi
fi

CMD=(
    "$PROJECT_ROOT/scripts/supabase_migration.sh"
    "$SOURCE_ENV"
    "$TARGET_ENV"
    --mode full
    --users
    --files
    --replace-data
    --backup
    --auto-confirm
)

if [ ${#EXTRA_FLAGS[@]} -gt 0 ]; then
    CMD+=("${EXTRA_FLAGS[@]}")
fi

"${CMD[@]}"


