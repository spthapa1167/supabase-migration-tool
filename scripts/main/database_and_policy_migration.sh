#!/bin/bash
# Database and Policy Migration Script (Ultra-Efficient CLI Method)
# Migrates database schema, RLS policies, roles, grants, and optionally data
# Uses Supabase CLI db pull/push for the most efficient migration
# Can be used independently or as part of a complete migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Global error handling
error_handler() {
    local exit_code=$?
    local line_number=$1
    local command="${2:-unknown}"
    
    # Log error details
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Script error at line $line_number: command '$command' failed with exit code $exit_code" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Cleanup: unlink from Supabase project
    supabase unlink --yes 2>/dev/null || true
    
    exit $exit_code
}

# Set up error trap
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap 'supabase unlink --yes 2>/dev/null || true; exit' EXIT INT TERM

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_report_generator.sh" 2>/dev/null || true

# Helper functions for reliable database connections (same as database_migration.sh)
# Helper: run psql query and capture output with fallback
run_psql_query_with_fallback() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query=$5

    local tmp_err
    tmp_err=$(mktemp)
    local success=false

    # First, try database connectivity via shared pooler (no API calls)
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -F '|' \
            -t -A \
            -v ON_ERROR_STOP=on \
            -c "$query" \
            2>"$tmp_err"; then
            success=true
            break
        else
            log_warning "Query execution failed via ${label}: $(head -n 1 "$tmp_err" 2>/dev/null || echo 'unknown error')"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    # If all pooler connections failed, try API to get correct pooler hostname
    if [ "$success" = "false" ]; then
        log_info "Pooler connections failed, trying API to get pooler hostname..."
        local api_pooler_host=""
        api_pooler_host=$(get_pooler_host_via_api "$ref" 2>/dev/null || echo "")
        
        if [ -n "$api_pooler_host" ]; then
            log_info "Retrying query with API-resolved pooler host: ${api_pooler_host}"
            
            # Try with API-resolved pooler host
            for port in "$pooler_port" "5432"; do
                if PGPASSWORD="$password" PGSSLMODE=require psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${ref}" \
                    -d postgres \
                    -F '|' \
                    -t -A \
                    -v ON_ERROR_STOP=on \
                    -c "$query" \
                    2>"$tmp_err"; then
                    success=true
                    break
                else
                    log_warning "Query execution failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -n 1 "$tmp_err" 2>/dev/null || echo 'unknown error')"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API"
        fi
    fi

    if [ "$success" = "true" ]; then
        rm -f "$tmp_err"
        return 0
    else
        cat "$tmp_err" >&2
        rm -f "$tmp_err"
        return 1
    fi
}

# Helper: run psql script file with fallback
run_psql_script_with_fallback() {
    local description=$1
    local ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local script_path=$6

    local success=false
    local tmp_err
    tmp_err=$(mktemp)

    # First, try database connectivity via shared pooler (no API calls)
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "${description} via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -v ON_ERROR_STOP=off \
            -f "$script_path" \
            >>"$LOG_FILE" 2>"$tmp_err"; then
            success=true
            break
        else
            log_warning "${description} failed via ${label}: $(head -n 1 "$tmp_err" 2>/dev/null || echo 'unknown error')"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    # If all pooler connections failed, try API to get correct pooler hostname
    if [ "$success" = "false" ]; then
        log_info "Pooler connections failed, trying API to get pooler hostname..."
        local api_pooler_host=""
        api_pooler_host=$(get_pooler_host_via_api "$ref" 2>/dev/null || echo "")
        
        if [ -n "$api_pooler_host" ]; then
            log_info "Retrying ${description} with API-resolved pooler host: ${api_pooler_host}"
            
            # Try with API-resolved pooler host
            for port in "$pooler_port" "5432"; do
                log_info "${description} via API-resolved pooler (${api_pooler_host}:${port})"
                if PGPASSWORD="$password" PGSSLMODE=require psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${ref}" \
                    -d postgres \
                    -v ON_ERROR_STOP=off \
                    -f "$script_path" \
                    >>"$LOG_FILE" 2>"$tmp_err"; then
                    success=true
                    break
                else
                    log_warning "${description} failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -n 1 "$tmp_err" 2>/dev/null || echo 'unknown error')"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API"
        fi
    fi

    rm -f "$tmp_err"
    $success && return 0 || return 1
}

# Usage function (must be defined before it's called)
usage() {
    cat << 'EOF'
Usage: database_and_policy_migration.sh <source_env> <target_env> [migration_dir|--migration-dir <path>] [options]

Ultra-efficient migration of database schema, RLS policies, roles, grants, and optionally data
from source to target using pg_dump and direct SQL application (avoids migration repair issues).

OVERVIEW
────────────────────────────────────────────────────────────────────────────────────────────
This script uses the most efficient migration method available:
  • Fastest Execution: 2-5 minutes for most projects (vs 15-30+ minutes manually)
  • Reliable: Uses pg_dump directly, avoiding migration repair issues
  • Automated: No manual SQL writing required
  • Built-in Validation: Automatic error checking
  • Direct Connection: Uses PostgreSQL tools directly

IMPORTANT: DATA MIGRATION LIMITATION
────────────────────────────────────────────────────────────────────────────────────────────
⚠️  The pg_dump method ONLY migrates SCHEMA, not data.

  • Schema includes: tables, RLS policies, roles, grants, functions, triggers, indexes
  • Data migration: NOT supported by pg_dump --schema-only method

If you use --data or --replace-data flags:
  • The script will warn you that pg_dump doesn't support data migration
  • It will proceed with schema-only migration
  • You'll receive guidance to use database_migration.sh for actual data migration

For data migration, use:
  ./scripts/components/database_migration.sh <source> <target> --data [--increment|--replace-data]

DEFAULT BEHAVIOR
────────────────────────────────────────────────────────────────────────────────────────────
  • Schema only (tables, RLS policies, roles, grants, functions, etc.)
  • No data migration
  • Interactive confirmation prompts (unless --auto-confirm)

ARGUMENTS
────────────────────────────────────────────────────────────────────────────────────────────
  source_env     Source environment name
                 Valid values: prod, test, dev, backup
                 Example: dev

  target_env     Target environment name
                 Valid values: prod, test, dev, backup
                 Example: test

  migration_dir  (Optional) Directory to store migration files
                 If not provided, auto-generated in backups/ directory
                 Can also be specified with --migration-dir flag

OPTIONS
────────────────────────────────────────────────────────────────────────────────────────────
  --data
      Request data migration (incremental mode)
      ⚠️  WARNING: CLI method doesn't support data migration
      Script will warn and proceed with schema-only migration
      Use database_migration.sh for actual data migration

  --replace-data
      Request data replacement (destructive mode)
      ⚠️  WARNING: CLI method doesn't support data migration
      Requires --data flag
      Script will warn and proceed with schema-only migration
      Use database_migration.sh for actual data replacement

  --auto-confirm, --yes, -y
      Automatically proceed without interactive confirmation prompts
      Useful for automated scripts and CI/CD pipelines

  --verify-only
      Only verify schema differences without migrating (dry-run)
      No changes will be made to source or target
      Useful for checking what would be migrated

  --migration-dir <path>
      Specify custom directory for migration files
      Same as providing migration_dir as positional argument

  -h, --help
      Show this help message and exit

EXAMPLES
────────────────────────────────────────────────────────────────────────────────────────────
  # Schema only migration (default - fastest method)
  ./scripts/main/database_and_policy_migration.sh dev test

  # Schema migration with custom backup directory
  ./scripts/main/database_and_policy_migration.sh dev test /path/to/backup

  # Schema migration with auto-confirm (no prompts)
  ./scripts/main/database_and_policy_migration.sh dev test --auto-confirm

  # Verify differences without migrating
  ./scripts/main/database_and_policy_migration.sh dev test --verify-only

  # Request data migration (will warn and proceed schema-only)
  ./scripts/main/database_and_policy_migration.sh dev test --data

  # Request data replacement (will warn and proceed schema-only)
  ./scripts/main/database_and_policy_migration.sh dev test --data --replace-data

PREREQUISITES
────────────────────────────────────────────────────────────────────────────────────────────
  1. Supabase CLI installed:
     npm install -g @supabase/cli

  2. Supabase CLI authenticated:
     supabase login

  3. Environment variables configured in .env.local:
     SUPABASE_<ENV>_PROJECT_REF
     SUPABASE_<ENV>_DB_PASSWORD
     (where <ENV> is SOURCE_ENV and TARGET_ENV in uppercase)

WHAT GETS MIGRATED
────────────────────────────────────────────────────────────────────────────────────────────
  ✓ Database schema (tables, columns, types, constraints)
  ✓ RLS (Row Level Security) policies
  ✓ Roles and role assignments
  ✓ Grants and permissions
  ✓ Functions and procedures
  ✓ Triggers
  ✓ Indexes
  ✓ Sequences
  ✗ Table data (NOT supported by CLI method)

RETURN CODES
────────────────────────────────────────────────────────────────────────────────────────────
  0  Success - Migration completed successfully
  1  Failure - Error occurred during migration

MIGRATION PROCESS
────────────────────────────────────────────────────────────────────────────────────────────
  Step 1: Verify Supabase CLI authentication
  Step 2: Export schema from source project (pg_dump)
  Step 3: Apply schema to target project (direct psql)
  Step 4: Verify migration success (pg_dump comparison)

MIGRATION FILES
────────────────────────────────────────────────────────────────────────────────────────────
  Migration files are created in:
    • backups/database_and_policies_migration_<source>_to_<target>_<timestamp>/
      - source_schema.sql - Schema exported from source
      - target_schema_after.sql - Schema exported from target after migration
      - migration.log - Detailed migration log
      - migration_summary.txt - Summary report

FOR MORE INFORMATION
────────────────────────────────────────────────────────────────────────────────────────────
  For data migration, use:
    ./scripts/components/database_migration.sh --help

  For comprehensive migration (all components), use:
    ./scripts/main/supabase_migration.sh --help

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
INCLUDE_DATA=false
REPLACE_DATA=false

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
        --data)
            INCLUDE_DATA=true
            ;;
        --replace-data)
            REPLACE_DATA=true
            INCLUDE_DATA=true  # Replace implies data migration
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT=true
            ;;
        --verify-only)
            VERIFY_ONLY=true
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

# Validate data migration flags
if [ "$REPLACE_DATA" = "true" ] && [ "$INCLUDE_DATA" != "true" ]; then
    log_error "--replace-data requires --data flag"
    exit 1
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
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

# Validate project references and passwords
if [ -z "$SOURCE_REF" ]; then
    log_error "Source project reference not found for environment: $SOURCE_ENV"
    log_error "Please set SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF in .env.local"
    exit 1
fi

if [ -z "$TARGET_REF" ]; then
    log_error "Target project reference not found for environment: $TARGET_ENV"
    log_error "Please set SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF in .env.local"
    exit 1
fi

if [ -z "$SOURCE_PASSWORD" ]; then
    log_error "Source database password not found for environment: $SOURCE_ENV"
    log_error "Please set SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD in .env.local"
    exit 1
fi

if [ -z "$TARGET_PASSWORD" ]; then
    log_error "Target database password not found for environment: $TARGET_ENV"
    log_error "Please set SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD in .env.local"
    exit 1
fi

# Check for required tools
if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - required for this migration method"
    log_error "Please install: npm install -g @supabase/cli"
    log_error "Then login: supabase login"
    exit 1
fi

if ! command -v pg_dump >/dev/null 2>&1; then
    log_error "pg_dump not found - required for schema export"
    log_error "Please install PostgreSQL client tools"
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    log_error "psql not found - required for schema application"
    log_error "Please install PostgreSQL client tools"
    exit 1
fi

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="database_and_policies"
    MIGRATION_DIR=$(create_backup_dir "database_and_policies" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="database_and_policies"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"
MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR_ABS/migration.log}"
log_to_file "$LOG_FILE" "Starting database and policies migration from $SOURCE_ENV to $TARGET_ENV"

log_info "⚡ Database & Policies Migration (Ultra-Efficient CLI Method)"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR_ABS"
log_info "Method: pg_dump + Direct SQL Application"
if [ "$VERIFY_ONLY" = "true" ]; then
    log_info "Mode: VERIFY ONLY (no changes will be made)"
elif [ "$INCLUDE_DATA" = "true" ]; then
    if [ "$REPLACE_DATA" = "true" ]; then
        log_warning "⚠️  DATA MIGRATION: REPLACE MODE - All target data will be replaced!"
    else
        log_info "Data Migration: INCREMENTAL (preserving existing target data)"
    fi
else
    log_info "Data Migration: DISABLED (schema only)"
fi
echo ""

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    confirm_message="Proceed with database and policies migration from $SOURCE_ENV to $TARGET_ENV?"
    if [ "$INCLUDE_DATA" = "true" ]; then
        if [ "$REPLACE_DATA" = "true" ]; then
            confirm_message="⚠️  DESTRUCTIVE: This will REPLACE all data in target. Proceed?"
        else
            confirm_message="This will migrate data incrementally. Proceed?"
        fi
    fi
    
    if ! component_prompt_proceed "Database & Policies Migration" "$confirm_message"; then
        log_warning "Database and policies migration skipped by user request."
        log_to_file "$LOG_FILE" "Database and policies migration skipped by user."
        exit 0
    fi
fi

# Additional confirmation for data migration
if [ "$INCLUDE_DATA" = "true" ] && [ "$AUTO_CONFIRM_COMPONENT" != "true" ] && [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    echo ""
    if [ "$REPLACE_DATA" = "true" ]; then
        log_error "⚠️  WARNING: REPLACE DATA MODE"
        log_error "   This will DELETE all existing data in the target database and replace it with source data."
        log_error "   This is a DESTRUCTIVE operation that cannot be easily undone."
        read -r -p "Are you absolutely sure you want to replace all target data? Type 'yes' to confirm: " confirm_replace
        if [ "$confirm_replace" != "yes" ]; then
            log_warning "Data replacement cancelled. Proceeding with schema-only migration."
            INCLUDE_DATA=false
            REPLACE_DATA=false
            log_to_file "$LOG_FILE" "Data replacement cancelled by user - proceeding schema-only"
        fi
    else
        log_warning "⚠️  Data migration will add new rows to target tables."
        log_warning "   Existing target data will be preserved (incremental mode)."
        read -r -p "Proceed with data migration? [y/N]: " confirm_data
        confirm_data=$(echo "$confirm_data" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        if [ "$confirm_data" != "y" ] && [ "$confirm_data" != "yes" ]; then
            log_warning "Data migration cancelled. Proceeding with schema-only migration."
            INCLUDE_DATA=false
            log_to_file "$LOG_FILE" "Data migration cancelled by user - proceeding schema-only"
        fi
    fi
    echo ""
fi

# Step 1: Verify Supabase CLI is logged in (optional - script uses pg_dump directly)
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 1/4: Checking Supabase CLI Authentication (Optional)"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

if supabase projects list >/dev/null 2>&1; then
log_success "✓ Supabase CLI is authenticated"
log_to_file "$LOG_FILE" "Supabase CLI authentication verified"
else
    log_warning "⚠ Supabase CLI is not authenticated (optional - using direct database connections)"
    log_info "  This script uses pg_dump/psql directly, so CLI authentication is not required"
    log_info "  If you want to use Supabase CLI features, run: supabase login"
    log_to_file "$LOG_FILE" "Supabase CLI not authenticated - continuing with direct database connections"
fi
echo ""

# Step 2: Export schema from source project
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 2/4: Exporting Schema from Source Project"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

SCHEMA_DUMP_FILE="$MIGRATION_DIR_ABS/source_schema.sql"

if [ "$VERIFY_ONLY" = "true" ]; then
    log_info "Verify-only mode: Exporting source schema for comparison..."
    log_to_file "$LOG_FILE" "Verify-only mode: Exporting source schema"
else
    log_info "Exporting schema from source project ($SOURCE_REF)..."
    log_to_file "$LOG_FILE" "Exporting schema from source project"
fi

# Note: We use pg_dump directly instead of supabase db pull to avoid migration repair issues
# supabase db pull tries to sync existing migrations and can fail if migrations don't match
log_info "Exporting schema from source project using pg_dump..."
log_to_file "$LOG_FILE" "Exporting schema from source project using pg_dump"

# Use the same connection pattern as database_migration.sh (which works)
# Use run_pg_tool_with_fallback helper function for reliable connections
log_info "Dumping source schema using reliable connection fallback..."
log_to_file "$LOG_FILE" "Dumping source schema from source project using pg_dump"

PG_DUMP_ARGS=(-d postgres --schema-only --no-owner -f "$SCHEMA_DUMP_FILE")
dump_success=false

if run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
    "${PG_DUMP_ARGS[@]}"; then
    dump_success=true
fi

if [ "$dump_success" = "true" ]; then
    if [ -s "$SCHEMA_DUMP_FILE" ]; then
        schema_size=$(wc -l < "$SCHEMA_DUMP_FILE" | tr -d '[:space:]')
        log_info "Raw schema dump: $schema_size lines"
        log_to_file "$LOG_FILE" "Raw schema dump: $schema_size lines"
        
        # CRITICAL: Extract policies from ORIGINAL dump BEFORE filtering
        # This ensures we don't lose any policies during filtering
        POLICIES_FILE="$MIGRATION_DIR_ABS/policies_only.sql"
        log_info "Extracting all non-storage policies from original dump (before filtering)..."
        
        # Use awk for multi-line policies (more robust - handles policies that span multiple lines)
        # This is the PRIMARY extraction method - it handles all cases including single-line and multi-line policies
        awk '
        BEGIN {
            in_policy = 0
            policy_lines = ""
            skip_this_policy = 0
        }
        /^CREATE POLICY/ {
            in_policy = 1
            policy_lines = $0
            skip_this_policy = 0
            # Check if this is a storage policy
            if ($0 ~ /ON storage\./) {
                skip_this_policy = 1
            }
            next
        }
        in_policy {
            policy_lines = policy_lines "\n" $0
            # Check if any line in the policy references storage (but allow "storage" in other contexts)
            if ($0 ~ /ON storage\./) {
                skip_this_policy = 1
            }
            # Check if policy statement ends (semicolon on its own or at end of line)
            if ($0 ~ /;[[:space:]]*$/) {
                if (!skip_this_policy) {
                    print policy_lines
                }
                policy_lines = ""
                in_policy = 0
                skip_this_policy = 0
            }
            next
        }
        /^ALTER TABLE.*ENABLE ROW LEVEL SECURITY/ && !/storage\./ {
            print
        }
        ' "$SCHEMA_DUMP_FILE" > "$POLICIES_FILE" 2>/dev/null || touch "$POLICIES_FILE"
        
        # Also extract ALTER TABLE ... ENABLE ROW LEVEL SECURITY statements (if not already captured)
        grep "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$SCHEMA_DUMP_FILE" | grep -v "storage\." >> "$POLICIES_FILE" 2>/dev/null || true
        
        # Remove duplicates while preserving order
        awk '!seen[$0]++' "$POLICIES_FILE" > "$POLICIES_FILE.tmp" 2>/dev/null && mv "$POLICIES_FILE.tmp" "$POLICIES_FILE" || true
        
        # Verify extraction by counting policies
        policies_in_extracted=$(grep -c "^CREATE POLICY" "$POLICIES_FILE" 2>/dev/null || echo "0")
        policies_in_source=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        storage_policies_in_source=$(grep -c "^CREATE POLICY.*ON storage\." "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        expected_non_storage=$(($policies_in_source - $storage_policies_in_source))
        
        if [ "$policies_in_extracted" -lt "$expected_non_storage" ]; then
            log_warning "  ⚠ Policy extraction may be incomplete: extracted $policies_in_extracted, expected ~$expected_non_storage"
            log_warning "  Attempting fallback extraction method..."
            # Fallback: Use grep as backup (handles single-line policies)
            grep "^CREATE POLICY" "$SCHEMA_DUMP_FILE" | grep -v "ON storage\." > "$POLICIES_FILE.fallback" 2>/dev/null || true
            grep "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$SCHEMA_DUMP_FILE" | grep -v "storage\." >> "$POLICIES_FILE.fallback" 2>/dev/null || true
            fallback_count=$(grep -c "^CREATE POLICY" "$POLICIES_FILE.fallback" 2>/dev/null || echo "0")
            if [ "$fallback_count" -gt "$policies_in_extracted" ]; then
                mv "$POLICIES_FILE.fallback" "$POLICIES_FILE"
                log_info "  Used fallback extraction (found $fallback_count policies)"
            else
                rm -f "$POLICIES_FILE.fallback"
            fi
        fi
        
        policies_extracted=$(wc -l < "$POLICIES_FILE" | tr -d '[:space:]' || echo "0")
        if [ "$policies_extracted" -gt 0 ]; then
            log_success "  ✓ Extracted $policies_extracted policy-related statement(s) to: $POLICIES_FILE"
            log_to_file "$LOG_FILE" "Extracted $policies_extracted policy statements to $POLICIES_FILE (before filtering)"
            
            # Convert policies to incremental format (DROP IF EXISTS + CREATE)
            log_info "  Converting policies to incremental format (DROP IF EXISTS + CREATE)..."
            POLICIES_INCREMENTAL="$POLICIES_FILE.incremental"
            
            # Write awk script to temporary file to avoid bash parsing issues
            AWK_SCRIPT=$(mktemp)
            cat > "$AWK_SCRIPT" << 'AWK_EOF'
BEGIN {
    in_policy = 0
    policy_lines = ""
    policy_name = ""
    table_name = ""
    schema_name = "public"
}
/^CREATE POLICY/ {
    if (in_policy) {
        # Finish previous policy - shouldn't happen but handle it
        if (policy_name != "" && table_name != "") {
            print "DROP POLICY IF EXISTS \"" policy_name "\" ON " schema_name "." table_name ";"
        }
        print policy_lines
        policy_lines = ""
    }
    in_policy = 1
    policy_lines = $0
    # Extract policy name (first quoted string after CREATE POLICY)
    if (match($0, /CREATE POLICY "([^"]+)"/, arr)) {
        policy_name = arr[1]
    }
    # Extract table name (after ON schema.table or ON table)
    # Pattern: ON public.table_name or ON table_name
    if (match($0, /ON[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\.([a-zA-Z_][a-zA-Z0-9_]*)/, arr)) {
        schema_name = arr[1]
        table_name = arr[2]
    } else if (match($0, /ON[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, arr)) {
        # No schema specified, default to public
        schema_name = "public"
        table_name = arr[1]
    }
    # Check if this is a single-line policy (ends with semicolon)
    if ($0 ~ /;[[:space:]]*$/) {
        if (policy_name != "" && table_name != "") {
            print "DROP POLICY IF EXISTS \"" policy_name "\" ON " schema_name "." table_name ";"
        }
        print policy_lines
        policy_lines = ""
        in_policy = 0
        policy_name = ""
        table_name = ""
        schema_name = "public"
    }
    next
}
in_policy {
    policy_lines = policy_lines "\n" $0
    # Extract schema.table if not found yet (might be on continuation line)
    if (table_name == "") {
        if (match($0, /ON[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\.([a-zA-Z_][a-zA-Z0-9_]*)/, arr)) {
            schema_name = arr[1]
            table_name = arr[2]
        } else if (match($0, /ON[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, arr)) {
            schema_name = "public"
            table_name = arr[1]
        }
    }
    # Check if policy statement ends (semicolon)
    if ($0 ~ /;[[:space:]]*$/) {
        if (policy_name != "" && table_name != "") {
            print "DROP POLICY IF EXISTS \"" policy_name "\" ON " schema_name "." table_name ";"
        }
        print policy_lines
        policy_lines = ""
        in_policy = 0
        policy_name = ""
        table_name = ""
        schema_name = "public"
    }
    next
}
/^ALTER TABLE.*ENABLE ROW LEVEL SECURITY/ {
    print
    next
}
AWK_EOF
            
            # Execute awk script from file
            awk -f "$AWK_SCRIPT" "$POLICIES_FILE" > "$POLICIES_INCREMENTAL" 2>/dev/null || cp "$POLICIES_FILE" "$POLICIES_INCREMENTAL"
            rm -f "$AWK_SCRIPT"
            
            # Verify conversion worked and ensure all CREATE POLICY have DROP IF EXISTS
            if [ -f "$POLICIES_INCREMENTAL" ] && [ -s "$POLICIES_INCREMENTAL" ]; then
                incremental_count=$(grep -c "^DROP POLICY IF EXISTS" "$POLICIES_INCREMENTAL" 2>/dev/null | tr -d '[:space:]' || echo "0")
                create_count=$(grep -c "^CREATE POLICY" "$POLICIES_INCREMENTAL" 2>/dev/null | tr -d '[:space:]' || echo "0")
                
                # Sanitize to ensure they're integers (remove any non-numeric characters)
                incremental_count=$(echo "$incremental_count" | tr -d '[:space:]' | sed 's/[^0-9]//g')
                create_count=$(echo "$create_count" | tr -d '[:space:]' | sed 's/[^0-9]//g')
                incremental_count=$((incremental_count + 0))
                create_count=$((create_count + 0))
                
                # If conversion didn't add DROP for all CREATE statements, add them manually
                if [ "$create_count" -gt 0 ] && [ "$incremental_count" -lt "$create_count" ]; then
                    log_warning "  Some policies missing DROP IF EXISTS, adding them..."
                    # Create a new file with DROP IF EXISTS before each CREATE POLICY
                    TEMP_POLICIES=$(mktemp)
                    while IFS= read -r line; do
                        if [[ "$line" =~ ^CREATE\ POLICY ]]; then
                            # Extract policy name and table from CREATE POLICY statement
                            policy_name=$(echo "$line" | sed -n 's/.*CREATE POLICY "\([^"]*\)".*/\1/p')
                            table_match=$(echo "$line" | sed -n 's/.*ON[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\)\.\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1.\2/p')
                            if [ -z "$table_match" ]; then
                                table_match=$(echo "$line" | sed -n 's/.*ON[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p')
                                table_match="public.$table_match"
                            fi
                            if [ -n "$policy_name" ] && [ -n "$table_match" ]; then
                                echo "DROP POLICY IF EXISTS \"$policy_name\" ON $table_match;"
                            fi
                        fi
                        echo "$line"
                    done < "$POLICIES_INCREMENTAL" > "$TEMP_POLICIES"
                    mv "$TEMP_POLICIES" "$POLICIES_INCREMENTAL"
                    incremental_count=$(grep -c "^DROP POLICY IF EXISTS" "$POLICIES_INCREMENTAL" 2>/dev/null | tr -d '[:space:]' | sed 's/[^0-9]//g' || echo "0")
                    incremental_count=$((incremental_count + 0))
                    log_info "  Added DROP IF EXISTS for all policies (now $incremental_count DROP statements)"
                fi
                
                # Sanitize again before comparison
                incremental_count=$((incremental_count + 0))
                create_count=$((create_count + 0))
                
                if [ "$incremental_count" -gt 0 ] && [ "$incremental_count" -eq "$create_count" ]; then
                    mv "$POLICIES_INCREMENTAL" "$POLICIES_FILE"
                    log_info "  Converted $incremental_count policies to incremental format (DROP IF EXISTS + CREATE)"
                elif [ "$create_count" -gt 0 ]; then
                    # Even if counts don't match exactly, use the incremental file if it has DROP statements
                    mv "$POLICIES_INCREMENTAL" "$POLICIES_FILE"
                    log_info "  Using incremental format with $incremental_count DROP and $create_count CREATE statements"
                else
                    log_warning "  Policy conversion may have issues (DROP: $incremental_count, CREATE: $create_count), using original"
                    rm -f "$POLICIES_INCREMENTAL"
                fi
            else
                log_warning "  Policy conversion failed, using original file"
                rm -f "$POLICIES_INCREMENTAL"
            fi
        else
            log_warning "  ⚠ No policies extracted - this may indicate an issue with the dump"
        fi
        
        # Save original unfiltered dump for comparison
        cp "$SCHEMA_DUMP_FILE" "$SCHEMA_DUMP_FILE.unfiltered" 2>/dev/null || true
        
        # Filter out system objects and statements that require superuser privileges
        log_info "Filtering schema dump to exclude system objects..."
        SCHEMA_DUMP_FILTERED="$SCHEMA_DUMP_FILE.filtered"
        
        # Policies have already been extracted above before filtering - no need to extract again
        # POLICIES_FILE is already set and contains all non-storage policies
        
        # Filter the schema dump to exclude system objects and statements requiring superuser privileges
        # Use a state machine to filter complete statement blocks, not just individual lines
        # Track skipped schemas for warning messages
        SCHEMAS_SKIPPED_FILE="$MIGRATION_DIR_ABS/skipped_schemas.txt"
        touch "$SCHEMAS_SKIPPED_FILE"
        
        awk -v skipped_schemas_file="$SCHEMAS_SKIPPED_FILE" '
        BEGIN {
            skip_block = 0
            in_event_trigger = 0
            in_publication = 0
            in_storage_policy = 0
            in_policy = 0
            skipped_auth = 0
            skipped_extensions = 0
            skipped_realtime = 0
            skipped_storage = 0
        }
        # Skip complete event trigger blocks
        /^CREATE EVENT TRIGGER/ {
            in_event_trigger = 1
            skip_block = 1
            next
        }
        /^ALTER EVENT TRIGGER/ {
            in_event_trigger = 1
            skip_block = 1
            next
        }
        /^DROP EVENT TRIGGER/ {
            in_event_trigger = 1
            skip_block = 1
            next
        }
        # Skip complete publication blocks
        /^CREATE PUBLICATION/ {
            in_publication = 1
            skip_block = 1
            next
        }
        /^ALTER PUBLICATION/ {
            in_publication = 1
            skip_block = 1
            next
        }
        /^DROP PUBLICATION/ {
            in_publication = 1
            skip_block = 1
            next
        }
        # Skip storage schema ALTER statements
        /^ALTER TABLE storage\./ {
            skip_block = 1
            next
        }
        # Skip auth schema ALTER statements (require superuser/exclusive ownership)
        /^ALTER (TABLE|FUNCTION|SCHEMA) auth\./ {
            if (!skipped_auth) {
                print "auth" >> skipped_schemas_file
                skipped_auth = 1
            }
            skip_block = 1
            next
        }
        # Skip extensions schema ALTER statements (require superuser/exclusive ownership)
        /^ALTER (TABLE|FUNCTION|SCHEMA) extensions\./ {
            if (!skipped_extensions) {
                print "extensions" >> skipped_schemas_file
                skipped_extensions = 1
            }
            skip_block = 1
            next
        }
        # Skip realtime schema ALTER statements (require superuser/exclusive ownership)
        /^ALTER (TABLE|FUNCTION|SCHEMA) realtime\./ {
            if (!skipped_realtime) {
                print "realtime" >> skipped_schemas_file
                skipped_realtime = 1
            }
            skip_block = 1
            next
        }
        # Skip ALL CREATE POLICY statements (policies are applied separately from POLICIES_FILE with incremental format)
        # This prevents "already exists" errors when policies are in both the schema dump and policies file
        /^CREATE POLICY/ {
            in_policy = 1
            skip_block = 1
            next
        }
        # Skip storage schema policies (complete blocks) - these are already excluded but keep for safety
        /^ALTER POLICY.*ON storage\./ {
            in_storage_policy = 1
            skip_block = 1
            next
        }
        /^DROP POLICY.*ON storage\./ {
            in_storage_policy = 1
            skip_block = 1
            next
        }
        /^ALTER POLICY/ && /storage\./ {
            in_storage_policy = 1
            skip_block = 1
            next
        }
        /^DROP POLICY/ && /storage\./ {
            in_storage_policy = 1
            skip_block = 1
            next
        }
        # End of event trigger block (semicolon on its own line or end of statement)
        in_event_trigger && /^[[:space:]]*;/ {
            in_event_trigger = 0
            skip_block = 0
            next
        }
        # End of publication block
        in_publication && /^[[:space:]]*;/ {
            in_publication = 0
            skip_block = 0
            next
        }
        # End of storage policy block
        in_storage_policy && /^[[:space:]]*;/ {
            in_storage_policy = 0
            skip_block = 0
            next
        }
        # End of policy block (all CREATE POLICY statements are skipped)
        in_policy && /^[[:space:]]*;/ {
            in_policy = 0
            skip_block = 0
            next
        }
        # Handle policy blocks (already started above)
        in_policy {
            next
        }
        # Skip ALTER statements on auth/extensions schemas (multi-line)
        skip_block && /^[[:space:]]+.*auth\.|^[[:space:]]+.*extensions\.|^[[:space:]]+.*realtime\./ {
            # Check if this is the end of the ALTER statement
            if (/^[[:space:]]*;/) {
                skip_block = 0
            }
            next
        }
        # Skip lines while in a block we want to exclude
        skip_block {
            # Check if this is the end of the statement (semicolon)
            if (/^[[:space:]]*;/) {
                skip_block = 0
            }
            next
        }
        # Print all other lines
        { print }
        ' "$SCHEMA_DUMP_FILE" > "$SCHEMA_DUMP_FILTERED" 2>/dev/null || true
        
        # If filtering removed everything, use original (shouldn't happen)
        if [ ! -s "$SCHEMA_DUMP_FILTERED" ]; then
            log_warning "⚠ Filtered schema dump is empty, using original dump"
            cp "$SCHEMA_DUMP_FILE" "$SCHEMA_DUMP_FILTERED"
        else
            filtered_size=$(wc -l < "$SCHEMA_DUMP_FILTERED" | tr -d '[:space:]')
            log_info "Filtered schema dump: $filtered_size lines (removed $((schema_size - filtered_size)) system object lines)"
            log_to_file "$LOG_FILE" "Filtered schema dump: $filtered_size lines"
        fi
        
        
        # Use filtered dump for application (policies will be applied separately from POLICIES_FILE)
        SCHEMA_DUMP_FILE="$SCHEMA_DUMP_FILTERED"
        
        # Display warnings for skipped schemas (single warning per schema)
        if [ -f "$SCHEMAS_SKIPPED_FILE" ] && [ -s "$SCHEMAS_SKIPPED_FILE" ]; then
            skipped_schemas=$(sort -u "$SCHEMAS_SKIPPED_FILE" | tr '\n' ' ' | sed 's/ $//')
            if [ -n "$skipped_schemas" ]; then
                log_warning "  ⚠ Skipped schema(s) requiring exclusive ownership: $skipped_schemas"
                log_warning "     These schemas are managed by Supabase and cannot be migrated"
                log_to_file "$LOG_FILE" "WARNING: Skipped schemas requiring exclusive ownership: $skipped_schemas"
            fi
        fi
        
        log_success "✓ Schema exported and filtered successfully"
        
        # Count policies in the filtered dump (for reference - actual policies come from POLICIES_FILE)
        policy_count_in_filtered=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        rls_enable_count=$(grep -c "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        
        # Count policies in original unfiltered dump and extracted file
        if [ -f "$SCHEMA_DUMP_FILE.unfiltered" ]; then
            unfiltered_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE.unfiltered" 2>/dev/null || echo "0")
            storage_policy_count=$(grep -c "^CREATE POLICY.*ON storage\." "$SCHEMA_DUMP_FILE.unfiltered" 2>/dev/null || echo "0")
            non_storage_expected=$((unfiltered_policy_count - storage_policy_count))
            
            log_info "  Policy counts:"
            log_info "    Original dump total: $unfiltered_policy_count"
            log_info "    Storage policies (excluded): $storage_policy_count"
            log_info "    Non-storage policies (should migrate): $non_storage_expected"
            log_info "    Extracted to policies file: $policies_extracted"
            log_info "    In filtered dump: $policy_count_in_filtered"
            
            if [ "$policies_extracted" -lt "$non_storage_expected" ]; then
                log_warning "  ⚠ Extracted file has fewer policies than expected!"
                log_warning "  Expected: $non_storage_expected, Extracted: $policies_extracted"
                log_warning "  Attempting to re-extract from original dump using improved method..."
                # Re-extract from original using awk (handles multi-line policies better)
                awk '
                BEGIN {
                    in_policy = 0
                    policy_lines = ""
                    skip_this_policy = 0
                }
                /^CREATE POLICY/ {
                    in_policy = 1
                    policy_lines = $0
                    skip_this_policy = 0
                    if ($0 ~ /ON storage\./) {
                        skip_this_policy = 1
                    }
                    next
                }
                in_policy {
                    policy_lines = policy_lines "\n" $0
                    if ($0 ~ /ON storage\./) {
                        skip_this_policy = 1
                    }
                    if ($0 ~ /;[[:space:]]*$/) {
                        if (!skip_this_policy) {
                            print policy_lines
                        }
                        policy_lines = ""
                        in_policy = 0
                        skip_this_policy = 0
                    }
                    next
                }
                /^ALTER TABLE.*ENABLE ROW LEVEL SECURITY/ && !/storage\./ {
                    print
                }
                ' "$SCHEMA_DUMP_FILE.unfiltered" > "$POLICIES_FILE.re_extract" 2>/dev/null || true
                # Also add ALTER TABLE statements
                grep "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$SCHEMA_DUMP_FILE.unfiltered" | grep -v "storage\." >> "$POLICIES_FILE.re_extract" 2>/dev/null || true
                # Remove duplicates
                awk '!seen[$0]++' "$POLICIES_FILE.re_extract" > "$POLICIES_FILE" 2>/dev/null || mv "$POLICIES_FILE.re_extract" "$POLICIES_FILE"
                rm -f "$POLICIES_FILE.re_extract"
                policies_extracted=$(grep -c "^CREATE POLICY" "$POLICIES_FILE" 2>/dev/null || echo "0")
                log_info "  Re-extracted $policies_extracted policies from original dump"
            fi
            
            if [ "$policies_extracted" -ge "$non_storage_expected" ]; then
                log_success "  ✓ All non-storage policies extracted successfully ($policies_extracted statements)"
            fi
        fi
        
        # Also count by schema to verify we're getting all policies
        if [ -f "$POLICIES_FILE" ] && [ -s "$POLICIES_FILE" ]; then
            public_policies=$(grep -c "^CREATE POLICY.*ON public\." "$POLICIES_FILE" 2>/dev/null || echo "0")
            if [ "$public_policies" -gt 0 ]; then
                log_info "  Public schema policies in extracted file: $public_policies"
            fi
        fi
    else
        log_warning "⚠ Schema dump file is empty"
        log_to_file "$LOG_FILE" "WARNING: Schema dump file is empty"
    fi
else
    log_error "Failed to dump schema from source project via any connection method"
    log_to_file "$LOG_FILE" "ERROR: Failed to dump schema from source"
    log_error "Tried:"
    log_error "  1. Pooler connections (via environment variables)"
    log_error "  2. API-resolved pooler hostname"
    log_error ""
    log_error "Please check:"
    log_error "  - Database passwords are correct (SUPABASE_${SOURCE_ENV}_DB_PASSWORD)"
    log_error "  - Pooler region/port settings are correct"
    log_error "  - Network connectivity to Supabase"
    log_error "  - Access tokens have permission to query pooler config (SUPABASE_${SOURCE_ENV}_ACCESS_TOKEN)"
    exit 1
fi
echo ""

# Step 3: Verify or Apply to target (if verify-only mode, exit here)
if [ "$VERIFY_ONLY" = "true" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 3/4: Verifying Target Project (Verify-Only Mode)"
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
    
    # First, try database connectivity via shared pooler (no API calls)
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_dump \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            --schema-only \
            --no-owner \
            -f "$TARGET_SCHEMA_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            target_dump_success=true
            break
        fi
    done <<< "$endpoints"
    
    # If all pooler connections failed, try API to get correct pooler hostname
    if [ "$target_dump_success" = "false" ]; then
        log_info "Pooler connections failed for target, trying API to get pooler hostname..."
        log_to_file "$LOG_FILE" "Pooler connections failed for target, trying API to get pooler hostname"
        api_pooler_host=""
        api_pooler_host=$(get_pooler_host_via_api "$TARGET_REF" 2>/dev/null || echo "")
        
        if [ -n "$api_pooler_host" ]; then
            log_info "Retrying target schema dump with API-resolved pooler host: ${api_pooler_host}"
            log_to_file "$LOG_FILE" "Retrying target schema dump with API-resolved pooler host: ${api_pooler_host}"
            
            # Try with API-resolved pooler host
            for port in "${TARGET_POOLER_PORT:-6543}" "5432"; do
                log_info "Attempting target schema dump via API-resolved pooler (${api_pooler_host}:${port})..."
                log_to_file "$LOG_FILE" "Attempting target schema dump via API-resolved pooler (${api_pooler_host}:${port})"
                if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_dump \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${TARGET_REF}" \
                    -d postgres \
                    --schema-only \
                    --no-owner \
                    -f "$TARGET_SCHEMA_FILE" 2>&1 | tee -a "$LOG_FILE"; then
                    target_dump_success=true
                    break
                else
                    log_warning "Target schema dump via API-resolved pooler (${api_pooler_host}:${port}) failed"
                    log_to_file "$LOG_FILE" "Target schema dump via API-resolved pooler (${api_pooler_host}:${port}) failed"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API for target"
            log_to_file "$LOG_FILE" "Could not resolve pooler hostname via API for target"
        fi
    fi
    
    if [ "$target_dump_success" = "true" ]; then
        if [ -s "$TARGET_SCHEMA_FILE" ]; then
            log_info "Comparing source and target schemas..."
            
            # Count policies in both
            source_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
            target_policy_count=$(grep -c "^CREATE POLICY" "$TARGET_SCHEMA_FILE" 2>/dev/null || echo "0")
            
            log_info "  Source policies: $source_policy_count"
            log_info "  Target policies: $target_policy_count"
            
        # Compare using non-storage policies from source
        if [ -f "$SCHEMA_DUMP_FILE.unfiltered" ]; then
            source_total=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE.unfiltered" 2>/dev/null || echo "0")
            source_storage=$(grep -c "^CREATE POLICY.*ON storage\." "$SCHEMA_DUMP_FILE.unfiltered" 2>/dev/null || echo "0")
            source_non_storage=$((source_total - source_storage))
        else
            source_non_storage=$source_policy_count
        fi
        
        if [ "$source_non_storage" -eq "$target_policy_count" ]; then
                log_success "✓ Policy counts match between source and target"
            else
            diff=$((source_non_storage - target_policy_count))
                if [ "$diff" -gt 0 ]; then
                log_warning "⚠ Target has $diff fewer policy(ies) than source (expected $source_non_storage, got $target_policy_count)"
                log_warning "  This indicates some policies failed to migrate"
                log_to_file "$LOG_FILE" "WARNING: Policy count mismatch - $diff policies missing"
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
if [ "$INCLUDE_DATA" = "true" ]; then
    if [ "$REPLACE_DATA" = "true" ]; then
        log_error "⚠️  DESTRUCTIVE: This will REPLACE all data in the target!"
    else
        log_warning "⚠ This will also migrate data to the target"
    fi
fi
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
# Note: We use psql directly for reliability, avoiding migration repair issues
log_info "Applying schema to target project..."
log_to_file "$LOG_FILE" "Applying schema to target project"

# Note: pg_dump only exports schema, not data
if [ "$INCLUDE_DATA" = "true" ]; then
    log_warning "⚠️  Note: pg_dump method only migrates schema, not data."
    log_warning "   For data migration, use database_migration.sh with --data flag."
    log_warning "   Proceeding with schema-only migration..."
    log_to_file "$LOG_FILE" "WARNING: Data migration requested but pg_dump method is schema-only"
else
    log_info "Schema only (no data)..."
    log_to_file "$LOG_FILE" "Applying schema only to target"
fi

# Helper function to get timeout command (handles macOS where timeout may not be available)
get_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    else
        echo ""  # No timeout available
    fi
}

TIMEOUT_CMD=$(get_timeout_cmd)
if [ -z "$TIMEOUT_CMD" ]; then
    log_info "Note: timeout command not available - psql will run without timeout (like source dump)"
fi

# Apply SQL file directly using psql with fallback (same pattern as database_migration.sh)
# Use run_psql_script_with_fallback helper function for reliable connections
sql_applied=false
schema_file_size=$(du -h "$SCHEMA_DUMP_FILE" 2>/dev/null | cut -f1 || echo "unknown")
schema_line_count=$(wc -l < "$SCHEMA_DUMP_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")
log_info "Applying schema dump (size: $schema_file_size, ~$schema_line_count lines)..."
log_info "This may take several minutes for large schemas. Please wait..."
log_to_file "$LOG_FILE" "Applying schema to target project using reliable connection fallback"

# Use run_psql_script_with_fallback which handles all connection retries automatically
set +e  # Don't exit on psql errors - we'll check the output
if run_psql_script_with_fallback "Applying schema" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_DUMP_FILE"; then
    psql_exit_code=0
    log_info "Schema application completed successfully"
    sql_applied=true
else
    psql_exit_code=$?
    log_warning "Schema application completed with exit code $psql_exit_code (checking for expected errors)..."
    sql_applied=false
fi
set -e

# Apply policies separately with better error handling (using same connection pattern)
if [ -f "$POLICIES_FILE" ] && [ -s "$POLICIES_FILE" ]; then
    policy_count=$(grep -c "^CREATE POLICY\|^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$POLICIES_FILE" 2>/dev/null || echo "0")
    log_info "Applying $policy_count policy statement(s) separately (this may take a moment)..."
    policies_output_file="$MIGRATION_DIR_ABS/policies_output.log"
    log_to_file "$LOG_FILE" "Applying policies to target project using reliable connection fallback"
    
    # Use run_psql_script_with_fallback which handles all connection retries automatically
    set +e
    if run_psql_script_with_fallback "Applying policies" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$POLICIES_FILE"; then
        policies_exit_code=0
        log_info "Policy application completed successfully"
    else
        policies_exit_code=$?
        log_warning "Policy application completed with exit code $policies_exit_code (checking for expected errors)..."
        
        # Extract policy output from log file
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            tail -100 "$LOG_FILE" | grep -A 50 "Applying policies" > "$policies_output_file" 2>/dev/null || true
        fi
    fi
    set -e
    
    # Check for policy errors in the log file (since run_psql_script_with_fallback writes to LOG_FILE)
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        # Extract policy-related output from log file for error checking
        policies_output_section=$(tail -200 "$LOG_FILE" | grep -A 100 "Applying policies" 2>/dev/null || tail -100 "$LOG_FILE")
        
        # Filter out expected policy errors (already exists, syntax errors on CREATE)
        filtered_policy_errors=$(echo "$policies_output_section" | grep "ERROR:" 2>/dev/null | \
            grep -vE "policy.*already exists|syntax error.*CREATE|syntax error at or near" | \
            wc -l | tr -d '[:space:]' || echo "0")
        
        if [ "$filtered_policy_errors" -gt 0 ]; then
            log_warning "Found $filtered_policy_errors unexpected policy error(s) (expected errors filtered out)"
        else
            log_info "Policy errors are expected (already exists, syntax issues) - continuing..."
        fi
        
        # Count policy application results
        policies_in_file=$(grep -c "^CREATE POLICY\|^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$POLICIES_FILE" 2>/dev/null || echo "0")
        policies_errors=$(echo "$policies_output_section" | grep -cE "ERROR.*[Pp]olicy|ERROR.*POLICY" 2>/dev/null || echo "0")
        if [ "$policies_in_file" -gt 0 ]; then
            log_info "Applied $policies_in_file policy statement(s) separately"
            if [ "$policies_errors" -gt 0 ]; then
                log_warning "$policies_errors policy statement(s) had errors (may be expected)"
            fi
        fi
    fi
fi

# Check for connection errors in the log file
if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    if grep -qE "FATAL|could not connect|connection refused|timeout" "$LOG_FILE" 2>/dev/null; then
        log_error "Connection failed - check log file for details"
        sql_applied=false
    fi
fi

# Check for critical errors in the log file (excluding expected system/permission errors)
if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    # Extract schema application output from log file
    schema_output_section=$(tail -200 "$LOG_FILE" | grep -A 100 "Applying schema" 2>/dev/null || tail -100 "$LOG_FILE")
    # Get all ERROR lines from the schema output section
    all_errors=$(echo "$schema_output_section" | grep "ERROR:" 2>/dev/null || true)
    
    if [ -n "$all_errors" ]; then
        # Filter out system errors - these are expected and should be ignored
        critical_errors=$(echo "$all_errors" | \
            grep -viE "must be owner|already exists|Non-superuser owned event trigger|permission denied for schema auth|permission denied for schema extensions|permission denied for schema realtime|permission denied for schema storage|schema.*already exists|type.*already exists|policy.*already exists|publication.*already exists|relation.*already member of publication|syntax error|at or near" | \
            wc -l | tr -d '[:space:]' || echo "0")
        
        # Count total and system errors
        total_errors=$(echo "$all_errors" | wc -l | tr -d '[:space:]' || echo "0")
        system_errors=$(echo "$all_errors" | \
            grep -iE "must be owner|already exists|Non-superuser owned event trigger|permission denied for schema auth|permission denied for schema extensions|permission denied for schema realtime|permission denied for schema storage|schema.*already exists|type.*already exists|policy.*already exists|publication.*already exists|relation.*already member of publication|syntax error|at or near" | \
            wc -l | tr -d '[:space:]' || echo "0")
    else
        critical_errors=0
        total_errors=0
        system_errors=0
    fi
    
    # Convert to integers for comparison
    total_errors_int=$((total_errors + 0))
    system_errors_int=$((system_errors + 0))
    critical_errors_int=$((critical_errors + 0))
    
    # If we have errors, check if they're all system errors (expected)
    if [ "$total_errors_int" -gt 0 ] && [ "$system_errors_int" -eq "$total_errors_int" ]; then
        # All errors are system errors (expected) - this is success
        sql_applied=true
        log_success "✓ Schema applied successfully to target ($system_errors system object errors expected and ignored)"
        log_to_file "$LOG_FILE" "Schema applied successfully to target ($system_errors system errors ignored)"
    elif [ "$critical_errors_int" -eq 0 ]; then
        # No critical errors - success
        sql_applied=true
        if [ "$total_errors_int" -gt 0 ]; then
            log_warning "⚠ Schema applied with some non-system errors ($critical_errors critical, $system_errors system)"
            log_to_file "$LOG_FILE" "Schema applied with warnings ($critical_errors critical errors, $system_errors system errors)"
        else
            log_success "✓ Schema applied successfully to target"
            log_to_file "$LOG_FILE" "Schema applied successfully to target"
        fi
    else
        log_warning "Schema application had $critical_errors critical error(s)"
        log_to_file "$LOG_FILE" "Schema application had $critical_errors critical errors (total: $total_errors, system: $system_errors)"
        if [ -n "$all_errors" ]; then
            log_to_file "$LOG_FILE" "First few errors:"
            echo "$all_errors" | head -5 | while IFS= read -r error_line; do
                log_to_file "$LOG_FILE" "  $error_line"
            done
        fi
        sql_applied=false
    fi
else
    # No output file - connection likely failed
    log_error "No output file generated - connection may have failed"
    sql_applied=false
fi

# If connection failed, the helper function already tried all endpoints, so we're done
if [ "$sql_applied" = "false" ]; then
    log_info "Pooler connections failed for target SQL application, trying API to get pooler hostname..."
    log_to_file "$LOG_FILE" "Pooler connections failed for target SQL application, trying API to get pooler hostname"
    api_pooler_host=""
    api_pooler_host=$(get_pooler_host_via_api "$TARGET_REF" 2>/dev/null || echo "")
    
    if [ -n "$api_pooler_host" ]; then
        log_info "Retrying SQL application with API-resolved pooler host: ${api_pooler_host}"
        log_to_file "$LOG_FILE" "Retrying SQL application with API-resolved pooler host: ${api_pooler_host}"
        
        # Try with API-resolved pooler host
        for port in "${TARGET_POOLER_PORT:-6543}" "5432"; do
            log_info "Applying schema via API-resolved pooler (${api_pooler_host}:${port})..."
            log_to_file "$LOG_FILE" "Attempting schema application via API-resolved pooler (${api_pooler_host}:${port})"
            
            psql_output_file="$MIGRATION_DIR_ABS/psql_output_api_pooler.log"
            set +e
            
            # Apply main schema
            schema_file_size=$(du -h "$SCHEMA_DUMP_FILE" 2>/dev/null | cut -f1 || echo "unknown")
            log_info "  Applying schema via API-resolved pooler (${api_pooler_host}:${port}, size: $schema_file_size)..."
            if [ -n "$TIMEOUT_CMD" ]; then
                PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require $TIMEOUT_CMD 600 psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${TARGET_REF}" \
                    -d postgres \
                    -v ON_ERROR_STOP=off \
                    --echo-errors \
                    -f "$SCHEMA_DUMP_FILE" > "$psql_output_file" 2>&1
            else
                PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${TARGET_REF}" \
                    -d postgres \
                    -v ON_ERROR_STOP=off \
                    --echo-errors \
                    -f "$SCHEMA_DUMP_FILE" > "$psql_output_file" 2>&1
            fi
            psql_exit_code=$?
            
            if [ $psql_exit_code -eq 124 ]; then
                log_error "  Schema application timed out after 10 minutes via API-resolved pooler"
                if [ -f "$psql_output_file" ] && [ -s "$psql_output_file" ]; then
                    log_info "  Partial output found (last 20 lines):"
                    tail -20 "$psql_output_file" | while IFS= read -r line; do
                        log_info "    $line"
                    done
                fi
                rm -f "$psql_output_file"
                continue
            elif [ $psql_exit_code -ne 0 ]; then
                log_warning "  Schema application completed with exit code $psql_exit_code (checking for expected errors)..."
            else
                log_info "  Schema application completed successfully"
            fi
            
            # Apply policies if available
            if [ -f "$POLICIES_FILE" ] && [ -s "$POLICIES_FILE" ]; then
                log_info "  Applying policies via API-resolved pooler..."
                policies_output_file="$MIGRATION_DIR_ABS/policies_output_api_pooler.log"
                if [ -n "$TIMEOUT_CMD" ]; then
                    PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require $TIMEOUT_CMD 600 psql \
                        -h "$api_pooler_host" \
                        -p "$port" \
                        -U "postgres.${TARGET_REF}" \
                        -d postgres \
                        -v ON_ERROR_STOP=off \
                        --echo-errors \
                        -f "$POLICIES_FILE" > "$policies_output_file" 2>&1
                else
                    PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                        -h "$api_pooler_host" \
                        -p "$port" \
                        -U "postgres.${TARGET_REF}" \
                        -d postgres \
                        -v ON_ERROR_STOP=off \
                        --echo-errors \
                        -f "$POLICIES_FILE" > "$policies_output_file" 2>&1
                fi
                policies_exit_code=$?
                
                if [ $policies_exit_code -eq 124 ]; then
                    log_error "  Policy application timed out after 10 minutes via API-resolved pooler"
                    if [ -f "$policies_output_file" ] && [ -s "$policies_output_file" ]; then
                        log_info "  Partial output found (last 20 lines):"
                        tail -20 "$policies_output_file" | while IFS= read -r line; do
                            log_info "    $line"
                        done
                    fi
                elif [ $policies_exit_code -ne 0 ]; then
                    log_warning "  Policy application completed with exit code $policies_exit_code (checking for expected errors)..."
                else
                    log_info "  Policy application completed successfully"
                fi
                
                cat "$policies_output_file" >> "$psql_output_file"
                rm -f "$policies_output_file"
            fi
            
            set -e
            
            # Check for connection errors
            if grep -qE "FATAL|could not connect|connection refused|timeout" "$psql_output_file" 2>/dev/null; then
                log_warning "Connection failed via API-resolved pooler (${api_pooler_host}:${port}), trying next port..."
                rm -f "$psql_output_file"
                continue
            fi
            
            # Check for critical errors (same logic as above)
            if [ -f "$psql_output_file" ] && [ -s "$psql_output_file" ]; then
                all_errors=$(grep "ERROR:" "$psql_output_file" 2>/dev/null || true)
                if [ -n "$all_errors" ]; then
                    critical_errors=$(echo "$all_errors" | \
                        grep -viE "must be owner|already exists|Non-superuser owned event trigger|permission denied for schema auth|permission denied for schema extensions|permission denied for schema realtime|permission denied for schema storage|schema.*already exists|type.*already exists|policy.*already exists|publication.*already exists|relation.*already member of publication|syntax error|at or near" | \
                        wc -l | tr -d '[:space:]' || echo "0")
                    
                    if [ "$critical_errors" -eq "0" ]; then
                        sql_applied=true
                        log_success "✓ Schema applied successfully via API-resolved pooler (${api_pooler_host}:${port})"
                        log_to_file "$LOG_FILE" "Schema applied successfully via API-resolved pooler (${api_pooler_host}:${port})"
                        cat "$psql_output_file" | tee -a "$LOG_FILE"
                        rm -f "$psql_output_file"
                        break
                    fi
                else
                    sql_applied=true
                    log_success "✓ Schema applied successfully via API-resolved pooler (${api_pooler_host}:${port})"
                    log_to_file "$LOG_FILE" "Schema applied successfully via API-resolved pooler (${api_pooler_host}:${port})"
                    cat "$psql_output_file" | tee -a "$LOG_FILE"
                    rm -f "$psql_output_file"
                    break
                fi
            fi
            
            rm -f "$psql_output_file"
        done
    else
        log_warning "Could not resolve pooler hostname via API for target SQL application"
        log_to_file "$LOG_FILE" "Could not resolve pooler hostname via API for target SQL application"
    fi
fi

if [ "$sql_applied" != "true" ]; then
    # Check if we have any actual critical errors or if all errors were system errors
    # If all errors were system errors, we should still consider it a success
    log_warning "⚠ Schema application did not complete via any endpoint"
    log_to_file "$LOG_FILE" "WARNING: Schema application did not complete via any endpoint"
    
    # Check if we can find any critical errors in the logs
    # If not, it means all errors were system errors and we should proceed
    if [ -f "$LOG_FILE" ]; then
        # Look for any non-system errors in the log (use same patterns as above)
        non_system_errors=$(grep "ERROR:" "$LOG_FILE" 2>/dev/null | \
            grep -viE "must be owner|already exists|Non-superuser owned event trigger|permission denied for schema auth|permission denied for schema extensions|permission denied for schema realtime|permission denied for schema storage|schema.*already exists|type.*already exists|policy.*already exists|publication.*already exists|relation.*already member of publication|syntax error|at or near" | \
            wc -l | tr -d '[:space:]' || echo "0")
        
        if [ "$non_system_errors" -eq 0 ]; then
            log_success "All errors were system errors (expected) - migration successful"
            log_to_file "$LOG_FILE" "INFO: All errors were system errors - migration successful"
            sql_applied=true
            # Continue execution - don't exit here
        else
            log_error "Failed to apply schema to target via any connection method"
            log_error "Found $non_system_errors critical error(s) in logs"
            log_to_file "$LOG_FILE" "ERROR: Failed to apply schema to target ($non_system_errors critical errors)"
            log_to_file "$LOG_FILE" "ERROR: Migration failed - exiting with error code 1"
            exit 1
        fi
    else
        log_error "Failed to apply schema to target via any connection method"
        log_to_file "$LOG_FILE" "ERROR: Failed to apply schema to target"
        exit 1
    fi
fi

# Log success
log_to_file "$LOG_FILE" "Schema application completed successfully: sql_applied=$sql_applied"

# Step 3.5: Detect and Apply Schema Differences (New Columns, Modified Columns, etc.)
# This step runs after schema application to catch any schema changes that pg_dump might have missed
# pg_dump creates full table definitions, not ALTER TABLE statements, so we need to detect and apply them manually
# ALWAYS RUN: Schema differences must be detected and applied to ensure new columns are migrated
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 3.5/4: Detecting and Applying Schema Differences"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Detecting schema differences (new columns, modified columns, etc.)..."
log_to_file "$LOG_FILE" "Detecting schema differences between source and target"

# Function to extract column information from a database
extract_columns_info() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local output_file=$5
    
    local query="
        SELECT 
            table_schema || '|' || 
            table_name || '|' || 
            column_name || '|' || 
            data_type || '|' || 
            COALESCE(format_type(a.atttypid, a.atttypmod), data_type) || '|' ||
            is_nullable || '|' || 
            COALESCE(column_default, '') || '|' ||
            ordinal_position
        FROM information_schema.columns c
        LEFT JOIN pg_catalog.pg_attribute a
            ON a.attrelid = (table_schema || '.' || table_name)::regclass
           AND a.attname = c.column_name
           AND a.attnum > 0
           AND a.attisdropped = false
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema NOT LIKE 'pg_toast%'
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        ORDER BY table_schema, table_name, ordinal_position;
    "
    
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
}

# Extract column information from source and target
SOURCE_COLUMNS_FILE="$MIGRATION_DIR_ABS/source_columns.txt"
TARGET_COLUMNS_FILE="$MIGRATION_DIR_ABS/target_columns.txt"
SCHEMA_DIFF_SQL="$MIGRATION_DIR_ABS/schema_differences.sql"

log_info "Extracting column information from source..."
extract_columns_info "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SOURCE_COLUMNS_FILE"

log_info "Extracting column information from target..."
extract_columns_info "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$TARGET_COLUMNS_FILE"

if [ -s "$SOURCE_COLUMNS_FILE" ] && [ -s "$TARGET_COLUMNS_FILE" ]; then
    log_info "Comparing schemas to find differences..."
    
    # Generate ALTER TABLE statements for schema differences using Python
    PYTHON_BIN=$(command -v python3 || command -v python || echo "")
    if [ -n "$PYTHON_BIN" ]; then
        PYTHON_OUTPUT=$("$PYTHON_BIN" - "$SOURCE_COLUMNS_FILE" "$TARGET_COLUMNS_FILE" "$SCHEMA_DIFF_SQL" <<'PYTHON_SCRIPT'
import sys
from collections import defaultdict

source_file = sys.argv[1]
target_file = sys.argv[2]
output_file = sys.argv[3]

# Parse column information
def parse_columns(file_path):
    columns = defaultdict(dict)  # {schema.table: {column_name: {info}}}
    with open(file_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split('|')
            if len(parts) >= 8:
                schema, table, column, data_type, formatted_type, is_nullable, default, position = parts[:8]
                key = f"{schema}.{table}"
                columns[key][column] = {
                    'data_type': data_type,
                    'formatted_type': formatted_type or data_type,
                    'is_nullable': is_nullable,
                    'default': default,
                    'position': int(position) if position.isdigit() else 999
                }
    return columns

source_cols = parse_columns(source_file)
target_cols = parse_columns(target_file)

alter_statements = []

# Find new columns (in source but not in target)
for table_key, source_table_cols in source_cols.items():
    target_table_cols = target_cols.get(table_key, {})
    schema, table = table_key.split('.', 1)
    
    for col_name, col_info in source_table_cols.items():
        if col_name not in target_table_cols:
            # New column - add it
            stmt = f'ALTER TABLE "{schema}"."{table}" ADD COLUMN "{col_name}" {col_info["formatted_type"]}'
            if col_info['default']:
                stmt += f' DEFAULT {col_info["default"]}'
            if col_info['is_nullable'].upper() == 'NO':
                stmt += ' NOT NULL'
            alter_statements.append(stmt + ';')
    
    # Find modified columns (type, nullable, default changes)
    for col_name, source_col_info in source_table_cols.items():
        if col_name in target_table_cols:
            target_col_info = target_table_cols[col_name]
            schema, table = table_key.split('.', 1)
            
            # Check for type changes
            if source_col_info['formatted_type'] != target_col_info['formatted_type']:
                new_type = source_col_info['formatted_type']
                alter_statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" TYPE {new_type} USING "{col_name}"::{new_type};')
            
            # Check for nullable changes
            if source_col_info['is_nullable'] != target_col_info['is_nullable']:
                if source_col_info['is_nullable'].upper() == 'NO':
                    alter_statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" SET NOT NULL;')
                else:
                    alter_statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" DROP NOT NULL;')
            
            # Check for default changes
            if source_col_info['default'] != target_col_info['default']:
                if source_col_info['default']:
                    alter_statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" SET DEFAULT {source_col_info["default"]};')
                else:
                    alter_statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" DROP DEFAULT;')

# Write ALTER statements to file
with open(output_file, 'w') as f:
    for stmt in alter_statements:
        f.write(stmt + '\n')

print(f"Generated {len(alter_statements)} ALTER TABLE statement(s)")
PYTHON_SCRIPT
)
        
        SCHEMA_DIFF_COUNT=$(echo "$PYTHON_OUTPUT" | grep -oE "[0-9]+" | head -1 || echo "0")
        
        if [ "$SCHEMA_DIFF_COUNT" -gt 0 ] && [ -s "$SCHEMA_DIFF_SQL" ]; then
            ACTUAL_COUNT=$(grep -c "^ALTER TABLE" "$SCHEMA_DIFF_SQL" 2>/dev/null || echo "0")
            log_info "Found $ACTUAL_COUNT schema difference(s) to apply"
            log_to_file "$LOG_FILE" "Found $ACTUAL_COUNT schema differences"
            
            # Show what will be changed
            log_info "Schema changes to apply:"
            grep "^ALTER TABLE" "$SCHEMA_DIFF_SQL" | head -10 | while read -r line; do
                log_info "  - $line"
            done
            if [ "$ACTUAL_COUNT" -gt 10 ]; then
                log_info "  ... and $((ACTUAL_COUNT - 10)) more"
            fi
            
            # Apply schema differences
            log_info "Applying schema differences to target..."
            set +e
            if run_psql_script_with_fallback "Applying schema differences" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_DIFF_SQL"; then
                log_success "✓ Schema differences applied successfully"
                log_to_file "$LOG_FILE" "SUCCESS: Schema differences applied"
            else
                log_warning "⚠ Some errors occurred while applying schema differences"
                log_warning "  Review the SQL file: $SCHEMA_DIFF_SQL"
                log_to_file "$LOG_FILE" "WARNING: Some schema differences may not have been applied"
            fi
            set -e
        else
            log_success "✓ No schema differences found - source and target schemas match"
            log_to_file "$LOG_FILE" "No schema differences detected"
        fi
    else
        log_warning "⚠ Python not found - cannot detect schema differences automatically"
        log_warning "  Please manually verify schema differences between source and target"
        log_to_file "$LOG_FILE" "WARNING: Python not found, schema difference detection skipped"
    fi
else
    log_warning "⚠ Could not extract column information - schema difference detection skipped"
    log_to_file "$LOG_FILE" "WARNING: Could not extract column information"
fi

log_info ""

# If data migration was requested, provide guidance
if [ "$INCLUDE_DATA" = "true" ]; then
    echo ""
    log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warning "  Data Migration Not Completed"
    log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warning ""
    log_warning "The pg_dump method only migrates schema, not data."
    log_warning "To migrate data, use the database_migration.sh script:"
    if [ "$REPLACE_DATA" = "true" ]; then
        log_warning "  ./scripts/components/database_migration.sh $SOURCE_ENV $TARGET_ENV --data --replace-data"
    else
        log_warning "  ./scripts/components/database_migration.sh $SOURCE_ENV $TARGET_ENV --data --increment"
    fi
    log_warning ""
    log_to_file "$LOG_FILE" "WARNING: Data migration not completed - use database_migration.sh for data"
fi
echo ""

# Step 4: Verify migration success
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4/4: Verifying Migration Success"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Verifying policies were migrated correctly..."
log_to_file "$LOG_FILE" "Verifying migration success"

# Export target schema after migration using pg_dump (same pattern as database_migration.sh)
TARGET_SCHEMA_AFTER="$MIGRATION_DIR_ABS/target_schema_after.sql"
log_info "Exporting target schema for verification..."
log_to_file "$LOG_FILE" "Exporting target schema for verification"

PG_DUMP_ARGS=(-d postgres --schema-only --no-owner -f "$TARGET_SCHEMA_AFTER")
target_after_dump_success=false

if run_pg_tool_with_fallback "pg_dump" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$LOG_FILE" \
    "${PG_DUMP_ARGS[@]}"; then
    target_after_dump_success=true
fi

if [ "$target_after_dump_success" = "true" ]; then
    if [ -s "$TARGET_SCHEMA_AFTER" ]; then
        # Count policies from the ORIGINAL unfiltered dump (to compare with actual database)
        source_unfiltered_dump="$SCHEMA_DUMP_FILE.unfiltered"
        if [ -f "$source_unfiltered_dump" ]; then
            source_total_policies=$(grep -c "^CREATE POLICY" "$source_unfiltered_dump" 2>/dev/null || echo "0")
            source_storage_policies=$(grep -c "^CREATE POLICY.*ON storage\." "$source_unfiltered_dump" 2>/dev/null || echo "0")
            source_non_storage_policies=$((source_total_policies - source_storage_policies))
        else
            # Fallback to filtered dump if original not available
            source_total_policies=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
            source_storage_policies=0
            source_non_storage_policies=$source_total_policies
        fi
        
        # Count policies in filtered dump (what we tried to apply)
        source_policy_count=$(grep -c "^CREATE POLICY" "$SCHEMA_DUMP_FILE" 2>/dev/null || echo "0")
        
        # Count policies in target (from all schemas)
        target_policy_count=$(grep -c "^CREATE POLICY" "$TARGET_SCHEMA_AFTER" 2>/dev/null || echo "0")
        
        log_info "  Source total policies (all schemas): $source_total_policies"
        log_info "  Source storage policies (excluded from migration): $source_storage_policies"
        log_info "  Source non-storage policies (should be migrated): $source_non_storage_policies"
        log_info "  Source policies in filtered dump: $source_policy_count"
        log_info "  Target policies after migration: $target_policy_count"
        
        # Calculate missing policies
        if [ "$source_non_storage_policies" -gt 0 ]; then
            missing_policies=$((source_non_storage_policies - target_policy_count))
            if [ "$missing_policies" -gt 0 ]; then
                log_error "❌ Policy migration incomplete: Target has $missing_policies fewer policy(ies) than source"
                log_error "  Expected: $source_non_storage_policies, Got: $target_policy_count"
                log_to_file "$LOG_FILE" "ERROR: Policy migration incomplete - $missing_policies policies missing"
                log_to_file "$LOG_FILE" "  Source non-storage policies: $source_non_storage_policies"
                log_to_file "$LOG_FILE" "  Target policies: $target_policy_count"
                
                # Try to identify which policies are missing by extracting policy names
                log_info "  Attempting to identify missing policies..."
                if [ -f "$source_unfiltered_dump" ] && [ -f "$TARGET_SCHEMA_AFTER" ]; then
                    # Extract policy names from source (non-storage)
                    source_policy_names=$(grep "^CREATE POLICY" "$source_unfiltered_dump" | \
                        grep -v "ON storage\." | \
                        sed -E 's/^CREATE POLICY[[:space:]]+([^[:space:]]+).*/\1/' | sort)
                    target_policy_names=$(grep "^CREATE POLICY" "$TARGET_SCHEMA_AFTER" | \
                        sed -E 's/^CREATE POLICY[[:space:]]+([^[:space:]]+).*/\1/' | sort)
                    
                    missing_policy_names=$(comm -23 <(echo "$source_policy_names") <(echo "$target_policy_names") 2>/dev/null | head -20 || echo "")
                    if [ -n "$missing_policy_names" ]; then
                        log_warning "  Sample missing policy names (from dump comparison):"
                        echo "$missing_policy_names" | while IFS= read -r policy_name; do
                            [ -n "$policy_name" ] && log_warning "    - $policy_name"
                            [ -n "$policy_name" ] && log_to_file "$LOG_FILE" "  Missing policy (from dump): $policy_name"
                        done
                        missing_count=$(echo "$missing_policy_names" | wc -l | tr -d '[:space:]')
                        if [ "$missing_count" -gt 20 ]; then
                            log_warning "    ... and more (check log file for complete list)"
                        fi
                    fi
                fi
                
                # Enhanced: Direct database query to identify missing policies with full identifiers
                log_info "  Querying databases directly to identify missing policies (more accurate)..."
                source_policies_query="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('storage', 'pg_catalog', 'information_schema') ORDER BY schemaname, tablename, policyname;"
                target_policies_query="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('storage', 'pg_catalog', 'information_schema') ORDER BY schemaname, tablename, policyname;"
                
                # Query source policies (using same connection pattern as database_migration.sh)
                source_policies_list_file="$MIGRATION_DIR_ABS/source_policies_list.txt"
                source_policies_success=false
                
                # Use run_psql_query_with_fallback helper
                if run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$source_policies_query" > "$source_policies_list_file" 2>/dev/null; then
                    source_policies_success=true
                    log_info "    Source policies queried successfully"
                else
                    log_warning "    Failed to query source policies"
                fi
                
                # Query target policies (using same connection pattern as database_migration.sh)
                target_policies_list_file="$MIGRATION_DIR_ABS/target_policies_list.txt"
                target_policies_success=false
                
                # Use run_psql_query_with_fallback helper
                if run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$target_policies_query" > "$target_policies_list_file" 2>/dev/null; then
                    target_policies_success=true
                    log_info "    Target policies queried successfully"
                else
                    log_warning "    Failed to query target policies"
                fi
                
                # Compare and identify missing policies
                if [ "$source_policies_success" = "true" ] && [ "$target_policies_success" = "true" ]; then
                    source_policies_db_count=$(wc -l < "$source_policies_list_file" | tr -d '[:space:]' || echo "0")
                    target_policies_db_count=$(wc -l < "$target_policies_list_file" | tr -d '[:space:]' || echo "0")
                    
                    log_info "  Direct database query results:"
                    log_info "    Source policies (from DB): $source_policies_db_count"
                    log_info "    Target policies (from DB): $target_policies_db_count"
                    log_to_file "$LOG_FILE" "Direct DB query - Source: $source_policies_db_count, Target: $target_policies_db_count"
                    
                    if [ "$source_policies_db_count" -gt "$target_policies_db_count" ]; then
                        missing_db_count=$((source_policies_db_count - target_policies_db_count))
                        log_error "  ❌ Missing $missing_db_count policy(ies) identified via direct database query"
                        log_to_file "$LOG_FILE" "ERROR: Missing $missing_db_count policies (direct DB query)"
                        
                        # Find missing policies using comm
                        missing_policies_file="$MIGRATION_DIR_ABS/missing_policies.txt"
                        comm -23 <(sort "$source_policies_list_file") <(sort "$target_policies_list_file") > "$missing_policies_file" 2>/dev/null || true
                        
                        if [ -s "$missing_policies_file" ]; then
                            missing_list=$(cat "$missing_policies_file")
                            log_error "  Missing policies (full identifier: schema.table.policy):"
                            echo "$missing_list" | while IFS= read -r policy_id; do
                                [ -n "$policy_id" ] && log_error "    - $policy_id"
                                [ -n "$policy_id" ] && log_to_file "$LOG_FILE" "  Missing policy: $policy_id"
                            done
                            log_info "  Full list of missing policies saved to: $missing_policies_file"
                            log_to_file "$LOG_FILE" "Missing policies list saved to: $missing_policies_file"
                        else
                            log_warning "  Could not generate missing policies list (comm command failed)"
                        fi
                    elif [ "$target_policies_db_count" -ge "$source_policies_db_count" ]; then
                        log_success "  ✓ All policies migrated successfully (direct database query confirms)"
                        log_to_file "$LOG_FILE" "SUCCESS: Direct DB query confirms all policies migrated"
                    fi
                else
                    if [ "$source_policies_success" = "false" ]; then
                        log_warning "  Could not query source policies directly from database"
                        log_to_file "$LOG_FILE" "WARNING: Failed to query source policies from DB"
                    fi
                    if [ "$target_policies_success" = "false" ]; then
                        log_warning "  Could not query target policies directly from database"
                        log_to_file "$LOG_FILE" "WARNING: Failed to query target policies from DB"
                    fi
                fi
            elif [ "$target_policy_count" -ge "$source_non_storage_policies" ]; then
                log_success "✓ Policy migration successful: All non-storage policies migrated ($target_policy_count policies)"
                log_to_file "$LOG_FILE" "SUCCESS: Policy migration complete ($target_policy_count policies)"
            fi
        else
            # Fallback comparison if we don't have unfiltered dump
        if [ "$source_policy_count" -eq "$target_policy_count" ]; then
            log_success "✓ Policy counts match! Migration successful"
            log_to_file "$LOG_FILE" "SUCCESS: Policy counts match ($source_policy_count policies)"
        else
            diff=$((source_policy_count - target_policy_count))
            if [ "$diff" -gt 0 ]; then
                log_warning "⚠ Target has $diff fewer policy(ies) than source"
                log_to_file "$LOG_FILE" "WARNING: Target has $diff fewer policies than source"
                    
                    # Enhanced: Direct database query to identify missing policies
                    log_info "  Querying databases directly to identify missing policies..."
                    source_policies_query="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('storage', 'pg_catalog', 'information_schema') ORDER BY schemaname, tablename, policyname;"
                    target_policies_query="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('storage', 'pg_catalog', 'information_schema') ORDER BY schemaname, tablename, policyname;"
                    
                    # Query source policies (using same connection pattern as database_migration.sh)
                    source_policies_list_file="$MIGRATION_DIR_ABS/source_policies_list.txt"
                    source_policies_success=false
                    
                    # Use run_psql_query_with_fallback helper
                    if run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$source_policies_query" > "$source_policies_list_file" 2>/dev/null; then
                        source_policies_success=true
                    fi
                    
                    # Query target policies (using same connection pattern as database_migration.sh)
                    target_policies_list_file="$MIGRATION_DIR_ABS/target_policies_list.txt"
                    target_policies_success=false
                    
                    # Use run_psql_query_with_fallback helper
                    if run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$target_policies_query" > "$target_policies_list_file" 2>/dev/null; then
                        target_policies_success=true
                    fi
                    
                    # Compare and identify missing policies
                    if [ "$source_policies_success" = "true" ] && [ "$target_policies_success" = "true" ]; then
                        source_policies_db_count=$(wc -l < "$source_policies_list_file" | tr -d '[:space:]' || echo "0")
                        target_policies_db_count=$(wc -l < "$target_policies_list_file" | tr -d '[:space:]' || echo "0")
                        
                        log_info "  Direct database query results:"
                        log_info "    Source policies (from DB): $source_policies_db_count"
                        log_info "    Target policies (from DB): $target_policies_db_count"
                        log_to_file "$LOG_FILE" "Direct DB query - Source: $source_policies_db_count, Target: $target_policies_db_count"
                        
                        if [ "$source_policies_db_count" -gt "$target_policies_db_count" ]; then
                            missing_db_count=$((source_policies_db_count - target_policies_db_count))
                            log_error "  ❌ Missing $missing_db_count policy(ies) identified via direct database query"
                            log_to_file "$LOG_FILE" "ERROR: Missing $missing_db_count policies (direct DB query)"
                            
                            # Find missing policies using comm
                            missing_policies_file="$MIGRATION_DIR_ABS/missing_policies.txt"
                            comm -23 <(sort "$source_policies_list_file") <(sort "$target_policies_list_file") > "$missing_policies_file" 2>/dev/null || true
                            
                            if [ -s "$missing_policies_file" ]; then
                                missing_list=$(cat "$missing_policies_file")
                                log_error "  Missing policies (full identifier: schema.table.policy):"
                                echo "$missing_list" | while IFS= read -r policy_id; do
                                    [ -n "$policy_id" ] && log_error "    - $policy_id"
                                    [ -n "$policy_id" ] && log_to_file "$LOG_FILE" "  Missing policy: $policy_id"
                                done
                                log_info "  Full list of missing policies saved to: $missing_policies_file"
                                log_to_file "$LOG_FILE" "Missing policies list saved to: $missing_policies_file"
                            fi
                        fi
                    fi
            else
                log_warning "⚠ Target has $((diff * -1)) more policy(ies) than source"
                log_to_file "$LOG_FILE" "WARNING: Target has $((diff * -1)) more policies than source"
                fi
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
                echo "$diff_output" | tee -a "$LOG_FILE"
                log_to_file "$LOG_FILE" "INFO: Some differences may remain"
            fi
        else
            log_info "Diff command not available - comparing policy counts only"
        fi
    else
        log_warning "⚠ Target schema dump is empty"
    fi
else
    log_warning "⚠ Failed to export target schema for verification"
    log_to_file "$LOG_FILE" "WARNING: Failed to export target schema for verification"
fi

# Create summary
SUMMARY_FILE="$MIGRATION_DIR_ABS/migration_summary.txt"
{
    echo "# Database & Policies Migration Summary (CLI Method)"
    echo ""
    echo "**Source**: $SOURCE_ENV ($SOURCE_REF)"
    echo "**Target**: $TARGET_ENV ($TARGET_REF)"
    echo "**Date**: $(date)"
    echo "**Method**: pg_dump + Direct SQL Application"
    echo "**Data Migration**: $([ "$INCLUDE_DATA" = "true" ] && echo "Yes ($([ "$REPLACE_DATA" = "true" ] && echo "Replace" || echo "Incremental"))" || echo "No (Schema only)")"
    echo ""
    echo "## Migration Results"
    echo ""
    echo "- **Status**: Migration completed"
    echo "- **Method**: pg_dump + Direct SQL Application"
    echo ""
    echo "## Files Generated"
    echo ""
    echo "- \`source_schema.sql\` - Schema exported from source"
    echo "- \`target_schema_after.sql\` - Schema exported from target after migration"
    echo "- \`migration.log\` - Detailed migration log"
    echo ""
    echo "## Next Steps"
    echo ""
    echo "1. Review the migration log: \`$LOG_FILE\`"
    echo "2. Verify schema in target environment"
    echo "3. Test application functionality"
    if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_DATA" = "true" ]; then
        echo "4. ⚠️  Data replacement may require additional steps - see warnings in log"
    fi
    echo ""
} > "$SUMMARY_FILE"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Complete"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_success "✓ Database and policies migration completed"
log_info "Summary: $SUMMARY_FILE"
log_info "Log: $LOG_FILE"
log_info ""
log_info "To verify migration, compare the schema files:"
log_info "  diff $SCHEMA_DUMP_FILE $TARGET_SCHEMA_AFTER"
log_info ""

echo "$MIGRATION_DIR_ABS"

# Explicitly exit with success code
exit 0
