#!/bin/bash
# Policies/User Profiles Migration Script
# Syncs missing user roles and profiles from source to target without overwriting existing data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
MIGRATION_DIR=""

DEFAULT_TABLES=("auth.roles" "auth.user_roles" "public.profiles")
TABLES=("${DEFAULT_TABLES[@]}")
AUTO_CONFIRM=${AUTO_CONFIRM:-false}

usage() {
    cat <<'EOF'
Usage: policies_migration.sh <source_env> <target_env> [migration_dir] [options]

Syncs user roles and profile records from source to target. Inserts only missing rows (`ON CONFLICT DO NOTHING`).

Options:
  --tables=table1,table2   Override default tables (auth.roles, auth.user_roles, public.profiles)
  --auto-confirm           Skip confirmation prompts
  -h, --help               Show this message

Example:
  ./scripts/policies_migration.sh prod dev
EOF
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

shift 2 || true

while [ $# -gt 0 ]; do
    case "$1" in
        --tables=*)
            IFS=',' read -r -a TABLES <<< "${1#*=}"
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$MIGRATION_DIR" ]; then
                MIGRATION_DIR="$1"
            else
                log_warning "Ignoring unexpected argument: $1"
            fi
            ;;
    esac
    shift || true
done

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required to transform insert statements."
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

if [ -z "$MIGRATION_DIR" ]; then
    MIGRATION_DIR=$(create_backup_dir "policies" "$SOURCE_ENV" "$TARGET_ENV")
fi
mkdir -p "$MIGRATION_DIR"

cleanup_old_backups "policies" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting policies/profiles migration from $SOURCE_ENV to $TARGET_ENV"

log_info "🛡️  Policies & Profiles Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
log_info "Tables: ${TABLES[*]}"
echo ""

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with policies/profile sync from $SOURCE_ENV to $TARGET_ENV? [y/N]: " reply
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$reply" != "y" ] && [ "$reply" != "yes" ]; then
        log_info "Migration cancelled."
        exit 0
    fi
fi

success_tables=()
failed_tables=()
skipped_tables=()

run_psql_script_direct() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local script_path=$5

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Executing script via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -f "$script_path"; then
            return 0
        fi
        log_warning "Execution failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

transform_inserts() {
    local input_file="$1"
    local output_file="$2"
    "$PYTHON_BIN" <<'PY' "$input_file" "$output_file"
import sys
src, dest = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f_in, open(dest, 'w', encoding='utf-8') as f_out:
    inside = False
    for line in f_in:
        if not inside and line.startswith("INSERT INTO"):
            inside = True
        f_out.write(line)
        if inside and line.rstrip().endswith(';'):
            f_out.seek(f_out.tell() - len(line))
            f_out.write(line.rstrip()[:-1] + " ON CONFLICT DO NOTHING;\n")
            inside = False
PY
}

for table in "${TABLES[@]}"; do
    table_trimmed=$(echo "$table" | xargs)
    [ -z "$table_trimmed" ] && continue
    table_safe=${table_trimmed//./_}
    dump_file="$MIGRATION_DIR/${table_safe}_source.sql"
    upsert_file="$MIGRATION_DIR/${table_safe}_upsert.sql"

    log_info "Dumping data from source table: $table_trimmed"
    if run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        -d postgres --data-only --column-inserts --table="$table_trimmed" --no-owner --no-privileges -f "$dump_file"; then
        log_success "Dump created for $table_trimmed"
    else
        log_warning "Could not dump $table_trimmed (object may be missing or inaccessible); skipping."
        skipped_tables+=("$table_trimmed (dump unavailable)")
        rm -f "$dump_file"
        continue
    fi

    log_info "Transforming insert statements for $table_trimmed"
    "$PYTHON_BIN" "$PROJECT_ROOT/scripts/utils/sql_add_on_conflict.py" "$dump_file" "$upsert_file"

    if [ ! -s "$upsert_file" ]; then
        log_warning "No data found for $table_trimmed; skipping insert."
        success_tables+=("$table_trimmed (no new rows)")
        rm -f "$dump_file" "$upsert_file"
        continue
    fi

    log_info "Upserting records into target table: $table_trimmed"
    if type run_psql_script_with_fallback >/dev/null 2>&1; then
        if run_psql_script_with_fallback "Upsert $table_trimmed" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$upsert_file"; then
            log_success "Upsert completed for $table_trimmed"
            success_tables+=("$table_trimmed")
        else
            log_error "Upsert failed for $table_trimmed"
            failed_tables+=("$table_trimmed")
        fi
    else
        if run_psql_script_direct "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$upsert_file"; then
            log_success "Upsert completed for $table_trimmed"
            success_tables+=("$table_trimmed")
        else
            log_error "Upsert failed for $table_trimmed"
            failed_tables+=("$table_trimmed")
        fi
    fi
done

rm -f "$MIGRATION_DIR"/*_source.sql "$MIGRATION_DIR"/*_upsert.sql 2>/dev/null || true

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ${#success_tables[@]} -gt 0 ]; then
    log_success "Tables processed successfully: ${success_tables[*]}"
fi
if [ ${#failed_tables[@]} -gt 0 ]; then
    log_warning "Tables with errors: ${failed_tables[*]}"
else
    log_success "No table errors reported."
fi
if [ ${#skipped_tables[@]} -gt 0 ]; then
    log_warning "Tables skipped: ${skipped_tables[*]}"
fi
log_info "Logs: $LOG_FILE"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#failed_tables[@]} -gt 0 ]; then
    exit 1
fi
exit 0

