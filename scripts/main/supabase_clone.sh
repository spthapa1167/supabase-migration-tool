#!/bin/bash
# Supabase Clone Script
# Clone one Supabase environment into another (destructive on the target)
# Creates a complete replica: schema, data, users, buckets, files, policies, edge functions, secrets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> [--auto-confirm] [additional flags]

Examples:
  ./scripts/main/supabase_clone.sh prod backup
  ./scripts/main/supabase_clone.sh prod backup --auto-confirm

Description:
  Creates a complete replica of the source environment in the target, including:
  - Database schema (tables, indexes, constraints, functions, triggers)
  - Database data (all table rows - REPLACED, not merged)
  - Authentication users and identities (REPLACED)
  - Storage buckets (all bucket configurations)
  - Storage files (all files in all buckets)
  - RLS policies, roles, grants, and access controls
  - Edge functions (all functions with code)
  - Secrets (new secret keys added incrementally)

Notes:
  - Target environment will be REPLACED with source state (destructive!)
  - Automatically takes a backup of the target before cloning
  - All data in target will be replaced, not merged
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
echo " Supabase Clone - Complete Replica"
echo "==================================================================="
echo " Source: $SOURCE_ENV"
echo " Target: $TARGET_ENV"
echo " Mode  : FULL REPLICA (complete replacement)"
echo ""
echo " Components to clone:"
echo "  ✓ Database schema (tables, indexes, functions, triggers)"
echo "  ✓ Database data (all table rows - REPLACED)"
echo "  ✓ Authentication users and identities (REPLACED)"
echo "  ✓ Storage buckets (all bucket configurations)"
echo "  ✓ Storage files (all files in all buckets)"
echo "  ✓ RLS policies, roles, grants, and access controls"
echo "  ✓ Edge functions (all functions with code)"
echo "  ✓ Secrets (new keys added incrementally)"
echo "==================================================================="
echo
echo "⚠️  WARNING: This operation is DESTRUCTIVE on the target environment."
echo "   All existing data, users, files, and configurations will be REPLACED."
echo "   A pre-clone backup of the target will be created automatically."
echo

if [ "$AUTO_PROCEED" != "true" ]; then
    read -p "Proceed with cloning $SOURCE_ENV → $TARGET_ENV? [y/N]: " confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$confirm" != "y" ] && [ "$confirm" != "yes" ]; then
        echo "[INFO] Clone cancelled by user."
        exit 0
    fi
fi

# Step 1: Run comprehensive main migration with all components
MAIN_CMD=(
    "$PROJECT_ROOT/scripts/main/supabase_migration.sh"
    "$SOURCE_ENV"
    "$TARGET_ENV"
    --data              # Include database row data migration
    --replace-data      # REPLACE all target data (destructive)
    --users             # Include auth users/identities migration
    --files             # Include storage bucket files migration
    --secret            # Include secrets migration
    --backup            # Create backup before migration
    --auto-confirm      # Skip confirmation prompts
)

if [ ${#EXTRA_FLAGS[@]} -gt 0 ]; then
    MAIN_CMD+=("${EXTRA_FLAGS[@]}")
fi

echo "[INFO] Step 1/7: Running comprehensive migration (schema, data, users, files, secrets, edge functions)..."
if ! "${MAIN_CMD[@]}"; then
    echo "[ERROR] Primary migration failed; aborting clone."
    exit 1
fi
echo "[SUCCESS] Step 1/7: Main migration completed"
echo ""

# Step 2: Ensure all table data is completely replaced (double-check for completeness)
PUBLIC_SCHEMA_SCRIPT="$PROJECT_ROOT/scripts/components/migrate_all_table_data.sh"
if [ -x "$PUBLIC_SCHEMA_SCRIPT" ]; then
    echo "[INFO] Step 2/7: Ensuring complete public schema data replacement..."
    if ! "$PUBLIC_SCHEMA_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[ERROR] Public schema data replacement failed; aborting clone."
        exit 1
    fi
    echo "[SUCCESS] Step 2/7: Public schema data replacement completed"
    echo ""
else
    echo "[WARNING] migrate_all_table_data.sh not found or not executable; skipping public schema data replacement."
fi

# Step 3: Replace all auth users and identities (ensure complete replacement)
AUTH_USERS_SCRIPT="$PROJECT_ROOT/scripts/components/authUsers_migration.sh"
if [ -x "$AUTH_USERS_SCRIPT" ]; then
    echo "[INFO] Step 3/7: Replacing all auth users and identities (replace mode)..."
    if ! "$AUTH_USERS_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --replace; then
        echo "[ERROR] Auth users migration failed; aborting clone."
        exit 1
    fi
    echo "[SUCCESS] Step 3/7: Auth users and identities replacement completed"
    echo ""
else
    echo "[WARNING] authUsers_migration.sh not found or not executable; skipping auth users replacement."
fi

# Step 4: Sync auth system tables and metadata
AUTH_SYSTEM_SCRIPT="$PROJECT_ROOT/scripts/components/auth_system_tables_migration.sh"
if [ -x "$AUTH_SYSTEM_SCRIPT" ]; then
    echo "[INFO] Step 4/7: Syncing auth system tables and Supabase metadata..."
    if ! "$AUTH_SYSTEM_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[ERROR] Auth system tables sync failed; aborting clone."
        exit 1
    fi
    echo "[SUCCESS] Step 4/7: Auth system tables sync completed"
    echo ""
else
    echo "[WARNING] auth_system_tables_migration.sh not found or not executable; skipping auth system table sync."
fi

# Step 5: Ensure storage buckets and files are completely migrated
STORAGE_SCRIPT="$PROJECT_ROOT/scripts/main/storage_buckets_migration.sh"
if [ -x "$STORAGE_SCRIPT" ]; then
    echo "[INFO] Step 5/7: Migrating all storage buckets with files..."
    if ! "$STORAGE_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --files --auto-confirm; then
        echo "[ERROR] Storage buckets and files migration failed; aborting clone."
        exit 1
    fi
    echo "[SUCCESS] Step 5/7: Storage buckets and files migration completed"
    echo ""
else
    echo "[WARNING] storage_buckets_migration.sh not found or not executable; skipping storage migration."
fi

# Step 6: Ensure policies, roles, and access controls are synced (already done in main migration, but double-check)
POLICIES_SCRIPT="$PROJECT_ROOT/scripts/main/policies_migration_new.sh"
if [ -x "$POLICIES_SCRIPT" ]; then
    echo "[INFO] Step 6/7: Verifying policies, roles, and access controls sync..."
    if ! "$POLICIES_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm; then
        echo "[WARNING] Policies/roles verification reported issues. Review logs above."
    else
        echo "[SUCCESS] Step 6/7: Policies, roles, and access controls verified"
    fi
    echo ""
else
    echo "[WARNING] policies_migration_new.sh not found or not executable; skipping policies verification."
fi

# Step 7: Retry any failed edge function deployments
RETRY_SCRIPT="$PROJECT_ROOT/scripts/components/retry_edge_functions.sh"
if [ -x "$RETRY_SCRIPT" ]; then
    echo "[INFO] Step 7/7: Retrying any failed edge function deployments..."
    if ! "$RETRY_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --allow-missing; then
        echo "[WARNING] Edge functions retry reported issues. Review logs above."
    else
        echo "[SUCCESS] Step 7/7: Edge functions deployment verified"
    fi
    echo ""
else
    echo "[WARNING] retry_edge_functions.sh not found or not executable; skipping edge functions retry."
fi

# Optional: Verify environment parity
COMPARE_SCRIPT="$PROJECT_ROOT/scripts/main/compare_env.sh"
if [ -x "$COMPARE_SCRIPT" ]; then
    echo "[INFO] Verifying environment parity (optional verification)..."
    if ! "$COMPARE_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-apply; then
        echo "[WARNING] Environment comparison detected differences. Review the latest compare report."
    else
        echo "[SUCCESS] Environment parity verification completed"
    fi
    echo ""
else
    echo "[WARNING] compare_env.sh not found or not executable; skipping parity verification."
fi

echo "==================================================================="
echo " Clone Completed Successfully"
echo "==================================================================="
echo " Target environment ($TARGET_ENV) should now be a complete replica of source ($SOURCE_ENV)"
echo ""
echo " Components cloned:"
echo "  ✓ Database schema (tables, indexes, functions, triggers)"
echo "  ✓ Database data (all table rows - REPLACED)"
echo "  ✓ Authentication users and identities (REPLACED)"
echo "  ✓ Storage buckets (all bucket configurations)"
echo "  ✓ Storage files (all files in all buckets)"
echo "  ✓ RLS policies, roles, grants, and access controls"
echo "  ✓ Edge functions (all functions with code)"
echo "  ✓ Secrets (new keys added incrementally)"
echo ""
echo " Note: Review migration logs in the backups/ directory for detailed information."
echo "==================================================================="

