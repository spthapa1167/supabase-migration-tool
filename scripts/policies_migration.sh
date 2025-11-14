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

DEFAULT_TABLES=("auth.roles" "auth.user_roles" "public.profiles" "public.user_roles")
TABLES=("${DEFAULT_TABLES[@]}")
AUTO_CONFIRM=${AUTO_CONFIRM:-false}
REPLACE_MODE=false

usage() {
    cat <<'EOF'
Usage: policies_migration.sh <source_env> <target_env> [migration_dir] [options]

Synchronises roles, role assignments, profiles, and policy-related tables between environments.
By default performs an incremental upsert (no destructive actions). Use --replace to force a full
replacement so the target matches the source exactly.

Options:
  --tables=table1,table2   Extend table list (auth.roles, auth.user_roles, public.profiles, public.user_roles)
  --replace                Destructive sync (truncate + reload + policy redeploy)
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
        --replace)
            REPLACE_MODE=true
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

FINAL_TABLES=()

discover_role_tables() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query="
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema IN ('auth','public')
          AND (table_name ILIKE '%role%' OR table_name ILIKE '%user_role%')
        ORDER BY 1;
    "

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        output=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null) && printf "%s\n" "$output" && return 0
        log_warning "Table discovery failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

add_unique_table() {
    local candidate
    candidate=$(echo "$1" | xargs)
    [[ -z "$candidate" || "$candidate" != *.* ]] && return 0
    local existing
    if [ ${#FINAL_TABLES[@]} -gt 0 ]; then
        for existing in "${FINAL_TABLES[@]}"; do
            if [ "$existing" = "$candidate" ]; then
                return 0
            fi
        done
    fi
    FINAL_TABLES+=("$candidate")
}

for tbl in "${TABLES[@]}"; do
    add_unique_table "$tbl"
done

while IFS= read -r line; do
    add_unique_table "$line"
done <<EOF
$(discover_role_tables "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" || echo "")
EOF

if [ ${#FINAL_TABLES[@]} -eq 0 ]; then
    log_warning "No role-related tables discovered; nothing to migrate."
    exit 0
fi

TABLES=("${FINAL_TABLES[@]}")

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
if [ "$REPLACE_MODE" = "true" ]; then
    log_warning "Replace mode enabled - target data will be made identical to source."
else
    log_info "Running in incremental mode - existing rows preserved, new rows inserted."
fi
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
    "$PYTHON_BIN" "$PROJECT_ROOT/scripts/utils/sql_add_on_conflict.py" "$input_file" "$output_file"
}

discover_role_tables() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query="
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema IN ('auth','public')
          AND (table_name ILIKE '%role%' OR table_name ILIKE '%user_role%')
        ORDER BY 1;
    "

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        output=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null) && printf "%s\n" "$output" && return 0
        log_warning "Table discovery failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

dump_table_incremental() {
    local table_identifier=$1
    local dump_file=$2
    local upsert_file=$3
    local table_schema=${table_identifier%%.*}
    local table_name=${table_identifier#*.}
    [ -z "$table_schema" ] && table_schema="public"

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    local dump_success=false

    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Dumping $table_identifier via ${label} (${host}:${port})"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$host" -p "$port" -U "$user" \
            -d postgres --data-only --column-inserts \
            --schema="$table_schema" --table="$table_name" \
            --no-owner --no-privileges -f "$dump_file" >>"$LOG_FILE" 2>&1; then
            dump_success=true
            break
        fi
        log_warning "Dump via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    if [ "$dump_success" = false ]; then
        local direct_host="db.${SOURCE_REF}.supabase.co"
        local direct_user="postgres"
        log_warning "Pooler dump failed; attempting direct connection for $table_identifier..."
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$direct_host" -p 5432 -U "$direct_user" \
            -d postgres --data-only --column-inserts \
            --schema="$table_schema" --table="$table_name" \
            --no-owner --no-privileges -f "$dump_file" >>"$LOG_FILE" 2>&1; then
            dump_success=true
        fi
    fi

    if [ "$dump_success" = false ]; then
        log_warning "Direct pg_dump failed for $table_identifier; attempting CSV fallback..."
        local csv_file="$MIGRATION_DIR/${table_schema}_${table_name}_fallback.csv"
        if copy_table_to_csv "$table_schema" "$table_name" "$csv_file"; then
            if convert_csv_to_sql "$csv_file" "$dump_file" "$table_schema" "$table_name"; then
                dump_success=true
                log_success "Fallback CSV export succeeded for $table_identifier"
            else
                log_warning "Failed to convert CSV fallback for $table_identifier"
            fi
        else
            log_warning "CSV fallback export failed for $table_identifier"
        fi
        rm -f "$csv_file"
    fi

    if [ "$dump_success" = false ]; then
        log_warning "Could not dump $table_identifier (object may be missing or inaccessible); skipping."
        skipped_tables+=("$table_identifier (dump unavailable)")
        rm -f "$dump_file"
        return 1
    fi

    log_success "Dump created for $table_identifier"

    log_info "Transforming insert statements for $table_identifier"
    transform_inserts "$dump_file" "$upsert_file"

    if [ ! -s "$upsert_file" ]; then
        log_warning "No data found for $table_identifier; skipping insert."
        success_tables+=("$table_identifier (no new rows)")
        rm -f "$dump_file" "$upsert_file"
        return 1
    fi
    return 0
}

copy_table_to_csv() {
    local schema=$1
    local table=$2
    local output_csv=$3
    local identifier="\"${schema}\".\"${table}\""

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Attempting CSV export of ${schema}.${table} via ${label}"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            psql -h "$host" -p "$port" -U "$user" -d postgres \
            -v ON_ERROR_STOP=1 \
            -c "\copy (SELECT * FROM ${identifier}) TO '${output_csv}' WITH CSV HEADER" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        log_warning "CSV export via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    local direct_host="db.${SOURCE_REF}.supabase.co"
    local direct_user="postgres"
    log_warning "CSV export via pooler failed; attempting direct connection..."
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
        psql -h "$direct_host" -p 5432 -U "$direct_user" -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "\copy (SELECT * FROM ${identifier}) TO '${output_csv}' WITH CSV HEADER" >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    return 1
}

convert_csv_to_sql() {
    local csv_file=$1
    local sql_file=$2
    local schema=$3
    local table=$4
    "$PYTHON_BIN" - "$csv_file" "$sql_file" "$schema" "$table" <<'PY'
import csv
import sys

csv_path, sql_path, schema, table = sys.argv[1:5]
table_ident = f'"{schema}"."{table}"'

with open(csv_path, newline='', encoding='utf-8') as src, open(sql_path, 'w', encoding='utf-8') as dst:
    reader = csv.DictReader(src)
    if reader.fieldnames is None:
        raise SystemExit("CSV fallback has no header")
    columns = [f'"{col}"' for col in reader.fieldnames]
    columns_joined = ", ".join(columns)
    for row in reader:
        values = []
        for col in reader.fieldnames:
            val = row[col]
            if val == "":
                values.append("NULL")
            else:
                escaped = val.replace("'", "''")
                values.append(f"'{escaped}'")
        values_joined = ", ".join(values)
        dst.write(f"INSERT INTO {table_ident} ({columns_joined}) VALUES ({values_joined});\n")
PY
}

apply_sql_with_fallback() {
    local sql_file=$1
    local label=$2
    if type run_psql_script_with_fallback >/dev/null 2>&1; then
        run_psql_script_with_fallback "$label" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$sql_file"
    else
        run_psql_script_direct "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$sql_file"
    fi
}

dump_schema_section() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local section=$5
    local output=$6
    shift 6
    local extra_args=("$@")
    if [ ${#extra_args[@]} -gt 0 ]; then
        run_pg_tool_with_fallback "pg_dump" "$ref" "$password" "$pooler_region" "$pooler_port" "$LOG_FILE" \
            -d postgres --schema-only --no-owner --no-privileges --section="$section" -N "pg_catalog" -N "information_schema" -f "$output" "${extra_args[@]}"
    else
        run_pg_tool_with_fallback "pg_dump" "$ref" "$password" "$pooler_region" "$pooler_port" "$LOG_FILE" \
            -d postgres --schema-only --no-owner --no-privileges --section="$section" -N "pg_catalog" -N "information_schema" -f "$output"
    fi
}

DATA_SQL="$MIGRATION_DIR/policies_data.sql"
SANITIZED_DATA_SQL="$MIGRATION_DIR/policies_data_sanitized.sql"
DDL_PRE_SQL="$MIGRATION_DIR/policies_pre_data.sql"
DDL_POST_SQL="$MIGRATION_DIR/policies_post_data.sql"

if $REPLACE_MODE; then
    log_info "Exporting full schema/policy definitions from source..."
    dump_schema_section "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" pre-data "$DDL_PRE_SQL"
    dump_schema_section "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" post-data "$DDL_POST_SQL"

    log_info "Exporting policy table data from source..."
    DATA_TABLE_ARGS=()
    DATA_SCHEMA_ARGS=()
    for tbl in "${TABLES[@]}"; do
        schema=${tbl%%.*}
        name=${tbl#*.}
        DATA_TABLE_ARGS+=(--table="${name}")
        if [ -n "$schema" ]; then
            DATA_SCHEMA_ARGS+=(--schema="${schema}")
        fi
    done
    # Deduplicate schema arguments
    if [ ${#DATA_SCHEMA_ARGS[@]} -gt 0 ]; then
        DATA_SCHEMA_ARGS=($(printf "%s\n" "${DATA_SCHEMA_ARGS[@]}" | sort -u))
    fi
    if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        -d postgres --data-only --no-owner --no-privileges -f "$DATA_SQL" "${DATA_SCHEMA_ARGS[@]}" "${DATA_TABLE_ARGS[@]}"; then
        log_error "Failed to export policy table data."
        exit 1
    fi

    log_info "Sanitising data SQL..."
    if ! "$PYTHON_BIN" - "$DATA_SQL" "$SANITIZED_DATA_SQL" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as infile, open(dst, "w", encoding="utf-8") as outfile:
    for line in infile:
        if line.lstrip().upper().startswith("SELECT PG_CATALOG.SETVAL"):
            continue
        outfile.write(line)
PY
    then
        log_error "Failed to sanitise policy data SQL."
        exit 1
    fi
fi

for table in "${TABLES[@]}"; do
    table_trimmed=$(echo "$table" | xargs)
    [ -z "$table_trimmed" ] && continue
    table_safe=${table_trimmed//./_}
    table_schema=${table_trimmed%%.*}
    table_name=${table_trimmed#*.}
    quoted_table="\"${table_schema}\".\"${table_name}\""
    table_identifier="${table_schema}.${table_name}"

    if $REPLACE_MODE; then
        log_info "Truncating target table: $table_trimmed"
        TRUNCATE_SQL_TEMP="$MIGRATION_DIR/truncate_${table_safe}.sql"
        printf 'TRUNCATE TABLE %s RESTART IDENTITY CASCADE;\n' "$quoted_table" >"$TRUNCATE_SQL_TEMP"
        if ! apply_sql_with_fallback "$TRUNCATE_SQL_TEMP" "Truncate $table_trimmed"; then
            log_error "Failed to truncate $table_trimmed"
            failed_tables+=("$table_trimmed")
            rm -f "$TRUNCATE_SQL_TEMP"
            continue
        fi
        rm -f "$TRUNCATE_SQL_TEMP"
        success_tables+=("$table_trimmed (truncated)")
    else
        dump_file="$MIGRATION_DIR/${table_safe}_source.sql"
        upsert_file="$MIGRATION_DIR/${table_safe}_upsert.sql"
        if ! dump_table_incremental "$table_identifier" "$dump_file" "$upsert_file"; then
            continue
        fi
        if apply_sql_with_fallback "$upsert_file" "Upsert $table_trimmed"; then
            log_success "Upsert completed for $table_trimmed"
            success_tables+=("$table_trimmed")
        else
            log_error "Upsert failed for $table_trimmed"
            failed_tables+=("$table_trimmed")
        fi
        rm -f "$dump_file" "$upsert_file"
    fi
done

if $REPLACE_MODE; then
    log_info "Applying schema pre-data (type definitions, etc.)..."
    apply_sql_with_fallback "$DDL_PRE_SQL" "Apply policy schema pre-data" || failed_tables+=("schema pre-data")

    log_info "Applying policy data..."
    if apply_sql_with_fallback "$SANITIZED_DATA_SQL" "Insert policy data"; then
        log_success "Policy data applied successfully."
    else
        log_error "Policy data application failed."
        failed_tables+=("policy data")
    fi

    log_info "Applying policy post-data (constraints, policies, functions)..."
    if apply_sql_with_fallback "$DDL_POST_SQL" "Apply policy post-data"; then
        log_success "Policy definitions applied successfully."
    else
        log_error "Policy post-data application failed."
        failed_tables+=("policy post-data")
    fi

    rm -f "$DDL_PRE_SQL" "$DDL_POST_SQL" "$DATA_SQL" "$SANITIZED_DATA_SQL"
fi

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

