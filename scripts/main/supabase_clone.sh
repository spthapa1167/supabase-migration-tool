#!/bin/bash
# Supabase Clone Script
# Clone one Supabase environment into another (destructive on the target)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> [--auto-confirm] [additional flags]

Examples:
  ./scripts/main/supabase_clone.sh prod backup
  ./scripts/main/supabase_clone.sh prod backup --auto-confirm

Notes:
  - Performs a full clone (schema + data + auth users + storage + edge functions + secrets structure)
  - Target environment will be replaced with source state (destructive!)
  - Automatically takes a backup of the target before cloning
  - Additional flags are forwarded to ./scripts/main/supabase_migration.sh
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

MAIN_CMD=(
    "$PROJECT_ROOT/scripts/main/supabase_migration.sh"
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
    MAIN_CMD+=("${EXTRA_FLAGS[@]}")
fi

echo "[INFO] Running primary migration..."
if ! "${MAIN_CMD[@]}"; then
    echo "[ERROR] Primary migration failed; aborting clone."
    exit 1
fi

PUBLIC_SCHEMA_SCRIPT="$PROJECT_ROOT/scripts/components/migrate_all_table_data.sh"
if [ -x "$PUBLIC_SCHEMA_SCRIPT" ]; then
    echo "[INFO] Replacing public schema data to guarantee identical table state..."
    if ! "$PUBLIC_SCHEMA_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[ERROR] Public schema replacement failed; aborting clone."
        exit 1
    fi
else
    echo "[WARNING] migrate_all_table_data.sh not found or not executable; skipping public schema replacement."
fi

AUTH_USERS_SCRIPT="$PROJECT_ROOT/scripts/components/authUsers_migration.sh"
if [ -x "$AUTH_USERS_SCRIPT" ]; then
    echo "[INFO] Refreshing auth schema (replace mode)..."
    if ! "$AUTH_USERS_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --replace; then
        echo "[ERROR] Auth users migration failed; aborting clone."
        exit 1
    fi
else
    echo "[WARNING] authUsers_migration.sh not found or not executable; skipping auth users refresh."
fi

AUTH_SYSTEM_SCRIPT="$PROJECT_ROOT/scripts/components/auth_system_tables_migration.sh"
if [ -x "$AUTH_SYSTEM_SCRIPT" ]; then
    echo "[INFO] Syncing auth system tables and Supabase metadata..."
    if ! "$AUTH_SYSTEM_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[ERROR] Auth system tables sync failed; aborting clone."
        exit 1
    fi
else
    echo "[WARNING] auth_system_tables_migration.sh not found or not executable; skipping auth system table sync."
fi

POLICIES_SCRIPT="$PROJECT_ROOT/scripts/components/policies_migration.sh"
if [ -x "$POLICIES_SCRIPT" ]; then
    echo "[INFO] Syncing policy/role tables..."
    if ! "$POLICIES_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[ERROR] Policies/roles migration failed; aborting clone."
        exit 1
    fi
else
    echo "[WARNING] policies_migration.sh not found or not executable; skipping policies sync."
fi

RETRY_SCRIPT="$PROJECT_ROOT/scripts/components/retry_edge_functions.sh"
if [ -x "$RETRY_SCRIPT" ]; then
    echo "[INFO] Retrying any failed edge function deployments..."
    if ! "$RETRY_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --allow-missing; then
        echo "[WARNING] Edge functions retry reported issues. Review logs above."
    fi
else
    echo "[WARNING] retry_edge_functions.sh not found or not executable; skipping edge retry."
fi

COMPARE_SCRIPT="$PROJECT_ROOT/scripts/main/compare_env.sh"
if [ -x "$COMPARE_SCRIPT" ]; then
    echo "[INFO] Verifying environment parity..."
    if ! "$COMPARE_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-apply; then
        echo "[WARNING] Environment comparison detected differences. Review the latest compare report."
    fi
else
    echo "[WARNING] compare_env.sh not found or not executable; skipping parity verification."
fi

echo "[SUCCESS] Clone completed. Target environment should now mirror source (including public schema, auth data, policies, and edge functions)."

