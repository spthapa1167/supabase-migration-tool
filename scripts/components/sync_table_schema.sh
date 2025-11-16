#!/bin/bash
# Sync a single public table schema from source to target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
mkdir -p "$PROJECT_ROOT/logs"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> <table_name> [--schema <schema_name>]

Synchronizes the schema for a specific table from source to target environment.
Only schema changes are applied; data remains untouched.

Arguments:
  source_env   Source environment alias (prod, test, dev, backup)
  target_env   Target environment alias (prod, test, dev, backup)
  table_name   Table name inside the schema (default schema is public)

Options:
  --schema <name>   Schema name (default: public)
  -h, --help        Show this help message
EOF
    exit 1
}

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
TABLE_NAME=${3:-}
shift 3 2>/dev/null || true

SCHEMA_NAME="public"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --schema)
            SCHEMA_NAME=${2:-}
            shift 2 || usage
            ;;
        --schema=*)
            SCHEMA_NAME="${1#*=}"
            shift
            ;;
        -s)
            SCHEMA_NAME=${2:-}
            shift 2 || usage
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_warning "Unknown option: $1"
            shift
            ;;
    esac
done

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ] || [ -z "$TABLE_NAME" ]; then
    usage
fi

if [[ ! "$TABLE_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Table name must contain only letters, numbers, and underscores."
    exit 1
fi

if [[ ! "$SCHEMA_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Schema name must contain only letters, numbers, and underscores."
    exit 1
fi

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "sync_table_schema" "$SOURCE_ENV" "$TARGET_ENV"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required but not found in PATH."
    exit 1
fi

SOURCE_COLUMNS_JSON=$(mktemp)
TARGET_COLUMNS_JSON=$(mktemp)
PLAN_JSON_FILE=$(mktemp)
SQL_PLAN_FILE=$(mktemp)
trap 'rm -f "$SOURCE_COLUMNS_JSON" "$TARGET_COLUMNS_JSON" "$PLAN_JSON_FILE" "$SQL_PLAN_FILE"' EXIT

fetch_columns_json() {
    local ref=$1
    local password=$2
    local region=$3
    local port=$4
    local schema=$5
    local table=$6
    local output=$7

    local query="
WITH column_data AS (
    SELECT 
        c.column_name,
        c.data_type,
        c.is_nullable,
        c.column_default,
        c.ordinal_position,
        format_type(a.atttypid, a.atttypmod) AS formatted_type
    FROM information_schema.columns c
    JOIN pg_catalog.pg_attribute a
        ON a.attrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
       AND a.attname = c.column_name
       AND a.attnum > 0
       AND a.attisdropped = false
    WHERE c.table_schema = '${schema}'
      AND c.table_name = '${table}'
)
SELECT COALESCE(json_agg(
    json_build_object(
        'name', column_name,
        'data_type', data_type,
        'formatted_type', formatted_type,
        'is_nullable', is_nullable,
        'column_default', column_default,
        'ordinal_position', ordinal_position
    ) ORDER BY ordinal_position
), '[]'::json)
FROM column_data;"

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$region" "$port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A -F '' --no-align --quiet \
            -c "$query" >"$output" 2>/dev/null; then
            return 0
        fi
    done <<<"$endpoints"

    local direct_host="db.${ref}.supabase.co"
    if PGPASSWORD="$password" PGSSLMODE=require psql \
        -h "$direct_host" \
        -p 5432 \
        -U "postgres" \
        -d postgres \
        -t -A -F '' --no-align --quiet \
        -c "$query" >"$output" 2>/dev/null; then
        return 0
    fi

    return 1
}

table_exists() {
    local ref=$1
    local password=$2
    local region=$3
    local port=$4
    local schema=$5
    local table=$6
    local result

    local query="SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema='${schema}' AND table_name='${table}'
    );"

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$region" "$port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        result=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A -F '' --no-align --quiet \
            -c "$query" 2>/dev/null | tr -d '[:space:]')
        if [ "$result" = "t" ] || [ "$result" = "f" ]; then
            [ "$result" = "t" ] && return 0 || return 1
        fi
    done <<<"$endpoints"

    local direct_host="db.${ref}.supabase.co"
    result=$(PGPASSWORD="$password" PGSSLMODE=require psql \
        -h "$direct_host" \
        -p 5432 \
        -U "postgres" \
        -d postgres \
        -t -A -F '' --no-align --quiet \
        -c "$query" 2>/dev/null | tr -d '[:space:]')

    [ "$result" = "t" ] && return 0 || return 1
}

if ! fetch_columns_json "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SCHEMA_NAME" "$TABLE_NAME" "$SOURCE_COLUMNS_JSON"; then
    log_error "Failed to retrieve column metadata from source."
    exit 1
fi

if ! fetch_columns_json "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_NAME" "$TABLE_NAME" "$TARGET_COLUMNS_JSON"; then
    log_error "Failed to retrieve column metadata from target."
    exit 1
fi

SOURCE_EXISTS=true
TARGET_EXISTS=true

if ! table_exists "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SCHEMA_NAME" "$TABLE_NAME"; then
    log_error "Table ${SCHEMA_NAME}.${TABLE_NAME} does not exist in source environment (${SOURCE_ENV})."
    exit 1
fi

if ! table_exists "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SCHEMA_NAME" "$TABLE_NAME"; then
    TARGET_EXISTS=false
fi

generate_plan() {
    "$PYTHON_BIN" - "$SCHEMA_NAME" "$TABLE_NAME" "$SOURCE_COLUMNS_JSON" "$TARGET_COLUMNS_JSON" "$TARGET_EXISTS" "$SQL_PLAN_FILE" "$PLAN_JSON_FILE" <<'PY'
import json
import sys
from pathlib import Path
import datetime

schema = sys.argv[1]
table = sys.argv[2]
source_path = Path(sys.argv[3])
target_path = Path(sys.argv[4])
target_exists = sys.argv[5].lower() == 'true'
sql_plan_path = Path(sys.argv[6])
plan_path = Path(sys.argv[7])

source = json.loads(source_path.read_text() or '[]')
target = json.loads(target_path.read_text() or '[]')

def column_map(columns):
    return {col['name']: col for col in (columns or [])}

def column_type(col):
    return col.get('formatted_type') or col.get('data_type') or 'unknown'

def build_statements():
    if not target_exists:
        return {
            'action': 'create_table',
            'statements': [],
            'operations': [{
                'type': 'create_table',
                'description': f"Create table {table} with {len(source)} column(s)"
            }],
            'summary': {
                'added': len(source),
                'removed': 0,
                'changed': 0
            },
            'destructive': False
        }

    source_map = column_map(source)
    target_map = column_map(target)

    added = [source_map[name] for name in sorted(set(source_map) - set(target_map))]
    removed = [target_map[name] for name in sorted(set(target_map) - set(source_map))]
    shared = sorted(set(source_map) & set(target_map))

    changed = []
    for name in shared:
        s_col = source_map[name]
        t_col = target_map[name]
        differences = {}
        for key in ('formatted_type', 'is_nullable', 'column_default'):
            if (s_col.get(key) or '') != (t_col.get(key) or ''):
                differences[key] = {
                    'source': s_col.get(key),
                    'target': t_col.get(key)
                }
        if differences:
            changed.append({'column': name, 'differences': differences})

    statements = []
    operations = []

    for col in added:
        stmt = f'ALTER TABLE "{schema}"."{table}" ADD COLUMN "{col["name"]}" {column_type(col)}'
        if (col.get('column_default') or '') != '':
            stmt += f' DEFAULT {col["column_default"]}'
        if (col.get('is_nullable') or '').upper() == 'NO':
            stmt += ' NOT NULL'
        statements.append(stmt + ';')
        operations.append({
            'type': 'add_column',
            'column': col['name'],
            'description': f'Add column {col["name"]} ({column_type(col)})'
        })

    for change in changed:
        col_name = change['column']
        diffs = change['differences']
        if 'formatted_type' in diffs:
            new_type = column_type(source_map[col_name])
            stmt = f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" TYPE {new_type} USING "{col_name}"::{new_type};'
            statements.append(stmt)
            operations.append({
                'type': 'alter_column_type',
                'column': col_name,
                'description': f'Change type of {col_name} to {new_type}'
            })
        if 'is_nullable' in diffs:
            if (source_map[col_name].get('is_nullable') or '').upper() == 'NO':
                statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" SET NOT NULL;')
                operations.append({
                    'type': 'set_not_null',
                    'column': col_name,
                    'description': f'SET NOT NULL on {col_name}'
                })
            else:
                statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" DROP NOT NULL;')
                operations.append({
                    'type': 'drop_not_null',
                    'column': col_name,
                    'description': f'DROP NOT NULL on {col_name}'
                })
        if 'column_default' in diffs:
            default_value = source_map[col_name].get('column_default')
            if default_value:
                statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" SET DEFAULT {default_value};')
                operations.append({
                    'type': 'set_default',
                    'column': col_name,
                    'description': f'SET DEFAULT on {col_name}'
                })
            else:
                statements.append(f'ALTER TABLE "{schema}"."{table}" ALTER COLUMN "{col_name}" DROP DEFAULT;')
                operations.append({
                    'type': 'drop_default',
                    'column': col_name,
                    'description': f'DROP DEFAULT on {col_name}'
                })

    for col in removed:
        statements.append(f'ALTER TABLE "{schema}"."{table}" DROP COLUMN "{col["name"]}";')
        operations.append({
            'type': 'remove_column',
            'column': col['name'],
            'description': f'Drop column {col["name"]}'
        })

    if not statements:
        return {
            'action': 'noop',
            'statements': [],
            'operations': [],
            'summary': {
                'added': 0,
                'removed': 0,
                'changed': 0
            },
            'destructive': False
        }

    return {
        'action': 'alter_table',
        'statements': statements,
        'operations': operations,
        'summary': {
            'added': len(added),
            'removed': len(removed),
            'changed': len(changed)
        },
        'destructive': bool(removed)
    }

plan = build_statements()

if plan['action'] == 'alter_table':
    sql_plan_path.write_text('\n'.join(plan['statements']) + '\n')
else:
    sql_plan_path.write_text('')

def utc_timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

plan['generatedAt'] = utc_timestamp()
plan_path.write_text(json.dumps(plan, separators=(',', ':')))
print(plan_path.read_text())
PY
}

generate_plan >/dev/null
PLAN_ACTION=$("$PYTHON_BIN" - "$PLAN_JSON_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('action'))
PY
)

if [ "$PLAN_ACTION" = "noop" ]; then
    FINAL_JSON=$("$PYTHON_BIN" - "$PLAN_JSON_FILE" "$SOURCE_ENV" "$TARGET_ENV" "$SCHEMA_NAME" "$TABLE_NAME" <<'PY'
import json, sys, datetime

def utc_timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

plan = json.load(open(sys.argv[1]))
result = {
    "sourceEnv": sys.argv[2],
    "targetEnv": sys.argv[3],
    "schema": sys.argv[4],
    "table": sys.argv[5],
    "status": "noop",
    "message": "Target schema already matches source.",
    "plan": plan,
    "timestamp": utc_timestamp()
}
print(json.dumps(result, separators=(',', ':')))
PY
)
    echo "PUBLIC_TABLE_SYNC_JSON=$FINAL_JSON"
    exit 0
fi

apply_sql_file() {
    local ref=$1
    local password=$2
    local region=$3
    local port=$4
    local sql_file=$5
    local description=$6

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$region" "$port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "${description} via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -v ON_ERROR_STOP=on \
            -f "$sql_file" >>"$PROJECT_ROOT/logs/sync_table_schema.log" 2>&1; then
            return 0
        fi
    done <<<"$endpoints"

    local direct_host="db.${ref}.supabase.co"
    log_info "${description} via direct host (${direct_host}:5432)"
    if PGPASSWORD="$password" PGSSLMODE=require psql \
        -h "$direct_host" \
        -p 5432 \
        -U "postgres" \
        -d postgres \
        -v ON_ERROR_STOP=on \
        -f "$sql_file" >>"$PROJECT_ROOT/logs/sync_table_schema.log" 2>&1; then
        return 0
    fi

    return 1
}

dump_table_schema() {
    local ref=$1
    local password=$2
    local region=$3
    local port=$4
    local schema=$5
    local table=$6
    local output=$7

    local args=(--schema-only --no-owner --no-privileges --file="$output" --table="${schema}.${table}" -d postgres)

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$region" "$port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Dumping definition via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require pg_dump \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            "${args[@]}" >/dev/null 2>&1; then
            return 0
        fi
    done <<<"$endpoints"

    local direct_host="db.${ref}.supabase.co"
    log_info "Dumping definition via direct host (${direct_host}:5432)"
    if PGPASSWORD="$password" PGSSLMODE=require pg_dump \
        -h "$direct_host" \
        -p 5432 \
        -U "postgres" \
        "${args[@]}" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

if [ "$PLAN_ACTION" = "create_table" ]; then
    TMP_SQL=$(mktemp)
    if ! dump_table_schema "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SCHEMA_NAME" "$TABLE_NAME" "$TMP_SQL"; then
        log_error "Failed to create schema dump for ${SCHEMA_NAME}.${TABLE_NAME}."
        rm -f "$TMP_SQL"
        exit 1
    fi
    if ! apply_sql_file "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$TMP_SQL" "Creating table ${SCHEMA_NAME}.${TABLE_NAME}"; then
        log_error "Failed to apply schema creation for ${SCHEMA_NAME}.${TABLE_NAME}."
        rm -f "$TMP_SQL"
        exit 1
    fi
    rm -f "$TMP_SQL"
else
    if [ ! -s "$SQL_PLAN_FILE" ]; then
        log_info "No SQL statements generated; nothing to apply."
    else
        if ! apply_sql_file "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$SQL_PLAN_FILE" "Applying schema changes for ${SCHEMA_NAME}.${TABLE_NAME}"; then
            log_error "Failed to apply schema alterations for ${SCHEMA_NAME}.${TABLE_NAME}."
            exit 1
        fi
    fi
fi

FINAL_JSON=$("$PYTHON_BIN" - "$PLAN_JSON_FILE" "$SOURCE_ENV" "$TARGET_ENV" "$SCHEMA_NAME" "$TABLE_NAME" "$PLAN_ACTION" <<'PY'
import json, sys, datetime

def utc_timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

plan = json.load(open(sys.argv[1]))
result = {
    "sourceEnv": sys.argv[2],
    "targetEnv": sys.argv[3],
    "schema": sys.argv[4],
    "table": sys.argv[5],
    "status": sys.argv[6],
    "message": "Schema synchronization completed.",
    "plan": plan,
    "timestamp": utc_timestamp()
}
print(json.dumps(result, separators=(',', ':')))
PY
)

echo "PUBLIC_TABLE_SYNC_JSON=$FINAL_JSON"

