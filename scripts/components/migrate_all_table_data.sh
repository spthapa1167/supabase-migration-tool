#!/bin/bash
# Replace target public schema with source public schema (schema + data).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<'EOF'
Usage: migrate_all_table_data.sh <source_env> <target_env> [--auto-confirm]

Performs a destructive replacement of the entire public schema in the target
environment so that schema and row counts match the source exactly.
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

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
    log_error "Source and target environments must differ."
    exit 1
fi

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

SOURCE_DIRECT_HOST="db.${SOURCE_REF}.supabase.co"
SOURCE_DIRECT_PORT="5432"
SOURCE_DIRECT_USER="postgres.${SOURCE_REF}"

TARGET_DIRECT_HOST="db.${TARGET_REF}.supabase.co"
TARGET_DIRECT_PORT="5432"
TARGET_DIRECT_USER="postgres.${TARGET_REF}"

REQUIRED_BINARIES=(psql pg_dump pg_restore)
for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log_error "Required command not found: $bin"
        exit 1
    fi
done

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [[ -z "$PYTHON_BIN" ]]; then
    log_error "python3 or python is required."
    exit 1
fi

prompt_confirm() {
    if $AUTO_CONFIRM; then
        return 0
    fi
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Public Schema Replacement"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "Source: $SOURCE_ENV ($SOURCE_REF)"
    log_warning "Target: $TARGET_ENV ($TARGET_REF)"
    log_warning "Action: Target public schema will be dropped and replaced."
    read -r -p "Proceed with destructive replacement? [y/N]: " reply
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

if ! prompt_confirm; then
    log_info "Operation cancelled."
    exit 0
fi

MIGRATION_DIR=$(create_backup_dir "table_data" "$SOURCE_ENV" "$TARGET_ENV")
LOG_FILE="$MIGRATION_DIR/migration.log"
DUMP_FILE="$MIGRATION_DIR/public_schema.dump"

log_to_file "$LOG_FILE" "Replacing public schema from $SOURCE_ENV to $TARGET_ENV"

dump_public_schema() {
    local dump_args=(
        --format=custom
        --clean
        --if-exists
        --schema=public
        --no-owner
        --no-privileges
        --dbname=postgres
        --file="$DUMP_FILE"
    )

    log_info "Dumping public schema from $SOURCE_ENV via pooler..."
    export PGOPTIONS="-c project=$SOURCE_REF"
    log_info "Using PGOPTIONS=$PGOPTIONS"
    if run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" "${dump_args[@]}"; then
        unset PGOPTIONS
        log_success "pg_dump completed via pooler."
        return 0
    fi
    unset PGOPTIONS

    log_warning "Pooler pg_dump failed; attempting direct connection..."
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
        pg_dump -h "$SOURCE_DIRECT_HOST" -p "$SOURCE_DIRECT_PORT" -U "$SOURCE_DIRECT_USER" \
        -d postgres "${dump_args[@]}" >>"$LOG_FILE" 2>&1; then
        log_success "Direct pg_dump completed."
        return 0
    fi

    log_error "Unable to dump public schema from source."
    return 1
}

evaluate_restore_output() {
    local status=$1
    local output_file=$2
    local section=$3

    if [ $status -eq 0 ]; then
        log_success "pg_restore ($section) completed successfully."
        return 0
    fi

    if grep -qiE "(FATAL:|could not connect|authentication failed|connection .* failed|SSL connection has been closed|Terminated)" "$output_file" 2>/dev/null; then
        log_warning "pg_restore ($section) encountered fatal connection errors."
        return 1
    fi

    local filtered_errors
    filtered_errors=$(grep -iE "error:" "$output_file" 2>/dev/null | grep -viE "(errors ignored|already exists|does not exist|permission denied to set role|must be owner of)" || true)

    if [ -z "$filtered_errors" ]; then
        local ignored_count
        ignored_count=$(grep -i "errors ignored on restore" "$output_file" 2>/dev/null | sed -n 's/.*errors ignored on restore: \([0-9]*\).*/\1/p' | head -1 || echo "some")
        log_success "pg_restore ($section) completed with expected warnings (exit code: $status, ignored: $ignored_count)."
        return 0
    fi

    log_warning "pg_restore ($section) reported non-ignorable errors:"
    echo "$filtered_errors" | sed 's/^/    /' >&2
    return 1
}

run_pg_restore_section() {
    local section=$1
    shift
    local extra_args=("$@")
    local restore_args=(
        --section="$section"
        --schema=public
        --no-owner
        --no-privileges
        --dbname=postgres
    )
    if [ "$#" -gt 0 ]; then
        restore_args+=("${extra_args[@]}")
    fi
    restore_args+=("$DUMP_FILE")

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    local temp_log status

    while IFS='|' read -r host port user label; do
        [[ -z "$host" ]] && continue
        log_info "Restoring $section to $TARGET_ENV via ${label}..."
        temp_log=$(mktemp)
        export PGOPTIONS="-c project=$TARGET_REF"
        set +e
        PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require \
            pg_restore -h "$host" -p "$port" -U "$user" "${restore_args[@]}" >"$temp_log" 2>&1
        status=$?
        set -e
        unset PGOPTIONS
        cat "$temp_log" >>"$LOG_FILE"
        if evaluate_restore_output $status "$temp_log" "$section"; then
            rm -f "$temp_log"
            return 0
        fi
        rm -f "$temp_log"
        log_warning "pg_restore ($section) via ${label} did not complete cleanly; trying next endpoint..."
    done <<< "$endpoints"

    log_warning "Pooler endpoints exhausted; attempting direct connection for $section..."
    temp_log=$(mktemp)
    set +e
    PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require \
        pg_restore -h "$TARGET_DIRECT_HOST" -p "$TARGET_DIRECT_PORT" -U "$TARGET_DIRECT_USER" "${restore_args[@]}" >"$temp_log" 2>&1
    status=$?
    set -e
    cat "$temp_log" >>"$LOG_FILE"
    if evaluate_restore_output $status "$temp_log" "$section"; then
        rm -f "$temp_log"
        return 0
    fi
    rm -f "$temp_log"

    log_error "Unable to restore $section to target."
    return 1
}

psql_execute_target_file() {
    local file=$1
    [[ ! -s "$file" ]] && return 0
    log_info "Applying post-data SQL against $TARGET_ENV..."
    export PGOPTIONS="-c project=$TARGET_REF"
    while IFS='|' read -r host port user label; do
        [[ -z "$host" ]] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require \
            psql -h "$host" -p "$port" -U "$user" -d postgres \
            -v ON_ERROR_STOP=1 -q -f "$file" >>"$LOG_FILE" 2>&1; then
            unset PGOPTIONS
            log_success "Post-data SQL applied via ${label}."
            return 0
        fi
        log_warning "Failed to apply post-data SQL via ${label}; trying next endpoint..."
    done < <(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    unset PGOPTIONS
    return 1
}

log_info "Migration workspace: $MIGRATION_DIR"

if ! dump_public_schema; then
    log_error "Public schema dump failed. See $LOG_FILE"
    exit 1
fi

POST_SQL_RAW="$MIGRATION_DIR/public_post_data.sql"
POST_SQL_FILTERED="$MIGRATION_DIR/public_post_data.filtered.sql"

if ! pg_restore --section=post-data --schema=public --no-owner --no-privileges --file="$POST_SQL_RAW" "$DUMP_FILE"; then
    log_error "Failed to extract post-data SQL."
    exit 1
fi

if ! "$PYTHON_BIN" - "$POST_SQL_RAW" "$POST_SQL_FILTERED" <<'PY'
import sys
src_path, dst_path = sys.argv[1], sys.argv[2]
buffer = []
skip_block = False
with open(src_path, "r", encoding="utf-8") as src, open(dst_path, "w", encoding="utf-8") as dst:
    for line in src:
        if skip_block:
            if line.strip() == "":
                skip_block = False
            continue
        if "REFERENCES auth." in line or 'REFERENCES "auth".' in line:
            buffer = []
            skip_block = True
            continue
        if line.startswith("ALTER TABLE"):
            buffer = [line]
            continue
        if buffer:
            buffer.append(line)
            for buffered_line in buffer:
                dst.write(buffered_line)
            buffer = []
        else:
            dst.write(line)
PY
then
    log_error "Failed to filter post-data SQL."
    exit 1
fi

rm -f "$POST_SQL_RAW"

RESET_SQL="$MIGRATION_DIR/reset_public_schema.sql"
cat >"$RESET_SQL" <<'SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
SQL

if ! psql_execute_target_file "$RESET_SQL"; then
    log_error "Failed to reset target public schema."
    exit 1
fi

rm -f "$RESET_SQL"

if ! run_pg_restore_section pre-data --clean --if-exists; then
    log_error "Pre-data restore failed. See $LOG_FILE"
    exit 1
fi

if ! run_pg_restore_section data; then
    log_error "Data restore failed. See $LOG_FILE"
    exit 1
fi

if ! psql_execute_target_file "$POST_SQL_FILTERED"; then
    log_warning "Post-data SQL execution encountered issues. Check $LOG_FILE"
fi

rm -f "$POST_SQL_FILTERED"

log_success "Public schema replaced successfully. Details logged at $LOG_FILE"
exit 0
