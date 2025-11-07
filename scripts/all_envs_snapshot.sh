#!/bin/bash
# All Environments Snapshot Script
# Collects comprehensive snapshots of all objects from dev, test, and prod environments
# Generates a JSON file for easy comparison across all three environments

set -eo pipefail
set +u  # Temporarily disable for environment loading

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/logger.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions (output to stderr so they don't interfere with command substitution)
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Usage
usage() {
    cat << EOF
Usage: $0 [output_dir]

Generates comprehensive snapshots of all objects from dev, test, and prod environments.

Arguments:
  output_dir   Directory to save the snapshot JSON file (optional, defaults to ./snapshots)

Examples:
  $0
  $0 ./custom_output

The script will generate:
  - A JSON file with comprehensive object counts and metadata for all three environments
  - Comparison data showing differences between environments
  - Timestamp and metadata for each snapshot

EOF
    exit 1
}

# Parse arguments
OUTPUT_DIR="${1:-snapshots}"
if [ "$OUTPUT_DIR" = "--snapshots" ] || [ "$OUTPUT_DIR" = "snapshots" ]; then
    OUTPUT_DIR="snapshots"
fi
mkdir -p "$OUTPUT_DIR"

# Load environment
set +e
load_env
LOAD_ENV_EXIT_CODE=$?
set -e
if [ $LOAD_ENV_EXIT_CODE -ne 0 ]; then
    log_error "Failed to load environment variables"
    exit 1
fi
set -u

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    log_error "SUPABASE_ACCESS_TOKEN not set in .env.local"
    exit 1
fi

# Timestamp for snapshot
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
SNAPSHOT_FILE="$OUTPUT_DIR/all_envs_snapshot_$(date +%Y%m%d_%H%M%S).json"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  All Environments Snapshot Generator"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Output: $SNAPSHOT_FILE"
log_info ""

# Query function helpers
query_database_counts() {
    local env=$1
    local project_ref=$2
    local password=$3
    local pooler_host=$4
    
    if [ -z "$project_ref" ] || [ -z "$password" ]; then
        echo "{\"tables\":0,\"views\":0,\"functions\":0,\"sequences\":0,\"indexes\":0,\"policies\":0,\"triggers\":0,\"types\":0,\"enums\":0}"
        return 0
    fi
    
    local direct_host="db.${project_ref}.supabase.co"
    local tables views functions sequences indexes policies triggers types enums

    run_count_with_fallback() {
        local query=$1
        local label=$2
        local result=""

        if [ -n "$pooler_host" ]; then
            if result=$(PGPASSWORD="$password" PGSSLMODE=require psql -h "$pooler_host" -p 6543 -U "postgres.${project_ref}" -d postgres -t -A -c "$query" 2>/dev/null); then
                result=$(echo "$result" | tr -d ' \n\r')
            else
                result=""
            fi
        fi

        if [ -z "$result" ]; then
            log_warning "Primary pooler query for $label in $env returned no data; retrying direct connection..."
            if result=$(PGPASSWORD="$password" PGSSLMODE=require psql -h "$direct_host" -p 5432 -U "postgres.${project_ref}" -d postgres -t -A -c "$query" 2>/dev/null); then
                result=$(echo "$result" | tr -d ' \n\r')
            else
                result=""
            fi
        fi

        if [ -z "$result" ]; then
            log_error "Unable to retrieve $label count for $env; defaulting to 0"
            result="0"
        fi

        echo "$result"
    }

    tables=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_tables WHERE schemaname IN ('public','storage','auth');" "tables")
    views=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_views WHERE schemaname IN ('public','storage','auth');" "views")
    functions=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname IN ('public','storage','auth');" "functions")
    sequences=$(run_count_with_fallback "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema IN ('public','storage','auth');" "sequences")
    indexes=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_indexes WHERE schemaname IN ('public','storage','auth');" "indexes")
    policies=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_policies WHERE schemaname IN ('public','storage');" "policies")
    triggers=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname IN ('public','storage','auth') AND NOT t.tgisinternal;" "triggers")
    types=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname IN ('public','storage','auth') AND t.typtype = 'c';" "types")
    enums=$(run_count_with_fallback "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname IN ('public','storage','auth') AND t.typtype = 'e';" "enums")

    echo "{\"tables\":${tables:-0},\"views\":${views:-0},\"functions\":${functions:-0},\"sequences\":${sequences:-0},\"indexes\":${indexes:-0},\"policies\":${policies:-0},\"triggers\":${triggers:-0},\"types\":${types:-0},\"enums\":${enums:-0}}"
}

query_auth_users_count() {
    local project_ref=$1
    local password=$2
    local pooler_host=$3
    
    if [ -z "$project_ref" ] || [ -z "$password" ]; then
        echo "0"
        return 0
    fi
    
    local auth_users=0
    
    if [ -n "$pooler_host" ]; then
        auth_users=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U "postgres.${project_ref}" -d postgres -t -A -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    if [ -z "$pooler_host" ] || [ "$auth_users" = "" ] || [ "$auth_users" = "0" ]; then
        local direct_host="db.${project_ref}.supabase.co"
        auth_users=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U "postgres.${project_ref}" -d postgres -t -A -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    echo "${auth_users:-0}"
}

query_edge_functions_count() {
    local project_ref=$1
    
    if [ -z "$project_ref" ] || [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        echo "0"
        return 0
    fi
    
    local temp_json=$(mktemp)
    local count=0
    
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${project_ref}/functions" \
        -o "$temp_json" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1 && jq empty "$temp_json" 2>/dev/null; then
            count=$(jq '. | length' "$temp_json" 2>/dev/null || echo "0")
        fi
    fi
    
    rm -f "$temp_json"
    echo "${count:-0}"
}

query_storage_buckets_count() {
    local project_ref=$1
    local password=$2
    local pooler_host=$3
    
    if [ -z "$project_ref" ] || [ -z "$password" ]; then
        echo "0"
        return 0
    fi
    
    local buckets=0
    
    if [ -n "$pooler_host" ]; then
        buckets=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U "postgres.${project_ref}" -d postgres -t -A -c "SELECT COUNT(*) FROM storage.buckets;" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    if [ -z "$pooler_host" ] || [ "$buckets" = "" ]; then
        local direct_host="db.${project_ref}.supabase.co"
        buckets=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U "postgres.${project_ref}" -d postgres -t -A -c "SELECT COUNT(*) FROM storage.buckets;" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    echo "${buckets:-0}"
}

query_secrets_count() {
    local project_ref=$1
    
    if [ -z "$project_ref" ] || [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        echo "0"
        return 0
    fi
    
    local temp_json=$(mktemp)
    local count=0
    
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${project_ref}/secrets" \
        -o "$temp_json" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1 && jq empty "$temp_json" 2>/dev/null; then
            count=$(jq '. | length' "$temp_json" 2>/dev/null || echo "0")
        fi
    fi
    
    rm -f "$temp_json"
    echo "${count:-0}"
}

# Collect snapshot for an environment
collect_env_snapshot() {
    local env=$1
    local env_name=$2
    
    log_info "Collecting snapshot for $env_name environment..."
    
    # Get environment details
    local project_ref=$(get_project_ref "$env")
    local project_name=""
    # Try to get project name from environment variables
    case $env in
        prod)
            project_name="${SUPABASE_PROD_PROJECT_NAME:-}"
            ;;
        test)
            project_name="${SUPABASE_TEST_PROJECT_NAME:-}"
            ;;
        dev)
            project_name="${SUPABASE_DEV_PROJECT_NAME:-}"
            ;;
    esac
    local password=$(get_db_password "$env")
    local pooler_host=$(get_pooler_host_for_env "$env" 2>/dev/null || get_pooler_host "$project_ref")
    
    if [ -z "$project_ref" ] || [ -z "$password" ]; then
        log_warning "  Skipping $env_name: Missing project_ref or password"
        # Return empty but valid JSON structure
        echo "{\"env\":\"$env\",\"name\":\"$env_name\",\"projectRef\":\"\",\"projectName\":\"\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"counts\":{\"tables\":0,\"views\":0,\"functions\":0,\"sequences\":0,\"indexes\":0,\"policies\":0,\"triggers\":0,\"types\":0,\"enums\":0,\"authUsers\":0,\"edgeFunctions\":0,\"buckets\":0,\"secrets\":0}}"
        return 0
    fi
    
    if [ -z "$pooler_host" ]; then
        pooler_host="aws-1-us-east-2.pooler.supabase.com"
    fi
    
    # Collect database counts
    log_info "  Querying database objects..."
    local db_counts=$(query_database_counts "$env" "$project_ref" "$password" "$pooler_host")
    
    # Collect auth users count
    log_info "  Querying auth users..."
    local auth_users=$(query_auth_users_count "$project_ref" "$password" "$pooler_host")
    
    # Collect edge functions count
    log_info "  Querying edge functions..."
    local edge_functions=$(query_edge_functions_count "$project_ref")
    
    # Collect storage buckets count
    log_info "  Querying storage buckets..."
    local buckets=$(query_storage_buckets_count "$project_ref" "$password" "$pooler_host")
    
    # Collect secrets count
    log_info "  Querying secrets..."
    local secrets=$(query_secrets_count "$project_ref")
    
    # Ensure all numeric values are valid (default to 0 if empty)
    auth_users=${auth_users:-0}
    edge_functions=${edge_functions:-0}
    buckets=${buckets:-0}
    secrets=${secrets:-0}
    
    # Ensure db_counts is valid JSON
    if ! echo "$db_counts" | jq empty 2>/dev/null; then
        log_warning "  Invalid db_counts JSON, using defaults"
        db_counts='{"tables":0,"views":0,"functions":0,"sequences":0,"indexes":0,"policies":0,"triggers":0,"types":0,"enums":0}'
    fi
    
    # Build JSON snapshot
    local snapshot_json
    if command -v jq >/dev/null 2>&1; then
        # Use a safer approach: build the JSON step by step
        snapshot_json=$(echo "$db_counts" | jq --arg env "$env" \
            --arg name "$env_name" \
            --arg ref "$project_ref" \
            --arg proj_name "${project_name:-}" \
            --argjson auth "$((auth_users))" \
            --argjson edge "$((edge_functions))" \
            --argjson bucket "$((buckets))" \
            --argjson secret "$((secrets))" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
                env: $env,
                name: $name,
                projectRef: $ref,
                projectName: $proj_name,
                timestamp: $timestamp,
                counts: {
                    tables: (.tables // 0),
                    views: (.views // 0),
                    functions: (.functions // 0),
                    sequences: (.sequences // 0),
                    indexes: (.indexes // 0),
                    policies: (.policies // 0),
                    triggers: (.triggers // 0),
                    types: (.types // 0),
                    enums: (.enums // 0),
                    authUsers: $auth,
                    edgeFunctions: $edge,
                    buckets: $bucket,
                    secrets: $secret
                }
            }' 2>/dev/null)
        
        # If jq failed, use fallback
        if [ -z "$snapshot_json" ] || ! echo "$snapshot_json" | jq empty 2>/dev/null; then
            log_warning "  jq failed, using fallback JSON construction"
            snapshot_json=""
        fi
    fi
    
    # Fallback if jq is not available or failed
    if [ -z "$snapshot_json" ]; then
        # Fallback without jq (simple JSON construction)
        local tables=$(echo "$db_counts" | grep -o '"tables":[0-9]*' | cut -d: -f2 || echo "0")
        local views=$(echo "$db_counts" | grep -o '"views":[0-9]*' | cut -d: -f2 || echo "0")
        local functions=$(echo "$db_counts" | grep -o '"functions":[0-9]*' | cut -d: -f2 || echo "0")
        local sequences=$(echo "$db_counts" | grep -o '"sequences":[0-9]*' | cut -d: -f2 || echo "0")
        local indexes=$(echo "$db_counts" | grep -o '"indexes":[0-9]*' | cut -d: -f2 || echo "0")
        local policies=$(echo "$db_counts" | grep -o '"policies":[0-9]*' | cut -d: -f2 || echo "0")
        local triggers=$(echo "$db_counts" | grep -o '"triggers":[0-9]*' | cut -d: -f2 || echo "0")
        local types=$(echo "$db_counts" | grep -o '"types":[0-9]*' | cut -d: -f2 || echo "0")
        local enums=$(echo "$db_counts" | grep -o '"enums":[0-9]*' | cut -d: -f2 || echo "0")
        
        snapshot_json="{\"env\":\"$env\",\"name\":\"$env_name\",\"projectRef\":\"$project_ref\",\"projectName\":\"$project_name\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"counts\":{\"tables\":$tables,\"views\":$views,\"functions\":$functions,\"sequences\":$sequences,\"indexes\":$indexes,\"policies\":$policies,\"triggers\":$triggers,\"types\":$types,\"enums\":$enums,\"authUsers\":$auth_users,\"edgeFunctions\":$edge_functions,\"buckets\":$buckets,\"secrets\":$secrets}}"
    fi
    
    echo "$snapshot_json"
}

# Collect snapshots for all environments
log_info "Collecting snapshots for all environments..."
log_info ""

DEV_SNAPSHOT=$(collect_env_snapshot "dev" "Development")
log_info ""

TEST_SNAPSHOT=$(collect_env_snapshot "test" "Test/Staging")
log_info ""

PROD_SNAPSHOT=$(collect_env_snapshot "prod" "Production")
log_info ""

# Combine all snapshots into final JSON
log_info "Generating final snapshot file..."

# Validate snapshots are valid JSON before combining
if command -v jq >/dev/null 2>&1; then
    # Validate each snapshot
    if ! echo "$DEV_SNAPSHOT" | jq empty 2>/dev/null; then
        log_warning "DEV_SNAPSHOT is invalid JSON, using empty object"
        DEV_SNAPSHOT='{"env":"dev","name":"Development","projectRef":"","projectName":"","timestamp":"","counts":{"tables":0,"views":0,"functions":0,"sequences":0,"indexes":0,"policies":0,"triggers":0,"types":0,"enums":0,"authUsers":0,"edgeFunctions":0,"buckets":0,"secrets":0}}'
    fi
    if ! echo "$TEST_SNAPSHOT" | jq empty 2>/dev/null; then
        log_warning "TEST_SNAPSHOT is invalid JSON, using empty object"
        TEST_SNAPSHOT='{"env":"test","name":"Test/Staging","projectRef":"","projectName":"","timestamp":"","counts":{"tables":0,"views":0,"functions":0,"sequences":0,"indexes":0,"policies":0,"triggers":0,"types":0,"enums":0,"authUsers":0,"edgeFunctions":0,"buckets":0,"secrets":0}}'
    fi
    if ! echo "$PROD_SNAPSHOT" | jq empty 2>/dev/null; then
        log_warning "PROD_SNAPSHOT is invalid JSON, using empty object"
        PROD_SNAPSHOT='{"env":"prod","name":"Production","projectRef":"","projectName":"","timestamp":"","counts":{"tables":0,"views":0,"functions":0,"sequences":0,"indexes":0,"policies":0,"triggers":0,"types":0,"enums":0,"authUsers":0,"edgeFunctions":0,"buckets":0,"secrets":0}}'
    fi
    
    # Use jq to safely combine the JSON objects
    # Write snapshots to temp files first to avoid shell escaping issues
    temp_dev=$(mktemp)
    temp_test=$(mktemp)
    temp_prod=$(mktemp)
    echo "$DEV_SNAPSHOT" > "$temp_dev"
    echo "$TEST_SNAPSHOT" > "$temp_test"
    echo "$PROD_SNAPSHOT" > "$temp_prod"
    
    jq -n \
        --arg timestamp "$TIMESTAMP" \
        --argjson generatedAt "$(date +%s)" \
        --slurpfile dev "$temp_dev" \
        --slurpfile test "$temp_test" \
        --slurpfile prod "$temp_prod" \
        '{
            timestamp: $timestamp,
            generatedAt: $generatedAt,
            environments: {
                dev: $dev[0],
                test: $test[0],
                prod: $prod[0]
            }
        }' > "$SNAPSHOT_FILE"
    
    # Clean up temp files
    rm -f "$temp_dev" "$temp_test" "$temp_prod"
else
    # Fallback without jq
    cat > "$SNAPSHOT_FILE" << EOF
{
    "timestamp": "$TIMESTAMP",
    "generatedAt": $(date +%s),
    "environments": {
        "dev": $DEV_SNAPSHOT,
        "test": $TEST_SNAPSHOT,
        "prod": $PROD_SNAPSHOT
    }
}
EOF
fi

log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "  Snapshot generated successfully!"
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Snapshot file: $SNAPSHOT_FILE"
log_info ""

# Display summary
if command -v jq >/dev/null 2>&1; then
    log_info "Summary:"
    echo ""
    echo "Environment | Tables | Views | Functions | Auth Users | Edge Functions | Buckets | Secrets"
    echo "------------|--------|-------|-----------|------------|----------------|---------|--------"
    
    for env in dev test prod; do
        env_data=$(jq -r ".environments.$env" "$SNAPSHOT_FILE" 2>/dev/null)
        if [ "$env_data" != "null" ] && [ -n "$env_data" ]; then
            name=$(echo "$env_data" | jq -r '.name // "N/A"')
            tables=$(echo "$env_data" | jq -r '.counts.tables // 0')
            views=$(echo "$env_data" | jq -r '.counts.views // 0')
            functions=$(echo "$env_data" | jq -r '.counts.functions // 0')
            auth=$(echo "$env_data" | jq -r '.counts.authUsers // 0')
            edge=$(echo "$env_data" | jq -r '.counts.edgeFunctions // 0')
            buckets=$(echo "$env_data" | jq -r '.counts.buckets // 0')
            secrets=$(echo "$env_data" | jq -r '.counts.secrets // 0')
            printf "%-12s| %-7s| %-5s| %-9s| %-10s| %-14s| %-7s| %-7s\n" "$name" "$tables" "$views" "$functions" "$auth" "$edge" "$buckets" "$secrets"
        else
            printf "%-12s| %-7s| %-5s| %-9s| %-10s| %-14s| %-7s| %-7s\n" "$env" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        fi
    done
    echo ""
fi

log_success "Done!"

