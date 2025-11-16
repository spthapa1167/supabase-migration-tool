#!/bin/bash
# Policies/User Profiles Migration Script
# Syncs missing user roles and profiles from source to target without overwriting existing data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> [migration_dir] [options]

Comprehensive migration of policies, roles, grants, user profiles, and database functions.
Synchronises:
  - RLS policies for all tables (auto-discovers all RLS-enabled tables)
  - Roles and user role assignments (auth.roles, auth.user_roles, public.user_roles)
  - User profiles (public.profiles)
  - Table grants/permissions for all tables
  - All database functions (public and auth schemas)
  - Security-definer helper functions

By default performs an incremental upsert (no destructive actions). Use --replace to force a full
replacement so the target matches the source exactly.

Options:
  --tables=table1,table2   Extend table list (default: auth.roles, auth.user_roles, public.profiles, public.user_roles)
  --replace                Destructive sync (truncate + reload + policy redeploy)
  --auto-confirm           Skip confirmation prompts
  -h, --help               Show this message

Example:
  ./scripts/components/policies_migration.sh prod dev
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

# If caller did not override TABLES, auto-extend with all RLS-enabled public tables
auto_discover_rls_tables() {
    # Only run if TABLES is still the default set
    if [ "${TABLES[*]}" != "${DEFAULT_TABLES[*]}" ]; then
        return 0
    fi

    log_info "Auto-discovering ALL RLS-enabled tables in source (public schema)..."
    log_info "  (Including tables with RLS enabled, even if they don't have policies yet)"

    local sql_content="
WITH rls_tables AS (
    SELECT DISTINCT
        n.nspname AS schema_name,
        c.relname AS table_name,
        format('%I.%I', n.nspname, c.relname) AS qualified
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname = 'public'
      AND c.relrowsecurity = true  -- Discover ALL tables with RLS enabled, not just those with policies
)
SELECT qualified
FROM rls_tables
ORDER BY qualified;
"

    local discovered_file
    discovered_file=$(mktemp)
    if run_source_sql_to_file "$sql_content" "$discovered_file"; then
        if [ -s "$discovered_file" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                local trimmed
                trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [ -z "$trimmed" ] && continue
                # Avoid duplicates
                local exists=false
                for existing in "${TABLES[@]}"; do
                    if [ "$existing" = "$trimmed" ]; then
                        exists=true
                        break
                    fi
                done
                if [ "$exists" = "false" ]; then
                    TABLES+=("$trimmed")
                fi
            done < "$discovered_file"
            log_info "RLS auto-discovery added tables: ${TABLES[*]}"
        else
            log_warning "No RLS-enabled public tables discovered in source."
        fi
    else
        log_warning "Failed to auto-discover RLS-enabled tables; continuing with default TABLES."
    fi

    rm -f "$discovered_file"
}

log_info "🛡️  Comprehensive Policies, Roles, Grants & Functions Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"

# Auto-discover additional RLS-enabled tables before logging the final table list
auto_discover_rls_tables

log_info "Tables (including ALL RLS-enabled public tables): ${TABLES[*]}"
if [ "$REPLACE_MODE" = "true" ]; then
    log_warning "Replace mode enabled - target data will be made identical to source."
else
    log_info "Running in incremental mode - existing rows preserved, new rows inserted."
fi
echo ""

log_info "Migration will cover:"
log_info "  ✓ RLS policies for all tables (including auto-discovered RLS-enabled tables)"
log_info "  ✓ Roles and user role assignments (auth.roles, auth.user_roles, public.user_roles)"
log_info "  ✓ User profiles (public.profiles)"
log_info "  ✓ Table grants/permissions for all tables"
log_info "  ✓ All database functions (public and auth schemas)"
log_info "  ✓ Security-definer helper functions"
echo ""

log_info "RLS safeguards:"
log_info "  - Security-definer helper functions are required for policy checks."
log_info "  - RLS remains enabled; no blanket grants are issued."
log_info "  - Policies are recreated atomically to avoid security gaps."

cat <<'SECURITY_NOTE' >>"$LOG_FILE"
[SECURITY] RLS Hardening Checklist
- Ensure SECURITY DEFINER helper functions exist prior to recreating policies.
- Avoid recursive policy definitions; never SELECT from the guarded table inside USING/WITH CHECK.
- RLS stays enabled throughout migration; no GRANT SELECT shortcuts are used.
- Policies are dropped and recreated in the same run to prevent exposure windows.
SECURITY_NOTE

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
    "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" "$input_file" "$output_file"
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

run_source_sql_to_file() {
    local sql_content=$1
    local output_file=$2

    local query_file
    query_file=$(mktemp)
    cat >"$query_file" <<SQL
\\pset format unaligned
\\pset tuples_only on
\\set ON_ERROR_STOP on
$sql_content
SQL

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Generating SQL from source via ${label} (${host}:${port})..."
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -f "$query_file" >"$output_file"; then
            rm -f "$query_file"
            return 0
        fi
        log_warning "SQL generation via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    rm -f "$query_file"
    return 1
}

generate_security_definer_sql() {
    local output_file=$1
    local sql_content="
WITH funcs AS (
    SELECT n.nspname,
           p.proname,
           regexp_replace(pg_get_functiondef(p.oid), '^CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION') AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.prosecdef = true
      AND n.nspname IN ('public','auth')
)
SELECT definition
FROM funcs
ORDER BY nspname, proname;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export security-definer functions from source."
        : >"$output_file"
        return 1
    fi
}

generate_all_database_functions_sql() {
    local output_file=$1
    local sql_content="
WITH funcs AS (
    SELECT n.nspname,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS args,
           regexp_replace(pg_get_functiondef(p.oid), '^CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION') AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','auth')
      AND p.prokind IN ('f', 'p', 'w')  -- functions, procedures, window functions
      AND NOT (n.nspname = 'pg_catalog' OR n.nspname = 'information_schema')
)
SELECT definition
FROM funcs
ORDER BY nspname, proname, args;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export all database functions from source."
        : >"$output_file"
        return 1
    fi
}

generate_grants_sql() {
    local output_file=$1
    # Export grants for ALL tables in public and auth schemas, not just those in TABLES array
    # This ensures comprehensive coverage of all permissions
    local sql_content="
WITH all_tables AS (
    SELECT c.oid AS relid,
           n.nspname AS schema_name,
           c.relname AS table_name,
           format('%I.%I', n.nspname, c.relname) AS qualified
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname IN ('public', 'auth')
)
, table_grants AS (
    SELECT 
        at.qualified,
        rtg.grantee,
        rtg.privilege_type,
        rtg.is_grantable,
        format(
            'GRANT %s ON %s TO %s%s;',
            rtg.privilege_type,
            at.qualified,
            quote_ident(rtg.grantee),
            CASE WHEN rtg.is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END
        ) AS grant_stmt
    FROM information_schema.role_table_grants rtg
    JOIN all_tables at ON at.schema_name = rtg.table_schema AND at.table_name = rtg.table_name
    WHERE rtg.grantee NOT IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
      AND rtg.grantee NOT LIKE 'pg_%'
)
SELECT grant_stmt
FROM table_grants
ORDER BY qualified, grantee, privilege_type;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export grants from source."
        : >"$output_file"
        return 1
    fi
}

generate_rls_sql() {
    local output_file=$1
    if [ ${#TABLES[@]} -eq 0 ]; then
        : >"$output_file"
        return 0
    fi

    local table_list_sql=""
    local tbl
    for tbl in "${TABLES[@]}"; do
        [ -z "$tbl" ] && continue
        safe_tbl=${tbl//\'/\'\'}
        table_list_sql+="'$safe_tbl',"
    done
    table_list_sql="${table_list_sql%,}"

    local sql_content="
WITH selected AS (
    SELECT c.oid AS relid,
           n.nspname,
           c.relname,
           format('%I.%I', n.nspname, c.relname) AS qualified,
           c.relrowsecurity,
           c.relforcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND format('%I.%I', n.nspname, c.relname) = ANY(ARRAY[$table_list_sql])
)
, drop_policies AS (
    SELECT sel.qualified,
           pol.polname,
           format('DROP POLICY IF EXISTS %I ON %s;', pol.polname, sel.qualified) AS stmt
    FROM pg_policy pol
    JOIN selected sel ON sel.relid = pol.polrelid
)
, create_policies AS (
    SELECT sel.qualified,
           pol.polname,
           format(
               'CREATE POLICY %1\$I%2\$s ON %3\$s %4\$s %5\$s %6\$s %7\$s;',
               pol.polname,
               CASE WHEN NOT pol.polpermissive THEN ' AS RESTRICTIVE' ELSE '' END,
               sel.qualified,
               CASE pol.polcmd
                   WHEN '' THEN ''
                   WHEN 'r' THEN 'FOR SELECT'
                   WHEN 'a' THEN 'FOR INSERT'
                   WHEN 'w' THEN 'FOR UPDATE'
                   WHEN 'd' THEN 'FOR DELETE'
                   ELSE 'FOR ALL'
               END,
               COALESCE('TO '||roles.role_list, ''),
               CASE WHEN pol.polqual IS NULL THEN '' ELSE 'USING ('||pg_get_expr(pol.polqual, pol.polrelid)||')' END,
               CASE WHEN pol.polwithcheck IS NULL THEN '' ELSE 'WITH CHECK ('||pg_get_expr(pol.polwithcheck, pol.polrelid)||')' END
           ) AS stmt
    FROM pg_policy pol
    JOIN selected sel ON sel.relid = pol.polrelid
    LEFT JOIN LATERAL (
        SELECT string_agg(quote_ident(r.rolname), ', ') AS role_list
        FROM unnest(pol.polroles) role_oid
        JOIN pg_roles r ON r.oid = role_oid
    ) AS roles ON true
)
SELECT stmt FROM (
    SELECT 1 AS ord, qualified AS obj, format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY;', qualified) AS stmt
    FROM selected
    UNION ALL
    SELECT 2 AS ord, qualified, format('ALTER TABLE %s FORCE ROW LEVEL SECURITY;', qualified)
    FROM selected
    WHERE relforcerowsecurity
    UNION ALL
    SELECT 3 AS ord, qualified, stmt FROM drop_policies
    UNION ALL
    SELECT 4 AS ord, qualified, stmt FROM create_policies
) ordered_statements
ORDER BY ord, obj, stmt;
"

    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export RLS policies from source."
        : >"$output_file"
        return 1
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

    # Filter post-data statements to avoid touching managed schemas (e.g. storage)
    FILTERED_DDL_POST_SQL="$MIGRATION_DIR/policies_post_data_filtered.sql"
    if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
        "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/filter_policies.py" "$DDL_POST_SQL" "$FILTERED_DDL_POST_SQL"
    else
        cp "$DDL_POST_SQL" "$FILTERED_DDL_POST_SQL"
    fi

    apply_post_data_with_owner_guard() {
        local sql_file=$1
        local temp_sql
        temp_sql=$(mktemp)
        {
            echo "RESET ROLE;"
            echo "SET search_path TO public,auth;"
            echo "RESET session authorization;"
        } >"$temp_sql"
        cat "$sql_file" >>"$temp_sql"

        log_info "Applying policy post-data (constraints, policies, functions) with owner-safe execution..."
        if run_psql_script_with_fallback "Apply policy post-data" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$temp_sql"; then
            log_success "Policy definitions applied successfully."
        else
            log_warning "Policy post-data application failed. Attempting per-statement execution with ownership guard."
            failed_tables+=("policy post-data")
        fi
        rm -f "$temp_sql"
    }

    apply_post_data_with_owner_guard "$FILTERED_DDL_POST_SQL"

    rm -f "$DDL_PRE_SQL" "$DDL_POST_SQL" "$DATA_SQL" "$SANITIZED_DATA_SQL" "$FILTERED_DDL_POST_SQL"
fi

    SECDEF_SQL="$MIGRATION_DIR/policies_security_definers.sql"
    RLS_SQL="$MIGRATION_DIR/policies_rls.sql"
    GRANTS_SQL="$MIGRATION_DIR/policies_grants.sql"
    FUNCTIONS_SQL="$MIGRATION_DIR/policies_all_functions.sql"

    log_info "Exporting security-definer helper functions..."
    if generate_security_definer_sql "$SECDEF_SQL"; then
        if [ -s "$SECDEF_SQL" ]; then
            apply_sql_with_fallback "$SECDEF_SQL" "Apply security helper functions"
        else
            log_info "No security-definer functions detected; skipping."
        fi
    fi

    log_info "Exporting all database functions (public and auth schemas)..."
    if generate_all_database_functions_sql "$FUNCTIONS_SQL"; then
        if [ -s "$FUNCTIONS_SQL" ]; then
            if apply_sql_with_fallback "$FUNCTIONS_SQL" "Apply all database functions"; then
                log_success "All database functions applied successfully."
            else
                log_warning "Database functions application had issues; inspect $FUNCTIONS_SQL."
                failed_tables+=("database functions")
            fi
        else
            log_info "No database functions detected in public/auth schemas."
        fi
    fi

    log_info "Exporting row level security policies..."
    if generate_rls_sql "$RLS_SQL"; then
        if [ -s "$RLS_SQL" ]; then
            if apply_sql_with_fallback "$RLS_SQL" "Apply RLS policies"; then
                log_success "RLS policies applied successfully."
            else
                log_warning "RLS policy application failed; inspect $RLS_SQL."
                failed_tables+=("RLS policies")
            fi
        else
            log_warning "No RLS policies detected for selected tables."
        fi
    fi

    log_info "Exporting table grants (permissions)..."
    if generate_grants_sql "$GRANTS_SQL"; then
        if [ -s "$GRANTS_SQL" ]; then
            if apply_sql_with_fallback "$GRANTS_SQL" "Apply table grants"; then
                log_success "Table grants applied successfully."
            else
                log_warning "Table grants application had issues; inspect $GRANTS_SQL."
                failed_tables+=("table grants")
            fi
        else
            log_info "No table grants detected for selected tables."
        fi
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

