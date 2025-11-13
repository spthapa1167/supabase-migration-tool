#!/bin/bash
# Sync auth system tables (audit logs, sessions, tokens) and Supabase migration metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<'EOF'
Usage: auth_system_tables_migration.sh <source_env> <target_env> [--auto-confirm]

Copies managed auth tables (audit logs, sessions, tokens, MFA) and Supabase migration
metadata from the source environment into the target. Target tables are truncated
prior to import to guarantee a perfect match.
EOF
    exit 1
}

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}

if [[ -z "$SOURCE_ENV" || -z "$TARGET_ENV" ]]; then
    usage
fi

shift 2 || true

AUTO_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift || true
done

if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
    log_error "Source and target environments must differ."
    exit 1
fi

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"
log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [[ -z "$PYTHON_BIN" ]]; then
    log_error "python3 or python is required."
    exit 1
fi

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

TARGET_DIRECT_HOST="db.${TARGET_REF}.supabase.co"
TARGET_DIRECT_PORT="5432"
TARGET_DIRECT_USER="postgres.${TARGET_REF}"

REQUIRED_BINARIES=(pg_dump pg_restore psql)
for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log_error "Required command not found: $bin"
        exit 1
    fi
done

TABLES=(
    "auth.audit_log_entries"
    "auth.mfa_amr_claims"
    "auth.one_time_tokens"
    "auth.refresh_tokens"
    "auth.sessions"
    "supabase_migrations.schema_migrations"
)

prompt_confirm() {
    if $AUTO_CONFIRM; then
        return 0
    fi
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Auth System Tables Sync"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "Source: $SOURCE_ENV ($SOURCE_REF)"
    log_warning "Target: $TARGET_ENV ($TARGET_REF)"
    log_warning "Action: Replace managed auth tables and Supabase migration metadata."
    read -r -p "Proceed with destructive sync? [y/N]: " reply
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

if ! prompt_confirm; then
    log_info "Operation cancelled."
    exit 0
fi

MIGRATION_DIR=$(create_backup_dir "auth_system_tables" "$SOURCE_ENV" "$TARGET_ENV")
LOG_FILE="$MIGRATION_DIR/migration.log"
DUMP_FILE="$MIGRATION_DIR/auth_system_tables.dump"
TRUNCATE_SQL="$MIGRATION_DIR/truncate_tables.sql"
DELETE_SQL="$MIGRATION_DIR/delete_auth_tables.sql"
RESTORE_SQL_RAW="$MIGRATION_DIR/auth_system_data_raw.sql"
RESTORE_SQL="$MIGRATION_DIR/auth_system_data.sql"

log_to_file "$LOG_FILE" "Syncing auth system tables from $SOURCE_ENV to $TARGET_ENV"

dump_tables() {
    local dump_args=(
        --format=custom
        --data-only
        --no-owner
        --no-privileges
        --dbname=postgres
        --file="$DUMP_FILE"
    )

    for table in "${TABLES[@]}"; do
        dump_args+=(--table="$table")
    done

    log_info "Dumping auth system tables from $SOURCE_ENV..."
    export PGOPTIONS="-c project=$SOURCE_REF"
    if run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" "${dump_args[@]}"; then
        unset PGOPTIONS
        return 0
    fi
    unset PGOPTIONS

    log_warning "Pooler pg_dump failed; attempting direct connection..."
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
        pg_dump -h "db.${SOURCE_REF}.supabase.co" -p 5432 -U "postgres.${SOURCE_REF}" \
        -d postgres "${dump_args[@]}" >>"$LOG_FILE" 2>&1; then
        log_success "Direct pg_dump completed."
        return 0
    fi

    log_error "Unable to dump auth system tables from source."
    return 1
}

psql_execute_target_file() {
    local file=$1
    [[ ! -s "$file" ]] && return 0
    export PGOPTIONS="-c project=$TARGET_REF"
    while IFS='|' read -r host port user label; do
        [[ -z "$host" ]] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require \
            psql -h "$host" -p "$port" -U "$user" -d postgres \
            -v ON_ERROR_STOP=1 -q -f "$file" >>"$LOG_FILE" 2>&1; then
            unset PGOPTIONS
            log_success "Executed $file via ${label}."
            return 0
        fi
        log_warning "Failed to execute $file via ${label}; trying next endpoint..."
    done < <(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT"; echo "${TARGET_DIRECT_HOST}|${TARGET_DIRECT_PORT}|${TARGET_DIRECT_USER}|direct_5432")
    unset PGOPTIONS
    return 1
}

generate_truncate_sql() {
    : >"$TRUNCATE_SQL"
    for table in "${TABLES[@]}"; do
        echo "TRUNCATE ${table} RESTART IDENTITY CASCADE;" >>"$TRUNCATE_SQL"
    done
}

generate_delete_sql() {
    : >"$DELETE_SQL"
    {
        echo "BEGIN;"
        for table in "${TABLES[@]}"; do
            echo "DELETE FROM ${table};"
        done
        echo "COMMIT;"
    } >>"$DELETE_SQL"
}

generate_restore_sql() {
    local restore_args=(
        --data-only
        --no-owner
        --no-privileges
    )
    for table in "${TABLES[@]}"; do
        restore_args+=(--table="$table")
    done
    restore_args+=(
        --file="$RESTORE_SQL_RAW"
        "$DUMP_FILE"
    )

    if ! pg_restore "${restore_args[@]}" >>"$LOG_FILE" 2>&1; then
        log_error "Failed to extract auth system data from dump."
        return 1
    fi

    if ! "$PYTHON_BIN" - "$RESTORE_SQL_RAW" "$RESTORE_SQL" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as infile, open(dst, "w", encoding="utf-8") as outfile:
    for line in infile:
        if "SELECT pg_catalog.setval" in line:
            continue
        outfile.write(line)
PY
    then
        log_error "Failed to sanitize auth system SQL."
        return 1
    fi

    rm -f "$RESTORE_SQL_RAW"
    return 0
}

log_info "Migration workspace: $MIGRATION_DIR"

if ! dump_tables; then
    log_error "Auth system table dump failed. See $LOG_FILE"
    exit 1
fi

generate_truncate_sql

generate_delete_sql

if ! psql_execute_target_file "$TRUNCATE_SQL"; then
    log_warning "TRUNCATE failed (likely due to sequence ownership). Falling back to DELETE statements."
    if ! psql_execute_target_file "$DELETE_SQL"; then
        log_error "Failed to delete target auth system table data."
        exit 1
    fi
else
    log_success "Target auth system tables truncated successfully."
fi
rm -f "$TRUNCATE_SQL" "$DELETE_SQL"

if ! generate_restore_sql; then
    exit 1
fi

if ! psql_execute_target_file "$RESTORE_SQL"; then
    log_error "Auth system table restore failed. See $LOG_FILE"
    exit 1
fi
rm -f "$RESTORE_SQL"

log_success "Auth system tables synced successfully. Details logged at $LOG_FILE"
exit 0

