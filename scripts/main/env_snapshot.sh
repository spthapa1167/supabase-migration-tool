#!/bin/bash
# Environment Snapshot Script
# Provides comprehensive counts of all objects in source and target environments
# and shows differences between them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Usage
usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env>

Creates a comprehensive snapshot comparing source and target environments.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)

The script provides counts for:
  - Database objects (tables, functions, triggers, indexes)
  - Public schema tables
  - RLS policies
  - Edge functions
  - Storage buckets
  - Auth users
  - Roles and grants
  - And more...

Examples:
  $0 dev test
  $0 prod backup

EOF
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV="$1"
TARGET_ENV="$2"

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

# Check for Node.js (needed for edge functions and buckets)
if ! command -v node >/dev/null 2>&1; then
    log_warning "Node.js not found - edge functions and buckets counts will be skipped"
    NODE_AVAILABLE=false
else
    NODE_AVAILABLE=true
fi

# Function to run a SQL query and get result
run_sql_query() {
    local env_name=$1
    local project_ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local query=$6
    
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$project_ref" "$pooler_region" "$pooler_port")
    
    local result=""
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        
        result=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null || echo "")
        
        if [ -n "$result" ]; then
            echo "$result" | tr -d '[:space:]'
            return 0
        fi
    done <<< "$endpoints"
    
    echo "0"
    return 1
}

# Function to get database object counts
get_db_counts() {
    local env_name=$1
    local project_ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    
    # Log to stderr so it doesn't interfere with output capture
    echo "[INFO] Collecting database counts for $env_name..." >&2
    
    # Tables (all schemas)
    local all_tables=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null || echo "0")
    
    # Public schema tables
    local public_tables=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" 2>/dev/null || echo "0")
    
    # RLS Policies
    local policies=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_policies WHERE schemaname IN ('public', 'auth');" 2>/dev/null || echo "0")
    
    # Functions
    local functions=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname IN ('public', 'auth') AND p.prokind = 'f';" 2>/dev/null || echo "0")
    
    # Triggers
    local triggers=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_trigger WHERE tgisinternal = false;" 2>/dev/null || echo "0")
    
    # Indexes
    local indexes=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_indexes WHERE schemaname IN ('public', 'auth');" 2>/dev/null || echo "0")
    
    # Views
    local views=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM information_schema.views WHERE table_schema IN ('public', 'auth');" 2>/dev/null || echo "0")
    
    # Sequences
    local sequences=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema IN ('public', 'auth');" 2>/dev/null || echo "0")
    
    # Roles
    local roles=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_roles WHERE rolname NOT LIKE 'pg_%' AND rolname NOT IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin', 'authenticator', 'service_role', 'anon', 'authenticated');" 2>/dev/null || echo "0")
    
    # Auth users
    local auth_users=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM auth.users;" 2>/dev/null || echo "0")
    
    # Auth identities
    local auth_identities=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM auth.identities;" 2>/dev/null || echo "0")
    
    # User roles (if table exists)
    local user_roles=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM public.user_roles;" 2>/dev/null || echo "0")
    
    # RLS enabled tables
    local rls_tables=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname IN ('public', 'auth') AND c.relkind = 'r' AND c.relrowsecurity = true;" 2>/dev/null || echo "0")
    
    # Constraints
    local constraints=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_schema IN ('public', 'auth');" 2>/dev/null || echo "0")
    
    # Extensions
    local extensions=$(run_sql_query "$env_name" "$project_ref" "$password" "$pooler_region" "$pooler_port" \
        "SELECT COUNT(*) FROM pg_extension WHERE extname NOT LIKE 'pg_%';" 2>/dev/null || echo "0")
    
    # Output only the pipe-delimited counts to stdout (for capture)
    # All logging should go to stderr
    echo "$all_tables|$public_tables|$policies|$functions|$triggers|$indexes|$views|$sequences|$roles|$auth_users|$auth_identities|$user_roles|$rls_tables|$constraints|$extensions"
}

# Function to get edge functions count using Management API
get_edge_functions_count() {
    local project_ref=$1
    local env_name=$2
    
    if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        echo "N/A"
        return
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        echo "N/A"
        return
    fi
    
    local count="0"
    local url="https://api.supabase.com/v1/projects/${project_ref}/functions"
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "$url" 2>/dev/null || echo "")
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] && [ -n "$body" ]; then
        # Use Python or Node.js to parse JSON, fallback to grep
        if command -v python3 >/dev/null 2>&1; then
            count=$(echo "$body" | python3 -c "import sys, json; data = json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null || echo "0")
        elif [ "$NODE_AVAILABLE" = "true" ]; then
            count=$(echo "$body" | node -e "try { const data = JSON.parse(require('fs').readFileSync(0, 'utf-8')); console.log(Array.isArray(data) ? data.length : 0); } catch(e) { console.log(0); }" 2>/dev/null || echo "0")
        else
            # Fallback: count array elements using grep
            count=$(echo "$body" | grep -o '"name"' | wc -l | tr -d '[:space:]' || echo "0")
        fi
    fi
    
    echo "$count"
}

# Function to get storage buckets count using REST API
get_buckets_count() {
    local project_ref=$1
    local env_name=$2
    
    # Get service role key for the environment
    local env_lc=$(echo "$env_name" | tr '[:upper:]' '[:lower:]')
    local env_key=""
    case "$env_lc" in
        prod|production|main) env_key="PROD" ;;
        test|staging) env_key="TEST" ;;
        dev|develop) env_key="DEV" ;;
        backup|bkup|bkp) env_key="BACKUP" ;;
    esac
    
    if [ -z "$env_key" ]; then
        echo "N/A"
        return
    fi
    
    local service_key_var="SUPABASE_${env_key}_SERVICE_ROLE_KEY"
    local service_key="${!service_key_var:-}"
    local project_url="https://${project_ref}.supabase.co"
    
    if [ -z "$service_key" ]; then
        echo "N/A"
        return
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        echo "N/A"
        return
    fi
    
    # Use REST API to get buckets
    local url="${project_url}/storage/v1/bucket"
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${service_key}" \
        -H "apikey: ${service_key}" \
        "$url" 2>/dev/null || echo "")
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    local count="0"
    if [ "$http_code" = "200" ] && [ -n "$body" ]; then
        # Use Python or Node.js to parse JSON, fallback to grep
        if command -v python3 >/dev/null 2>&1; then
            count=$(echo "$body" | python3 -c "import sys, json; data = json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null || echo "0")
        elif [ "$NODE_AVAILABLE" = "true" ]; then
            count=$(echo "$body" | node -e "try { const data = JSON.parse(require('fs').readFileSync(0, 'utf-8')); console.log(Array.isArray(data) ? data.length : 0); } catch(e) { console.log(0); }" 2>/dev/null || echo "0")
        else
            # Fallback: count array elements using grep
            count=$(echo "$body" | grep -o '"name"' | wc -l | tr -d '[:space:]' || echo "0")
        fi
    fi
    
    echo "$count"
}

# Collect counts for source
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Source Environment Snapshot: $SOURCE_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Capture only the pipe-delimited output, redirect logs to stderr
# Use process substitution to separate stdout (counts) from stderr (logs)
source_counts=$(get_db_counts "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" 2>&1 | grep -E "^[0-9]+\|" | tail -1)
if [ -z "$source_counts" ] || ! echo "$source_counts" | grep -qE "^[0-9]+\|"; then
    # If no valid output, set defaults
    source_counts="0|0|0|0|0|0|0|0|0|0|0|0|0|0|0"
fi
IFS='|' read -r source_all_tables source_public_tables source_policies source_functions source_triggers \
    source_indexes source_views source_sequences source_roles source_auth_users source_auth_identities \
    source_user_roles source_rls_tables source_constraints source_extensions <<< "$source_counts"

source_edge_functions=$(get_edge_functions_count "$SOURCE_REF" "$SOURCE_ENV")
source_buckets=$(get_buckets_count "$SOURCE_REF" "$SOURCE_ENV")

# Collect counts for target
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Target Environment Snapshot: $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Capture only the pipe-delimited output, redirect logs to stderr
# Use process substitution to separate stdout (counts) from stderr (logs)
target_counts=$(get_db_counts "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" 2>&1 | grep -E "^[0-9]+\|" | tail -1)
if [ -z "$target_counts" ] || ! echo "$target_counts" | grep -qE "^[0-9]+\|"; then
    # If no valid output, set defaults
    target_counts="0|0|0|0|0|0|0|0|0|0|0|0|0|0|0"
fi
IFS='|' read -r target_all_tables target_public_tables target_policies target_functions target_triggers \
    target_indexes target_views target_sequences target_roles target_auth_users target_auth_identities \
    target_user_roles target_rls_tables target_constraints target_extensions <<< "$target_counts"

target_edge_functions=$(get_edge_functions_count "$TARGET_REF" "$TARGET_ENV")
target_buckets=$(get_buckets_count "$TARGET_REF" "$TARGET_ENV")

# Helper function to calculate difference
calculate_diff() {
    local source=$1
    local target=$2
    local diff=$((source - target))
    
    if [ "$diff" -eq 0 ]; then
        echo "✓"
    elif [ "$diff" -gt 0 ]; then
        echo "+$diff"
    else
        echo "$diff"
    fi
}

# Helper function to format number
format_number() {
    local num=$1
    if [ "$num" = "N/A" ] || [ -z "$num" ]; then
        echo "N/A"
    else
        printf "%'d" "$num" 2>/dev/null || echo "$num"
    fi
}

# Display results
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Environment Snapshot Comparison"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
printf "%-35s %15s %15s %10s\n" "Object Type" "$SOURCE_ENV" "$TARGET_ENV" "Diff"
echo "────────────────────────────────────────────────────────────────────────────"
printf "%-35s %15s %15s %10s\n" "Database Tables (all schemas)" \
    "$(format_number "$source_all_tables")" \
    "$(format_number "$target_all_tables")" \
    "$(calculate_diff "$source_all_tables" "$target_all_tables")"

printf "%-35s %15s %15s %10s\n" "Public Schema Tables" \
    "$(format_number "$source_public_tables")" \
    "$(format_number "$target_public_tables")" \
    "$(calculate_diff "$source_public_tables" "$target_public_tables")"

printf "%-35s %15s %15s %10s\n" "RLS Policies" \
    "$(format_number "$source_policies")" \
    "$(format_number "$target_policies")" \
    "$(calculate_diff "$source_policies" "$target_policies")"

printf "%-35s %15s %15s %10s\n" "RLS Enabled Tables" \
    "$(format_number "$source_rls_tables")" \
    "$(format_number "$target_rls_tables")" \
    "$(calculate_diff "$source_rls_tables" "$target_rls_tables")"

printf "%-35s %15s %15s %10s\n" "Database Functions" \
    "$(format_number "$source_functions")" \
    "$(format_number "$target_functions")" \
    "$(calculate_diff "$source_functions" "$target_functions")"

printf "%-35s %15s %15s %10s\n" "Triggers" \
    "$(format_number "$source_triggers")" \
    "$(format_number "$target_triggers")" \
    "$(calculate_diff "$source_triggers" "$target_triggers")"

printf "%-35s %15s %15s %10s\n" "Indexes" \
    "$(format_number "$source_indexes")" \
    "$(format_number "$target_indexes")" \
    "$(calculate_diff "$source_indexes" "$target_indexes")"

printf "%-35s %15s %15s %10s\n" "Views" \
    "$(format_number "$source_views")" \
    "$(format_number "$target_views")" \
    "$(calculate_diff "$source_views" "$target_views")"

printf "%-35s %15s %15s %10s\n" "Sequences" \
    "$(format_number "$source_sequences")" \
    "$(format_number "$target_sequences")" \
    "$(calculate_diff "$source_sequences" "$target_sequences")"

printf "%-35s %15s %15s %10s\n" "Constraints" \
    "$(format_number "$source_constraints")" \
    "$(format_number "$target_constraints")" \
    "$(calculate_diff "$source_constraints" "$target_constraints")"

printf "%-35s %15s %15s %10s\n" "Extensions" \
    "$(format_number "$source_extensions")" \
    "$(format_number "$target_extensions")" \
    "$(calculate_diff "$source_extensions" "$target_extensions")"

printf "%-35s %15s %15s %10s\n" "Roles" \
    "$(format_number "$source_roles")" \
    "$(format_number "$target_roles")" \
    "$(calculate_diff "$source_roles" "$target_roles")"

printf "%-35s %15s %15s %10s\n" "Auth Users" \
    "$(format_number "$source_auth_users")" \
    "$(format_number "$target_auth_users")" \
    "$(calculate_diff "$source_auth_users" "$target_auth_users")"

printf "%-35s %15s %15s %10s\n" "Auth Identities" \
    "$(format_number "$source_auth_identities")" \
    "$(format_number "$target_auth_identities")" \
    "$(calculate_diff "$source_auth_identities" "$target_auth_identities")"

printf "%-35s %15s %15s %10s\n" "User Roles" \
    "$(format_number "$source_user_roles")" \
    "$(format_number "$target_user_roles")" \
    "$(calculate_diff "$source_user_roles" "$target_user_roles")"

printf "%-35s %15s %15s %10s\n" "Edge Functions" \
    "$(format_number "$source_edge_functions")" \
    "$(format_number "$target_edge_functions")" \
    "$(if [ "$source_edge_functions" != "N/A" ] && [ "$target_edge_functions" != "N/A" ]; then calculate_diff "$source_edge_functions" "$target_edge_functions"; else echo "N/A"; fi)"

printf "%-35s %15s %15s %10s\n" "Storage Buckets" \
    "$(format_number "$source_buckets")" \
    "$(format_number "$target_buckets")" \
    "$(if [ "$source_buckets" != "N/A" ] && [ "$target_buckets" != "N/A" ]; then calculate_diff "$source_buckets" "$target_buckets"; else echo "N/A"; fi)"

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Summary of Differences"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Identify differences
differences_found=false

# Helper function to safely compare numbers (handles empty/N/A values)
safe_compare() {
    local val1=$1
    local val2=$2
    
    # Check if values are numeric
    if [[ "$val1" =~ ^[0-9]+$ ]] && [[ "$val2" =~ ^[0-9]+$ ]]; then
        [ "$val1" -ne "$val2" ]
    else
        false
    fi
}

if safe_compare "$source_all_tables" "$target_all_tables"; then
    log_warning "⚠ Tables count differs: Source has $source_all_tables, Target has $target_all_tables"
    differences_found=true
fi

if safe_compare "$source_public_tables" "$target_public_tables"; then
    log_warning "⚠ Public tables count differs: Source has $source_public_tables, Target has $target_public_tables"
    differences_found=true
fi

if safe_compare "$source_policies" "$target_policies"; then
    log_warning "⚠ RLS Policies count differs: Source has $source_policies, Target has $target_policies"
    differences_found=true
fi

if safe_compare "$source_functions" "$target_functions"; then
    log_warning "⚠ Functions count differs: Source has $source_functions, Target has $target_functions"
    differences_found=true
fi

if safe_compare "$source_auth_users" "$target_auth_users"; then
    log_warning "⚠ Auth users count differs: Source has $source_auth_users, Target has $target_auth_users"
    differences_found=true
fi

if [ "$source_edge_functions" != "N/A" ] && [ "$target_edge_functions" != "N/A" ]; then
    if [ "$source_edge_functions" -ne "$target_edge_functions" ]; then
        log_warning "⚠ Edge functions count differs: Source has $source_edge_functions, Target has $target_edge_functions"
        differences_found=true
    fi
fi

if [ "$source_buckets" != "N/A" ] && [ "$target_buckets" != "N/A" ]; then
    if [ "$source_buckets" -ne "$target_buckets" ]; then
        log_warning "⚠ Storage buckets count differs: Source has $source_buckets, Target has $target_buckets"
        differences_found=true
    fi
fi

if [ "$differences_found" = "false" ]; then
    log_success "✓ All object counts match between source and target!"
else
    log_info "Review the differences above and consider running migration if needed."
fi

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Snapshot Complete"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0

