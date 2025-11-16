#!/bin/bash
# Sync a specific policies-related record (policy, grant, role, user_role) from source to target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
shift 2 || true

TYPE=""
ACTION="create"
SCHEMA_NAME="public"
TABLE_NAME=""
POLICY_NAME=""
GRANTEE=""
PRIVILEGE=""
GRANTABLE=""
ROLE_NAME=""
USER_ID=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> --type <policy|grant|role|user_role> [options]

Options per type:
  policy:
    --schema <schema>   (default: public)
    --table <table>     (required)
    --policy <name>     (required)
    --action <create|drop|update> (default: create)

  grant:
    --schema <schema>   (default: public)
    --table <table>     (required)
    --grantee <role>    (required)
    --privilege <priv>  (required)
    --action <create|drop> (default: create)

  role:
    --role <role_name>  (required)
    --action <create|drop> (default: create)

  user_role:
    --user-id <uuid>    (required)
    --role <role_name>  (required)
    --action <create|drop> (default: create)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            TYPE=${2:-}
            shift 2 || usage
            ;;
        --type=*)
            TYPE="${1#*=}"
            shift
            ;;
        --action)
            ACTION=${2:-}
            shift 2 || usage
            ;;
        --action=*)
            ACTION="${1#*=}"
            shift
            ;;
        --schema)
            SCHEMA_NAME=${2:-}
            shift 2 || usage
            ;;
        --schema=*)
            SCHEMA_NAME="${1#*=}"
            shift
            ;;
        --table)
            TABLE_NAME=${2:-}
            shift 2 || usage
            ;;
        --table=*)
            TABLE_NAME="${1#*=}"
            shift
            ;;
        --policy)
            POLICY_NAME=${2:-}
            shift 2 || usage
            ;;
        --policy=*)
            POLICY_NAME="${1#*=}"
            shift
            ;;
        --grantee)
            GRANTEE=${2:-}
            shift 2 || usage
            ;;
        --grantee=*)
            GRANTEE="${1#*=}"
            shift
            ;;
        --privilege)
            PRIVILEGE=${2:-}
            shift 2 || usage
            ;;
        --privilege=*)
            PRIVILEGE="${1#*=}"
            shift
            ;;
        --grantable)
            GRANTABLE=${2:-}
            shift 2 || usage
            ;;
        --grantable=*)
            GRANTABLE="${1#*=}"
            shift
            ;;
        --role)
            ROLE_NAME=${2:-}
            shift 2 || usage
            ;;
        --role=*)
            ROLE_NAME="${1#*=}"
            shift
            ;;
        --user-id)
            USER_ID=${2:-}
            shift 2 || usage
            ;;
        --user-id=*)
            USER_ID="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_warning "Ignoring unknown option: $1"
            shift
            ;;
    esac
done

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ] || [ -z "$TYPE" ]; then
    usage
fi

TYPE=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')
ACTION=$(echo "$ACTION" | tr '[:upper:]' '[:lower:]')

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "policies_sync_item" "$SOURCE_ENV" "$TARGET_ENV"
mkdir -p "$PROJECT_ROOT/logs"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

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

    local env_name=""
    if [ "$ref" = "$SOURCE_REF" ]; then
        env_name="$SOURCE_ENV"
    elif [ "$ref" = "$TARGET_REF" ]; then
        env_name="$TARGET_ENV"
    fi

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
            >>"$PROJECT_ROOT/logs/policies_sync.log" 2>"$tmp_err"; then
            success=true
            break
        else
            log_warning "${description} failed via ${label}: $(head -n 1 "$tmp_err")"
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    if ! $success; then
        log_warning "${description} failed across all poolers, retrying via direct host..."
        local direct_host
        while IFS= read -r direct_host; do
            [ -z "$direct_host" ] && continue
            if PGPASSWORD="$password" PGSSLMODE=require psql \
                -h "$direct_host" \
                -p 5432 \
                -U "postgres.$ref" \
                -d postgres \
                -v ON_ERROR_STOP=on \
                -c "$command" \
                >>"$PROJECT_ROOT/logs/policies_sync.log" 2>"$tmp_err"; then
                success=true
                break
            else
                log_warning "${description} failed via ${direct_host}: $(head -n 1 "$tmp_err")"
            fi
        done < <(get_direct_db_host_candidates "$env_name" "$ref")
        if ! $success; then
            log_error "${description} failed via direct host: $(head -n 1 "$tmp_err")"
        fi
    fi

    rm -f "$tmp_err"
    $success
}

run_psql_query_with_fallback() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query=$5

    local tmp_file
    tmp_file=$(mktemp)
    local success=false

    local env_name=""
    if [ "$ref" = "$SOURCE_REF" ]; then
        env_name="$SOURCE_ENV"
    elif [ "$ref" = "$TARGET_REF" ]; then
        env_name="$TARGET_ENV"
    fi

    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A -F '' --no-align --quiet \
            -c "$query" >"$tmp_file" 2>/dev/null; then
            success=true
            break
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    if ! $success; then
        local direct_host
        while IFS= read -r direct_host; do
            [ -z "$direct_host" ] && continue
            if PGPASSWORD="$password" PGSSLMODE=require psql \
                -h "$direct_host" \
                -p 5432 \
                -U "postgres.$ref" \
                -d postgres \
                -t -A -F '' --no-align --quiet \
                -c "$query" >"$tmp_file" 2>/dev/null; then
                success=true
                break
            fi
        done < <(get_direct_db_host_candidates "$env_name" "$ref")
    fi

    if ! $success; then
        rm -f "$tmp_file"
        return 1
    fi

    cat "$tmp_file"
    rm -f "$tmp_file"
    return 0
}

sql_escape_literal() {
    local input=${1:-}
    input=${input//\'/\'\'}
    printf "'%s'" "$input"
}

run_source_query() {
    local query=$1
    run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$query"
}

run_target_sql() {
    local description=$1
    local sql=$2
    run_psql_command_with_fallback "$description" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$sql"
}

fetch_policy_definition() {
    local schema=$1
    local table=$2
    local policy=$3
    local query="
        SELECT pg_get_policydef(pol.oid)
        FROM pg_policy pol
        JOIN pg_class c ON pol.polrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = $(sql_escape_literal "$schema")
          AND c.relname = $(sql_escape_literal "$table")
          AND pol.polname = $(sql_escape_literal "$policy")
        LIMIT 1;
    "
    local output
    output=$(run_source_query "$query")
    echo "$output" | tr -d '\r'
}

fetch_grant_row() {
    local schema=$1
    local table=$2
    local grantee=$3
    local privilege=$4
    local query="
        SELECT table_schema, table_name, grantee, privilege_type, is_grantable
        FROM information_schema.role_table_grants
        WHERE table_schema = $(sql_escape_literal "$schema")
          AND table_name = $(sql_escape_literal "$table")
          AND grantee = $(sql_escape_literal "$grantee")
          AND privilege_type = $(sql_escape_literal "$privilege")
        LIMIT 1;
    "
    run_source_query "$query"
}

fetch_role_json() {
    local role=$1
    local query="
        SELECT row_to_json(r)::text
        FROM auth.roles r
        WHERE role = $(sql_escape_literal "$role")
        LIMIT 1;
    "
    run_source_query "$query"
}

fetch_user_role_json() {
    local user_id=$1
    local role=$2
    local query="
        SELECT row_to_json(ur)::text
        FROM auth.user_roles ur
        WHERE user_id::text = $(sql_escape_literal "$user_id")
          AND role = $(sql_escape_literal "$role")
        LIMIT 1;
    "
    run_source_query "$query"
}

json_to_sql_literal() {
    local json=$1
    printf "%s" "$json" | sed "s/'/''/g"
}

sync_policy() {
    if [ -z "$TABLE_NAME" ] || [ -z "$POLICY_NAME" ]; then
        log_error "Policy sync requires --table and --policy arguments."
        exit 1
    fi

    local definition=""
    if [ "$ACTION" != "drop" ]; then
        definition=$(fetch_policy_definition "$SCHEMA_NAME" "$TABLE_NAME" "$POLICY_NAME")
        if [ -z "$definition" ]; then
            log_error "Policy ${POLICY_NAME} not found in source environment."
            exit 1
        fi
    fi

    local sql=""
    if [ "$ACTION" = "drop" ]; then
        sql=$(cat <<SQL
DROP POLICY IF EXISTS "${POLICY_NAME}" ON "${SCHEMA_NAME}"."${TABLE_NAME}";
SQL
)
    else
        sql=$(cat <<SQL
DROP POLICY IF EXISTS "${POLICY_NAME}" ON "${SCHEMA_NAME}"."${TABLE_NAME}";
${definition};
ALTER TABLE "${SCHEMA_NAME}"."${TABLE_NAME}" ENABLE ROW LEVEL SECURITY;
SQL
)
    fi

    run_target_sql "Policy sync for ${SCHEMA_NAME}.${TABLE_NAME}.${POLICY_NAME}" "$sql"
    echo "POLICIES_SYNC_JSON=$(printf '{"type":"policy","action":"%s","schema":"%s","table":"%s","policy":"%s","status":"ok"}' "$ACTION" "$SCHEMA_NAME" "$TABLE_NAME" "$POLICY_NAME")"
}

sync_grant() {
    if [ -z "$TABLE_NAME" ] || [ -z "$GRANTEE" ] || [ -z "$PRIVILEGE" ]; then
        log_error "Grant sync requires --table, --grantee, and --privilege."
        exit 1
    fi

    local privilege_upper
    privilege_upper=$(echo "$PRIVILEGE" | tr '[:lower:]' '[:upper:]')

    local sql=""
    if [ "$ACTION" = "drop" ]; then
        sql=$(cat <<SQL
REVOKE ${privilege_upper} ON "${SCHEMA_NAME}"."${TABLE_NAME}" FROM "${GRANTEE}";
SQL
)
    else
        local grant_row
        grant_row=$(fetch_grant_row "$SCHEMA_NAME" "$TABLE_NAME" "$GRANTEE" "$PRIVILEGE")
        if [ -z "$grant_row" ]; then
            log_error "Grant definition not found in source environment."
            exit 1
        fi
        local grantable_flag
        grantable_flag=$(echo "$grant_row" | awk -F'|' '{print $5}')
        local grant_option=""
        if [[ "${grantable_flag^^}" = "YES" ]]; then
            grant_option=" WITH GRANT OPTION"
        fi
        sql=$(cat <<SQL
REVOKE ${privilege_upper} ON "${SCHEMA_NAME}"."${TABLE_NAME}" FROM "${GRANTEE}";
GRANT ${privilege_upper} ON "${SCHEMA_NAME}"."${TABLE_NAME}" TO "${GRANTEE}"${grant_option};
SQL
)
    fi

    run_target_sql "Grant sync for ${SCHEMA_NAME}.${TABLE_NAME}.${GRANTEE}.${PRIVILEGE}" "$sql"
    echo "POLICIES_SYNC_JSON=$(printf '{"type":"grant","action":"%s","schema":"%s","table":"%s","grantee":"%s","privilege":"%s","status":"ok"}' "$ACTION" "$SCHEMA_NAME" "$TABLE_NAME" "$GRANTEE" "$PRIVILEGE")"
}

sync_role() {
    if [ -z "$ROLE_NAME" ]; then
        log_error "Role sync requires --role."
        exit 1
    fi

    if [ "$ACTION" = "drop" ]; then
        local sql="DELETE FROM auth.roles WHERE role = $(sql_escape_literal "$ROLE_NAME");"
        run_target_sql "Role removal for ${ROLE_NAME}" "$sql"
        echo "POLICIES_SYNC_JSON=$(printf '{"type":"role","action":"drop","role":"%s","status":"ok"}' "$ROLE_NAME")"
        return
    fi

    local role_json
    role_json=$(fetch_role_json "$ROLE_NAME")
    if [ -z "$role_json" ]; then
        log_error "Role ${ROLE_NAME} not found in source environment."
        exit 1
    fi
    local role_literal
    role_literal=$(json_to_sql_literal "$role_json")

    local sql=$(cat <<SQL
WITH src AS (
    SELECT * FROM json_populate_record(NULL::auth.roles, '${role_literal}'::json)
)
DELETE FROM auth.roles WHERE id = (SELECT id FROM src)::uuid OR role = (SELECT role FROM src);
INSERT INTO auth.roles SELECT * FROM src;
SQL
)

    run_target_sql "Role sync for ${ROLE_NAME}" "$sql"
    echo "POLICIES_SYNC_JSON=$(printf '{"type":"role","action":"create","role":"%s","status":"ok"}' "$ROLE_NAME")"
}

sync_user_role() {
    if [ -z "$USER_ID" ] || [ -z "$ROLE_NAME" ]; then
        log_error "User role sync requires --user-id and --role."
        exit 1
    fi

    if [ "$ACTION" = "drop" ]; then
        local sql=$(cat <<SQL
DELETE FROM auth.user_roles
WHERE user_id::text = $(sql_escape_literal "$USER_ID")
  AND role = $(sql_escape_literal "$ROLE_NAME");
SQL
)
        run_target_sql "User role removal for ${USER_ID}/${ROLE_NAME}" "$sql"
        echo "POLICIES_SYNC_JSON=$(printf '{"type":"user_role","action":"drop","userId":"%s","role":"%s","status":"ok"}' "$USER_ID" "$ROLE_NAME")"
        return
    fi

    local user_role_json
    user_role_json=$(fetch_user_role_json "$USER_ID" "$ROLE_NAME")
    if [ -z "$user_role_json" ]; then
        log_error "User role assignment not found in source environment."
        exit 1
    fi
    local escaped
    escaped=$(json_to_sql_literal "$user_role_json")

    local sql=$(cat <<SQL
WITH src AS (
    SELECT * FROM json_populate_record(NULL::auth.user_roles, '${escaped}'::json)
)
DELETE FROM auth.user_roles WHERE id = (SELECT id FROM src);
INSERT INTO auth.user_roles SELECT * FROM src;
SQL
)

    run_target_sql "User role sync for ${USER_ID}/${ROLE_NAME}" "$sql"
    echo "POLICIES_SYNC_JSON=$(printf '{"type":"user_role","action":"create","userId":"%s","role":"%s","status":"ok"}' "$USER_ID" "$ROLE_NAME")"
}

case "$TYPE" in
    policy)
        sync_policy
        ;;
    grant)
        sync_grant
        ;;
    role)
        sync_role
        ;;
    user_role|user-role)
        sync_user_role
        ;;
    *)
        log_error "Unknown sync type: $TYPE"
        usage
        ;;
esac

