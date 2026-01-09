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

    # First, try database connectivity via shared pooler (no API calls)
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
                    -v ON_ERROR_STOP=on \
                    -c "$command" \
                    >>"$LOG_FILE" 2>"$tmp_err"; then
                    success=true
                    break
                else
                    log_warning "${description} failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -n 1 "$tmp_err")"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API"
        fi
    fi

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
            log_warning "Query execution failed via ${label}: $(head -n 1 "$tmp_err")"
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
                    log_warning "Query execution failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -n 1 "$tmp_err")"
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
            log_warning "${description} failed via ${label}: $(head -n 1 "$tmp_err")"
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
                    log_warning "${description} failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -n 1 "$tmp_err")"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API"
        fi
    fi

    rm -f "$tmp_err"
    $success && return 0 || return 1
}

#!/bin/bash
# Database Migration Script
# Migrates database schema (and optionally data) from source to target
# Can be used independently or as part of a complete migration
# Default: schema-only migration (no data)
# Use --data flag to include data migration

unset INCLUDE_TABLES 2>/dev/null || true
set -euo pipefail
declare -a INCLUDE_TABLES=()

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
# Decoupled increment modes:
# - SCHEMA_CLEAN_MODE: when true, schema restore uses --clean --if-exists (default: true)
# - DATA_INCREMENTAL_MODE: when true, data restore prefers delta/append semantics
SCHEMA_CLEAN_MODE=true
DATA_INCREMENTAL_MODE=false
TARGET_DATA_BACKUP=""
TARGET_DATA_BACKUP_SQL=""
TARGET_SCHEMA_BEFORE_FILE=""
TARGET_SCHEMA_AFTER_FILE=""
RELAXED_NOT_NULL_FILE=""

AUTO_CONFIRM_COMPONENT="${AUTO_CONFIRM:-false}"
SKIP_COMPONENT_CONFIRM="${SKIP_COMPONENT_CONFIRM:-false}"

# Supabase-managed schemas that are handled by dedicated scripts or platform defaults
PROTECTED_SCHEMAS=(auth vault storage realtime pgbouncer graphql_public supabase_functions supabase_functions_api pgsodium supavisor)

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required but not found in PATH."
    exit 1
fi

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
        # Backwards-compat: legacy --increment toggles data increment only (schema remains clean by default)
        --increment|--incremental)
            DATA_INCREMENTAL_MODE=true
            ;;
        # New flags: explicit split of schema vs data increment behavior
        --increment-data)
            DATA_INCREMENTAL_MODE=true
            ;;
        --increment-schema)
            SCHEMA_CLEAN_MODE=false
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT="true"
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
Usage: $0 <source_env> <target_env> [migration_dir] [--data] [--users] [--backup] [--replace-data] [--increment-data] [--increment-schema]

Migrates database schema (and optionally data and auth users) from source to target

Default Behavior:
  - Schema: Clean sync (drop/recreate changed objects) for parity unless --increment-schema is provided.
  - Data: Not migrated unless --data is provided. With --data, default is delta/append unless --replace-data is provided.
  - Auth: Use --users to include auth users/identities.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  --data             Include data migration (default: schema only)
  --replace-data     Replace target data (destructive). Without this flag, data migrations run in append/delta mode.
  --users            Include authentication users, roles, and policies
  --backup           Create backup of target before migration (optional)
  --increment-data   Prefer incremental/delta data operations (append-only)
  --increment-schema Prefer incremental/non-destructive schema (skip --clean). Not recommended if parity is required.

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

if [ "$DATA_INCREMENTAL_MODE" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
    log_warning "Incremental mode requested but --replace-data supplied; replace mode will override incremental behaviour for data sections."
fi

log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
log_info "Mode: $MIGRATION_MODE"
log_info "Schema clean mode: $SCHEMA_CLEAN_MODE"
log_info "Data incremental mode: $DATA_INCREMENTAL_MODE"
log_to_file "$LOG_FILE" "Schema clean mode: $SCHEMA_CLEAN_MODE"
log_to_file "$LOG_FILE" "Data incremental mode: $DATA_INCREMENTAL_MODE"
echo ""

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    if ! component_prompt_proceed "Database Migration" "Proceed with database migration from $SOURCE_ENV to $TARGET_ENV?"; then
        log_warning "Database migration skipped by user request."
        log_to_file "$LOG_FILE" "Database migration skipped by user."
        exit 0
    fi
fi

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
        rollback_mode="schema"
        if [ "$INCLUDE_DATA" = "true" ]; then
            rollback_mode="full"
        fi
        if ! capture_target_state_for_rollback "$TARGET_REF" "$TARGET_PASSWORD" "$MIGRATION_DIR/rollback_db.sql" "$rollback_mode"; then
            if [ "$rollback_mode" = "full" ]; then
                log_warning "Full rollback capture failed, attempting schema-only fallback..."
                capture_target_state_for_rollback "$TARGET_REF" "$TARGET_PASSWORD" "$MIGRATION_DIR/rollback_db.sql" "schema" || \
                    log_warning "Schema-only rollback capture also failed."
            else
                log_warning "Schema-only rollback capture failed."
            fi
        else
            log_success "Rollback SQL script created: $MIGRATION_DIR/rollback_db.sql"
        fi
        
        supabase unlink --yes 2>/dev/null || true
    fi
fi

# Step 2: Dump source database
if [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 1/3: Dumping source database (schema + data)..."
    log_to_file "$LOG_FILE" "Dumping source database (schema + data)"
    
    DUMP_FILE="$MIGRATION_DIR/source_full.dump"
    
    # CLI linking is optional - direct pg_dump connections don't require it
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed (Unauthorized) - continuing with direct database connections"
        log_info "Direct pg_dump connections don't require CLI authentication"
    fi
    
    # Get pooler host using environment name (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    PG_DUMP_ARGS=(-d postgres -Fc --verbose -f "$DUMP_FILE")
    for schema in "${PROTECTED_SCHEMAS[@]}"; do
        PG_DUMP_ARGS+=(--exclude-schema="$schema")
    done

    log_info "Creating full database dump (protected schemas excluded: ${PROTECTED_SCHEMAS[*]})..."
    if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        "${PG_DUMP_ARGS[@]}"; then
        log_warning "Failed to create full dump via any connection"
    fi
else
    log_info "Step 1/3: Dumping source schema (structure only)..."
    log_to_file "$LOG_FILE" "Dumping source schema (structure only)"
    
    DUMP_FILE="$MIGRATION_DIR/source_schema.dump"
    
    # CLI linking is optional - direct pg_dump connections don't require it
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed (Unauthorized) - continuing with direct database connections"
        log_info "Direct pg_dump connections don't require CLI authentication"
    fi
    
    # Get pooler host using environment name (more reliable)
    POOLER_HOST=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
    if [ -z "$POOLER_HOST" ]; then
        POOLER_HOST="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    PG_DUMP_ARGS=(-d postgres -Fc --schema-only --no-owner --verbose -f "$DUMP_FILE")
    for schema in "${PROTECTED_SCHEMAS[@]}"; do
        PG_DUMP_ARGS+=(--exclude-schema="$schema")
    done

    log_info "Creating schema-only dump (protected schemas excluded: ${PROTECTED_SCHEMAS[*]})..."
    if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        "${PG_DUMP_ARGS[@]}"; then
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
    
    # CLI linking is optional - direct connections don't require it
    if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed - continuing with direct database connections"
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
    
    # CLI linking is optional - direct pg_restore connections don't require it
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed (Unauthorized) - continuing with direct database connections"
        log_info "Direct pg_restore connections don't require CLI authentication"
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
    
    # CLI linking is optional - direct pg_restore connections don't require it
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed (Unauthorized) - continuing with direct database connections"
        log_info "Direct pg_restore connections don't require CLI authentication"
    fi
fi

# Restore dump
RESTORE_ARGS=(--verbose)
RESTORE_SUCCESS=false
RESTORE_OUTPUT=$(mktemp)

RESTORE_ARGS+=(--schema-only --no-owner)
if [ "$INCLUDE_DATA" = "true" ]; then
    log_info "Step 3/3: Restoring dump to target..."
else
    log_info "Step 3/3: Restoring schema dump to target..."
fi
# Schema restore strategy (clean by default unless explicitly disabled)
if [ "$SCHEMA_CLEAN_MODE" = "true" ]; then
    RESTORE_ARGS+=(--clean --if-exists)
else
    log_info "Schema incremental mode: skipping --clean on schema restore to avoid dropping target objects."
fi

DUPLICATE_ALLOWED=false
if [ "$DATA_INCREMENTAL_MODE" = "true" ]; then
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
    SQL_BACKUP_ARGS=(-d postgres --data-only --inserts --column-inserts --no-owner -f "$TARGET_DATA_BACKUP_SQL")
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
    error_lines=$(grep -iE "error:" "$RESTORE_OUTPUT" 2>/dev/null | grep -viE "(errors ignored|already exists|does not exist|permission denied to set role|must be owner of)" || echo "")
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
    
    DATA_RESTORE_ARGS=(--verbose --no-owner --data-only -d postgres)
    for schema in "${PROTECTED_SCHEMAS[@]}"; do
        DATA_RESTORE_ARGS+=(--exclude-schema="$schema")
    done
    if [ ${#INCLUDE_TABLES[@]} -gt 0 ]; then
        for table in "${INCLUDE_TABLES[@]}"; do
            DATA_RESTORE_ARGS+=(--table="$table")
        done
    fi
    
    DATA_RESTORE_SUCCESS=false
    
    if [ "$REPLACE_TARGET_DATA" = "true" ]; then
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
            
            log_warning "Data restore via ${label} failed (exit code $DATA_RESTORE_EXIT)"
            if [ -s "$restore_log" ]; then
                tail -n 5 "$restore_log" | while read line; do
                    log_warning "  $line"
                done
            fi
            rm -f "$restore_log"
        done < <(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    fi
    
    if [ "$DATA_RESTORE_SUCCESS" != "true" ]; then
        log_info "Using incremental SQL restore with ON CONFLICT DO NOTHING..."
        incremental_sql=$(mktemp)
        processed_sql=$(mktemp)
        TABLE_FILTER_ARGS=()
        if [ ${#INCLUDE_TABLES[@]} -gt 0 ]; then
            for t in "${INCLUDE_TABLES[@]}"; do
                TABLE_FILTER_ARGS+=(--table="$t")
            done
        fi
        # Build pg_restore command with proper handling of empty array
        pg_restore_cmd=("pg_restore" "--data-only" "--no-owner" "--no-privileges")
        if [ ${#TABLE_FILTER_ARGS[@]} -gt 0 ]; then
            pg_restore_cmd+=("${TABLE_FILTER_ARGS[@]}")
        fi
        pg_restore_cmd+=("-f" "$incremental_sql" "$DUMP_FILE")
        if "${pg_restore_cmd[@]}"; then
            if [ ${#INCLUDE_TABLES[@]} -gt 0 ]; then
                TARGET_TABLE_LIST=$(for t in "${INCLUDE_TABLES[@]}"; do printf "'%s'," "$t"; done)
                TARGET_TABLE_LIST="${TARGET_TABLE_LIST%,}"
                prune_sql=$(mktemp)
                {
                    echo "DELETE FROM public._policy_dump_queue;"
                    echo "CREATE TEMP TABLE _inserted_tables(table_name text primary key);"
                } >"$prune_sql"
                "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" "$incremental_sql" "$processed_sql"
                cat <<'SQL' >>"$processed_sql"
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT DISTINCT table_schema || '.' || table_name AS full_name
             FROM information_schema.tables
             WHERE table_schema NOT IN ('pg_catalog','information_schema') LOOP
        BEGIN
            EXECUTE 'INSERT INTO _inserted_tables(table_name) VALUES ($1)' USING r.full_name;
        EXCEPTION WHEN unique_violation THEN
            NULL;
        END;
    END LOOP;
END $$;

SQL
            else
                "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" "$incremental_sql" "$processed_sql"
            fi
            if run_psql_script_with_fallback "Incremental data restore" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$processed_sql"; then
                log_success "Incremental data restore completed successfully."
                DATA_RESTORE_SUCCESS=true
            else
                log_error "Incremental SQL restore failed."
            fi
        else
            log_error "pg_restore could not produce SQL dump for incremental restore."
        fi
        rm -f "$incremental_sql" "$processed_sql"
    fi
    
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
    
    # CLI linking is optional - direct connections don't require it
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD" 2>/dev/null; then
        log_warning "Supabase CLI linking failed - continuing with direct database connections"
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
                --role=supabase_auth_admin \
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
            --role=supabase_auth_admin \
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

# Step 4: Detect and Apply Schema Differences (New Columns, Modified Columns, etc.)
# This step runs after restore to catch any schema changes that pg_restore might have missed
# pg_restore doesn't generate ALTER TABLE statements, so we need to detect and apply them manually
# ALWAYS RUN: Schema differences must be detected and applied regardless of restore success status
# This ensures new columns and schema changes are always migrated, even if restore had warnings
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4: Detecting and Applying Schema Differences"
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
    SOURCE_COLUMNS_FILE="$MIGRATION_DIR/source_columns.txt"
    TARGET_COLUMNS_FILE="$MIGRATION_DIR/target_columns.txt"
    SCHEMA_DIFF_SQL="$MIGRATION_DIR/schema_differences.sql"
    
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

# Step 4a: Migrate Storage RLS Policies (ALWAYS RUN - independent of restore success)
# Storage schema is excluded from main migration, so we need to migrate RLS policies separately
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4a: Migrating Storage RLS Policies"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Extracting storage RLS policies from source..."
log_to_file "$LOG_FILE" "Extracting storage RLS policies"

# Function to extract storage policies from source (improved query)
extract_storage_policies() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local output_file=$5
    
    # Improved query that handles all cases including public role
    local query="
        SELECT 
            'CREATE POLICY ' || quote_ident(pol.polname) || 
            ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) ||
            ' FOR ' || CASE pol.polcmd
                WHEN 'r' THEN 'SELECT'
                WHEN 'a' THEN 'INSERT'
                WHEN 'w' THEN 'UPDATE'
                WHEN 'd' THEN 'DELETE'
                WHEN '*' THEN 'ALL'
            END ||
            CASE 
                WHEN array_length(pol.polroles, 1) > 0 AND (pol.polroles != ARRAY[0]::oid[]) THEN
                    ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY rol.rolname)
                WHEN pol.polroles = ARRAY[0]::oid[] OR array_length(pol.polroles, 1) IS NULL THEN
                    ' TO public'
                ELSE ''
            END ||
            CASE 
                WHEN pol.polqual IS NOT NULL THEN
                    ' USING (' || pg_get_expr(pol.polqual, pol.polrelid) || ')'
                ELSE ''
            END ||
            CASE 
                WHEN pol.polwithcheck IS NOT NULL THEN
                    ' WITH CHECK (' || pg_get_expr(pol.polwithcheck, pol.polrelid) || ')'
                ELSE ''
            END || ';' as policy_sql
        FROM pg_policy pol
        JOIN pg_class c ON c.oid = pol.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
        WHERE n.nspname = 'storage'
          AND c.relname IN ('objects', 'buckets')
        GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, pol.polqual, pol.polrelid, pol.polwithcheck, pol.polroles
        ORDER BY c.relname, pol.polname;
    "
    
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
}

STORAGE_POLICIES_SQL="$MIGRATION_DIR/storage_policies.sql"
extract_storage_policies "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$STORAGE_POLICIES_SQL"

if [ -s "$STORAGE_POLICIES_SQL" ]; then
    POLICY_COUNT=$(grep -c "^CREATE POLICY" "$STORAGE_POLICIES_SQL" 2>/dev/null || echo "0")
    log_info "Found $POLICY_COUNT storage RLS policy(ies) to migrate"
    log_to_file "$LOG_FILE" "Found $POLICY_COUNT storage RLS policies to migrate"
    
    if [ "$POLICY_COUNT" -gt 0 ]; then
        # First, ensure RLS is enabled on storage.objects and storage.buckets
        log_info "Ensuring RLS is enabled on storage tables..."
        log_to_file "$LOG_FILE" "Ensuring RLS is enabled on storage tables"
        RLS_ENABLE_STORAGE_SQL="$MIGRATION_DIR/storage_rls_enable.sql"
        cat > "$RLS_ENABLE_STORAGE_SQL" << 'EOF'
-- Enable RLS on storage tables if not already enabled
ALTER TABLE IF EXISTS storage.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS storage.buckets ENABLE ROW LEVEL SECURITY;
EOF
        
        set +e
        if run_psql_script_with_fallback "Enabling RLS on storage tables" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$RLS_ENABLE_STORAGE_SQL"; then
            log_success "✓ RLS enabled on storage tables"
            log_to_file "$LOG_FILE" "RLS enabled on storage tables successfully"
        else
            log_warning "⚠ Some errors occurred while enabling RLS on storage tables (may already be enabled)"
            log_to_file "$LOG_FILE" "WARNING: Some errors occurred while enabling RLS on storage tables"
        fi
        set -e
        
        # Drop existing policies on target first (to avoid conflicts)
        log_info "Dropping existing storage policies on target (if any)..."
        log_to_file "$LOG_FILE" "Dropping existing storage policies on target"
        
        DROP_STORAGE_POLICIES_SQL="$MIGRATION_DIR/storage_policies_drop.sql"
        cat > "$DROP_STORAGE_POLICIES_SQL" << 'EOF'
-- Drop existing policies on storage.objects
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT policyname FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects')
    LOOP
        EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON storage.objects';
    END LOOP;
    
    -- Drop existing policies on storage.buckets
    FOR r IN (SELECT policyname FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'buckets')
    LOOP
        EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON storage.buckets';
    END LOOP;
END $$;
EOF
        
        set +e
        run_psql_script_with_fallback "Dropping existing storage policies" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$DROP_STORAGE_POLICIES_SQL" >/dev/null 2>&1
        set -e
        
        # Apply storage policies
        log_info "Applying storage RLS policies to target..."
        log_to_file "$LOG_FILE" "Applying storage RLS policies"
        set +e
        if run_psql_script_with_fallback "Applying storage policies" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$STORAGE_POLICIES_SQL"; then
            log_success "✓ Storage RLS policies applied successfully"
            log_to_file "$LOG_FILE" "Storage RLS policies applied successfully"
            
            # Verify policies were applied
            sleep 2  # Give database time to update
            TARGET_STORAGE_POLICY_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename IN ('objects', 'buckets');" 2>/dev/null | tr -d '[:space:]' || echo "0")
            
            if [ "$TARGET_STORAGE_POLICY_COUNT" = "$POLICY_COUNT" ]; then
                log_success "✓ Verified: All $POLICY_COUNT storage policies are now in target"
                log_to_file "$LOG_FILE" "SUCCESS: All storage policies migrated - $POLICY_COUNT policies"
            else
                log_warning "⚠ Policy count mismatch: Expected $POLICY_COUNT, found $TARGET_STORAGE_POLICY_COUNT"
                log_to_file "$LOG_FILE" "WARNING: Storage policy count mismatch - expected $POLICY_COUNT, found $TARGET_STORAGE_POLICY_COUNT"
            fi
        else
            log_warning "⚠ Some errors occurred while applying storage policies"
            log_warning "  Check the log file for details: $LOG_FILE"
            log_warning "  Storage policies SQL saved to: $STORAGE_POLICIES_SQL"
            log_to_file "$LOG_FILE" "WARNING: Some errors occurred while applying storage policies"
        fi
        set -e
    else
        log_info "No storage RLS policies found in source (this may be normal if using default Supabase policies)"
        log_to_file "$LOG_FILE" "No storage RLS policies found in source"
    fi
else
    log_warning "⚠ Failed to extract storage RLS policies from source"
    log_to_file "$LOG_FILE" "WARNING: Failed to extract storage RLS policies from source"
fi
echo ""

# Step 4b: Migrate Database Extensions
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4b: Migrating Database Extensions"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Extracting database extensions from source..."
log_to_file "$LOG_FILE" "Extracting database extensions"

# Function to extract extensions from source
extract_extensions() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local output_file=$5
    
    # Get all extensions (excluding default PostgreSQL extensions)
    local query="
        SELECT 'CREATE EXTENSION IF NOT EXISTS ' || quote_ident(extname) || 
               CASE WHEN extversion IS NOT NULL AND extversion != '' THEN 
                   ' VERSION ' || quote_literal(extversion) 
               ELSE '' END || ';' as extension_sql
        FROM pg_extension
        WHERE extname NOT IN ('plpgsql', 'uuid-ossp', 'pgcrypto', 'pgjwt', 'pg_stat_statements')
          AND extname NOT LIKE 'pg_%'
          AND extname NOT LIKE 'pl%'
        ORDER BY extname;
    "
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
}

EXTENSIONS_SQL="$MIGRATION_DIR/extensions.sql"
extract_extensions "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$EXTENSIONS_SQL"

if [ -s "$EXTENSIONS_SQL" ]; then
    EXTENSION_COUNT=$(grep -c "^CREATE EXTENSION" "$EXTENSIONS_SQL" 2>/dev/null || echo "0")
    log_info "Found $EXTENSION_COUNT extension(s) to migrate"
    log_to_file "$LOG_FILE" "Found $EXTENSION_COUNT extensions to migrate"
    
    if [ "$EXTENSION_COUNT" -gt 0 ]; then
        log_info "Applying extensions to target..."
        log_to_file "$LOG_FILE" "Applying extensions to target"
        set +e
        if run_psql_script_with_fallback "Applying extensions" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$EXTENSIONS_SQL"; then
            log_success "✓ Extensions applied successfully"
            log_to_file "$LOG_FILE" "Extensions applied successfully"
        else
            log_warning "⚠ Some extensions may require superuser privileges or may already exist"
            log_to_file "$LOG_FILE" "WARNING: Some extensions may require superuser privileges"
        fi
        set -e
    else
        log_info "No custom extensions found in source"
        log_to_file "$LOG_FILE" "No custom extensions found in source"
    fi
else
    log_info "No extensions found in source (or extraction failed)"
    log_to_file "$LOG_FILE" "No extensions found in source"
fi
echo ""

# Step 4c: Migrate All Grants and Permissions (ALWAYS RUN)
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4c: Migrating All Grants and Permissions"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Extracting all grants and permissions from source..."
log_to_file "$LOG_FILE" "Extracting all grants and permissions"

# Function to extract ALL grants from source database
extract_all_grants() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local output_file=$5
    
    # Extract grants for tables, sequences, functions, and schemas
    local query="
        -- Table grants
        SELECT 'GRANT ' || privilege_type || 
               CASE WHEN is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END ||
               ' ON TABLE ' || quote_ident(table_schema) || '.' || quote_ident(table_name) ||
               ' TO ' || quote_ident(grantee) || ';' as grant_sql
        FROM information_schema.table_privileges
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema NOT LIKE 'pg_toast%'
          AND table_schema != 'storage'
          AND table_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        
        UNION ALL
        
        -- Sequence grants
        SELECT 'GRANT ' || privilege_type ||
               CASE WHEN is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END ||
               ' ON SEQUENCE ' || quote_ident(sequence_schema) || '.' || quote_ident(sequence_name) ||
               ' TO ' || quote_ident(grantee) || ';' as grant_sql
        FROM information_schema.usage_privileges
        WHERE object_type = 'SEQUENCE'
          AND object_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND object_schema NOT LIKE 'pg_toast%'
          AND object_schema != 'storage'
          AND object_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        
        UNION ALL
        
        -- Function grants
        SELECT 'GRANT EXECUTE ON FUNCTION ' || 
               quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' ||
               pg_get_function_identity_arguments(p.oid) || ')' ||
               ' TO ' || quote_ident(grantee) || ';' as grant_sql
        FROM information_schema.routine_privileges rp
        JOIN pg_proc p ON p.proname = rp.routine_name
        JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = rp.routine_schema
        WHERE rp.routine_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND rp.routine_schema NOT LIKE 'pg_toast%'
          AND rp.routine_schema != 'storage'
          AND rp.routine_schema != 'auth'
          AND rp.grantee NOT IN ('postgres', 'PUBLIC')
          AND rp.privilege_type = 'EXECUTE'
        
        UNION ALL
        
        -- Schema usage grants (simplified - extract from information_schema if available)
        SELECT DISTINCT 'GRANT USAGE ON SCHEMA ' || quote_ident(table_schema) ||
               ' TO ' || quote_ident(grantee) || ';' as grant_sql
        FROM information_schema.usage_privileges
        WHERE object_type = 'SCHEMA'
          AND object_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND object_schema NOT LIKE 'pg_toast%'
          AND object_schema != 'storage'
          AND object_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        
        ORDER BY grant_sql;
    "
    
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
}

# Extract all grants from source
ALL_GRANTS_SQL="$MIGRATION_DIR/all_grants.sql"
extract_all_grants "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$ALL_GRANTS_SQL"

if [ -s "$ALL_GRANTS_SQL" ]; then
    GRANT_COUNT=$(grep -c "^GRANT" "$ALL_GRANTS_SQL" 2>/dev/null || echo "0")
    log_info "Found $GRANT_COUNT grant(s) to migrate"
    log_to_file "$LOG_FILE" "Found $GRANT_COUNT grants to migrate"
    
    if [ "$GRANT_COUNT" -gt 0 ]; then
        # Count by type
        TABLE_GRANTS=$(grep -c "ON TABLE" "$ALL_GRANTS_SQL" 2>/dev/null || echo "0")
        SEQUENCE_GRANTS=$(grep -c "ON SEQUENCE" "$ALL_GRANTS_SQL" 2>/dev/null || echo "0")
        FUNCTION_GRANTS=$(grep -c "ON FUNCTION" "$ALL_GRANTS_SQL" 2>/dev/null || echo "0")
        SCHEMA_GRANTS=$(grep -c "ON SCHEMA" "$ALL_GRANTS_SQL" 2>/dev/null || echo "0")
        
        log_info "  Grant breakdown: Tables=$TABLE_GRANTS, Sequences=$SEQUENCE_GRANTS, Functions=$FUNCTION_GRANTS, Schemas=$SCHEMA_GRANTS"
        log_to_file "$LOG_FILE" "Grants breakdown: Tables=$TABLE_GRANTS, Sequences=$SEQUENCE_GRANTS, Functions=$FUNCTION_GRANTS, Schemas=$SCHEMA_GRANTS"
        
        # Apply grants to target
        log_info "Applying grants to target..."
        set +e
        if run_psql_script_with_fallback "Applying all grants" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$ALL_GRANTS_SQL"; then
            log_success "✓ All grants applied successfully"
            log_to_file "$LOG_FILE" "SUCCESS: All grants applied"
        else
            log_warning "⚠ Some errors occurred while applying grants (some may already exist)"
            log_to_file "$LOG_FILE" "WARNING: Some grants may not have been applied"
        fi
        set -e
    else
        log_info "No custom grants found (using default permissions)"
        log_to_file "$LOG_FILE" "No custom grants to migrate"
    fi
else
    log_warning "⚠ Could not extract grants from source"
    log_to_file "$LOG_FILE" "WARNING: Could not extract grants"
fi

log_info ""

# Step 4d: Migrate Cron Jobs (pg_cron)
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4d: Migrating Cron Jobs (pg_cron)"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Extracting cron jobs from source..."
log_to_file "$LOG_FILE" "Extracting cron jobs from source"

# Function to extract cron jobs from source
extract_cron_jobs() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local output_file=$5
    
    # Check if pg_cron extension exists first
    local cron_exists=$(run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "
        SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');
    " 2>/dev/null | tr -d '[:space:]' || echo "false")
    
    if [ "$cron_exists" = "t" ] || [ "$cron_exists" = "true" ]; then
        # Get all cron jobs
        local query="
            SELECT 'SELECT cron.schedule(' || quote_literal(jobname) || ', ' || 
                   quote_literal(schedule) || ', ' || quote_literal(command) || ');' as cron_sql
            FROM cron.job
            WHERE jobname IS NOT NULL
            ORDER BY jobid;
        "
        run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
    else
        echo "" > "$output_file"
    fi
}

CRON_JOBS_SQL="$MIGRATION_DIR/cron_jobs.sql"
extract_cron_jobs "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$CRON_JOBS_SQL"

if [ -s "$CRON_JOBS_SQL" ] && [ "$(grep -c "^SELECT cron.schedule" "$CRON_JOBS_SQL" 2>/dev/null || echo "0")" -gt 0 ]; then
    CRON_COUNT=$(grep -c "^SELECT cron.schedule" "$CRON_JOBS_SQL" 2>/dev/null || echo "0")
    log_info "Found $CRON_COUNT cron job(s) to migrate"
    log_to_file "$LOG_FILE" "Found $CRON_COUNT cron jobs to migrate"
    
    if [ "$CRON_COUNT" -gt 0 ]; then
        # Check if pg_cron exists in target
        TARGET_CRON_EXISTS=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
            SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');
        " 2>/dev/null | tr -d '[:space:]' || echo "false")
        
        if [ "$TARGET_CRON_EXISTS" != "t" ] && [ "$TARGET_CRON_EXISTS" != "true" ]; then
            log_info "Installing pg_cron extension in target..."
            set +e
            run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "CREATE EXTENSION IF NOT EXISTS pg_cron;" >/dev/null 2>&1
            set -e
        fi
        
        # Drop existing cron jobs first
        log_info "Dropping existing cron jobs on target..."
        log_to_file "$LOG_FILE" "Dropping existing cron jobs on target"
        set +e
        run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
            SELECT cron.unschedule(jobid) FROM cron.job;
        " >/dev/null 2>&1 || true
        set -e
        
        log_info "Applying cron jobs to target..."
        log_to_file "$LOG_FILE" "Applying cron jobs to target"
        set +e
        if run_psql_script_with_fallback "Applying cron jobs" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$CRON_JOBS_SQL"; then
            log_success "✓ Cron jobs applied successfully"
            log_to_file "$LOG_FILE" "Cron jobs applied successfully"
        else
            log_warning "⚠ Some cron jobs may require pg_cron extension or superuser privileges"
            log_to_file "$LOG_FILE" "WARNING: Some cron jobs may require pg_cron extension"
        fi
        set -e
    fi
else
    log_info "No cron jobs found in source (pg_cron may not be installed or no jobs configured)"
    log_to_file "$LOG_FILE" "No cron jobs found in source"
fi
echo ""

# Step 5: Verify and retry policies/roles if needed
if [ "$RESTORE_SUCCESS" = "true" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 5: Verifying Policies and Roles"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    
    log_info "Verifying RLS policies and roles migration..."
    log_to_file "$LOG_FILE" "Verifying RLS policies and roles migration"
    
    # Function to count policies in a database (ALL schemas, not just public)
    count_policies() {
        local ref=$1
        local password=$2
        local pooler_region=$3
        local pooler_port=$4
        
        # Count policies from ALL schemas (not just public) - use pg_policy directly
        local query="
            SELECT COUNT(*) 
            FROM pg_policy pol
            JOIN pg_class c ON c.oid = pol.polrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
              AND n.nspname NOT LIKE 'pg_toast%'
              AND n.nspname != 'storage';  -- Storage policies counted separately
        "
        run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null | tr -d '[:space:]' || echo "0"
    }
    
    # Function to count roles in a database (excluding system roles)
    count_roles() {
        local ref=$1
        local password=$2
        local pooler_region=$3
        local pooler_port=$4
        
        local query="SELECT COUNT(*) FROM pg_roles WHERE rolname NOT IN ('postgres', 'pg_database_owner', 'pg_read_all_data', 'pg_write_all_data', 'pg_monitor', 'pg_read_all_settings', 'pg_read_all_stats', 'pg_stat_scan_tables', 'pg_read_server_files', 'pg_write_server_files', 'pg_execute_server_program', 'pg_signal_backend', 'pg_checkpoint', 'pg_use_reserved_connections', 'pg_create_subscription', 'pg_replication', 'authenticator', 'anon', 'authenticated', 'service_role', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_functions_admin', 'supabase_realtime_admin', 'supabase_replication_admin', 'supabase_read_only_user', 'dashboard_user') AND rolname NOT LIKE 'pg_%' AND rolname NOT LIKE 'rds_%';"
        run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null | tr -d '[:space:]' || echo "0"
    }
    
    # Get policy and role counts from source
    log_info "Counting policies and roles in source database..."
    SOURCE_POLICY_COUNT=$(count_policies "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    SOURCE_ROLE_COUNT=$(count_roles "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    
    log_info "  Source policies: $SOURCE_POLICY_COUNT"
    log_info "  Source roles: $SOURCE_ROLE_COUNT"
    log_to_file "$LOG_FILE" "Source policies: $SOURCE_POLICY_COUNT, Source roles: $SOURCE_ROLE_COUNT"
    
    # Get policy and role counts from target
    log_info "Counting policies and roles in target database..."
    TARGET_POLICY_COUNT=$(count_policies "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    TARGET_ROLE_COUNT=$(count_roles "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    
    log_info "  Target policies: $TARGET_POLICY_COUNT"
    log_info "  Target roles: $TARGET_ROLE_COUNT"
    log_to_file "$LOG_FILE" "Target policies: $TARGET_POLICY_COUNT, Target roles: $TARGET_ROLE_COUNT"
    
    # Check if policies match
    POLICY_MISMATCH=false
    ROLE_MISMATCH=false
    
    if [ "$SOURCE_POLICY_COUNT" != "$TARGET_POLICY_COUNT" ]; then
        POLICY_MISMATCH=true
        POLICY_DIFF=$((SOURCE_POLICY_COUNT - TARGET_POLICY_COUNT))
        if [ "$POLICY_DIFF" -gt 0 ]; then
            log_warning "⚠ Policy count mismatch: Target has $POLICY_DIFF fewer policy(ies) than source"
            log_warning "  Source: $SOURCE_POLICY_COUNT policies, Target: $TARGET_POLICY_COUNT policies"
            log_to_file "$LOG_FILE" "WARNING: Policy count mismatch - $POLICY_DIFF policies missing"
        else
            log_warning "⚠ Policy count mismatch: Target has $((POLICY_DIFF * -1)) more policy(ies) than source"
            log_to_file "$LOG_FILE" "WARNING: Policy count mismatch - target has more policies than source"
        fi
    else
        log_success "✓ Policy counts match: $TARGET_POLICY_COUNT policies"
    fi
    
    if [ "$SOURCE_ROLE_COUNT" != "$TARGET_ROLE_COUNT" ]; then
        ROLE_MISMATCH=true
        ROLE_DIFF=$((SOURCE_ROLE_COUNT - TARGET_ROLE_COUNT))
        if [ "$ROLE_DIFF" -gt 0 ]; then
            log_warning "⚠ Role count mismatch: Target has $ROLE_DIFF fewer role(s) than source"
            log_warning "  Source: $SOURCE_ROLE_COUNT roles, Target: $TARGET_ROLE_COUNT roles"
            log_to_file "$LOG_FILE" "WARNING: Role count mismatch - $ROLE_DIFF roles missing"
        else
            log_warning "⚠ Role count mismatch: Target has $((ROLE_DIFF * -1)) more role(s) than source"
            log_to_file "$LOG_FILE" "WARNING: Role count mismatch - target has more roles than source"
        fi
    else
        log_success "✓ Role counts match: $TARGET_ROLE_COUNT roles"
    fi
    
    ###########################################################################
    # Detailed gap analysis: compare policies and tables by name, not just count
    ###########################################################################
    log_info "Performing detailed comparison of policies, tables, and RLS settings..."
    log_to_file "$LOG_FILE" "Performing detailed comparison of policies and tables"

    # Function to get policy list with table names (schemaname.tablename|policyname)
    get_policy_list() {
        local ref=$1
        local password=$2
        local pooler_region=$3
        local pooler_port=$4

        local query="SELECT schemaname || '.' || tablename || '|' || policyname FROM pg_policies WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND schemaname NOT LIKE 'pg_toast%' ORDER BY schemaname, tablename, policyname;"
        run_psql_query_with_fallback \"$ref\" \"$password\" \"$pooler_region\" \"$pooler_port\" \"$query\" 2>/dev/null || echo \"\"
    }

        # Function to get tables with RLS enabled (ALL schemas)
        get_rls_enabled_tables() {
            local ref=$1
            local password=$2
            local pooler_region=$3
            local pooler_port=$4

            local query="
                SELECT n.nspname || '.' || c.relname
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                  AND n.nspname NOT LIKE 'pg_toast%'
                  AND n.nspname != 'storage'
                  AND c.relrowsecurity = true
                  AND c.relkind = 'r'
                ORDER BY n.nspname, c.relname;
            "
            run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null || echo ""
        }

    # Function to get all tables
    get_table_list() {
        local ref=$1
        local password=$2
        local pooler_region=$3
        local pooler_port=$4

        local query=\"SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND schemaname NOT LIKE 'pg_toast%' ORDER BY schemaname, tablename;\"
        run_psql_query_with_fallback \"$ref\" \"$password\" \"$pooler_region\" \"$pooler_port\" \"$query\" 2>/dev/null || echo \"\"
    }

    # Get detailed lists from source and target
    log_info \"Getting detailed policy and table lists from source...\"
    SOURCE_POLICY_LIST=$(get_policy_list \"$SOURCE_REF\" \"$SOURCE_PASSWORD\" \"$SOURCE_POOLER_REGION\" \"$SOURCE_POOLER_PORT\")
    SOURCE_RLS_TABLES=$(get_rls_enabled_tables \"$SOURCE_REF\" \"$SOURCE_PASSWORD\" \"$SOURCE_POOLER_REGION\" \"$SOURCE_POOLER_PORT\")
    SOURCE_TABLE_LIST=$(get_table_list \"$SOURCE_REF\" \"$SOURCE_PASSWORD\" \"$SOURCE_POOLER_REGION\" \"$SOURCE_POOLER_PORT\")

    log_info \"Getting detailed policy and table lists from target...\"
    TARGET_POLICY_LIST=$(get_policy_list \"$TARGET_REF\" \"$TARGET_PASSWORD\" \"$TARGET_POOLER_REGION\" \"$TARGET_POOLER_PORT\")
    TARGET_RLS_TABLES=$(get_rls_enabled_tables \"$TARGET_REF\" \"$TARGET_PASSWORD\" \"$TARGET_POOLER_REGION\" \"$TARGET_POOLER_PORT\")
    TARGET_TABLE_LIST=$(get_table_list \"$TARGET_REF\" \"$TARGET_PASSWORD\" \"$TARGET_POOLER_REGION\" \"$TARGET_POOLER_PORT\")

    # Find missing policies (by name and table)
    MISSING_POLICIES=\"\"
    while IFS='|' read -r table_policy; do
        [ -z \"$table_policy\" ] && continue
        if ! echo \"$TARGET_POLICY_LIST\" | grep -Fxq \"$table_policy\"; then
            MISSING_POLICIES=\"${MISSING_POLICIES}${MISSING_POLICIES:+$'\\n'}$table_policy\"
        fi
    done <<< \"$SOURCE_POLICY_LIST\"

    # Find missing RLS-enabled tables
    MISSING_RLS_TABLES=\"\"
    while IFS= read -r table; do
        [ -z \"$table\" ] && continue
        if ! echo \"$TARGET_RLS_TABLES\" | grep -Fxq \"$table\"; then
            MISSING_RLS_TABLES=\"${MISSING_RLS_TABLES}${MISSING_RLS_TABLES:+$'\\n'}$table\"
        fi
    done <<< \"$SOURCE_RLS_TABLES\"

    # Find missing tables
    MISSING_TABLES=\"\"
    while IFS= read -r table; do
        [ -z \"$table\" ] && continue
        if ! echo \"$TARGET_TABLE_LIST\" | grep -Fxq \"$table\"; then
            MISSING_TABLES=\"${MISSING_TABLES}${MISSING_TABLES:+$'\\n'}$table\"
        fi
    done <<< \"$SOURCE_TABLE_LIST\"

    # Report gaps
    if [ -n \"$MISSING_POLICIES\" ]; then
        MISSING_POLICY_COUNT=$(echo \"$MISSING_POLICIES\" | grep -c . || echo \"0\")
        POLICY_MISMATCH=true
        log_warning \"⚠ Found $MISSING_POLICY_COUNT missing policy(ies) by name!\"
        log_warning \"  Missing policies:\"
        echo \"$MISSING_POLICIES\" | while IFS='|' read -r table_name policy_name; do
            log_warning \"    - Table: $table_name, Policy: $policy_name\"
        done
        log_to_file \"$LOG_FILE\" \"WARNING: $MISSING_POLICY_COUNT policies missing by name\"

        MISSING_POLICIES_FILE=\"$MIGRATION_DIR/missing_policies.txt\"
        echo \"$MISSING_POLICIES\" > \"$MISSING_POLICIES_FILE\"
        log_info \"  Missing policies saved to: $MISSING_POLICIES_FILE\"
    fi

    if [ -n \"$MISSING_RLS_TABLES\" ]; then
        MISSING_RLS_COUNT=$(echo \"$MISSING_RLS_TABLES\" | grep -c . || echo \"0\")
        log_warning \"⚠ Found $MISSING_RLS_COUNT table(s) missing RLS enabled!\"
        log_warning \"  Tables missing RLS:\"
        echo \"$MISSING_RLS_TABLES\" | while read -r table; do
            log_warning \"    - $table\"
        done
        log_to_file \"$LOG_FILE\" \"WARNING: $MISSING_RLS_COUNT tables missing RLS\"

        MISSING_RLS_FILE=\"$MIGRATION_DIR/missing_rls_tables.txt\"
        echo \"$MISSING_RLS_TABLES\" > \"$MISSING_RLS_FILE\"
        log_info \"  Missing RLS tables saved to: $MISSING_RLS_FILE\"
    fi

    if [ -n \"$MISSING_TABLES\" ]; then
        MISSING_TABLE_COUNT=$(echo \"$MISSING_TABLES\" | grep -c . || echo \"0\")
        log_warning \"⚠ Found $MISSING_TABLE_COUNT missing table(s)!\"
        log_warning \"  Missing tables:\"
        echo \"$MISSING_TABLES\" | while read -r table; do
            log_warning \"    - $table\"
        done
        log_to_file \"$LOG_FILE\" \"WARNING: $MISSING_TABLE_COUNT tables missing\"

        MISSING_TABLES_FILE=\"$MIGRATION_DIR/missing_tables.txt\"
        echo \"$MISSING_TABLES\" > \"$MISSING_TABLES_FILE\"
        log_info \"  Missing tables saved to: $MISSING_TABLES_FILE\"
    fi

    # If gaps found, trigger retry logic even if counts matched
    if [ -n \"$MISSING_POLICIES\" ] || [ -n \"$MISSING_RLS_TABLES\" ] || [ -n \"$MISSING_TABLES\" ]; then
        POLICY_MISMATCH=true
        log_warning \"⚠ Gaps detected - will attempt to fix even though counts matched\"
    fi

    if [ -z \"$MISSING_POLICIES\" ] && [ -z \"$MISSING_RLS_TABLES\" ] && [ -z \"$MISSING_TABLES\" ]; then
        log_success \"✓ All policies, RLS settings, and tables match by name\"
    fi
    
    # If there's a mismatch, try to extract and re-apply policies/roles
    if [ "$POLICY_MISMATCH" = "true" ] || [ "$ROLE_MISMATCH" = "true" ]; then
        log_info "Attempting to fix policy/role mismatches by re-applying from source..."
        log_to_file "$LOG_FILE" "Attempting to fix policy/role mismatches"
        
        # CRITICAL FIX: Extract policies directly from database (not just dump) to preserve roles correctly
        # Dump files may not preserve role information correctly, so we extract directly from pg_policy
        log_info "Extracting ALL policies directly from source database (to preserve roles)..."
        log_to_file "$LOG_FILE" "Extracting all policies directly from database to preserve roles"
        
        # Function to extract ALL policies directly from database with complete role information
        extract_all_policies_from_db() {
            local ref=$1
            local password=$2
            local pooler_region=$3
            local pooler_port=$4
            local output_file=$5
            
            # Extract ALL policies with complete role information directly from pg_policy
            local query="
                SELECT 
                    'CREATE POLICY ' || quote_ident(pol.polname) || 
                    ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) ||
                    ' FOR ' || CASE pol.polcmd
                        WHEN 'r' THEN 'SELECT'
                        WHEN 'a' THEN 'INSERT'
                        WHEN 'w' THEN 'UPDATE'
                        WHEN 'd' THEN 'DELETE'
                        WHEN '*' THEN 'ALL'
                    END ||
                    CASE 
                        WHEN array_length(pol.polroles, 1) > 0 AND (pol.polroles != ARRAY[0]::oid[]) THEN
                            ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY rol.rolname)
                        WHEN pol.polroles = ARRAY[0]::oid[] OR array_length(pol.polroles, 1) IS NULL THEN
                            ' TO public'
                        ELSE ''
                    END ||
                    CASE 
                        WHEN pol.polqual IS NOT NULL THEN
                            ' USING (' || pg_get_expr(pol.polqual, pol.polrelid) || ')'
                        ELSE ''
                    END ||
                    CASE 
                        WHEN pol.polwithcheck IS NOT NULL THEN
                            ' WITH CHECK (' || pg_get_expr(pol.polwithcheck, pol.polrelid) || ')'
                        ELSE ''
                    END || ';' as policy_sql
                FROM pg_policy pol
                JOIN pg_class c ON c.oid = pol.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                  AND n.nspname NOT LIKE 'pg_toast%'
                  AND n.nspname != 'storage'  -- Storage policies handled separately in Step 4a
                GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, pol.polqual, pol.polrelid, pol.polwithcheck, pol.polroles
                ORDER BY n.nspname, c.relname, pol.polname;
            "
            
            run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" > "$output_file" 2>/dev/null || echo ""
        }
        
        # Extract all policies directly from source database
        ALL_POLICIES_FROM_DB="$MIGRATION_DIR/all_policies_from_db.sql"
        extract_all_policies_from_db "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$ALL_POLICIES_FROM_DB"
        
        if [ -s "$ALL_POLICIES_FROM_DB" ]; then
            ALL_POLICY_COUNT=$(grep -c "^CREATE POLICY" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            log_info "Extracted $ALL_POLICY_COUNT policy(ies) directly from source database"
            
            # Log policies by schema for visibility (CRITICAL: See what's being extracted)
            log_info "Policy breakdown by schema:"
            POLICY_BY_SCHEMA=$(grep "^CREATE POLICY" "$ALL_POLICIES_FROM_DB" | sed -n 's/.*ON \([^.]*\)\.\([^ ]*\).*/\1.\2/p' | sort | uniq -c)
            if [ -n "$POLICY_BY_SCHEMA" ]; then
                echo "$POLICY_BY_SCHEMA" | while read -r count table; do
                    [ -z "$table" ] && continue
                    log_info "  - $table: $count policy(ies)"
                done
            else
                log_warning "  ⚠ Could not parse policy breakdown by schema"
            fi
            
            # Count by policy type for visibility
            SELECT_COUNT=$(grep -c " FOR SELECT" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            INSERT_COUNT=$(grep -c " FOR INSERT" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            UPDATE_COUNT=$(grep -c " FOR UPDATE" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            DELETE_COUNT=$(grep -c " FOR DELETE" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            ALL_TYPE_COUNT=$(grep -c " FOR ALL" "$ALL_POLICIES_FROM_DB" 2>/dev/null || echo "0")
            
            log_info "  Policy breakdown by type: SELECT=$SELECT_COUNT, INSERT=$INSERT_COUNT, UPDATE=$UPDATE_COUNT, DELETE=$DELETE_COUNT, ALL=$ALL_TYPE_COUNT"
            log_to_file "$LOG_FILE" "Extracted $ALL_POLICY_COUNT policies from DB: SELECT=$SELECT_COUNT, INSERT=$INSERT_COUNT, UPDATE=$UPDATE_COUNT, DELETE=$DELETE_COUNT, ALL=$ALL_TYPE_COUNT"
            
            # Use the directly extracted policies instead of dump-based extraction
            POLICY_SQL="$ALL_POLICIES_FROM_DB"
            
            # CRITICAL FIX: Enable RLS on ALL tables that have policies (not just those with RLS already enabled)
            # This ensures RLS is enabled before policies are applied
            log_info "Ensuring RLS is enabled on ALL tables that have policies..."
            log_to_file "$LOG_FILE" "Ensuring RLS is enabled on all tables with policies"
            
            RLS_ENABLE_SQL="$MIGRATION_DIR/rls_enable_fix.sql"
            run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
                SELECT DISTINCT 'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || 
                       ' ENABLE ROW LEVEL SECURITY;'
                FROM pg_policy pol
                JOIN pg_class c ON c.oid = pol.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                  AND n.nspname NOT LIKE 'pg_toast%'
                  AND n.nspname != 'storage'  -- Storage policies handled separately
                  AND c.relkind = 'r'  -- Only tables, not views
                ORDER BY n.nspname, c.relname;
            " > "$RLS_ENABLE_SQL" 2>/dev/null || echo ""
            
            if [ -s "$RLS_ENABLE_SQL" ]; then
                RLS_ENABLE_COUNT=$(grep -c "ENABLE ROW LEVEL SECURITY" "$RLS_ENABLE_SQL" 2>/dev/null || echo "0")
                log_info "Found $RLS_ENABLE_COUNT table(s) with policies that need RLS enabled"
                log_to_file "$LOG_FILE" "Found $RLS_ENABLE_COUNT tables with policies that need RLS enabled"
            fi
        else
            log_warning "⚠ Failed to extract policies directly from database, falling back to dump extraction"
            log_to_file "$LOG_FILE" "WARNING: Direct policy extraction failed, using dump extraction"
            
            # Fallback to dump-based extraction
        if [ -f "$DUMP_FILE" ] && [ -s "$DUMP_FILE" ]; then
                log_info "Extracting policies and roles from existing source dump (fallback)..."
                POLICIES_ROLES_SQL="$MIGRATION_DIR/policies_roles_fix.sql"
                
                # Convert dump to SQL and extract policies/roles
                if pg_restore -f "$POLICIES_ROLES_SQL" --schema-only "$DUMP_FILE" 2>/dev/null; then
                    # Extract RLS enable statements separately (must be applied before policies)
                    RLS_ENABLE_SQL="$MIGRATION_DIR/rls_enable_fix.sql"
                    {
                        grep -E "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$POLICIES_ROLES_SQL" 2>/dev/null || true
                        # Also handle multi-line ALTER TABLE statements
                        awk '/^ALTER TABLE.*ENABLE ROW LEVEL SECURITY/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    } | sort -u > "$RLS_ENABLE_SQL" 2>/dev/null || true
                    
                    # Extract CREATE POLICY statements (separate from RLS enable)
                    POLICY_SQL="$MIGRATION_DIR/policies_only_fix.sql"
                    {
                        grep -E "^CREATE POLICY" "$POLICIES_ROLES_SQL" 2>/dev/null || true
                        # Also extract multi-line policies using awk
                        awk '/^CREATE POLICY/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    } | sort -u > "$POLICY_SQL" 2>/dev/null || true
                else
                    log_warning "Failed to extract policies from dump file"
                    POLICY_SQL=""
                fi
            else
                log_warning "Source dump file not available for policy extraction"
                POLICY_SQL=""
            fi
        fi
        
        # Extract policies and roles from source dump (if available) or create new dump
        if [ -f "$DUMP_FILE" ] && [ -s "$DUMP_FILE" ] && [ -z "${POLICY_SQL:-}" ]; then
            log_info "Extracting policies and roles from existing source dump..."
            POLICIES_ROLES_SQL="$MIGRATION_DIR/policies_roles_fix.sql"
            
            # Convert dump to SQL and extract policies/roles
            if pg_restore -f "$POLICIES_ROLES_SQL" --schema-only "$DUMP_FILE" 2>/dev/null; then
                # Extract RLS enable statements separately (must be applied before policies)
                if [ ! -f "$RLS_ENABLE_SQL" ] || [ ! -s "$RLS_ENABLE_SQL" ]; then
                    RLS_ENABLE_SQL="$MIGRATION_DIR/rls_enable_fix.sql"
                    {
                        grep -E "^ALTER TABLE.*ENABLE ROW LEVEL SECURITY" "$POLICIES_ROLES_SQL" 2>/dev/null || true
                        # Also handle multi-line ALTER TABLE statements
                        awk '/^ALTER TABLE.*ENABLE ROW LEVEL SECURITY/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    } | sort -u > "$RLS_ENABLE_SQL" 2>/dev/null || true
                fi
                
                # Extract CREATE POLICY statements (separate from RLS enable)
                if [ ! -f "$POLICY_SQL" ] || [ ! -s "$POLICY_SQL" ]; then
                POLICY_SQL="$MIGRATION_DIR/policies_only_fix.sql"
                {
                        grep -E "^CREATE POLICY" "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    # Also extract multi-line policies using awk
                    awk '/^CREATE POLICY/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                } | sort -u > "$POLICY_SQL" 2>/dev/null || true
                fi
                
                # Extract CREATE ROLE and GRANT statements
                ROLE_SQL="$MIGRATION_DIR/roles_only_fix.sql"
                {
                    grep -E "^CREATE ROLE|^ALTER ROLE|^GRANT|^REVOKE" "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    # Also extract multi-line role statements
                    awk '/^CREATE ROLE/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                    awk '/^GRANT/,/;/ {print}' "$POLICIES_ROLES_SQL" 2>/dev/null || true
                } | sort -u > "$ROLE_SQL" 2>/dev/null || true
                
                # First, enable RLS on tables that should have it
                if [ -f "$RLS_ENABLE_SQL" ] && [ -s "$RLS_ENABLE_SQL" ]; then
                    RLS_ENABLE_COUNT=$(grep -c "ENABLE ROW LEVEL SECURITY" "$RLS_ENABLE_SQL" 2>/dev/null || echo "0")
                    log_info "Enabling RLS on $RLS_ENABLE_COUNT table(s) before applying policies..."
                    log_to_file "$LOG_FILE" "Enabling RLS on tables before policy application"
                    
                    set +e
                    if run_psql_script_with_fallback "Enabling RLS on tables" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$RLS_ENABLE_SQL"; then
                        log_success "✓ RLS enabled on tables"
                        log_to_file "$LOG_FILE" "RLS enabled on tables successfully"
                    else
                        log_warning "⚠ Some errors occurred while enabling RLS (some tables may already have RLS enabled)"
                        log_to_file "$LOG_FILE" "WARNING: Some errors occurred while enabling RLS"
                    fi
                    set -e
                fi
                
                # Drop existing policies first to ensure clean application with correct roles
                # CRITICAL FIX: Drop from ALL schemas, not just public
                log_info "Dropping existing policies on target before applying corrected versions..."
                log_to_file "$LOG_FILE" "Dropping existing policies from ALL schemas before re-application"
                
                DROP_POLICIES_SQL="$MIGRATION_DIR/drop_all_policies.sql"
                run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
                    SELECT 'DROP POLICY IF EXISTS ' || quote_ident(pol.polname) || ' ON ' || 
                           quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';'
                    FROM pg_policy pol
                    JOIN pg_class c ON c.oid = pol.polrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                      AND n.nspname NOT LIKE 'pg_toast%'
                      AND n.nspname != 'storage'  -- Storage policies handled separately in Step 4a
                    ORDER BY n.nspname, c.relname, pol.polname;
                " > "$DROP_POLICIES_SQL" 2>/dev/null || echo ""
                
                if [ -s "$DROP_POLICIES_SQL" ]; then
                    DROP_COUNT=$(grep -c "^DROP POLICY" "$DROP_POLICIES_SQL" 2>/dev/null || echo "0")
                    log_info "Dropping $DROP_COUNT existing policy(ies) from all schemas..."
                    log_to_file "$LOG_FILE" "Dropping $DROP_COUNT existing policies from all schemas"
                fi
                
                if [ -s "$DROP_POLICIES_SQL" ]; then
                    set +e
                    run_psql_script_with_fallback "Dropping existing policies" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$DROP_POLICIES_SQL" >/dev/null 2>&1
                    set -e
                fi
                
                # Apply policies with retry logic (after RLS is enabled and old policies dropped)
                if [ -f "$POLICY_SQL" ] && [ -s "$POLICY_SQL" ]; then
                    POLICY_COUNT_IN_FILE=$(grep -c "^CREATE POLICY" "$POLICY_SQL" 2>/dev/null || echo "0")
                    log_info "Found $POLICY_COUNT_IN_FILE policy definition(s) to re-apply with correct roles..."
                    
                    MAX_RETRIES=3
                    RETRY_COUNT=0
                    POLICY_APPLY_SUCCESS=false
                    
                    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$POLICY_APPLY_SUCCESS" != "true" ]; do
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        log_info "Attempting to apply policies with correct roles (attempt $RETRY_COUNT/$MAX_RETRIES)..."
                        
                        # Apply policies with error handling and detailed error reporting
                        POLICY_APPLY_OUTPUT=$(mktemp)
                        if run_psql_script_with_fallback "Policy re-application with roles (attempt $RETRY_COUNT)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$POLICY_SQL" 2>"$POLICY_APPLY_OUTPUT"; then
                            # Verify policies were applied
                            sleep 2  # Give database time to update
                            NEW_TARGET_POLICY_COUNT=$(count_policies "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                            
                            # Check for specific policy application errors
                            if [ -s "$POLICY_APPLY_OUTPUT" ]; then
                                POLICY_ERRORS=$(grep -iE "error|failed|syntax error" "$POLICY_APPLY_OUTPUT" 2>/dev/null | grep -viE "already exists|does not exist" || echo "")
                                if [ -n "$POLICY_ERRORS" ]; then
                                    log_warning "⚠ Some policy application errors detected:"
                                    echo "$POLICY_ERRORS" | head -5 | while read -r error_line; do
                                        [ -z "$error_line" ] && continue
                                        log_warning "    - $error_line"
                                    done
                                    if [ "$(echo "$POLICY_ERRORS" | wc -l)" -gt 5 ]; then
                                        log_warning "    ... and more errors (check log file for details)"
                                    fi
                                    log_to_file "$LOG_FILE" "Policy application errors: $POLICY_ERRORS"
                                fi
                            fi
                            
                            # Compare source and target policies by schema to find missing ones
                            log_info "Comparing policies by schema to identify any missing policies..."
                            MISSING_POLICIES=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
                                SELECT n.nspname || '.' || c.relname || '.' || pol.polname
                                FROM pg_policy pol
                                JOIN pg_class c ON c.oid = pol.polrelid
                                JOIN pg_namespace n ON n.oid = c.relnamespace
                                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                                  AND n.nspname != 'storage'
                                EXCEPT
                                SELECT n.nspname || '.' || c.relname || '.' || pol.polname
                                FROM pg_policy pol
                                JOIN pg_class c ON c.oid = pol.polrelid
                                JOIN pg_namespace n ON n.oid = c.relnamespace
                                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                                  AND n.nspname != 'storage';
                            " 2>/dev/null | grep -v "^$" || echo "")
                            
                            if [ -n "$MISSING_POLICIES" ]; then
                                MISSING_COUNT=$(echo "$MISSING_POLICIES" | grep -c . || echo "0")
                                log_warning "⚠ Found $MISSING_COUNT policy(ies) in source that are missing in target:"
                                echo "$MISSING_POLICIES" | head -10 | while read -r policy; do
                                    [ -z "$policy" ] && continue
                                    log_warning "    - $policy"
                                done
                                if [ "$MISSING_COUNT" -gt 10 ]; then
                                    log_warning "    ... and $((MISSING_COUNT - 10)) more missing policies"
                                fi
                                log_to_file "$LOG_FILE" "WARNING: $MISSING_COUNT policies missing in target"
                            fi
                            
                            if [ "$NEW_TARGET_POLICY_COUNT" -ge "$TARGET_POLICY_COUNT" ]; then
                                if [ "$NEW_TARGET_POLICY_COUNT" = "$SOURCE_POLICY_COUNT" ]; then
                                    POLICY_APPLY_SUCCESS=true
                                    log_success "✓ All policies re-applied successfully"
                                    log_info "  Target now has: $NEW_TARGET_POLICY_COUNT policies (matches source)"
                                    TARGET_POLICY_COUNT=$NEW_TARGET_POLICY_COUNT
                                elif [ "$NEW_TARGET_POLICY_COUNT" -gt "$TARGET_POLICY_COUNT" ]; then
                                    log_info "Policy count increased to $NEW_TARGET_POLICY_COUNT (was $TARGET_POLICY_COUNT), continuing..."
                                    TARGET_POLICY_COUNT=$NEW_TARGET_POLICY_COUNT
                                    # Continue to next retry if not at max
                                    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                                        continue
                                    fi
                                fi
                            else
                                log_warning "Policy count did not increase after re-application (still $NEW_TARGET_POLICY_COUNT)"
                            fi
                        else
                            log_warning "Policy re-application attempt $RETRY_COUNT failed"
                            if [ -s "$POLICY_APPLY_OUTPUT" ]; then
                                log_warning "Error details:"
                                head -10 "$POLICY_APPLY_OUTPUT" | while read -r error_line; do
                                    [ -z "$error_line" ] && continue
                                    log_warning "  - $error_line"
                                done
                                log_to_file "$LOG_FILE" "Policy application error output: $(cat "$POLICY_APPLY_OUTPUT")"
                            fi
                        fi
                        rm -f "$POLICY_APPLY_OUTPUT"
                    done
                    
                    if [ "$POLICY_APPLY_SUCCESS" != "true" ]; then
                        log_warning "⚠ Failed to re-apply all policies after $MAX_RETRIES attempts"
                        log_warning "  Some policies may need manual review. Check: $POLICY_SQL"
                        log_to_file "$LOG_FILE" "WARNING: Policy re-application failed after $MAX_RETRIES attempts"
                    fi
                fi
                
                # Apply roles with retry logic
                if [ -f "$ROLE_SQL" ] && [ -s "$ROLE_SQL" ]; then
                    ROLE_COUNT_IN_FILE=$(grep -c "^CREATE ROLE\|^ALTER ROLE\|^GRANT" "$ROLE_SQL" 2>/dev/null || echo "0")
                    log_info "Found $ROLE_COUNT_IN_FILE role definition(s) to re-apply..."
                    
                    MAX_RETRIES=3
                    RETRY_COUNT=0
                    ROLE_APPLY_SUCCESS=false
                    
                    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$ROLE_APPLY_SUCCESS" != "true" ]; do
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        log_info "Attempting to apply roles (attempt $RETRY_COUNT/$MAX_RETRIES)..."
                        
                        # Apply roles with error handling
                        if run_psql_script_with_fallback "Role re-application (attempt $RETRY_COUNT)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$ROLE_SQL"; then
                            # Verify roles were applied
                            sleep 2  # Give database time to update
                            NEW_TARGET_ROLE_COUNT=$(count_roles "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                            
                            if [ "$NEW_TARGET_ROLE_COUNT" -ge "$TARGET_ROLE_COUNT" ]; then
                                if [ "$NEW_TARGET_ROLE_COUNT" = "$SOURCE_ROLE_COUNT" ]; then
                                    ROLE_APPLY_SUCCESS=true
                                    log_success "✓ All roles re-applied successfully"
                                    log_info "  Target now has: $NEW_TARGET_ROLE_COUNT roles (matches source)"
                                    TARGET_ROLE_COUNT=$NEW_TARGET_ROLE_COUNT
                                elif [ "$NEW_TARGET_ROLE_COUNT" -gt "$TARGET_ROLE_COUNT" ]; then
                                    log_info "Role count increased to $NEW_TARGET_ROLE_COUNT (was $TARGET_ROLE_COUNT), continuing..."
                                    TARGET_ROLE_COUNT=$NEW_TARGET_ROLE_COUNT
                                    # Continue to next retry if not at max
                                    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                                        continue
                                    fi
                                fi
                            else
                                log_warning "Role count did not increase after re-application (still $NEW_TARGET_ROLE_COUNT)"
                            fi
                        else
                            log_warning "Role re-application attempt $RETRY_COUNT failed"
                        fi
                    done
                    
                    if [ "$ROLE_APPLY_SUCCESS" != "true" ]; then
                        log_warning "⚠ Failed to re-apply all roles after $MAX_RETRIES attempts"
                        log_warning "  Some roles may need manual review. Check: $ROLE_SQL"
                        log_to_file "$LOG_FILE" "WARNING: Role re-application failed after $MAX_RETRIES attempts"
                    fi
                fi
            else
                log_warning "Failed to extract policies/roles SQL from dump"
            fi
        else
            log_warning "Source dump file not available for policy/role extraction"
        fi
        
        # Verify RLS is enabled on tables that should have it
        log_info "Verifying RLS is enabled on all tables that should have policies..."
        log_to_file "$LOG_FILE" "Verifying RLS is enabled on tables"
        
        # Function to get tables that have policies but RLS not enabled (ALL schemas)
        check_rls_on_policy_tables() {
            local ref=$1
            local password=$2
            local pooler_region=$3
            local pooler_port=$4
            
            local query="
                SELECT DISTINCT n.nspname || '.' || c.relname
                FROM pg_policy pol
                JOIN pg_class c ON c.oid = pol.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                  AND n.nspname NOT LIKE 'pg_toast%'
                  AND n.nspname != 'storage'
                  AND c.relkind = 'r'
                  AND c.relrowsecurity = false
                ORDER BY n.nspname, c.relname;
            "
            run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null || echo ""
        }
        
        TABLES_WITHOUT_RLS=$(check_rls_on_policy_tables "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
        
        if [ -n "$TABLES_WITHOUT_RLS" ]; then
            MISSING_RLS_COUNT=$(echo "$TABLES_WITHOUT_RLS" | grep -c . || echo "0")
            log_warning "⚠ Found $MISSING_RLS_COUNT table(s) with policies but RLS not enabled!"
            log_warning "  These tables need RLS enabled to prevent policy violations:"
            echo "$TABLES_WITHOUT_RLS" | while read -r table; do
                [ -z "$table" ] && continue
                log_warning "    - $table"
            done
            log_to_file "$LOG_FILE" "WARNING: $MISSING_RLS_COUNT tables have policies but RLS not enabled"
            
            # Try to enable RLS on these tables
            log_info "Attempting to enable RLS on tables with policies..."
            RLS_FIX_SQL="$MIGRATION_DIR/rls_fix_missing.sql"
            echo "$TABLES_WITHOUT_RLS" | while read -r table; do
                [ -z "$table" ] && continue
                echo "ALTER TABLE $table ENABLE ROW LEVEL SECURITY;" >> "$RLS_FIX_SQL"
            done
            
            if [ -f "$RLS_FIX_SQL" ] && [ -s "$RLS_FIX_SQL" ]; then
                set +e
                if run_psql_script_with_fallback "Enabling RLS on tables with policies" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$RLS_FIX_SQL"; then
                    log_success "✓ RLS enabled on tables that were missing it"
                    log_to_file "$LOG_FILE" "RLS enabled on tables that were missing it"
                else
                    log_warning "⚠ Failed to enable RLS on some tables - manual intervention may be required"
                    log_to_file "$LOG_FILE" "WARNING: Failed to enable RLS on some tables"
                fi
                set -e
            fi
        else
            log_success "✓ All tables with policies have RLS enabled"
            log_to_file "$LOG_FILE" "All tables with policies have RLS enabled"
        fi
        
        # Final verification
        log_info "Performing final verification of policies and roles..."
        FINAL_TARGET_POLICY_COUNT=$(count_policies "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
        FINAL_TARGET_ROLE_COUNT=$(count_roles "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
        
        if [ "$FINAL_TARGET_POLICY_COUNT" = "$SOURCE_POLICY_COUNT" ]; then
            log_success "✅ All policies successfully migrated: $FINAL_TARGET_POLICY_COUNT policies"
            log_to_file "$LOG_FILE" "SUCCESS: All policies migrated - $FINAL_TARGET_POLICY_COUNT policies"
        else
            FINAL_POLICY_DIFF=$((SOURCE_POLICY_COUNT - FINAL_TARGET_POLICY_COUNT))
            if [ "$FINAL_POLICY_DIFF" -gt 0 ]; then
                log_warning "⚠ Still missing $FINAL_POLICY_DIFF policy(ies) after retry attempts"
                log_warning "  Source: $SOURCE_POLICY_COUNT, Target: $FINAL_TARGET_POLICY_COUNT"
                if [ -f "$POLICY_SQL" ]; then
                    log_warning "  Review the policy SQL file for manual application: $POLICY_SQL"
                fi
                log_to_file "$LOG_FILE" "WARNING: $FINAL_POLICY_DIFF policies still missing after retry"
            fi
        fi
        
        if [ "$FINAL_TARGET_ROLE_COUNT" = "$SOURCE_ROLE_COUNT" ]; then
            log_success "✅ All roles successfully migrated: $FINAL_TARGET_ROLE_COUNT roles"
            log_to_file "$LOG_FILE" "SUCCESS: All roles migrated - $FINAL_TARGET_ROLE_COUNT roles"
        else
            FINAL_ROLE_DIFF=$((SOURCE_ROLE_COUNT - FINAL_TARGET_ROLE_COUNT))
            if [ "$FINAL_ROLE_DIFF" -gt 0 ]; then
                log_warning "⚠ Still missing $FINAL_ROLE_DIFF role(s) after retry attempts"
                log_warning "  Source: $SOURCE_ROLE_COUNT, Target: $FINAL_TARGET_ROLE_COUNT"
                if [ -f "$ROLE_SQL" ]; then
                    log_warning "  Review the role SQL file for manual application: $ROLE_SQL"
                fi
                log_to_file "$LOG_FILE" "WARNING: $FINAL_ROLE_DIFF roles still missing after retry"
            fi
        fi
    else
        log_success "✅ Policy and role counts match - no retry needed"
        log_to_file "$LOG_FILE" "SUCCESS: All policies and roles migrated correctly"
    fi
    
    echo ""
fi

# Step 6: Comprehensive Verification (ALWAYS RUN - independent of restore success)
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 6: Comprehensive Migration Verification"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Performing comprehensive verification of all migrated components..."
log_to_file "$LOG_FILE" "Performing comprehensive verification"

# Verify Storage RLS Policies
log_info "Verifying storage RLS policies..."
SOURCE_STORAGE_POLICIES=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename IN ('objects', 'buckets');" 2>/dev/null | tr -d '[:space:]' || echo "0")
TARGET_STORAGE_POLICIES=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename IN ('objects', 'buckets');" 2>/dev/null | tr -d '[:space:]' || echo "0")

if [ "$SOURCE_STORAGE_POLICIES" = "$TARGET_STORAGE_POLICIES" ]; then
    log_success "✓ Storage RLS policies match: $TARGET_STORAGE_POLICIES policies"
    log_to_file "$LOG_FILE" "SUCCESS: Storage RLS policies match - $TARGET_STORAGE_POLICIES policies"
else
    log_warning "⚠ Storage RLS policy mismatch: Source has $SOURCE_STORAGE_POLICIES, Target has $TARGET_STORAGE_POLICIES"
    log_to_file "$LOG_FILE" "WARNING: Storage RLS policy mismatch"
fi

# Verify Extensions
log_info "Verifying database extensions..."
SOURCE_EXTENSIONS=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "SELECT COUNT(*) FROM pg_extension WHERE extname NOT IN ('plpgsql', 'uuid-ossp', 'pgcrypto', 'pgjwt', 'pg_stat_statements') AND extname NOT LIKE 'pg_%' AND extname NOT LIKE 'pl%';" 2>/dev/null | tr -d '[:space:]' || echo "0")
TARGET_EXTENSIONS=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "SELECT COUNT(*) FROM pg_extension WHERE extname NOT IN ('plpgsql', 'uuid-ossp', 'pgcrypto', 'pgjwt', 'pg_stat_statements') AND extname NOT LIKE 'pg_%' AND extname NOT LIKE 'pl%';" 2>/dev/null | tr -d '[:space:]' || echo "0")

if [ "$SOURCE_EXTENSIONS" = "$TARGET_EXTENSIONS" ]; then
    log_success "✓ Extensions match: $TARGET_EXTENSIONS extensions"
    log_to_file "$LOG_FILE" "SUCCESS: Extensions match - $TARGET_EXTENSIONS extensions"
else
    log_warning "⚠ Extension mismatch: Source has $SOURCE_EXTENSIONS, Target has $TARGET_EXTENSIONS"
    log_to_file "$LOG_FILE" "WARNING: Extension mismatch"
fi

# Verify Cron Jobs
log_info "Verifying cron jobs..."
SOURCE_CRON_EXISTS=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');" 2>/dev/null | tr -d '[:space:]' || echo "false")
TARGET_CRON_EXISTS=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');" 2>/dev/null | tr -d '[:space:]' || echo "false")

if [ "$SOURCE_CRON_EXISTS" = "t" ] || [ "$SOURCE_CRON_EXISTS" = "true" ]; then
    if [ "$TARGET_CRON_EXISTS" = "t" ] || [ "$TARGET_CRON_EXISTS" = "true" ]; then
        SOURCE_CRON_JOBS=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "SELECT COUNT(*) FROM cron.job;" 2>/dev/null | tr -d '[:space:]' || echo "0")
        TARGET_CRON_JOBS=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "SELECT COUNT(*) FROM cron.job;" 2>/dev/null | tr -d '[:space:]' || echo "0")
        
        if [ "$SOURCE_CRON_JOBS" = "$TARGET_CRON_JOBS" ]; then
            log_success "✓ Cron jobs match: $TARGET_CRON_JOBS jobs"
            log_to_file "$LOG_FILE" "SUCCESS: Cron jobs match - $TARGET_CRON_JOBS jobs"
        else
            log_warning "⚠ Cron job mismatch: Source has $SOURCE_CRON_JOBS, Target has $TARGET_CRON_JOBS"
            log_to_file "$LOG_FILE" "WARNING: Cron job mismatch"
        fi
    else
        log_warning "⚠ pg_cron extension not installed in target (source has cron jobs)"
        log_to_file "$LOG_FILE" "WARNING: pg_cron extension not installed in target"
    fi
else
    log_info "No cron jobs in source (pg_cron not installed)"
    log_to_file "$LOG_FILE" "No cron jobs in source"
fi

# Verify RLS is enabled on storage tables
log_info "Verifying RLS is enabled on storage tables..."
SOURCE_STORAGE_RLS=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT COUNT(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage' AND c.relname IN ('objects', 'buckets') AND c.relrowsecurity = true;
" 2>/dev/null | tr -d '[:space:]' || echo "0")
TARGET_STORAGE_RLS=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT COUNT(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage' AND c.relname IN ('objects', 'buckets') AND c.relrowsecurity = true;
" 2>/dev/null | tr -d '[:space:]' || echo "0")

if [ "$SOURCE_STORAGE_RLS" = "$TARGET_STORAGE_RLS" ] && [ "$SOURCE_STORAGE_RLS" = "2" ]; then
    log_success "✓ RLS enabled on storage tables (objects and buckets)"
    log_to_file "$LOG_FILE" "SUCCESS: RLS enabled on storage tables"
elif [ "$SOURCE_STORAGE_RLS" != "$TARGET_STORAGE_RLS" ]; then
    log_warning "⚠ Storage RLS mismatch: Source has $SOURCE_STORAGE_RLS tables with RLS, Target has $TARGET_STORAGE_RLS"
    log_to_file "$LOG_FILE" "WARNING: Storage RLS mismatch"
fi

# Verify Policy Roles Match (Critical Check)
log_info "Verifying policy roles match between source and target..."
log_to_file "$LOG_FILE" "Verifying policy roles match"

# Function to get policies with roles for comparison
get_policies_with_roles() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    
    local query="
        SELECT 
            n.nspname || '.' || c.relname || '|' || pol.polname || '|' || 
            CASE pol.polcmd
                WHEN 'r' THEN 'SELECT'
                WHEN 'a' THEN 'INSERT'
                WHEN 'w' THEN 'UPDATE'
                WHEN 'd' THEN 'DELETE'
                WHEN '*' THEN 'ALL'
            END || '|' ||
            COALESCE(
                string_agg(DISTINCT quote_ident(rol.rolname), ',' ORDER BY rol.rolname),
                'public'
            ) as policy_info
        FROM pg_policy pol
        JOIN pg_class c ON c.oid = pol.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname != 'storage'  -- Storage policies handled separately
        GROUP BY n.nspname, c.relname, pol.polname, pol.polcmd
        ORDER BY n.nspname, c.relname, pol.polname;
    "
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null || echo ""
}

SOURCE_POLICIES_WITH_ROLES=$(get_policies_with_roles "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
TARGET_POLICIES_WITH_ROLES=$(get_policies_with_roles "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")

# Find policies with role mismatches
ROLE_MISMATCHES=""
while IFS='|' read -r table_policy cmd roles; do
    [ -z "$table_policy" ] && continue
    TARGET_MATCH=$(echo "$TARGET_POLICIES_WITH_ROLES" | grep "^${table_policy}|" || echo "")
    if [ -n "$TARGET_MATCH" ]; then
        TARGET_ROLES=$(echo "$TARGET_MATCH" | cut -d'|' -f4)
        if [ "$roles" != "$TARGET_ROLES" ]; then
            ROLE_MISMATCHES="${ROLE_MISMATCHES}${ROLE_MISMATCHES:+$'\n'}${table_policy}|${cmd}|Source: ${roles}|Target: ${TARGET_ROLES}"
        fi
    fi
done <<< "$SOURCE_POLICIES_WITH_ROLES"

if [ -n "$ROLE_MISMATCHES" ]; then
    MISMATCH_COUNT=$(echo "$ROLE_MISMATCHES" | grep -c . || echo "0")
    log_warning "⚠ Found $MISMATCH_COUNT policy(ies) with role mismatches!"
    log_warning "  Policies with different roles in source vs target:"
    echo "$ROLE_MISMATCHES" | while IFS='|' read -r table_policy cmd source_roles target_roles; do
        [ -z "$table_policy" ] && continue
        log_warning "    - $table_policy ($cmd):"
        log_warning "        $source_roles"
        log_warning "        $target_roles"
    done
    log_to_file "$LOG_FILE" "WARNING: $MISMATCH_COUNT policies have role mismatches"
    log_warning "  These policies need to be re-applied with correct roles"
else
    log_success "✓ All policy roles match between source and target"
    log_to_file "$LOG_FILE" "SUCCESS: All policy roles match"
fi

# Verify Column Counts Match (Critical for schema migration)
log_info "Verifying column counts match between source and target..."
SOURCE_COLUMN_COUNT=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND table_schema NOT LIKE 'pg_toast%'
      AND table_schema != 'storage'
      AND table_schema != 'auth';
" 2>/dev/null | tr -d '[:space:]' || echo "0")
TARGET_COLUMN_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND table_schema NOT LIKE 'pg_toast%'
      AND table_schema != 'storage'
      AND table_schema != 'auth';
" 2>/dev/null | tr -d '[:space:]' || echo "0")

if [ "$SOURCE_COLUMN_COUNT" = "$TARGET_COLUMN_COUNT" ]; then
    log_success "✓ Column counts match: $TARGET_COLUMN_COUNT columns"
    log_to_file "$LOG_FILE" "SUCCESS: Column counts match - $TARGET_COLUMN_COUNT columns"
else
    COLUMN_DIFF=$((SOURCE_COLUMN_COUNT - TARGET_COLUMN_COUNT))
    if [ "$COLUMN_DIFF" -gt 0 ]; then
        log_warning "⚠ Column count mismatch: Source has $SOURCE_COLUMN_COUNT, Target has $TARGET_COLUMN_COUNT (missing $COLUMN_DIFF column(s))"
        log_warning "  This indicates missing columns in target. Re-run migration or check schema differences."
        log_to_file "$LOG_FILE" "WARNING: Column count mismatch - Source: $SOURCE_COLUMN_COUNT, Target: $TARGET_COLUMN_COUNT (missing $COLUMN_DIFF)"
    else
        log_warning "⚠ Column count mismatch: Source has $SOURCE_COLUMN_COUNT, Target has $TARGET_COLUMN_COUNT (target has $((COLUMN_DIFF * -1)) extra column(s))"
        log_to_file "$LOG_FILE" "WARNING: Column count mismatch - Source: $SOURCE_COLUMN_COUNT, Target: $TARGET_COLUMN_COUNT"
    fi
fi

# Verify Grants Match
log_info "Verifying grants match between source and target..."
SOURCE_GRANT_COUNT=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT COUNT(*) FROM (
        SELECT table_schema, table_name, grantee, privilege_type
        FROM information_schema.table_privileges
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        UNION ALL
        SELECT object_schema, object_name, grantee, privilege_type
        FROM information_schema.usage_privileges
        WHERE object_type = 'SEQUENCE'
          AND object_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND object_schema != 'storage'
          AND object_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        UNION ALL
        SELECT routine_schema, routine_name, grantee, privilege_type
        FROM information_schema.routine_privileges
        WHERE routine_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND routine_schema != 'storage'
          AND routine_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
    ) all_grants;
" 2>/dev/null | tr -d '[:space:]' || echo "0")
TARGET_GRANT_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT COUNT(*) FROM (
        SELECT table_schema, table_name, grantee, privilege_type
        FROM information_schema.table_privileges
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        UNION ALL
        SELECT object_schema, object_name, grantee, privilege_type
        FROM information_schema.usage_privileges
        WHERE object_type = 'SEQUENCE'
          AND object_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND object_schema != 'storage'
          AND object_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
        UNION ALL
        SELECT routine_schema, routine_name, grantee, privilege_type
        FROM information_schema.routine_privileges
        WHERE routine_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND routine_schema != 'storage'
          AND routine_schema != 'auth'
          AND grantee NOT IN ('postgres', 'PUBLIC')
    ) all_grants;
" 2>/dev/null | tr -d '[:space:]' || echo "0")

if [ "$SOURCE_GRANT_COUNT" = "$TARGET_GRANT_COUNT" ]; then
    log_success "✓ Grant counts match: $TARGET_GRANT_COUNT grants"
    log_to_file "$LOG_FILE" "SUCCESS: Grant counts match - $TARGET_GRANT_COUNT grants"
else
    GRANT_DIFF=$((SOURCE_GRANT_COUNT - TARGET_GRANT_COUNT))
    if [ "$GRANT_DIFF" -gt 0 ]; then
        log_warning "⚠ Grant count mismatch: Source has $SOURCE_GRANT_COUNT, Target has $TARGET_GRANT_COUNT (missing $GRANT_DIFF grant(s))"
        log_warning "  This indicates missing grants in target. Re-run migration or check grants."
        log_to_file "$LOG_FILE" "WARNING: Grant count mismatch - Source: $SOURCE_GRANT_COUNT, Target: $TARGET_GRANT_COUNT (missing $GRANT_DIFF)"
    else
        log_warning "⚠ Grant count mismatch: Source has $SOURCE_GRANT_COUNT, Target has $TARGET_GRANT_COUNT"
        log_to_file "$LOG_FILE" "WARNING: Grant count mismatch - Source: $SOURCE_GRANT_COUNT, Target: $TARGET_GRANT_COUNT"
    fi
fi

# Diff grants across all schemas (first 30), to detect privilege drift
log_info "Comparing grant entries across all schemas to detect drift..."
GRANTS_SOURCE="$MIGRATION_DIR/grants_source.txt"
GRANTS_TARGET="$MIGRATION_DIR/grants_target.txt"
run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT 'TABLE|' || table_schema || '.' || table_name || '|' || grantee || '|' || privilege_type || '|' || is_grantable
    FROM information_schema.table_privileges
    WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND table_schema != 'auth' AND table_schema != 'storage'
    UNION ALL
    SELECT 'SEQUENCE|' || object_schema || '.' || object_name || '|' || grantee || '|' || privilege_type || '|NO'
    FROM information_schema.usage_privileges
    WHERE object_type='SEQUENCE' AND object_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND object_schema != 'auth' AND object_schema != 'storage'
    UNION ALL
    SELECT 'FUNCTION|' || routine_schema || '.' || routine_name || '(' || pg_get_function_identity_arguments(p.oid) || ')' || '|' || grantee || '|EXECUTE|NO'
    FROM information_schema.routine_privileges rp
    JOIN pg_proc p ON p.proname = rp.routine_name
    JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = rp.routine_schema
    WHERE rp.routine_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND rp.routine_schema != 'auth' AND rp.routine_schema != 'storage'
    ORDER BY 1;
" > "$GRANTS_SOURCE" 2>/dev/null || true
run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT 'TABLE|' || table_schema || '.' || table_name || '|' || grantee || '|' || privilege_type || '|' || is_grantable
    FROM information_schema.table_privileges
    WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND table_schema != 'auth' AND table_schema != 'storage'
    UNION ALL
    SELECT 'SEQUENCE|' || object_schema || '.' || object_name || '|' || grantee || '|' || privilege_type || '|NO'
    FROM information_schema.usage_privileges
    WHERE object_type='SEQUENCE' AND object_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND object_schema != 'auth' AND object_schema != 'storage'
    UNION ALL
    SELECT 'FUNCTION|' || routine_schema || '.' || routine_name || '(' || pg_get_function_identity_arguments(p.oid) || ')' || '|' || grantee || '|EXECUTE|NO'
    FROM information_schema.routine_privileges rp
    JOIN pg_proc p ON p.proname = rp.routine_name
    JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = rp.routine_schema
    WHERE rp.routine_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND rp.routine_schema != 'auth' AND rp.routine_schema != 'storage'
    ORDER BY 1;
" > "$GRANTS_TARGET" 2>/dev/null || true
if [ -s "$GRANTS_SOURCE" ] && [ -s "$GRANTS_TARGET" ]; then
    MISSING_GRANTS=$(comm -23 <(sort "$GRANTS_SOURCE") <(sort "$GRANTS_TARGET") | head -30)
    if [ -n "$MISSING_GRANTS" ]; then
        log_warning "⚠ Grants present in source but missing in target (first 30):"
        echo "$MISSING_GRANTS" | while read -r g; do [ -n "$g" ] && log_warning "  - $g"; done
    else
        log_success "✓ No missing grants detected by entry"
    fi
fi

# Diff policies across all schemas (names), show up to 20 missing in target
log_info "Comparing policy names across all schemas to detect drift..."
POLICY_DIFF_SQL_SOURCE="$MIGRATION_DIR/policy_names_source.txt"
POLICY_DIFF_SQL_TARGET="$MIGRATION_DIR/policy_names_target.txt"
run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT n.nspname || '.' || c.relname || '.' || pol.polname
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND n.nspname != 'storage'
    ORDER BY 1;
" > "$POLICY_DIFF_SQL_SOURCE" 2>/dev/null || true
run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT n.nspname || '.' || c.relname || '.' || pol.polname
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND n.nspname != 'storage'
    ORDER BY 1;
" > "$POLICY_DIFF_SQL_TARGET" 2>/dev/null || true
if [ -s "$POLICY_DIFF_SQL_SOURCE" ] && [ -s "$POLICY_DIFF_SQL_TARGET" ]; then
    MISSING_POLICY_LIST=$(comm -23 <(sort "$POLICY_DIFF_SQL_SOURCE") <(sort "$POLICY_DIFF_SQL_TARGET") | head -20)
    EXTRA_POLICY_LIST=$(comm -13 <(sort "$POLICY_DIFF_SQL_SOURCE") <(sort "$POLICY_DIFF_SQL_TARGET") | head -20)
    if [ -n "$MISSING_POLICY_LIST" ]; then
        log_warning "⚠ Policies present in source but missing in target (first 20):"
        echo "$MISSING_POLICY_LIST" | while read -r p; do [ -n "$p" ] && log_warning "  - $p"; done
    else
        log_success "✓ No missing policies detected by name"
    fi
    if [ -n "$EXTRA_POLICY_LIST" ]; then
        log_warning "⚠ Policies present in target but not in source (first 20):"
        echo "$EXTRA_POLICY_LIST" | while read -r p; do [ -n "$p" ] && log_warning "  - $p"; done
    fi
fi

# Verify All Database Constraints Match (Critical Check)
log_info "Verifying all database constraints match between source and target..."
log_to_file "$LOG_FILE" "Verifying all database constraints match"

# Function to count constraints by type
count_constraints() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    
    local query="
        SELECT 
            'primary_keys' as constraint_type,
            COUNT(*) as count
        FROM information_schema.table_constraints
        WHERE constraint_type = 'PRIMARY KEY'
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        
        UNION ALL
        
        SELECT 
            'foreign_keys' as constraint_type,
            COUNT(*) as count
        FROM information_schema.table_constraints
        WHERE constraint_type = 'FOREIGN KEY'
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        
        UNION ALL
        
        SELECT 
            'unique_constraints' as constraint_type,
            COUNT(*) as count
        FROM information_schema.table_constraints
        WHERE constraint_type = 'UNIQUE'
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        
        UNION ALL
        
        SELECT 
            'check_constraints' as constraint_type,
            COUNT(*) as count
        FROM information_schema.table_constraints
        WHERE constraint_type = 'CHECK'
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        
        UNION ALL
        
        SELECT 
            'not_null_constraints' as constraint_type,
            COUNT(*) as count
        FROM information_schema.columns
        WHERE is_nullable = 'NO'
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth'
        
        UNION ALL
        
        SELECT 
            'default_values' as constraint_type,
            COUNT(*) as count
        FROM information_schema.columns
        WHERE column_default IS NOT NULL
          AND table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema != 'storage'
          AND table_schema != 'auth';
    "
    
    run_psql_query_with_fallback "$ref" "$password" "$pooler_region" "$pooler_port" "$query" 2>/dev/null || echo ""
}

SOURCE_CONSTRAINTS=$(count_constraints "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
TARGET_CONSTRAINTS=$(count_constraints "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")

# Parse and compare constraint counts
CONSTRAINT_MISMATCHES=""
while IFS='|' read -r constraint_type count; do
    [ -z "$constraint_type" ] && continue
    SOURCE_COUNT=$(echo "$SOURCE_CONSTRAINTS" | grep "^${constraint_type}|" | cut -d'|' -f2 | tr -d '[:space:]' || echo "0")
    TARGET_COUNT=$(echo "$TARGET_CONSTRAINTS" | grep "^${constraint_type}|" | cut -d'|' -f2 | tr -d '[:space:]' || echo "0")
    
    if [ "$SOURCE_COUNT" != "$TARGET_COUNT" ]; then
        CONSTRAINT_MISMATCHES="${CONSTRAINT_MISMATCHES}${CONSTRAINT_MISMATCHES:+$'\n'}${constraint_type}|Source: ${SOURCE_COUNT}|Target: ${TARGET_COUNT}"
    fi
done <<< "$SOURCE_CONSTRAINTS"

if [ -z "$CONSTRAINT_MISMATCHES" ]; then
    log_success "✓ All constraint counts match between source and target"
    log_to_file "$LOG_FILE" "SUCCESS: All constraint counts match"
    
    # Show summary
    echo "$SOURCE_CONSTRAINTS" | while IFS='|' read -r constraint_type count; do
        [ -z "$constraint_type" ] && continue
        log_info "  - ${constraint_type}: $count"
    done
else
    MISMATCH_COUNT=$(echo "$CONSTRAINT_MISMATCHES" | grep -c . || echo "0")
    log_warning "⚠ Found $MISMATCH_COUNT constraint type(s) with mismatches!"
    log_warning "  Constraint mismatches:"
    echo "$CONSTRAINT_MISMATCHES" | while IFS='|' read -r constraint_type source_count target_count; do
        [ -z "$constraint_type" ] && continue
        log_warning "    - $constraint_type:"
        log_warning "        $source_count"
        log_warning "        $target_count"
    done
    log_to_file "$LOG_FILE" "WARNING: $MISMATCH_COUNT constraint types have mismatches"
    log_warning "  These constraints need to be verified. pg_dump should include all constraints, but please verify."
fi

# Diff constraint names (first 30) to catch specific missing constraints
log_info "Comparing constraint names to detect drift..."
CONSTRAINTS_SRC="$MIGRATION_DIR/constraints_source.txt"
CONSTRAINTS_TGT="$MIGRATION_DIR/constraints_target.txt"
run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "
    SELECT table_schema || '.' || table_name || '|' || constraint_name || '|' || constraint_type
    FROM information_schema.table_constraints
    WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND table_schema != 'auth' AND table_schema != 'storage'
    ORDER BY 1,2,3;
" > "$CONSTRAINTS_SRC" 2>/dev/null || true
run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "
    SELECT table_schema || '.' || table_name || '|' || constraint_name || '|' || constraint_type
    FROM information_schema.table_constraints
    WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND table_schema != 'auth' AND table_schema != 'storage'
    ORDER BY 1,2,3;
" > "$CONSTRAINTS_TGT" 2>/dev/null || true
if [ -s "$CONSTRAINTS_SRC" ] && [ -s "$CONSTRAINTS_TGT" ]; then
    MISSING_CONSTRAINTS=$(comm -23 <(sort "$CONSTRAINTS_SRC") <(sort "$CONSTRAINTS_TGT") | head -30)
    if [ -n "$MISSING_CONSTRAINTS" ]; then
        log_warning "⚠ Constraints present in source but missing in target (first 30):"
        echo "$MISSING_CONSTRAINTS" | while read -r c; do [ -n "$c" ] && log_warning "  - $c"; done
    else
        log_success "✓ No missing constraints detected by name"
    fi
fi

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Comprehensive Verification Complete"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

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

