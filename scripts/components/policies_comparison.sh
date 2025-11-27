#!/bin/bash
# Policies & Access Comparison Script
# Compares policies, grants, roles, and user role assignments between two environments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Helper: mirror the database migration fallback strategy for psql queries
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
            -F '' \
            -t -A \
            -v ON_ERROR_STOP=on \
            -c "$query" \
            2>"$tmp_err"; then
            success=true
            break
        fi
        log_warning "Snapshot query failed via ${label}: $(tail -n 1 "$tmp_err")"
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    # If all pooler connections failed, try API to get correct pooler hostname
    if [ "$success" = "false" ]; then
        log_info "Pooler connections failed, trying API to get pooler hostname..." >&2
        local api_pooler_host=""
        api_pooler_host=$(get_pooler_host_via_api "$ref" 2>/dev/null || echo "")
        
        if [ -n "$api_pooler_host" ]; then
            log_info "Retrying query with API-resolved pooler host: ${api_pooler_host}" >&2
            
            # Try with API-resolved pooler host
            for port in "$pooler_port" "5432"; do
                if PGPASSWORD="$password" PGSSLMODE=require psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${ref}" \
                    -d postgres \
                    -F '' \
                    -t -A \
                    -v ON_ERROR_STOP=on \
                    -c "$query" \
                    2>"$tmp_err"; then
                    success=true
                    break
                else
                    log_warning "Snapshot query failed via API-resolved pooler (${api_pooler_host}:${port}): $(tail -n 1 "$tmp_err")"
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API" >&2
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

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env>

Generates a JSON comparison of policies, auth roles, grants, and user role assignments
between source and target environments.
EOF
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "policies_comparison" "$SOURCE_ENV" "$TARGET_ENV"

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required but not found in PATH."
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SOURCE_SNAPSHOT="$TMP_DIR/source.json"
TARGET_SNAPSHOT="$TMP_DIR/target.json"

fetch_snapshot() {
    local env=$1
    local output=$2

    local ref password region port
    ref=$(get_project_ref "$env")
    password=$(get_db_password "$env")
    region=$(get_pooler_region_for_env "$env")
    port=$(get_pooler_port_for_env "$env")

    local query="
WITH policy_source AS (
    SELECT
        n.nspname AS schema_name,
        c.relname AS table_name,
        pol.polname AS policy_name,
        pol.cmd,
        pol.permissive,
        COALESCE(
            (SELECT json_agg(rol.rolname ORDER BY rol.rolname)
             FROM pg_roles rol
             WHERE pol.polroles IS NOT NULL AND rol.oid = ANY(pol.polroles)),
            '[]'::json
        ) AS roles,
        pg_get_expr(pol.polqual, pol.polrelid) AS using_expression,
        pg_get_expr(pol.polwithcheck, pol.polrelid) AS with_check_expression,
        pg_get_policydef(pol.oid) AS definition
    FROM pg_policy pol
    JOIN pg_class c ON pol.polrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'public'
),
grant_source AS (
    SELECT
        table_schema,
        table_name,
        grantee,
        privilege_type,
        is_grantable
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
),
role_source AS (
    SELECT row_to_json(r) AS row_data
    FROM auth.roles r
),
user_role_source AS (
    SELECT row_to_json(ur) AS row_data
    FROM auth.user_roles ur
)
SELECT json_build_object(
    'policies', COALESCE(
        (SELECT json_agg(
            json_build_object(
                'schema', schema_name,
                'table', table_name,
                'policy', policy_name,
                'command', cmd,
                'permissive', permissive,
                'roles', roles,
                'using', using_expression,
                'check', with_check_expression,
                'definition', definition
            )
            ORDER BY schema_name, table_name, policy_name
        ) FROM policy_source),
        '[]'::json
    ),
    'grants', COALESCE(
        (SELECT json_agg(
            json_build_object(
                'schema', table_schema,
                'table', table_name,
                'grantee', grantee,
                'privilege', privilege_type,
                'grantable', is_grantable
            )
            ORDER BY table_schema, table_name, grantee, privilege_type
        ) FROM grant_source),
        '[]'::json
    ),
    'roles', CASE
        WHEN to_regclass('auth.roles') IS NULL THEN '[]'::json
        ELSE COALESCE(
            (SELECT json_agg(row_to_json(r) ORDER BY r.role) FROM auth.roles r),
            '[]'::json
        )
    END,
    'user_roles', CASE
        WHEN to_regclass('auth.user_roles') IS NULL THEN '[]'::json
        ELSE COALESCE(
            (SELECT json_agg(row_to_json(ur) ORDER BY ur.user_id, ur.role) FROM auth.user_roles ur),
            '[]'::json
        )
    END
);
"

    local tmp_err
    tmp_err=$(mktemp)

    if run_psql_query_with_fallback "$ref" "$password" "$region" "$port" "$query" >"$output"; then
        rm -f "$tmp_err"
        return 0
    fi

    local direct_used=false
    local direct_host
    while IFS= read -r direct_host; do
        [ -z "$direct_host" ] && continue
        direct_used=true
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$direct_host" \
            -p 5432 \
            -U "postgres" \
            -d postgres \
            -t -A -F '' --no-align --quiet \
            -c "$query" >"$output" 2>"$tmp_err"; then
            rm -f "$tmp_err"
            return 0
        fi
        log_warning "Snapshot query via ${direct_host} (postgres) failed: $(tail -n 1 "$tmp_err")"

        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$direct_host" \
            -p 5432 \
            -U "postgres.${ref}" \
            -d postgres \
            -t -A -F '' --no-align --quiet \
            -c "$query" >"$output" 2>"$tmp_err"; then
            rm -f "$tmp_err"
            return 0
        fi
        log_warning "Snapshot query via ${direct_host} (postgres.${ref}) failed: $(tail -n 1 "$tmp_err")"
    done < <(get_direct_db_host_candidates "$env" "$ref")

    if ! $direct_used; then
        log_warning "No direct database hosts available for ${env} (${ref})."
    fi

    log_error "Snapshot query failed for ${env}: $(tail -n 1 "$tmp_err")"
    rm -f "$tmp_err"
    return 1
}

log_info "Fetching policies snapshot from ${SOURCE_ENV}..."
if ! fetch_snapshot "$SOURCE_ENV" "$SOURCE_SNAPSHOT"; then
    log_error "Failed to fetch policies snapshot from ${SOURCE_ENV}"
    exit 1
fi

log_info "Fetching policies snapshot from ${TARGET_ENV}..."
if ! fetch_snapshot "$TARGET_ENV" "$TARGET_SNAPSHOT"; then
    log_error "Failed to fetch policies snapshot from ${TARGET_ENV}"
    exit 1
fi

RESULT_JSON=$("$PYTHON_BIN" - "$SOURCE_ENV" "$TARGET_ENV" "$SOURCE_SNAPSHOT" "$TARGET_SNAPSHOT" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

source_env = sys.argv[1]
target_env = sys.argv[2]
source = json.loads(Path(sys.argv[3]).read_text() or '{}')
target = json.loads(Path(sys.argv[4]).read_text() or '{}')

def to_map(items, keys):
    out = {}
    for item in items or []:
        key = tuple(item.get(k) for k in keys)
        out[key] = item
    return out

def diff_objects(source_list, target_list, keys, compare_fields=None):
    source_map = to_map(source_list, keys)
    target_map = to_map(target_list, keys)

    added = []
    removed = []
    changed = []

    for key, item in source_map.items():
        if key not in target_map:
            added.append(item)
            continue
        target_item = target_map[key]
        compare_keys = compare_fields or item.keys()
        differences = {}
        for field in compare_keys:
            if (item.get(field) or '') != (target_item.get(field) or ''):
                differences[field] = {
                    'source': item.get(field),
                    'target': target_item.get(field)
                }
        if differences:
            changed.append({
                'key': {k: key[idx] for idx, k in enumerate(keys)},
                'source': item,
                'target': target_item,
                'differences': differences
            })

    for key, item in target_map.items():
        if key not in source_map:
            removed.append(item)

    return added, removed, changed

policies_added, policies_removed, policies_changed = diff_objects(
    source.get('policies', []),
    target.get('policies', []),
    keys=['schema', 'table', 'policy'],
    compare_fields=['command', 'permissive', 'roles', 'using', 'check', 'definition']
)

grants_added, grants_removed, grants_changed = diff_objects(
    source.get('grants', []),
    target.get('grants', []),
    keys=['schema', 'table', 'grantee', 'privilege'],
    compare_fields=['grantable']
)

roles_added, roles_removed, roles_changed = diff_objects(
    source.get('roles', []),
    target.get('roles', []),
    keys=['role'],
    compare_fields=None
)

user_roles_added, user_roles_removed, _ = diff_objects(
    source.get('user_roles', []),
    target.get('user_roles', []),
    keys=['user_id', 'role'],
    compare_fields=None
)

result = {
    'context': {
        'sourceEnv': source_env,
        'targetEnv': target_env,
        'generatedAt': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    },
    'summary': {
        'policies': {
            'added': len(policies_added),
            'removed': len(policies_removed),
            'changed': len(policies_changed)
        },
        'grants': {
            'added': len(grants_added),
            'removed': len(grants_removed),
            'changed': len(grants_changed)
        },
        'roles': {
            'added': len(roles_added),
            'removed': len(roles_removed),
            'changed': len(roles_changed)
        },
        'userRoles': {
            'added': len(user_roles_added),
            'removed': len(user_roles_removed)
        }
    },
    'policies': {
        'added': policies_added,
        'removed': policies_removed,
        'changed': policies_changed
    },
    'grants': {
        'added': grants_added,
        'removed': grants_removed,
        'changed': grants_changed
    },
    'roles': {
        'added': roles_added,
        'removed': roles_removed,
        'changed': roles_changed
    },
    'userRoles': {
        'added': user_roles_added,
        'removed': user_roles_removed
    }
}

print(json.dumps(result, separators=(',', ':')))
PY
)

if [ -z "$RESULT_JSON" ]; then
    log_error "Failed to generate policies comparison JSON"
    exit 1
fi

echo "POLICIES_DIFF_JSON=$RESULT_JSON"

