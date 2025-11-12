#!/usr/bin/env bash

# Helper: run psql command with fallback across available endpoints
run_psql_command_with_fallback() {
    local description=$1
    local ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local command=$6

    local success=false
    local tmp_err
    tmp_err=$(mktemp)

    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "${description} via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -v ON_ERROR_STOP=on \
            -c "$command" \
            >>"$LOG_FILE" 2>"$tmp_err"; then
            success=true
            break
        else
            log_warning "${description} failed via ${label}: $(head -n 1 "$tmp_err")"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    rm -f "$tmp_err"
    $success && return 0 || return 1
}

# Helper: run psql query and capture output with fallback
run_psql_query_with_fallback() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query=$5

    local tmp_err
    tmp_err=$(mktemp)

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
            rm -f "$tmp_err"
            return 0
        else
            log_warning "Query execution failed via ${label}: $(head -n 1 "$tmp_err")"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    cat "$tmp_err" >&2
    rm -f "$tmp_err"
    return 1
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
            log_warning "${description} failed via ${label}: $(head -n 1 "$tmp_err")"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    rm -f "$tmp_err"
    $success && return 0 || return 1
}

#!/bin/bash
# Database Migration Script
# Migrates database schema (and optionally data) from source to target
# Can be used independently or as part of a complete migration
# Default: schema-only migration (no data)
# Use --data flag to include data migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_report_generator.sh" 2>/dev/null || true

# Default: schema-only migration (no data)
INCLUDE_DATA=false
INCLUDE_USERS=false
BACKUP_TARGET=false
MIGRATION_DIR=""
REPLACE_TARGET_DATA=false
INCREMENTAL_MODE=false
TARGET_DATA_BACKUP=""
TARGET_DATA_BACKUP_SQL=""
TARGET_SCHEMA_BEFORE_FILE=""
TARGET_SCHEMA_AFTER_FILE=""
RELAXED_NOT_NULL_FILE=""

# Parse arguments - extract flags first, then positional arguments
SOURCE_ENV=""
TARGET_ENV=""
POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --data)
            INCLUDE_DATA=true
            ;;
        --users)
            INCLUDE_USERS=true
            ;;
        --backup)
            BACKUP_TARGET=true
            ;;
        --replace-data|--force-data-replace)
            REPLACE_TARGET_DATA=true
            ;;
        --increment|--incremental)
            INCREMENTAL_MODE=true
            ;;
        -h|--help)
            # Will show usage after it's defined
            SHOW_HELP=true
            ;;
        --)
            # End of flags, rest are positional - but we're already in a loop, so just continue
            # The -- will be treated as a positional arg
            POSITIONAL_ARGS+=("$arg")
            ;;
        -*)
            # Unknown flag
            echo "Error: Unknown option: $arg" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            # Positional argument
            POSITIONAL_ARGS+=("$arg")
            ;;
    esac
done

# Extract positional arguments
SOURCE_ENV=${POSITIONAL_ARGS[0]:-}
TARGET_ENV=${POSITIONAL_ARGS[1]:-}
MIGRATION_DIR=${POSITIONAL_ARGS[2]:-""}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [migration_dir] [--data] [--users] [--backup] [--replace-data]

Migrates database schema (and optionally data and auth users) from source to target

Default Behavior:
  By default, migrates SCHEMA ONLY (no data, no auth users).
  Use --data flag to include data migration.
  Use --users flag to include authentication users, roles, and policies.
  Use --increment to prefer incremental/delta operations (non-destructive) when possible.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  --data         Include data migration (default: schema only)
  --replace-data Replace target data (destructive). Without this flag, data migrations run in append/delta mode.
  --users        Include authentication users, roles, and policies
  --backup       Create backup of target before migration (optional)
  --increment    Prefer incremental/delta operations (default: disabled)

Examples:
  $0 prod test                          # Migrate schema only (default)
  $0 prod test --data                   # Migrate schema + data
  $0 prod test --users                  # Migrate schema + auth users
  $0 prod test --data --users           # Migrate schema + data + auth users
  $0 dev test /path/to/backup           # Migrate schema with custom backup directory
  $0 prod test /path/to/backup --data --users --backup  # Full migration with backup

Returns:
  0 on success, 1 on failure

EOF
    exit 1
}

# Check if help was requested
if [ "${SHOW_HELP:-false}" = "true" ]; then
    usage
fi

# Check arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    echo "Error: Source and target environments are required" >&2
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
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    if [ "$INCLUDE_DATA" = "true" ]; then
        BACKUP_TYPE="full_db"
        MIGRATION_DIR=$(create_backup_dir "full_db" "$SOURCE_ENV" "$TARGET_ENV")
    else
        BACKUP_TYPE="schema_db"
        MIGRATION_DIR=$(create_backup_dir "schema_db" "$SOURCE_ENV" "$TARGET_ENV")
    fi
else
    # Determine backup type from directory name
    if echo "$MIGRATION_DIR" | grep -q "full_db"; then
        BACKUP_TYPE="full_db"
    else
        BACKUP_TYPE="schema_db"
    fi
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
MIGRATION_MODE="Schema Only"
if [ "$INCLUDE_DATA" = "true" ] && [ "$INCLUDE_USERS" = "true" ]; then
    log_to_file "$LOG_FILE" "Starting database schema + data + auth users migration from $SOURCE_ENV to $TARGET_ENV"
    if [ "$REPLACE_TARGET_DATA" = "true" ]; then
        log_info "📊 Database Schema + Data + Auth Users Migration (replace target data)"
        MIGRATION_MODE="Schema + Data + Auth Users (replace)"
    else
        log_info "📊 Database Schema + Data + Auth Users Migration (delta/append)"
        MIGRATION_MODE="Schema + Data + Auth Users (delta)"
    fi
elif [ "$INCLUDE_DATA" = "true" ]; then
    log_to_file "$LOG_FILE" "Starting database schema + data migration from $SOURCE_ENV to $TARGET_ENV"
    if [ "$REPLACE_TARGET_DATA" = "true" ]; then
        log_info "📊 Database Schema + Data Migration (replace target data)"
        MIGRATION_MODE="Schema + Data (replace)"
    else
        log_info "📊 Database Schema + Data Migration (delta/append)"
        MIGRATION_MODE="Schema + Data (delta)"
    fi
elif [ "$INCLUDE_USERS" = "true" ]; then
    log_to_file "$LOG_FILE" "Starting database schema + auth users migration from $SOURCE_ENV to $TARGET_ENV"
    log_info "📊 Database Schema + Auth Users Migration"
    MIGRATION_MODE="Schema + Auth Users"
else
    log_to_file "$LOG_FILE" "Starting database schema-only migration from $SOURCE_ENV to $TARGET_ENV"
    log_info "📊 Database Schema-Only Migration"
fi

if [ "$INCREMENTAL_MODE" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
    log_warning "Incremental mode requested but --replace-data supplied; replace mode will override incremental behaviour for data sections."
fi

log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
log_info "Mode: $MIGRATION_MODE"
log_info "Incremental mode: $INCREMENTAL_MODE"
log_to_file "$LOG_FILE" "Incremental mode: $INCREMENTAL_MODE"
echo ""

# Source rollback utilities
source "$PROJECT_ROOT/lib/rollback_utils.sh" 2>/dev/null || true

# Step 1: Backup target if requested
if [ "$BACKUP_TARGET" = "--backup" ] || [ "$BACKUP_TARGET" = "true" ]; then
    log_info "Creating backup of target environment..."
    log_to_file "$LOG_FILE" "Creating backup of target"
    
    if link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        log_info "Backing up target database (binary format)..."
        if run_pg_tool_with_fallback "pg_dump" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$LOG_FILE" \
            -d postgres -Fc -f "$MIGRATION_DIR/target_backup.dump"; then
            log_success "Backup created: $MIGRATION_DIR/target_backup.dump"
        else
            log_warning "Backup may have failed, continuing..."
        fi
        
        # Capture target state as SQL for manual rollback
        log_info "Creating rollback SQL script..."
        if [ "$INCLUDE_DATA" = "true" ]; then
            if capture_target_state_for_rollback "$TARGET_REF" "$TARGET_PASSWORD" "$MIGRATION_DIR/rollback_db.sql" "full"; then
                log_success "Rollback SQL script created: $MIGRATION_DIR/rollback_db.sql"
            fi
        else
            if capture_target_state_for_rollback "$TARGET_REF" "$TARGET_PASSWORD" "$MIGRATION_DIR/rollback_db.sql" "schema"; then
                log_success "Rollback SQL script created: $MIGRATION_DIR/rollback_db.sql"
            fi
        fi
        
        supabase unlink --yes 2>/dev/null || true
    fi
fi

# Step 2: Dump source database
if [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 1/3: Dumping source database (schema + data)..."
    log_to_file "$LOG_FILE" "Dumping source database (schema + data)"
    
    DUMP_FILE="$MIGRATION_DIR/source_full.dump"
    
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
        log_error "Failed to link to source project"
        exit 1
    fi
    
    # Get pooler host using environment name (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    if [ "$INCLUDE_USERS" = "true" ]; then
         log_info "Creating full database dump (excluding auth schema - will be handled separately)..."
        if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
            -d postgres -Fc --verbose --exclude-schema=auth -f "$DUMP_FILE"; then
            log_warning "Failed to create full dump via any connection"
        fi
    else
        log_info "Creating full database dump..."
        if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
            -d postgres -Fc --verbose -f "$DUMP_FILE"; then
            log_warning "Failed to create full dump via any connection"
        fi
    fi
else
    log_info "Step 1/3: Dumping source schema (structure only)..."
    log_to_file "$LOG_FILE" "Dumping source schema (structure only)"
    
    DUMP_FILE="$MIGRATION_DIR/source_schema.dump"
    
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
        log_error "Failed to link to source project"
        exit 1
    fi
    
    # Get pooler host using environment name (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    log_info "Creating schema-only dump (no data)..."
    if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        -d postgres -Fc --schema-only --no-owner --no-acl --verbose -f "$DUMP_FILE"; then
        log_warning "Failed to create schema-only dump via any connection"
    fi
 fi

if [ ! -f "$DUMP_FILE" ] || [ ! -s "$DUMP_FILE" ]; then
    log_error "Failed to create dump file"
    exit 1
fi

log_success "Dump created: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"

# Step 2a: Dump auth users if requested
if [ "$INCLUDE_USERS" = "true" ]; then
    log_info "Step 1b/4: Dumping auth users and related data..."
    log_to_file "$LOG_FILE" "Dumping auth users and related data"
    
    AUTH_USERS_DUMP="$MIGRATION_DIR/auth_users.dump"
    
    # Ensure we're still linked to source
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD" 2>/dev/null; then
        log_info "Re-linking to source project for auth users dump..."
        if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
            log_error "Failed to link to source project for auth users dump"
            exit 1
        fi
    fi
    
    # Get pooler host using environment name (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    log_info "Creating auth users dump (auth schema data)..."
    # Dump auth schema and ALL auth table data including auth.users
    # This includes: auth.users, auth.identities, auth.refresh_tokens, auth.sessions, etc.
    # Note: We use --data-only to get only the data, and specify auth schema
    # This will copy all authentication users and their related data
    log_info "Dumping all auth schema tables (users, identities, refresh_tokens, sessions, etc.)..."
    # Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U "postgres.${SOURCE_REF}" \
        -d postgres \
        -Fc \
        --schema=auth \
        --data-only \
        --verbose \
        -f "$AUTH_USERS_DUMP" \
        2>&1 | tee -a "$LOG_FILE" || {
            log_warning "Pooler connection failed for auth users, trying direct connection..."
            PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
                -h "db.${SOURCE_REF}.supabase.co" \
                -p 5432 \
                -U "postgres.${SOURCE_REF}" \
            -d postgres \
            -Fc \
            --schema=auth \
            --data-only \
            --verbose \
            -f "$AUTH_USERS_DUMP" \
            2>&1 | tee -a "$LOG_FILE"
    }
    
    if [ -f "$AUTH_USERS_DUMP" ] && [ -s "$AUTH_USERS_DUMP" ]; then
        AUTH_USER_COUNT=$(PGPASSWORD="$SOURCE_PASSWORD" psql \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U "postgres.${SOURCE_REF}" \
            -d postgres \
            -t -A \
            -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
        log_success "Auth users dump created: $AUTH_USERS_DUMP ($(du -h "$AUTH_USERS_DUMP" | cut -f1)) - $AUTH_USER_COUNT users"
    else
        log_warning "Auth users dump may be empty or failed - continuing anyway"
    fi
fi

supabase unlink --yes 2>/dev/null || true

# Step 3: Restore to target
if [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 2/3: Restoring to target environment..."
    log_to_file "$LOG_FILE" "Restoring to target environment"
    
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        log_error "Failed to link to target project"
        exit 1
    fi
    
    if [ "$REPLACE_TARGET_DATA" = "true" ]; then
        # Drop existing objects for full migration
        log_warning "Dropping existing objects in target database (replace mode enabled)..."
        DROP_SCRIPT="$MIGRATION_DIR/drop_all.sql"
        cat > "$DROP_SCRIPT" << 'EOF'
DO $$ 
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') 
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
    
    FOR r IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public')
    LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(r.sequence_name) || ' CASCADE';
    END LOOP;
    
    FOR r IN (SELECT proname, oidvectortypes(proargtypes) as args 
              FROM pg_proc INNER JOIN pg_namespace ON pg_proc.pronamespace = pg_namespace.oid 
              WHERE pg_namespace.nspname = 'public')
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || quote_ident(r.proname) || '(' || r.args || ') CASCADE';
    END LOOP;
END $$;
EOF

        # Get pooler host using environment name (more reliable)
        POOLER_HOST=$(get_pooler_host_for_env "$TARGET_ENV" 2>/dev/null || get_pooler_host "$TARGET_REF")
        if [ -z "$POOLER_HOST" ]; then
            POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
        fi
        if ! PGPASSWORD="$TARGET_PASSWORD" psql \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U "postgres.${TARGET_REF}" \
            -d postgres \
            -f "$DROP_SCRIPT" \
            2>&1 | tee -a "$LOG_FILE"; then
                log_warning "Pooler connection failed for drop, trying direct connection..."
            if check_direct_connection_available "$TARGET_REF"; then
                PGPASSWORD="$TARGET_PASSWORD" psql \
                    -h "db.${TARGET_REF}.supabase.co" \
                    -p 5432 \
                    -U "postgres.${TARGET_REF}" \
                    -d postgres \
                    -f "$DROP_SCRIPT" \
                    2>&1 | tee -a "$LOG_FILE" || log_warning "Some objects may not have been dropped"
            fi
        fi
    else
        log_info "Delta mode enabled: skipping destructive DROP of target objects. Existing rows will be preserved."
    fi
else
    log_info "Step 2/3: Restoring schema to target environment..."
    log_to_file "$LOG_FILE" "Restoring schema to target environment"
    
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        log_error "Failed to link to target project"
        exit 1
    fi
fi

# Restore dump
RESTORE_ARGS=(--verbose)
RESTORE_SUCCESS=false
RESTORE_OUTPUT=$(mktemp)

RESTORE_ARGS+=(--schema-only --no-owner --no-acl)
if [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 3/3: Restoring dump to target..."
else
    log_info "Step 3/3: Restoring schema dump to target..."
fi
if [ "$INCREMENTAL_MODE" = "true" ] && [ "$REPLACE_TARGET_DATA" != "true" ]; then
    log_info "Incremental mode: skipping --clean on schema restore to avoid dropping target objects."
else
    RESTORE_ARGS+=(--clean --if-exists)
fi

DUPLICATE_ALLOWED=false
if [ "$INCREMENTAL_MODE" = "true" ]; then
    DUPLICATE_ALLOWED=true
fi

# Preserve target data when running schema-only delta migrations
if [ "$INCLUDE_DATA" != "true" ] && [ "$REPLACE_TARGET_DATA" != "true" ]; then
    TARGET_DATA_BACKUP="$MIGRATION_DIR/target_data_backup.dump"
    TARGET_DATA_BACKUP_SQL="$MIGRATION_DIR/target_data_backup.sql"
    TARGET_SCHEMA_BEFORE_FILE="$MIGRATION_DIR/target_schema_columns.before"
    SCHEMA_SNAPSHOT_QUERY="SELECT table_schema, table_name, column_name, is_nullable, CASE WHEN column_default IS NULL THEN 'false' ELSE 'true' END AS has_default, data_type FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_schema NOT LIKE 'pg_toast%%' ORDER BY 1,2,3;"
    log_info "Backing up existing target data to preserve rows..."
    BACKUP_ARGS=(-d postgres -Fc --data-only --verbose -f "$TARGET_DATA_BACKUP")
    if [ "$INCLUDE_USERS" = "true" ]; then
        BACKUP_ARGS+=(--exclude-schema=auth)
    fi
    if run_pg_tool_with_fallback "pg_dump" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$LOG_FILE" \
        "${BACKUP_ARGS[@]}"; then
        if [ -f "$TARGET_DATA_BACKUP" ] && [ -s "$TARGET_DATA_BACKUP" ]; then
            log_success "Target data backup created: $TARGET_DATA_BACKUP"
        else
            log_warning "Target data backup file appears empty; continuing without restore safeguard"
            TARGET_DATA_BACKUP=""
        fi
    else
        log_warning "Failed to backup target data; schema restore will proceed without automatic data preservation"
        TARGET_DATA_BACKUP=""
    fi

    log_info "Creating fallback SQL backup for preserved data..."
    SQL_BACKUP_ARGS=(-d postgres --data-only --inserts --column-inserts --no-owner --no-acl --disable-triggers -f "$TARGET_DATA_BACKUP_SQL")
    if [ "$INCLUDE_USERS" = "true" ]; then
        SQL_BACKUP_ARGS+=(--exclude-schema=auth)
    fi
    if ! run_pg_tool_with_fallback "pg_dump" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$LOG_FILE" \
        "${SQL_BACKUP_ARGS[@]}"; then
        log_warning "Failed to create SQL fallback backup; duplicate row handling may be limited."
        TARGET_DATA_BACKUP_SQL=""
    fi

    if run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_SNAPSHOT_QUERY" >"$TARGET_SCHEMA_BEFORE_FILE"; then
        log_info "Captured target schema snapshot before migration."
    else
        log_warning "Unable to capture target schema snapshot before migration."
        TARGET_SCHEMA_BEFORE_FILE=""
    fi
fi

# Get pooler host using environment name (more reliable)
POOLER_HOST=$(get_pooler_host_for_env "$TARGET_ENV" 2>/dev/null || get_pooler_host "$TARGET_REF")
if [ -z "$POOLER_HOST" ]; then
    POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
fi

set +e
# Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
PGPASSWORD="$TARGET_PASSWORD" pg_restore \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U "postgres.${TARGET_REF}" \
    -d postgres \
    "${RESTORE_ARGS[@]}" \
    "$DUMP_FILE" \
    2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
RESTORE_EXIT_CODE=${PIPESTATUS[0]}
set -e

# pg_restore with --clean can return exit code 1 even when successful
# because "errors ignored on restore" are expected when objects don't exist
# We need to check for actual errors (FATAL, connection failures) vs expected warnings
log_info "Restore exit code: $RESTORE_EXIT_CODE"

# Check for actual failures (not just expected warnings)
has_fatal_error=false
has_actual_error=false

# Check for FATAL errors (connection/auth issues)
# Don't match SQL commands like "SET log_min_messages TO 'fatal'" - only match actual error messages
if grep -qiE "(FATAL:|could not connect|connection.*failed|authentication failed|could not translate host)" "$RESTORE_OUTPUT" 2>/dev/null && \
   ! grep -qiE "SET.*log_min_messages.*fatal|Command was:.*fatal" "$RESTORE_OUTPUT" 2>/dev/null; then
    has_fatal_error=true
    log_warning "FATAL/connection errors detected in restore output"
fi

# Check for actual errors (not "errors ignored on restore")
if grep -qiE "error:" "$RESTORE_OUTPUT" 2>/dev/null && ! grep -qi "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null; then
    # Check if there are errors other than expected ones
    error_lines=$(grep -iE "error:" "$RESTORE_OUTPUT" 2>/dev/null | grep -viE "(errors ignored|already exists|does not exist)" || echo "")
    if [ "$DUPLICATE_ALLOWED" = "true" ]; then
        error_lines=$(echo "$error_lines" | grep -viE "duplicate key value violates unique constraint|Key \\(" || echo "")
        if grep -qiE "duplicate key value violates unique constraint" "$RESTORE_OUTPUT" 2>/dev/null; then
            log_warning "Duplicate key conflicts detected while inserting data. Existing rows in target were preserved."
        fi
    fi
    if [ -n "$error_lines" ]; then
        has_actual_error=true
        log_warning "Actual errors detected (not just ignored errors)"
    fi
fi

duplicate_conflicts=false
if [ "$DUPLICATE_ALLOWED" = "true" ] && grep -qiE "duplicate key value violates unique constraint" "$RESTORE_OUTPUT" 2>/dev/null; then
    duplicate_conflicts=true
fi

# Success conditions:
# 1. Exit code 0 with no FATAL errors, OR
# 2. Exit code 1 but only "errors ignored on restore" (expected) and no FATAL/connection errors
if [ $RESTORE_EXIT_CODE -eq 0 ] && [ "$has_fatal_error" = "false" ]; then
    # Perfect success - exit code 0 and no fatal errors
    RESTORE_SUCCESS=true
    if [ "$INCLUDE_DATA" = "true" ]; then
        log_success "Restore completed successfully via pooler (exit code: $RESTORE_EXIT_CODE)"
    else
        log_success "Schema restore completed successfully via pooler (exit code: $RESTORE_EXIT_CODE)"
    fi
    log_info "Warnings about 'errors ignored on restore' are expected with --clean option"
elif [ $RESTORE_EXIT_CODE -eq 1 ] && [ "$has_fatal_error" = "false" ] && [ "$has_actual_error" = "false" ] && { [ "$duplicate_conflicts" = "true" ] || grep -qi "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null; }; then
    # Exit code 1 but only expected warnings - this is success
    RESTORE_SUCCESS=true
    if [ "$duplicate_conflicts" = "true" ]; then
        log_success "Restore completed with existing rows preserved (duplicate keys skipped)."
    else
        ignored_count=$(grep -i "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null | sed -n 's/.*errors ignored on restore: \([0-9]*\).*/\1/p' | head -1 || echo "many")
        if [ "$INCLUDE_DATA" = "true" ]; then
            log_success "Restore completed successfully via pooler (exit code: 1, but only expected errors ignored: $ignored_count)"
        else
            log_success "Schema restore completed successfully via pooler (exit code: 1, but only expected errors ignored: $ignored_count)"
        fi
    fi
    log_info "With --clean option, pg_restore returns exit code 1 when objects don't exist (expected behavior)"
else
    # Actual failure - try direct connection if available
    if [ "$INCLUDE_DATA" = "true" ]; then
        log_warning "Pooler restore may have failed (exit code: $RESTORE_EXIT_CODE)"
    else
        log_warning "Pooler restore may have failed (exit code: $RESTORE_EXIT_CODE)"
    fi
    if [ "$has_fatal_error" = "true" ]; then
        log_warning "FATAL/connection errors detected, will retry with direct connection if available"
        grep -iE "(FATAL|could not connect|connection)" "$RESTORE_OUTPUT" 2>/dev/null | head -3 | while read line; do
            log_warning "  $line"
        done
    fi
    # Check if direct connection is available before attempting
    if ! check_direct_connection_available "$TARGET_REF"; then
        log_error "Direct connection not available (DNS resolution failed)"
        log_error "Cannot proceed with restore - pooler may have failed and direct connection unavailable"
        log_error "Please check your network connection and project configuration"
        rm -f "$RESTORE_OUTPUT"
        supabase unlink --yes 2>/dev/null || true
        exit 1
    fi
fi

if [ "$RESTORE_SUCCESS" != "true" ] && check_direct_connection_available "$TARGET_REF"; then
    log_info "Attempting restore via direct connection..."
    RESTORE_OUTPUT=$(mktemp)
    set +e
        PGPASSWORD="$TARGET_PASSWORD" pg_restore \
            -h "db.${TARGET_REF}.supabase.co" \
            -p 5432 \
            -U "postgres.${TARGET_REF}" \
            -d postgres \
            "${RESTORE_ARGS[@]}" \
            "$DUMP_FILE" \
        2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
    RESTORE_EXIT_CODE=${PIPESTATUS[0]}
    set -e
    
    # Same logic as pooler restore
    has_fatal_error=false
    has_actual_error=false
    
    if grep -qiE "(FATAL:|could not connect|connection.*failed|authentication failed|could not translate host)" "$RESTORE_OUTPUT" 2>/dev/null && \
       ! grep -qiE "SET.*log_min_messages.*fatal|Command was:.*fatal" "$RESTORE_OUTPUT" 2>/dev/null; then
        has_fatal_error=true
    fi
    
    if grep -qiE "error:" "$RESTORE_OUTPUT" 2>/dev/null && ! grep -qi "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null; then
        error_lines=$(grep -iE "error:" "$RESTORE_OUTPUT" 2>/dev/null | grep -viE "(errors ignored|already exists|does not exist)" || echo "")
        if [ "$DUPLICATE_ALLOWED" = "true" ]; then
            error_lines=$(echo "$error_lines" | grep -viE "duplicate key value violates unique constraint|Key \\(" || echo "")
        fi
        if [ -n "$error_lines" ]; then
            has_actual_error=true
        fi
    fi

    duplicate_conflicts=false
    if [ "$DUPLICATE_ALLOWED" = "true" ] && grep -qiE "duplicate key value violates unique constraint" "$RESTORE_OUTPUT" 2>/dev/null; then
        duplicate_conflicts=true
        log_warning "Duplicate key conflicts detected while inserting data over direct connection. Existing rows in target were preserved."
    fi
    
    if [ $RESTORE_EXIT_CODE -eq 0 ] && [ "$has_fatal_error" = "false" ]; then
        RESTORE_SUCCESS=true
        if [ "$INCLUDE_DATA" = "true" ]; then
            log_success "Restore completed successfully via direct connection (exit code: $RESTORE_EXIT_CODE)"
        else
            log_success "Schema restore completed successfully via direct connection (exit code: $RESTORE_EXIT_CODE)"
        fi
        log_info "Warnings about 'errors ignored on restore' are expected with --clean option"
    elif [ $RESTORE_EXIT_CODE -eq 1 ] && [ "$has_fatal_error" = "false" ] && [ "$has_actual_error" = "false" ] && { [ "$duplicate_conflicts" = "true" ] || grep -qi "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null; }; then
        RESTORE_SUCCESS=true
        if [ "$duplicate_conflicts" = "true" ]; then
            log_success "Restore completed with existing rows preserved (duplicate keys skipped)."
        else
            ignored_count=$(grep -i "errors ignored on restore" "$RESTORE_OUTPUT" 2>/dev/null | sed -n 's/.*errors ignored on restore: \([0-9]*\).*/\1/p' | head -1 || echo "many")
            if [ "$INCLUDE_DATA" = "true" ]; then
                log_success "Restore completed successfully via direct connection (exit code: 1, but only expected errors ignored: $ignored_count)"
            else
                log_success "Schema restore completed successfully via direct connection (exit code: 1, but only expected errors ignored: $ignored_count)"
            fi
            log_info "With --clean option, pg_restore returns exit code 1 when objects don't exist (expected behavior)"
        fi
    else
        log_error "Direct connection restore also failed (exit code: $RESTORE_EXIT_CODE)"
        if [ "$has_fatal_error" = "true" ]; then
            log_error "FATAL/connection errors found:"
            grep -iE "(FATAL|could not connect|connection)" "$RESTORE_OUTPUT" 2>/dev/null | head -5 | while read line; do
                log_error "  $line"
            done
        fi
        if [ "$has_actual_error" = "true" ]; then
            log_error "Actual errors found (not just ignored):"
            grep -iE "error:" "$RESTORE_OUTPUT" 2>/dev/null | grep -viE "(errors ignored|already exists|does not exist)" | head -5 | while read line; do
                log_error "  $line"
            done
        fi
    fi
fi

rm -f "$RESTORE_OUTPUT"

if [ "$RESTORE_SUCCESS" = "true" ] && [ -n "$TARGET_SCHEMA_BEFORE_FILE" ] && [ -f "$TARGET_SCHEMA_BEFORE_FILE" ]; then
    TARGET_SCHEMA_AFTER_FILE="$MIGRATION_DIR/target_schema_columns.after"
    SCHEMA_SNAPSHOT_QUERY="SELECT table_schema, table_name, column_name, is_nullable, CASE WHEN column_default IS NULL THEN 'false' ELSE 'true' END AS has_default, data_type FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_schema NOT LIKE 'pg_toast%%' ORDER BY 1,2,3;"
    if run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_SNAPSHOT_QUERY" >"$TARGET_SCHEMA_AFTER_FILE"; then
        tmp_relaxed_file="$MIGRATION_DIR/relaxed_not_null_columns.list"
        set +e
        python_output=$(SQL_BEFORE="$TARGET_SCHEMA_BEFORE_FILE" SQL_AFTER="$TARGET_SCHEMA_AFTER_FILE" python <<'PY'
import os
before_path = os.environ["SQL_BEFORE"]
after_path = os.environ["SQL_AFTER"]
before_keys = set()
with open(before_path, "r", encoding="utf-8") as before_fp:
    for line in before_fp:
        parts = line.strip().split("|")
        if len(parts) < 3:
            continue
        key = tuple(parts[:3])
        before_keys.add(key)
new_columns = []
with open(after_path, "r", encoding="utf-8") as after_fp:
    for line in after_fp:
        parts = line.strip().split("|")
        if len(parts) < 6:
            continue
        key = tuple(parts[:3])
        if key in before_keys:
            continue
        is_nullable = parts[3]
        has_default = parts[4]
        data_type = parts[5]
        if is_nullable.upper() == "NO" and has_default.lower() == "false":
            new_columns.append("|".join(list(key) + [data_type]))
if new_columns:
    print("\n".join(new_columns))
PY
)
        python_status=$?
        set -e
        if [ $python_status -eq 0 ] && [ -n "$python_output" ]; then
            printf "%s\n" "$python_output" >"$tmp_relaxed_file"
            RELAXED_NOT_NULL_FILE="$tmp_relaxed_file"
            while IFS='|' read -r schema_name table_name column_name data_type; do
                [ -z "$schema_name" ] && continue
                drop_sql=$(printf 'ALTER TABLE "%s"."%s" ALTER COLUMN "%s" DROP NOT NULL;' "$schema_name" "$table_name" "$column_name")
                run_psql_command_with_fallback "Temporarily relaxing NOT NULL constraint on ${schema_name}.${table_name}.${column_name}" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$drop_sql" || true
            done <"$RELAXED_NOT_NULL_FILE"
            if [ -s "$RELAXED_NOT_NULL_FILE" ]; then
                log_warning "New NOT NULL columns detected without defaults; constraints temporarily relaxed to allow data preservation."
            fi
        else
            RELAXED_NOT_NULL_FILE=""
            rm -f "$tmp_relaxed_file"
        fi
    else
        log_warning "Unable to capture target schema snapshot after migration."
        TARGET_SCHEMA_AFTER_FILE=""
    fi
fi

# Restore preserved data if applicable
if [ "$RESTORE_SUCCESS" = "true" ] && [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 3b/3: Applying data changes from source dump..."
    
    DATA_DUPLICATE_ALLOWED=false
    if [ "$REPLACE_TARGET_DATA" != "true" ]; then
        DATA_DUPLICATE_ALLOWED=true
    fi
    
    DATA_RESTORE_ARGS=(--verbose --no-owner --no-acl --disable-triggers --data-only -d postgres)
    if [ "$REPLACE_TARGET_DATA" = "true" ]; then
        DATA_RESTORE_ARGS+=(--clean)
    fi
    
    DATA_RESTORE_SUCCESS=false
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        
        log_info "Restoring source data via ${label} (${host}:${port})..."
        restore_log=$(mktemp)
        set +e
        PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_restore \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            "${DATA_RESTORE_ARGS[@]}" \
            "$DUMP_FILE" \
            2>&1 | tee -a "$LOG_FILE" | tee "$restore_log"
        DATA_RESTORE_EXIT=${PIPESTATUS[0]}
        set -e
        
        if [ $DATA_RESTORE_EXIT -eq 0 ]; then
            DATA_RESTORE_SUCCESS=true
            log_success "Data restore from source succeeded via ${label}"
            rm -f "$restore_log"
            break
        fi
        
        if [ "$DATA_DUPLICATE_ALLOWED" = "true" ] && \
            { grep -qiE "duplicate key value violates unique constraint" "$restore_log" || grep -qiE "errors ignored on restore" "$restore_log"; }; then
            DATA_RESTORE_SUCCESS=true
            log_warning "Data restore via ${label} completed with duplicate key warnings; existing rows were preserved."
            rm -f "$restore_log"
            break
        fi
        
        log_warning "Data restore via ${label} failed (exit code $DATA_RESTORE_EXIT)"
        if [ -s "$restore_log" ]; then
            tail -n 5 "$restore_log" | while read line; do
                log_warning "  $line"
            done
        fi
        rm -f "$restore_log"
    done < <(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    
    if [ "$DATA_RESTORE_SUCCESS" = "true" ]; then
        log_success "Source data restored successfully."
    else
        log_error "Failed to restore source data after all connection attempts."
        exit 1
    fi
fi

# Restore preserved data if applicable (schema-only mode)
if [ "$RESTORE_SUCCESS" = "true" ] && [ "$INCLUDE_DATA" != "true" ] && [ -n "$TARGET_DATA_BACKUP" ] && [ -f "$TARGET_DATA_BACKUP" ] && [ -s "$TARGET_DATA_BACKUP" ]; then
    log_info "Restoring preserved target data into updated schema..."

    data_restore_completed=false
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue

        log_info "Restoring preserved data via ${label} (${host}:${port})..."
        restore_log=$(mktemp)
        set +e
        PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require pg_restore \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            --data-only \
            --no-owner \
            --no-acl \
            --disable-triggers \
            -d postgres \
            "$TARGET_DATA_BACKUP" \
            2>&1 | tee -a "$LOG_FILE" | tee "$restore_log"
        DATA_RESTORE_EXIT=${PIPESTATUS[0]}
        set -e

        if [ $DATA_RESTORE_EXIT -eq 0 ]; then
            data_restore_completed=true
            log_success "Data restore succeeded via ${label}"
            rm -f "$restore_log"
            break
        fi

        if grep -qiE "duplicate key value violates unique constraint" "$restore_log" || grep -qiE "errors ignored on restore" "$restore_log"; then
            data_restore_completed=true
            log_warning "Data restore via ${label} completed with duplicate key warnings; existing rows were preserved."
            rm -f "$restore_log"
            break
        fi

        log_warning "Data restore via ${label} failed (exit code $DATA_RESTORE_EXIT)"
        rm -f "$restore_log"
    done < <(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")

    if [ "$data_restore_completed" != "true" ] && [ -n "$TARGET_DATA_BACKUP_SQL" ] && [ -f "$TARGET_DATA_BACKUP_SQL" ] && [ -s "$TARGET_DATA_BACKUP_SQL" ]; then
        log_warning "Binary restore failed; attempting SQL fallback with ON CONFLICT DO NOTHING..."
        transformed_sql=$(mktemp)
        SQL_FALLBACK_SOURCE="$TARGET_DATA_BACKUP_SQL" SQL_FALLBACK_DEST="$transformed_sql" python - <<'PY'
import os, re
src_path = os.environ["SQL_FALLBACK_SOURCE"]
dst_path = os.environ["SQL_FALLBACK_DEST"]
with open(src_path, "r", encoding="utf-8") as src:
    sql = src.read()
pattern = re.compile(r'(INSERT INTO .*?;)', re.S | re.IGNORECASE)
def repl(match):
    stmt = match.group(1)
    if 'ON CONFLICT' in stmt.upper():
        return stmt
    stmt = stmt.rstrip(';\n')
    return stmt + ' ON CONFLICT DO NOTHING;\n'
sql = pattern.sub(repl, sql)
with open(dst_path, "w", encoding="utf-8") as dst:
    dst.write(sql)
PY
        if run_psql_script_with_fallback "SQL data restore fallback" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$transformed_sql"; then
            data_restore_completed=true
            log_success "SQL fallback restore completed successfully."
        else
            log_warning "SQL fallback restore failed."
        fi
        rm -f "$transformed_sql"
    fi

    if [ "$data_restore_completed" = "true" ]; then
        log_success "Preserved target data restored successfully."
    else
        log_error "Failed to restore preserved target data after all connection attempts."
        exit 1
    fi
fi

if [ "$RESTORE_SUCCESS" = "true" ] && [ -n "$RELAXED_NOT_NULL_FILE" ] && [ -f "$RELAXED_NOT_NULL_FILE" ] && [ -s "$RELAXED_NOT_NULL_FILE" ]; then
    while IFS='|' read -r schema_name table_name column_name data_type; do
        [ -z "$schema_name" ] && continue
        null_count_query=$(printf 'SELECT COUNT(*) FROM "%s"."%s" WHERE "%s" IS NULL;' "$schema_name" "$table_name" "$column_name")
        set +e
        null_count=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$null_count_query")
        query_status=$?
        set -e
        if [ $query_status -ne 0 ]; then
            log_warning "Unable to validate NULL count for ${schema_name}.${table_name}.${column_name}; leaving column nullable."
            continue
        fi
        null_count=$(echo "$null_count" | tr -d '[:space:]')
        if [ -z "$null_count" ]; then
            log_warning "Unexpected NULL count result for ${schema_name}.${table_name}.${column_name}; leaving column nullable."
            continue
        fi
        if [ "$null_count" = "0" ]; then
            set +e
            set_sql=$(printf 'ALTER TABLE "%s"."%s" ALTER COLUMN "%s" SET NOT NULL;' "$schema_name" "$table_name" "$column_name")
            if run_psql_command_with_fallback "Reinstating NOT NULL constraint on ${schema_name}.${table_name}.${column_name}" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$set_sql"; then
                log_success "Reinstated NOT NULL constraint on ${schema_name}.${table_name}.${column_name}."
            else
                log_warning "Failed to reinstate NOT NULL constraint on ${schema_name}.${table_name}.${column_name}; manual review required."
            fi
            set -e
        else
            log_warning "Column ${schema_name}.${table_name}.${column_name} has ${null_count} NULL values after data restore."
            log_warning "Please backfill values, for example:"
            log_warning "  UPDATE \"${schema_name}\".\"${table_name}\" SET \"${column_name}\" = COALESCE(/* derive value */, 'default_value') WHERE \"${column_name}\" IS NULL;"
            log_warning "After backfilling, rerun the migration or apply 'ALTER TABLE \"${schema_name}\".\"${table_name}\" ALTER COLUMN \"${column_name}\" SET NOT NULL;' manually."
        fi
    done <"$RELAXED_NOT_NULL_FILE"
    rm -f "$RELAXED_NOT_NULL_FILE"
    RELAXED_NOT_NULL_FILE=""
fi

[ -n "$TARGET_SCHEMA_BEFORE_FILE" ] && rm -f "$TARGET_SCHEMA_BEFORE_FILE"
[ -n "$TARGET_SCHEMA_AFTER_FILE" ] && rm -f "$TARGET_SCHEMA_AFTER_FILE"
TARGET_SCHEMA_BEFORE_FILE=""
TARGET_SCHEMA_AFTER_FILE=""

# Step 4: Sync auth users from source to target if requested
if [ "$INCLUDE_USERS" = "true" ] && [ "$RESTORE_SUCCESS" = "true" ]; then
    log_info "Step 4/4: Syncing auth users from source to target..."
    log_to_file "$LOG_FILE" "Syncing auth users from source to target"
    
    # Ensure we're linked to target
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD" 2>/dev/null; then
        log_info "Re-linking to target project for auth users sync..."
        if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
            log_error "Failed to link to target project for auth users sync"
            exit 1
        fi
    fi
    
    # Get pooler hosts using environment names (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$TARGET_ENV" 2>/dev/null || get_pooler_host "$TARGET_REF")
    SOURCE_POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    if [ -z "$SOURCE_POOLER_HOST" ]; then
        SOURCE_POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    # Get source user count
    SOURCE_USER_COUNT=$(PGPASSWORD="$SOURCE_PASSWORD" psql \
        -h "$SOURCE_POOLER_HOST" \
        -p 6543 \
        -U "postgres.${SOURCE_REF}" \
        -d postgres \
        -t -A \
        -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
    
    if [ "$SOURCE_USER_COUNT" = "0" ]; then
        log_warning "Source has 0 auth users"
        
        # If both --data and --users are used with replace mode, clear target to match source
        if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
            log_info "Clearing all auth users from target to match source (full sync)..."
            TARGET_USER_COUNT_BEFORE=$(PGPASSWORD="$TARGET_PASSWORD" psql \
                -h "$POOLER_HOST" \
                -p 6543 \
                -U "postgres.${TARGET_REF}" \
                -d postgres \
                -t -A \
                -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
            
            if [ "$TARGET_USER_COUNT_BEFORE" -gt 0 ]; then
                PGPASSWORD="$TARGET_PASSWORD" psql \
                    -h "$POOLER_HOST" \
                    -p 6543 \
                    -U "postgres.${TARGET_REF}" \
                    -d postgres \
                    -c "
                    DELETE FROM auth.refresh_tokens;
                    DELETE FROM auth.sessions;
                    DELETE FROM auth.identities;
                    DELETE FROM auth.users;
                    " 2>&1 | tee -a "$LOG_FILE" || {
                    log_warning "Failed to clear auth data via pooler, trying direct connection..."
                    if check_direct_connection_available "$TARGET_REF"; then
                        PGPASSWORD="$TARGET_PASSWORD" psql \
                            -h db.${TARGET_REF}.supabase.co \
                            -p 5432 \
                            -U "postgres.${TARGET_REF}" \
                            -d postgres \
                            -c "
                            DELETE FROM auth.refresh_tokens;
                            DELETE FROM auth.sessions;
                            DELETE FROM auth.identities;
                            DELETE FROM auth.users;
                            " 2>&1 | tee -a "$LOG_FILE" || log_warning "Failed to clear auth data"
                    fi
                }
                log_success "Cleared all auth users from target (target now matches source: 0 users)"
            fi
        else
            log_info "Delta mode enabled: existing auth users in target will be preserved."
        fi
        log_warning "Skipping auth users sync (source has no users)"
    else
        log_info "Source has $SOURCE_USER_COUNT auth user(s)"
        
        # Check current user count in target
        TARGET_USER_COUNT_BEFORE=$(PGPASSWORD="$TARGET_PASSWORD" psql \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U postgres.${TARGET_REF} \
            -d postgres \
            -t -A \
            -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
        log_info "Current auth users in target: $TARGET_USER_COUNT_BEFORE"
        
        # If both --data and --users are used with replace mode, do a FULL SYNC (replace all users)
        if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
            log_info "Full sync mode: Clearing existing auth data in target to ensure exact match with source..."
            log_warning "This will remove all existing auth users, identities, refresh_tokens, and sessions in target"
            
            # Clear existing auth data first (in correct order to respect foreign keys)
            if PGPASSWORD="$TARGET_PASSWORD" psql \
                -h "$POOLER_HOST" \
                -p 6543 \
                -U "postgres.${TARGET_REF}" \
                -d postgres \
                -c "
                -- Delete in order to respect foreign keys
                DELETE FROM auth.refresh_tokens;
                DELETE FROM auth.sessions;
                DELETE FROM auth.identities;
                DELETE FROM auth.users;
                " 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Cleared existing auth data from target"
            else
                log_warning "Failed to clear auth data via pooler, trying direct connection..."
                if check_direct_connection_available "$TARGET_REF"; then
                    if PGPASSWORD="$TARGET_PASSWORD" psql \
                        -h db.${TARGET_REF}.supabase.co \
                        -p 5432 \
                        -U "postgres.${TARGET_REF}" \
                        -d postgres \
                        -c "
                        DELETE FROM auth.refresh_tokens;
                        DELETE FROM auth.sessions;
                        DELETE FROM auth.identities;
                        DELETE FROM auth.users;
                        " 2>&1 | tee -a "$LOG_FILE"; then
                        log_success "Cleared existing auth data from target (direct connection)"
                    else
                        log_error "Failed to clear auth data - aborting auth users sync to prevent data loss"
                        exit 1
                    fi
                else
                    log_error "Failed to clear auth data - aborting auth users sync to prevent data loss"
                    exit 1
                fi
            fi
        else
            log_info "Delta mode enabled: existing auth users in target will be preserved (no deletions)."
        fi
        
        # Use the existing auth_users.dump file (created in Step 2a) to restore all users
        if [ -f "$AUTH_USERS_DUMP" ] && [ -s "$AUTH_USERS_DUMP" ]; then
            if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
                log_info "Restoring all auth users from source (replace mode)..."
            else
                log_info "Copying auth users from source (delta/append mode)..."
            fi
            
            RESTORE_OUTPUT=$(mktemp)
            set +e
            PGPASSWORD="$TARGET_PASSWORD" pg_restore \
                -h "$POOLER_HOST" \
                -p 6543 \
                -U "postgres.${TARGET_REF}" \
                -d postgres \
                --no-owner \
                --no-acl \
                --data-only \
                --disable-triggers \
                "$AUTH_USERS_DUMP" \
                2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
            RESTORE_EXIT_CODE=${PIPESTATUS[0]}
            set -e
            
            # Check for fatal errors (connection issues, etc.)
            has_fatal_error=false
            if grep -qiE "(FATAL:|could not connect|connection.*failed|authentication failed|could not translate host)" "$RESTORE_OUTPUT" 2>/dev/null && \
               ! grep -qiE "SET.*log_min_messages.*fatal|Command was:.*fatal" "$RESTORE_OUTPUT" 2>/dev/null; then
                has_fatal_error=true
            fi

            auth_duplicates=false
            if [ "$REPLACE_TARGET_DATA" != "true" ] && grep -qiE "duplicate key value violates unique constraint" "$RESTORE_OUTPUT" 2>/dev/null; then
                auth_duplicates=true
                log_warning "Duplicate auth users detected in target; existing records were preserved."
            fi
            
            # Verify final count
            TARGET_USER_COUNT_AFTER=$(PGPASSWORD="$TARGET_PASSWORD" psql \
                -h "$POOLER_HOST" \
                -p 6543 \
                -U "postgres.${TARGET_REF}" \
                -d postgres \
                -t -A \
                -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
            
            if [ "$has_fatal_error" = "true" ]; then
                log_error "Auth users sync failed with fatal errors"
                log_error "Check the logs above for connection or authentication issues"
                
                # Try direct connection if pooler failed
                if check_direct_connection_available "$TARGET_REF"; then
                    log_info "Retrying auth users restore via direct connection..."
                    
                    # Clear again if needed (in case partial restore happened)
                    if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ] && [ "$TARGET_USER_COUNT_AFTER" -lt "$SOURCE_USER_COUNT" ]; then
                        log_info "Clearing partial data and retrying..."
                        PGPASSWORD="$TARGET_PASSWORD" psql \
                            -h db.${TARGET_REF}.supabase.co \
                            -p 5432 \
                            -U "postgres.${TARGET_REF}" \
                            -d postgres \
                            -c "
                            DELETE FROM auth.refresh_tokens;
                            DELETE FROM auth.sessions;
                            DELETE FROM auth.identities;
                            DELETE FROM auth.users;
                            " 2>&1 | tee -a "$LOG_FILE" || log_warning "Failed to clear auth data"
                    fi
                    
                    RESTORE_OUTPUT=$(mktemp)
                    set +e
        PGPASSWORD="$TARGET_PASSWORD" pg_restore \
            -h "db.${TARGET_REF}.supabase.co" \
            -p 5432 \
            -U "postgres.${TARGET_REF}" \
                        -d postgres \
                        --no-owner \
                        --no-acl \
                        --data-only \
                        --disable-triggers \
                        "$AUTH_USERS_DUMP" \
                        2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
                    RESTORE_EXIT_CODE=${PIPESTATUS[0]}
                    set -e
                    
                    TARGET_USER_COUNT_AFTER=$(PGPASSWORD="$TARGET_PASSWORD" psql \
                        -h db.${TARGET_REF}.supabase.co \
                        -p 5432 \
                        -U "postgres.${TARGET_REF}" \
                        -d postgres \
                        -t -A \
                        -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
                fi
            fi
            
            # Verify sync was successful
            if [ "$INCLUDE_DATA" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
                # Full sync mode: target must match source exactly
                if [ "$TARGET_USER_COUNT_AFTER" = "$SOURCE_USER_COUNT" ]; then
                    log_success "Auth users sync completed successfully:"
                    log_info "  Target now has: $TARGET_USER_COUNT_AFTER user(s) (matches source exactly)"
                    log_info "  Users removed from target: $((TARGET_USER_COUNT_BEFORE > TARGET_USER_COUNT_AFTER ? TARGET_USER_COUNT_BEFORE - TARGET_USER_COUNT_AFTER : 0))"
                    log_info "  Users added to target: $TARGET_USER_COUNT_AFTER"
                else
                    log_error "Auth users sync FAILED - target has $TARGET_USER_COUNT_AFTER user(s) but source has $SOURCE_USER_COUNT"
                    log_error "Target should match source exactly in full sync mode"
                    exit 1
                fi
            else
                # Incremental mode: just add missing users
                ACTUAL_COPIED=$((TARGET_USER_COUNT_AFTER - TARGET_USER_COUNT_BEFORE))
                if [ "$ACTUAL_COPIED" -lt 0 ]; then
                    ACTUAL_COPIED=0
                fi
                if [ "$ACTUAL_COPIED" -gt 0 ] || [ "$RESTORE_EXIT_CODE" -eq 0 ] || [ "$auth_duplicates" = "true" ]; then
                    log_success "Auth users copy completed:"
                    log_info "  New users added: $ACTUAL_COPIED user(s)"
                    log_info "  Target now has: $TARGET_USER_COUNT_AFTER user(s) (was $TARGET_USER_COUNT_BEFORE, source had $SOURCE_USER_COUNT)"
                else
                    log_warning "No new users were added (all users may already exist in target)"
                fi
            fi
            
            rm -f "$RESTORE_OUTPUT"
        else
            log_error "Auth users dump file not found - cannot sync auth users"
            log_info "Note: Auth users dump should have been created in Step 2a"
            exit 1
        fi
    fi
fi

supabase unlink --yes 2>/dev/null || true

# Generate HTML report
if [ "$RESTORE_SUCCESS" = "true" ]; then
    STATUS="success"
    if [ "$INCLUDE_DATA" = "true" ] && [ "$INCLUDE_USERS" = "true" ]; then
        COMPONENT_NAME="Database Migration (Schema + Data + Auth Users)"
        log_success "✅ Database schema + data + auth users migration completed successfully"
        log_to_file "$LOG_FILE" "Database schema + data + auth users migration completed successfully"
    elif [ "$INCLUDE_DATA" = "true" ]; then
        COMPONENT_NAME="Database Migration (Schema + Data)"
        log_success "✅ Database schema + data migration completed successfully"
        log_to_file "$LOG_FILE" "Database schema + data migration completed successfully"
    elif [ "$INCLUDE_USERS" = "true" ]; then
        COMPONENT_NAME="Database Migration (Schema + Auth Users)"
        log_success "✅ Database schema + auth users migration completed successfully"
        log_to_file "$LOG_FILE" "Database schema + auth users migration completed successfully"
    else
        COMPONENT_NAME="Database Migration (Schema Only)"
        log_success "✅ Database schema-only migration completed successfully"
        log_to_file "$LOG_FILE" "Database schema migration completed successfully"
    fi
else
    STATUS="failed"
    COMPONENT_NAME="Database Migration"
    log_error "❌ Database migration failed!"
    log_to_file "$LOG_FILE" "Database migration failed"
fi

# Collect migration statistics
MIGRATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
if [ "$RESTORE_SUCCESS" = "true" ]; then
    MIGRATED_COUNT=1  # Schema migrated successfully
else
    FAILED_COUNT=1
fi

# Generate details section
DETAILS_SECTION=$(format_migration_details "$LOG_FILE" "database")

# Generate HTML report
export MIGRATED_COUNT SKIPPED_COUNT FAILED_COUNT DETAILS_SECTION
generate_migration_html_report \
    "$MIGRATION_DIR" \
    "$COMPONENT_NAME" \
    "$SOURCE_ENV" \
    "$TARGET_ENV" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$STATUS" \
    ""

log_info "HTML report generated: $MIGRATION_DIR/result.html"

if [ "$RESTORE_SUCCESS" = "true" ]; then
    echo "$MIGRATION_DIR"  # Return migration directory for use by other scripts
    exit 0
else
    exit 1
fi

