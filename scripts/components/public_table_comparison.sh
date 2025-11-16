#!/bin/bash
# Public Table Comparison Script
# Compares public schema tables and columns between two environments and outputs JSON

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env>

Generates a JSON comparison of public schema tables between source and target environments.
EOF
    exit 1
}

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "public_table_comparison" "$SOURCE_ENV" "$TARGET_ENV"

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required but not found in PATH."
    exit 1
fi

get_connection_info() {
    local env=$1
    local ref password region port
    ref=$(get_project_ref "$env")
    password=$(get_db_password "$env")
    region=$(get_pooler_region_for_env "$env")
    port=$(get_pooler_port_for_env "$env")
    echo "$ref|$password|$region|$port"
}

fetch_table_metadata() {
    local env=$1
    local output_file=$2
    local info ref password region port
    info=$(get_connection_info "$env")
    IFS='|' read -r ref password region port <<<"$info"

    local query
    query="
WITH table_list AS (
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name
),
column_data AS (
    SELECT 
        c.table_name,
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
    WHERE c.table_schema = 'public'
)
SELECT COALESCE(json_agg(
    json_build_object(
        'name', table_name,
        'columns', (
            SELECT json_agg(json_build_object(
                'name', column_name,
                'data_type', data_type,
                'formatted_type', formatted_type,
                'is_nullable', is_nullable,
                'column_default', column_default,
                'ordinal_position', ordinal_position
            ) ORDER BY ordinal_position)
            FROM column_data c
            WHERE c.table_name = table_list.table_name
        )
    ) ORDER BY table_name
), '[]'::json)
FROM table_list;"

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
            -c "$query" >"$output_file" 2>/dev/null; then
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
        -c "$query" >"$output_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

SOURCE_JSON=$(mktemp)
TARGET_JSON=$(mktemp)
trap 'rm -f "$SOURCE_JSON" "$TARGET_JSON"' EXIT

if ! fetch_table_metadata "$SOURCE_ENV" "$SOURCE_JSON"; then
    log_error "Failed to fetch table metadata from $SOURCE_ENV"
    exit 1
fi

if ! fetch_table_metadata "$TARGET_ENV" "$TARGET_JSON"; then
    log_error "Failed to fetch table metadata from $TARGET_ENV"
    exit 1
fi

RESULT_JSON=$("$PYTHON_BIN" - "$SOURCE_ENV" "$TARGET_ENV" "$SOURCE_JSON" "$TARGET_JSON" <<'PY'
import json
import sys
from pathlib import Path

source_env = sys.argv[1]
target_env = sys.argv[2]
source = json.loads(Path(sys.argv[3]).read_text() or '[]')
target = json.loads(Path(sys.argv[4]).read_text() or '[]')

def to_map(items):
    return {item['name']: item for item in items}

source_map = to_map(source)
target_map = to_map(target)

source_only = sorted(set(source_map.keys()) - set(target_map.keys()))
target_only = sorted(set(target_map.keys()) - set(source_map.keys()))
shared = sorted(set(source_map.keys()) & set(target_map.keys()))

def column_map(table):
    cols = table.get('columns') or []
    return {c['name']: c for c in cols}

def diff_table(name):
    s_table = source_map[name]
    t_table = target_map[name]
    s_cols = column_map(s_table)
    t_cols = column_map(t_table)

    added = [s_cols[col] for col in sorted(set(s_cols) - set(t_cols))]
    removed = [t_cols[col] for col in sorted(set(t_cols) - set(s_cols))]

    changed = []
    for col in sorted(set(s_cols) & set(t_cols)):
        s_col = s_cols[col]
        t_col = t_cols[col]
        differences = {}
        for key in ('data_type', 'is_nullable', 'column_default'):
            if (s_col.get(key) or '') != (t_col.get(key) or ''):
                differences[key] = {
                    'source': s_col.get(key),
                    'target': t_col.get(key)
                }
        if differences:
            changed.append({
                'column': col,
                'differences': differences
            })

    status = 'identical'
    if added or removed or changed:
        status = 'changed'

    diff_summary = {
        'added': len(added),
        'removed': len(removed),
        'changed': len(changed)
    }

    operations = []
    for col in added:
        operations.append({
            'type': 'add_column',
            'column': col.get('name'),
            'description': f"Add column {col.get('name')} ({column_type(col)})"
        })

    for col in removed:
        operations.append({
            'type': 'remove_column',
            'column': col.get('name'),
            'description': f"Drop column {col.get('name')} ({column_type(col)})"
        })

    for change in changed:
        changes = []
        for key, value in change['differences'].items():
            changes.append({
                'property': key,
                'from': value.get('source'),
                'to': value.get('target')
            })
        operations.append({
            'type': 'alter_column',
            'column': change['column'],
            'description': f"Alter column {change['column']}",
            'changes': changes
        })

    reason_parts = []
    if added:
        reason_parts.append(f"{len(added)} new column(s)")
    if removed:
        reason_parts.append(f"{len(removed)} column(s) removed")
    if changed:
        reason_parts.append(f"{len(changed)} column(s) modified")
    reason = ', '.join(reason_parts) or 'No differences detected'

    return {
        'name': name,
        'schema': 'public',
        'status': status,
        'reason': reason,
        'syncable': status == 'changed',
        'syncType': 'alter',
        'columns': {
            'source': s_table.get('columns') or [],
            'target': t_table.get('columns') or []
        },
        'diff': {
            'addedColumns': added,
            'removedColumns': removed,
            'changedColumns': changed
        },
        'diffSummary': diff_summary,
        'syncPlanPreview': {
            'operations': operations,
            'destructive': bool(removed),
            'estimatedStatements': len(operations)
        }
    }

def column_type(column):
    return column.get('formatted_type') or column.get('data_type') or 'unknown'

comparison_tables = [diff_table(name) for name in shared]
changed_tables = [t for t in comparison_tables if t['status'] == 'changed']

def build_source_only_details():
    details = []
    for name in source_only:
        table = source_map[name]
        columns = table.get('columns') or []
        details.append({
            'name': name,
            'schema': 'public',
            'status': 'source-only',
            'reason': f"{name} exists in {source_env} but not in {target_env}",
            'columnCount': len(columns),
            'columns': columns,
            'syncable': True,
            'syncType': 'create',
            'diffSummary': {
                'added': len(columns),
                'removed': 0,
                'changed': 0
            },
            'syncPlanPreview': {
                'operations': [{
                    'type': 'create_table',
                    'description': f"Create table {name} with {len(columns)} column(s)"
                }],
                'destructive': False,
                'estimatedStatements': 1
            }
        })
    return details

def build_target_only_details():
    details = []
    for name in target_only:
        table = target_map[name]
        columns = table.get('columns') or []
        details.append({
            'name': name,
            'schema': 'public',
            'status': 'target-only',
            'reason': f"{name} exists in {target_env} but not in {source_env}",
            'columnCount': len(columns),
            'columns': columns,
            'syncable': False,
            'syncType': 'none',
            'diffSummary': {
                'added': 0,
                'removed': len(columns),
                'changed': 0
            },
            'syncPlanPreview': {
                'operations': [],
                'destructive': True,
                'estimatedStatements': 0
            }
        })
    return details

result = {
    'context': {
        'sourceEnv': source_env,
        'targetEnv': target_env
    },
    'summary': {
        'sourceTables': len(source_map),
        'targetTables': len(target_map),
        'sourceOnly': len(source_only),
        'targetOnly': len(target_only),
        'changed': len(changed_tables)
    },
    'sourceOnlyTables': source_only,
    'targetOnlyTables': target_only,
    'sourceOnlyDetails': build_source_only_details(),
    'targetOnlyDetails': build_target_only_details(),
    'changedTables': changed_tables,
    'tables': comparison_tables,
    'generatedAt': Path(sys.argv[3]).stat().st_mtime if source else None
}

print(json.dumps(result, separators=(',', ':')))
PY
)

if [ -z "$RESULT_JSON" ]; then
    log_error "Failed to generate comparison JSON"
    exit 1
fi

echo "PUBLIC_TABLE_DIFF_JSON=$RESULT_JSON"

