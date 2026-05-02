#!/bin/bash
# Supabase Clone Script
# Clone one Supabase environment into another (destructive on the target)
# Creates a complete replica: schema, data, users, buckets, files, policies, edge functions,
# and project secret names (Edge/CLI secrets) aligned to the source with placeholder/blank
# values so you can set real values after cutover.

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
  - Authentication users and identities (REPLACED, including encrypted passwords)
  - Storage buckets (all bucket configurations)
  - Storage files (all files in all buckets)
  - RLS policies, roles, grants, and access controls
  - Edge functions (all functions with code and shared dependencies)

  Supabase project secrets: secret names from the source are applied to the target with
  blank or PLACEHOLDER_UPDATE_REQUIRED values. Existing target secret values for those keys
  are overwritten. Update real values in the target project after cloning.

Notes:
  - Target environment will be REPLACED with source state (destructive for data/schema/users/files/secret values)
  - Use the target project's own anon and service_role keys in the app; URL and API keys are per project
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
echo " Supabase Clone - Complete Replica"
echo "==================================================================="
echo " Source: $SOURCE_ENV"
echo " Target: $TARGET_ENV"
echo " Mode  : FULL REPLICA (complete replacement)"
echo ""
echo " Components to clone:"
echo "  ✓ Database schema (tables, indexes, functions, triggers, types, extensions)"
echo "  ✓ Database data (all table rows - REPLACED, not merged)"
echo "  ✓ Authentication users and identities (REPLACED, including encrypted passwords)"
echo "  ✓ Storage buckets (all bucket configurations and policies)"
echo "  ✓ Storage files (all files in all buckets - complete file migration)"
echo "  ✓ RLS policies, roles, grants, and access controls (complete policy sync)"
echo "  ✓ Edge functions (all functions with code and shared dependencies)"
echo "  ✓ Project secrets (key names from source; values set to blank/placeholder — set real values after)"
echo "==================================================================="
echo
echo "⚠️  WARNING: This operation is DESTRUCTIVE on the target environment."
echo "   Schema, data, users, files, and project secret key values (placeholders) will be replaced/aligned to source."
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

# Step 1: Main migration: all components; database data handled in later clone steps
# --clone-secrets: align target project secret key names to source; values blank/placeholder (may overwrite)
# --clone: skip database data in main migration; Step 2 runs migrate_all_table_data for full data replacement
MAIN_CMD=(
    "$PROJECT_ROOT/scripts/main/supabase_migration.sh"
    "$SOURCE_ENV"
    "$TARGET_ENV"
    --full              # Schema + data flags + users + files + edge functions + secrets
    --clone-secrets     # Secret keys from source; placeholder/blank values on target
    --clone             # Skip database data in main; Step 2 runs migrate_all_table_data
    --replace-data      # REPLACE all target data (ensures complete clone)
    --backup            # Create backup before migration
    --auto-confirm      # Skip confirmation prompts
)

if [ ${#EXTRA_FLAGS[@]} -gt 0 ]; then
    MAIN_CMD+=("${EXTRA_FLAGS[@]}")
fi

echo "[INFO] Step 1/7: Running comprehensive migration (schema, users, files, edge functions, secrets w/ placeholders; data in Step 2)..."
echo "[INFO] Note: Database data is migrated in Step 2 (migrate_all_table_data). Secrets use placeholders — set real values on target after clone."
# Capture the migration directory from the main migration output if possible
# The main migration will create a backup directory automatically
if ! "${MAIN_CMD[@]}"; then
    echo "[ERROR] Primary migration failed; aborting clone."
    exit 1
fi
echo "[SUCCESS] Step 1/7: Main migration completed"
echo ""

# Find the most recent migration directory created by the main migration
# This ensures Step 5 uses the same migration directory
# Use macOS/BSD compatible find command
LATEST_MIGRATION_DIR=$(find "$PROJECT_ROOT/backups" -maxdepth 1 -type d -name "*migration_${SOURCE_ENV}_to_${TARGET_ENV}_*" -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)
if [ -z "$LATEST_MIGRATION_DIR" ] || [ ! -d "$LATEST_MIGRATION_DIR" ]; then
    # Fallback: let storage migration script create its own directory
    LATEST_MIGRATION_DIR=""
fi

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
    echo "[INFO] Step 5/7: Verifying storage buckets and files migration (with files)..."
    STORAGE_CMD=("$STORAGE_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV")
    if [ -n "$LATEST_MIGRATION_DIR" ]; then
        STORAGE_CMD+=("$LATEST_MIGRATION_DIR")
    fi
    STORAGE_CMD+=(--files --auto-confirm)
    if ! "${STORAGE_CMD[@]}"; then
        echo "[WARNING] Storage buckets verification reported issues. Review logs above."
        echo "[INFO] Continuing clone process (storage was already migrated in Step 1 with --full flag)..."
    else
        echo "[SUCCESS] Step 5/7: Storage buckets and files verification completed"
    fi
    echo ""
else
    echo "[WARNING] storage_buckets_migration.sh not found or not executable; skipping storage verification."
fi

# Step 6: Ensure policies, roles, and access controls are synced
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

# Step 7: Run policy_migration_complete.sh to ensure all RLS policies are copied (final pass, closes any policy gap)
POLICY_COMPLETE_SCRIPT="$PROJECT_ROOT/scripts/main/policy_migration_complete.sh"
if [ -x "$POLICY_COMPLETE_SCRIPT" ]; then
    echo "[INFO] Step 7/7: Running policy migration complete (final RLS policy sync)..."
    if ! "$POLICY_COMPLETE_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV"; then
        echo "[WARNING] Policy migration complete reported a remaining gap or errors. Check output above for manual SQL file path."
    else
        echo "[SUCCESS] Step 7/7: Policy migration complete finished"
    fi
    echo ""
else
    echo "[WARNING] policy_migration_complete.sh not found or not executable; skipping final policy pass."
fi

echo "[INFO] Secrets: Applied in Step 1 via --clone-secrets (key names from source, placeholder/blank values on target)."
echo ""

# Note: Edge functions are migrated once in Step 1 via supabase_migration.sh
# If any edge functions failed, they can be retried manually using:
#   ./scripts/components/retry_edge_functions.sh <source_env> <target_env>

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
echo "  ✓ Database schema (tables, indexes, functions, triggers, types, extensions)"
echo "  ✓ Database data (all table rows - REPLACED, not merged)"
echo "  ✓ Authentication users and identities (REPLACED, including encrypted passwords)"
echo "  ✓ Storage buckets (all bucket configurations and policies)"
echo "  ✓ Storage files (all files in all buckets - complete file migration)"
echo "  ✓ RLS policies, roles, grants, and access controls (complete policy sync)"
echo "  ✓ Edge functions (all functions with code and shared dependencies)"
echo "  ✓ Project secret names aligned to source; values are placeholders — set before production use"
echo ""
echo " Verification:"
echo "  - Review migration logs in the backups/ directory"
echo "  - Check component summaries in the migration directory"
echo "  - Use compare_env.sh to verify environment parity if needed"
echo "  - Set real project secret values: supabase secrets set KEY=value --project-ref <target_ref>"
echo "  - Use the target project URL, anon, and service_role keys in the application"
echo ""
echo " Note: Review migration logs in the backups/ directory for detailed information."
echo "==================================================================="

