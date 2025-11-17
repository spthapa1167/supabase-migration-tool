#!/bin/bash
# RLS Policy Diagnostic Script
# Diagnoses RLS policy issues by checking dependencies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <env> <schema_name> <table_name>

Diagnoses RLS policy issues for a specific table by checking:
  - RLS policies and their definitions
  - Security-definer functions used by policies
  - Missing dependencies
  - Auth context functions

Arguments:
  env          Environment (prod, test, dev, backup)
  schema_name  Schema name (e.g., public)
  table_name   Table name to diagnose

Example:
  $0 prod public setting_categories
EOF
    exit 1
}

if [ $# -lt 3 ]; then
    usage
fi

ENV=$1
SCHEMA_NAME=$2
TABLE_NAME=$3

load_env
validate_environments "$ENV" "$ENV"

PROJECT_REF=$(get_project_ref "$ENV")
PASSWORD=$(get_db_password "$ENV")
POOLER_REGION=$(get_pooler_region_for_env "$ENV")
POOLER_PORT=$(get_pooler_port_for_env "$ENV")

TABLE_IDENTIFIER="${SCHEMA_NAME}.${TABLE_NAME}"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  RLS Policy Diagnostic: $TABLE_IDENTIFIER"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Environment: $ENV ($PROJECT_REF)"
echo ""

# Helper to run query
run_query() {
    local query=$1
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$PROJECT_REF" "$POOLER_REGION" "$POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if result=$(PGPASSWORD="$PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null); then
            echo "$result"
            return 0
        fi
    done <<< "$endpoints"
    return 1
}

# 1. Check if table exists and RLS status
log_info "1. Checking table RLS status..."
RLS_QUERY="
SELECT 
    CASE WHEN c.relrowsecurity THEN 'ENABLED' ELSE 'DISABLED' END as rls_status,
    CASE WHEN c.relforcerowsecurity THEN 'FORCED' ELSE 'NOT FORCED' END as force_status
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$SCHEMA_NAME'
  AND c.relname = '$TABLE_NAME'
  AND c.relkind = 'r';
"

if rls_info=$(run_query "$RLS_QUERY"); then
    if [ -n "$rls_info" ]; then
        log_success "✓ Table exists"
        echo "   RLS Status: $(echo "$rls_info" | cut -d'|' -f1)"
        echo "   Force Status: $(echo "$rls_info" | cut -d'|' -f2)"
    else
        log_error "✗ Table $TABLE_IDENTIFIER does not exist"
        exit 1
    fi
else
    log_error "✗ Failed to check table status"
    exit 1
fi
echo ""

# 2. List all policies
log_info "2. Checking RLS policies..."
POLICIES_QUERY="
SELECT 
    pol.polname,
    CASE pol.polcmd
        WHEN 'r' THEN 'SELECT'
        WHEN 'a' THEN 'INSERT'
        WHEN 'w' THEN 'UPDATE'
        WHEN 'd' THEN 'DELETE'
        WHEN '*' THEN 'ALL'
        ELSE pol.polcmd::text
    END as command,
    CASE WHEN pol.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END as type,
    pg_get_expr(pol.polqual, pol.polrelid) as using_expr,
    pg_get_expr(pol.polwithcheck, pol.polrelid) as with_check_expr,
    array_to_string(ARRAY(
        SELECT r.rolname 
        FROM unnest(pol.polroles) role_oid
        JOIN pg_roles r ON r.oid = role_oid
    ), ', ') as roles
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$SCHEMA_NAME'
  AND c.relname = '$TABLE_NAME'
ORDER BY pol.polname;
"

if policies=$(run_query "$POLICIES_QUERY"); then
    if [ -z "$policies" ]; then
        log_warning "⚠ No RLS policies found for $TABLE_IDENTIFIER"
    else
        policy_count=$(echo "$policies" | grep -c . || echo "0")
        log_success "✓ Found $policy_count policy(ies)"
        echo ""
        echo "$policies" | while IFS='|' read -r name cmd type using_expr with_check_expr roles; do
            echo "   Policy: $name"
            echo "   Command: $cmd | Type: $type"
            [ -n "$roles" ] && echo "   Roles: $roles"
            [ -n "$using_expr" ] && echo "   USING: $using_expr"
            [ -n "$with_check_expr" ] && echo "   WITH CHECK: $with_check_expr"
            echo ""
        done
    fi
else
    log_error "✗ Failed to query policies"
fi
echo ""

# 3. Extract function names from policies
log_info "3. Checking functions referenced in policies..."
FUNCTIONS_QUERY="
WITH policy_exprs AS (
    SELECT 
        pg_get_expr(pol.polqual, pol.polrelid) as using_expr,
        pg_get_expr(pol.polwithcheck, pol.polrelid) as with_check_expr
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '$SCHEMA_NAME'
      AND c.relname = '$TABLE_NAME'
)
SELECT DISTINCT
    regexp_split_to_table(
        COALESCE(using_expr, '') || ' ' || COALESCE(with_check_expr, ''),
        '[^a-zA-Z0-9_]+'
    ) as potential_func
FROM policy_exprs
WHERE using_expr IS NOT NULL OR with_check_expr IS NOT NULL;
"

if potential_funcs=$(run_query "$FUNCTIONS_QUERY"); then
    if [ -n "$potential_funcs" ]; then
        log_info "   Potential functions referenced in policies:"
        echo "$potential_funcs" | grep -E '^[a-z_][a-z0-9_]*$' | sort -u | while read func; do
            # Check if function exists
            FUNC_CHECK="
            SELECT COUNT(*)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE p.proname = '$func'
              AND n.nspname IN ('public', 'auth', 'pg_catalog');
            "
            if count=$(run_query "$FUNC_CHECK"); then
                count=$(echo "$count" | tr -d ' ')
                if [ "$count" -gt 0 ]; then
                    echo "   ✓ $func (exists)"
                else
                    echo "   ✗ $func (MISSING)"
                fi
            fi
        done
    fi
fi
echo ""

# 4. Check security-definer functions
log_info "4. Checking security-definer functions..."
SECDEF_QUERY="
SELECT 
    n.nspname || '.' || p.proname as func_name,
    pg_get_function_identity_arguments(p.oid) as args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosecdef = true
  AND n.nspname IN ('public', 'auth')
ORDER BY n.nspname, p.proname;
"

if secdef_funcs=$(run_query "$SECDEF_QUERY"); then
    if [ -z "$secdef_funcs" ]; then
        log_warning "⚠ No security-definer functions found"
    else
        count=$(echo "$secdef_funcs" | grep -c . || echo "0")
        log_success "✓ Found $count security-definer function(s)"
        echo "$secdef_funcs" | while IFS='|' read -r func_name args; do
            echo "   - $func_name($args)"
        done
    fi
else
    log_warning "⚠ Failed to query security-definer functions"
fi
echo ""

# 5. Check grants
log_info "5. Checking table grants..."
GRANTS_QUERY="
SELECT 
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.role_table_grants
WHERE table_schema = '$SCHEMA_NAME'
  AND table_name = '$TABLE_NAME'
  AND grantee NOT IN ('postgres', 'supabase_admin')
ORDER BY grantee, privilege_type;
"

if grants=$(run_query "$GRANTS_QUERY"); then
    if [ -z "$grants" ]; then
        log_warning "⚠ No grants found for $TABLE_IDENTIFIER"
    else
        count=$(echo "$grants" | grep -c . || echo "0")
        log_success "✓ Found $count grant(s)"
        echo "$grants" | while IFS='|' read -r grantee priv grantable; do
            echo "   $grantee: $priv $([ "$grantable" = "YES" ] && echo "(GRANTABLE)")"
        done
    fi
else
    log_warning "⚠ Failed to query grants"
fi
echo ""

# 6. Test auth context
log_info "6. Testing auth context functions..."
AUTH_TEST="
SELECT 
    CASE WHEN auth.uid() IS NULL THEN 'NULL' ELSE 'OK' END as uid_status,
    CASE WHEN auth.role() IS NULL THEN 'NULL' ELSE auth.role() END as role_status;
"

if auth_info=$(run_query "$AUTH_TEST"); then
    log_success "✓ Auth context functions accessible"
    echo "$auth_info" | while IFS='|' read -r uid_status role_status; do
        echo "   auth.uid(): $uid_status"
        echo "   auth.role(): $role_status"
    done
else
    log_warning "⚠ Failed to test auth context"
fi
echo ""

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Diagnostic Complete"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Review the output above to identify missing dependencies."
log_info "Common issues:"
log_info "  - Missing security-definer functions"
log_info "  - Functions referenced in policies don't exist"
log_info "  - Missing grants on functions or tables"
log_info "  - Auth context not properly set"

exit 0

