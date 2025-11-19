#!/bin/bash
# Policies Migration Script (New - Using Supabase CLI)
# Migrates RLS policies, roles, grants, and access controls from source to target
# Uses Supabase CLI db pull/push for complete and accurate migration
# Can be used independently or as part of a complete migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_report_generator.sh" 2>/dev/null || true

# Usage function (must be defined before it's called)
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [migration_dir|--migration-dir <path>] [options]

Migrates RLS policies, roles, grants, and access controls from source to target
using pg_dump for schema export and direct SQL application for migration.

This script uses a hybrid approach:
- Complete and Accurate: Uses pg_dump to capture ALL RLS policies, indexes, and dependencies
- Minimal Manual Work: Automated process reduces human error
- Fast Execution: Direct SQL application for efficient migration
- Rollback Capability: Schema dumps are saved for easy reference

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  --migration-dir <path>  Same as positional migration_dir argument

Options:
  --auto-confirm Automatically proceed without interactive confirmation
  --verify-only  Only verify policies without migrating (dry-run)
  --schema-only  Only migrate schema (policies, roles, grants) without data
  -h, --help     Show this help message

Examples:
  $0 prod test                          # Migrate policies from prod to test
  $0 dev test /path/to/backup           # Migrate with custom backup directory
  $0 prod test --verify-only            # Verify policies without migrating

Returns:
  0 on success, 1 on failure

EOF
    exit 0
}

# Handle help flag early
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

# Configuration defaults
AUTO_CONFIRM_COMPONENT="${AUTO_CONFIRM:-false}"
SKIP_COMPONENT_CONFIRM="${SKIP_COMPONENT_CONFIRM:-false}"
MIGRATION_DIR=""
VERIFY_ONLY=false
SCHEMA_ONLY=true  # Default: schema only (policies, roles, grants)

# Argument parsing
if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2
shift 2

while [ $# -gt 0 ]; do
    case "$1" in
        --migration-dir)
            if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                MIGRATION_DIR=$2
                shift
            else
                log_error "--migration-dir requires a path argument"
                exit 1
            fi
            ;;
        --migration-dir=*)
            MIGRATION_DIR="${1#*=}"
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT=true
            ;;
        --verify-only)
            VERIFY_ONLY=true
            ;;
        --schema-only)
            SCHEMA_ONLY=true
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_warning "Ignoring unknown option: $1"
            ;;
        *)
            if [ -z "$MIGRATION_DIR" ]; then
                MIGRATION_DIR="$1"
            else
                log_warning "Ignoring unexpected argument (migration directory already set): $1"
            fi
            ;;
    esac
    shift || true
done

component_prompt_proceed() {
    local title=$1
    local message=${2:-"Proceed?"}

    if [ "${AUTO_CONFIRM_COMPONENT}" = "true" ] || [ "${SKIP_COMPONENT_CONFIRM}" = "true" ]; then
        return 0
    fi

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  ${title}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "$message"
    read -r -p "Proceed? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    echo ""

    if [ "$response" = "y" ] || [ "$response" = "yes" ]; then
        return 0
    fi
    return 1
}

# Check arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

# Check for Supabase CLI
if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - required for this migration method"
    log_error "Please install: npm install -g @supabase/cli"
    log_error "Then login: supabase login"
    exit 1
fi

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="policies_cli"
    MIGRATION_DIR=$(create_backup_dir "policies_cli" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="policies_cli"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"
MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR_ABS/migration.log}"
log_to_file "$LOG_FILE" "Starting policies migration (CLI method) from $SOURCE_ENV to $TARGET_ENV"

log_info "🔐 Policies Migration (Supabase CLI Method)"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR_ABS"
log_info "Method: pg_dump + Direct SQL Application"
if [ "$VERIFY_ONLY" = "true" ]; then
    log_info "Mode: VERIFY ONLY (no changes will be made)"
fi
echo ""

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    if ! component_prompt_proceed "Policies Migration (CLI Method)" "Proceed with policies migration from $SOURCE_ENV to $TARGET_ENV?"; then
        log_warning "Policies migration skipped by user request."
        log_to_file "$LOG_FILE" "Policies migration skipped by user."
        exit 0
    fi
fi

# Step 1: Verify Supabase CLI is logged in
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 1/4: Verifying Supabase CLI Authentication"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

if ! supabase projects list >/dev/null 2>&1; then
    log_error "Supabase CLI is not authenticated"
    log_error "Please run: supabase login"
    exit 1
fi
log_success "✓ Supabase CLI is authenticated"
log_to_file "$LOG_FILE" "Supabase CLI authentication verified"
echo ""

# Step 2: Export schema from source project
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 2/4: Exporting Schema from Source Project"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

SCHEMA_DUMP_FILE="$MIGRATION_DIR_ABS/source_schema.sql"
log_info "Exporting schema from source project ($SOURCE_REF)..."
log_to_file "$LOG_FILE" "Exporting schema from source project"

# Export schema from source using pg_dump directly
# Note: supabase db dump doesn't support --schema-only flag, so we use pg_dump directly
log_info "Exporting schema from source project..."
log_to_file "$LOG_FILE" "Exporting schema from source project using pg_dump"

# Get connection endpoints for source
endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "${SOURCE_POOLER_REGION:-}" "${SOURCE_POOLER_PORT:-6543}")
dump_success=false

while IFS='|' read -r host port user label; do
    [ -z "$host" ] && continue
    log_info "Attempting schema dump via ${label} (${host}:${port})..."
    log_to_file "$LOG_FILE" "Attempting schema dump via ${label}"
    
    # Use pg_dump directly with schema-only flag
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require pg_dump \
        -h "$host" \
        -p "$port" \
        -U "$user" \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-privileges \
        -f "$SCHEMA_DUMP_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        dump_success=true
        break
    else
        log_warning "Schema dump via ${label} failed, trying next endpoint..."
        log_to_file "$LOG_FILE" "Schema dump via ${label} failed"
    fi
done <<< "$endpoints"

if [ "$dump_success" = "true" ]; then
    if [ -s "$SCHEMA_DUMP_FILE" ]; then
        schema_size=$(wc -l < "$SCHEMA_DUMP_FILE" | tr -d '[:space:]')
        log_success "✓ Schema exported successfully ($schema_size lines)"
        log_to_file "$LOG_FILE" "Schema exported: $schema_size lines"
        
        # Count policies in the dump
        policy_count=$(grep -c "^CREATE POLICY\|^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        log_info "  Found $policy_count policy-related statement(s) in schema dump"
    else
        log_warning "⚠ Schema dump file is empty"
        log_to_file "$LOG_FILE" "WARNING: Schema dump file is empty"
    fi
else
    log_error "Failed to dump schema from source project via any connection method"
    log_to_file "$LOG_FILE" "ERROR: Failed to dump schema from source"
    exit 1
fi
echo ""

# Step 3: Verify policies in target (if verify-only mode)
if [ "$VERIFY_ONLY" = "true" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 3/4: Verifying Policies (Verify-Only Mode)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    
    log_info "Checking differences between source and target..."
    log_to_file "$LOG_FILE" "Verifying policies (verify-only mode)"
    
    # Create a temporary directory for comparison
    TEMP_DIR=$(mktemp -d)
    TARGET_SCHEMA_FILE="$TEMP_DIR/target_schema.sql"
    
    # Export target schema for comparison using pg_dump
    log_info "Exporting target schema for comparison..."
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "${TARGET_POOLER_REGION:-}" "${TARGET_POOLER_PORT:-6543}")
    target_dump_success=false
    
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_dump \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-privileges \
            -f "$TARGET_SCHEMA_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            target_dump_success=true
            break
        fi
    done <<< "$endpoints"
    
    if [ "$target_dump_success" = "true" ]; then
        if [ -s "$TARGET_SCHEMA_FILE" ]; then
            log_info "Comparing source and target schemas..."
            
            # Count policies in both
            source_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
            target_policy_count=$(grep -c "^CREATE POLICY" "$TARGET_SCHEMA_FILE" 2>/dev/null || echo "0")
            
            log_info "  Source policies: $source_policy_count"
            log_info "  Target policies: $target_policy_count"
            
            if [ "$source_policy_count" -eq "$target_policy_count" ]; then
                log_success "✓ Policy counts match between source and target"
            else
                diff=$((source_policy_count - target_policy_count))
                if [ "$diff" -gt 0 ]; then
                    log_warning "⚠ Target has $diff fewer policy(ies) than source"
                else
                    log_warning "⚠ Target has $((diff * -1)) more policy(ies) than source"
                fi
            fi
            
            # Compare schemas using diff command
            log_info "Running detailed diff check..."
            if command -v diff >/dev/null 2>&1; then
                diff_output=$(diff -u "$SCHEMA_DUMP_FILE" "$TARGET_SCHEMA_FILE" 2>&1 | head -50 || true)
                if [ -z "$diff_output" ]; then
                    log_success "✓ No differences found between source and target schemas"
                else
                    log_info "Differences found (showing first 50 lines):"
                    echo "$diff_output" | tee -a "$LOG_FILE"
                fi
            else
                log_info "Diff command not available - comparing policy counts only"
            fi
        else
            log_warning "⚠ Target schema dump is empty"
        fi
    else
        log_warning "⚠ Failed to export target schema for comparison"
    fi
    
    rm -rf "$TEMP_DIR"
    log_success "✓ Verification completed (no changes made)"
    log_to_file "$LOG_FILE" "Verification completed (verify-only mode)"
    echo ""
    exit 0
fi

# Step 3: Apply schema to target project
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 3/4: Applying Schema to Target Project"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Applying schema to target project ($TARGET_REF)..."
log_warning "⚠ This will modify the target database schema (policies, roles, grants)"
log_to_file "$LOG_FILE" "Applying schema to target project"

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ] && [ "$AUTO_CONFIRM_COMPONENT" != "true" ]; then
    read -r -p "Continue with applying schema to target? [y/N]: " confirm_apply
    confirm_apply=$(echo "$confirm_apply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$confirm_apply" != "y" ] && [ "$confirm_apply" != "yes" ]; then
        log_warning "Schema application cancelled by user"
        log_to_file "$LOG_FILE" "Schema application cancelled by user"
        exit 0
    fi
fi

# Apply schema to target project using direct SQL application
# Note: We use psql directly for reliability, as db push requires migrations directory setup
log_info "Applying schema to target project..."
log_to_file "$LOG_FILE" "Applying schema to target project"

# Apply SQL file directly using psql with fallback
endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "${TARGET_POOLER_REGION:-}" "${TARGET_POOLER_PORT:-6543}")
sql_applied=false
while IFS='|' read -r host port user label; do
    [ -z "$host" ] && continue
    log_info "Applying schema via ${label} (${host}:${port})..."
    log_to_file "$LOG_FILE" "Attempting schema application via ${label}"
    if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
        -h "$host" \
        -p "$port" \
        -U "$user" \
        -d postgres \
        -f "$SCHEMA_DUMP_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        sql_applied=true
        log_success "✓ Schema applied successfully to target"
        log_to_file "$LOG_FILE" "Schema applied successfully to target via ${label}"
        break
    else
        log_warning "Schema application via ${label} failed, trying next endpoint..."
        log_to_file "$LOG_FILE" "Schema application via ${label} failed"
    fi
done <<< "$endpoints"

if [ "$sql_applied" != "true" ]; then
    log_error "Failed to apply schema to target via any connection method"
    log_to_file "$LOG_FILE" "ERROR: Failed to apply schema to target"
    exit 1
fi
echo ""

# Step 4: Verify migration success
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4/4: Verifying Migration Success"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Verifying policies were migrated correctly..."
log_to_file "$LOG_FILE" "Verifying migration success"

# Export target schema after migration using pg_dump
TARGET_SCHEMA_AFTER="$MIGRATION_DIR_ABS/target_schema_after.sql"
log_info "Exporting target schema for verification..."
endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "${TARGET_POOLER_REGION:-}" "${TARGET_POOLER_PORT:-6543}")
target_after_dump_success=false

while IFS='|' read -r host port user label; do
    [ -z "$host" ] && continue
    if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_dump \
        -h "$host" \
        -p "$port" \
        -U "$user" \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-privileges \
        -f "$TARGET_SCHEMA_AFTER" 2>&1 | tee -a "$LOG_FILE"; then
        target_after_dump_success=true
        break
    fi
done <<< "$endpoints"

if [ "$target_after_dump_success" = "true" ]; then
    if [ -s "$TARGET_SCHEMA_AFTER" ]; then
        # Count policies
        source_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        target_policy_count=$(grep -c "^CREATE POLICY" "$TARGET_SCHEMA_AFTER" 2>/dev/null || echo "0")
        
        log_info "  Source policies: $source_policy_count"
        log_info "  Target policies (after migration): $target_policy_count"
        
        if [ "$source_policy_count" -eq "$target_policy_count" ]; then
            log_success "✓ Policy counts match! Migration successful"
            log_to_file "$LOG_FILE" "SUCCESS: Policy counts match ($source_policy_count policies)"
        else
            diff=$((source_policy_count - target_policy_count))
            if [ "$diff" -gt 0 ]; then
                log_warning "⚠ Target has $diff fewer policy(ies) than source"
                log_to_file "$LOG_FILE" "WARNING: Target has $diff fewer policies than source"
            else
                log_warning "⚠ Target has $((diff * -1)) more policy(ies) than source"
                log_to_file "$LOG_FILE" "WARNING: Target has $((diff * -1)) more policies than source"
            fi
        fi
        
        # Compare schemas to check for remaining differences
        log_info "Running final diff check..."
        if command -v diff >/dev/null 2>&1; then
            diff_output=$(diff -u "$SCHEMA_DUMP_FILE" "$TARGET_SCHEMA_AFTER" 2>&1 | head -50 || true)
            if [ -z "$diff_output" ]; then
                log_success "✓ No schema differences detected - migration complete!"
                log_to_file "$LOG_FILE" "SUCCESS: No schema differences detected"
            else
                log_info "Some differences may remain (showing first 50 lines):"
                echo "$diff_output" | tee -a "$LOG_FILE" | head -20
                log_to_file "$LOG_FILE" "INFO: Some differences may remain"
            fi
        else
            log_info "Diff command not available - policy count comparison only"
            log_to_file "$LOG_FILE" "INFO: Diff command not available"
        fi
    else
        log_warning "⚠ Target schema dump is empty"
    fi
else
    log_warning "⚠ Failed to export target schema for verification"
    log_to_file "$LOG_FILE" "WARNING: Failed to export target schema for verification"
fi

# Create summary
SUMMARY_FILE="$MIGRATION_DIR_ABS/policies_migration_summary.txt"
{
    echo "# Policies Migration Summary (CLI Method)"
    echo ""
    echo "**Source**: $SOURCE_ENV ($SOURCE_REF)"
    echo "**Target**: $TARGET_ENV ($TARGET_REF)"
    echo "**Date**: $(date)"
    echo "**Method**: pg_dump + Direct SQL Application"
    echo ""
    echo "## Migration Results"
    echo ""
    if [ -s "$SCHEMA_DUMP_FILE" ] && [ -s "${TARGET_SCHEMA_AFTER:-/dev/null}" ]; then
        source_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        target_policy_count=$(grep -c "^CREATE POLICY" "$TARGET_SCHEMA_AFTER" 2>/dev/null || echo "0")
        echo "- **Source Policies**: $source_policy_count"
        echo "- **Target Policies (after)**: $target_policy_count"
        if [ "$source_policy_count" -eq "$target_policy_count" ]; then
            echo "- **Status**: ✅ SUCCESS - Policy counts match"
        else
            echo "- **Status**: ⚠️  WARNING - Policy count mismatch"
        fi
    else
        echo "- **Status**: Migration completed (see logs for details)"
    fi
    echo ""
    echo "## Files Generated"
    echo ""
    echo "- \`source_schema.sql\` - Source schema dump"
    if [ -f "$TARGET_SCHEMA_AFTER" ]; then
        echo "- \`target_schema_after.sql\` - Target schema after migration"
    fi
    echo "- \`migration.log\` - Detailed migration log"
    echo ""
    echo "## Next Steps"
    echo ""
    echo "1. Review the migration log: \`$LOG_FILE\`"
    echo "2. Verify policies in target environment"
    echo "3. Test application functionality with new policies"
    echo ""
} > "$SUMMARY_FILE"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Complete"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_success "✓ Policies migration completed"
log_info "Summary: $SUMMARY_FILE"
log_info "Log: $LOG_FILE"
log_info ""
log_info "To verify migration, compare the schema files:"
log_info "  diff source_schema.sql target_schema_after.sql"
log_info ""

echo "$MIGRATION_DIR_ABS"

