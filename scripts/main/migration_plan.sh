#!/bin/bash
# Migration Plan Generator
# Generates a comprehensive HTML report comparing source and target environments
# Shows current status, differences, and migration recommendations

set -eo pipefail
# Note: Temporarily disabling 'u' flag for heredoc variable expansion
# Variables are initialized before use, but heredoc expansion can cause false positives
# Temporarily disable strict mode for environment loading to handle .env.local gracefully
set +u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [output_dir]

Generates a comprehensive HTML migration plan comparing source and target environments.

Arguments:
  source_env   Source environment (prod, test, dev, backup)
  target_env   Target environment (prod, test, dev, backup)
  output_dir   Directory to save the HTML report (optional, defaults to ./migration_plans)

Examples:
  ./scripts/main/migration_plan.sh dev test
  ./scripts/main/migration_plan.sh prod test ./custom_output

The script will generate:
  - migration_plan_[source]_to_[target]_[timestamp].html

EOF
    exit 1
}

# Check arguments
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
OUTPUT_DIR=${3:-"./migration_plans"}

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
set +e  # Temporarily disable exit on error for environment loading
load_env
LOAD_ENV_EXIT_CODE=$?
set -e  # Re-enable exit on error
if [ $LOAD_ENV_EXIT_CODE -ne 0 ]; then
    log_error "Failed to load environment variables"
    exit 1
fi
set -u  # Re-enable unbound variable checking after environment is loaded

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

validate_environments "$SOURCE_ENV" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

# Create output directory
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HTML_FILE="$OUTPUT_DIR/migration_plan_${SOURCE_ENV}_to_${TARGET_ENV}_${TIMESTAMP}.html"
DIFF_JSON_FILE="$OUTPUT_DIR/migration_plan_${SOURCE_ENV}_to_${TARGET_ENV}_${TIMESTAMP}.json"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Plan Generator"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Output: $HTML_FILE"
log_info ""

# Helper function to count lines in file (excluding empty lines)
count_items() {
    local file=$1
    if [ -f "$file" ]; then
        grep -v '^[[:space:]]*$' "$file" | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# Helper function to get file contents as array
get_file_contents() {
    local file=$1
    if [ -f "$file" ] && [ -s "$file" ]; then
        cat "$file"
    else
        echo ""
    fi
}

# Helper to run a psql query with automatic fallback to direct connection
run_psql_with_fallback() {
    local output_path=$1
    local description=$2
    local ref=$3
    local password=$4
    local pooler_region=$5
    local pooler_port=$6
    local query=$7
    shift 7
    local psql_extra_flags=()
    if [ $# -gt 0 ]; then
        psql_extra_flags=("$@")
    fi

    local tmp_file="${output_path}.tmp"
    local tmp_err="${output_path}.err"
    rm -f "$tmp_file"
    rm -f "$tmp_err"

    local success=false
    local attempt_label=""

    # First, try database connectivity via shared pooler (no API calls)
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            ${psql_extra_flags[@]+"${psql_extra_flags[@]}"} \
            -c "$query" \
            >"$tmp_file" 2>"$tmp_err"; then
            success=true
            attempt_label="$label"
            break
        else
            status=$?
            if [ -s "$tmp_err" ]; then
                log_warning "$description for $ref failed via $label: $(head -1 "$tmp_err")"
            else
                log_warning "$description for $ref failed via $label (psql exited with status $status)"
            fi
            log_warning "Trying next endpoint..."
        fi
    done < <(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    # If all pooler connections failed, try API to get correct pooler hostname
    if [ "$success" = "false" ]; then
        log_info "Pooler connections failed, trying API to get pooler hostname..."
        local api_pooler_host=""
        api_pooler_host=$(get_pooler_host_via_api "$ref" 2>/dev/null || echo "")
        
        if [ -n "$api_pooler_host" ]; then
            log_info "Retrying $description with API-resolved pooler host: ${api_pooler_host}"
            
            # Try with API-resolved pooler host
            for port in "$pooler_port" "5432"; do
                if PGPASSWORD="$password" PGSSLMODE=require psql \
                    -h "$api_pooler_host" \
                    -p "$port" \
                    -U "postgres.${ref}" \
                    -d postgres \
                    -t -A \
                    ${psql_extra_flags[@]+"${psql_extra_flags[@]}"} \
                    -c "$query" \
                    >"$tmp_file" 2>"$tmp_err"; then
                    success=true
                    attempt_label="API-resolved pooler (${api_pooler_host}:${port})"
                    break
                else
                    status=$?
                    if [ -s "$tmp_err" ]; then
                        log_warning "$description for $ref failed via API-resolved pooler (${api_pooler_host}:${port}): $(head -1 "$tmp_err")"
                    else
                        log_warning "$description for $ref failed via API-resolved pooler (${api_pooler_host}:${port}) (psql exited with status $status)"
                    fi
                fi
            done
        else
            log_warning "Could not resolve pooler hostname via API"
        fi
    fi

    if $success; then
        mv "$tmp_file" "$output_path"
        rm -f "$tmp_err"
        if [ -s "$output_path" ]; then
            log_info "Retrieved $description for $ref via $attempt_label"
        else
            log_info "$description for $ref via $attempt_label returned no rows"
        fi
    else
        : > "$output_path"
        log_warning "Unable to retrieve $description for $ref after all connection attempts"
        rm -f "$tmp_file" "$tmp_err"
    fi
}

# Function to get database schema information
get_db_schema_info() {
    local env=$1
    local ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local output_file=$6
    
    log_info "Collecting database schema information from $env..."
    
    # Tables (simple list for backwards compatibility)
    local tables_query="SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, tablename;"
    run_psql_with_fallback "$output_file.tables" "table list" "$ref" "$password" "$pooler_region" "$pooler_port" "$tables_query"
    
    # Views (list)
    local views_query="SELECT schemaname||'.'||viewname FROM pg_views WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, viewname;"
    run_psql_with_fallback "$output_file.views" "view list" "$ref" "$password" "$pooler_region" "$pooler_port" "$views_query"
    
    # Functions (list)
    local functions_query="SELECT n.nspname||'.'||p.proname||'('||pg_get_function_arguments(p.oid)||')' FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname IN ('public', 'storage', 'auth') ORDER BY n.nspname, p.proname;"
    run_psql_with_fallback "$output_file.db_functions" "database functions list" "$ref" "$password" "$pooler_region" "$pooler_port" "$functions_query"
    
    # Triggers (list)
    local triggers_query="SELECT n.nspname||'.'||c.relname||'.'||t.tgname FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname IN ('public', 'storage', 'auth') AND t.tgisinternal = false ORDER BY n.nspname, c.relname, t.tgname;"
    run_psql_with_fallback "$output_file.triggers" "trigger list" "$ref" "$password" "$pooler_region" "$pooler_port" "$triggers_query"
    
    # Sequences (list)
    local sequences_query="SELECT schemaname||'.'||sequencename FROM pg_sequences WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, sequencename;"
    run_psql_with_fallback "$output_file.sequences" "sequence list" "$ref" "$password" "$pooler_region" "$pooler_port" "$sequences_query"
    
    # Row counts (list)
    local row_counts_query="
        SELECT 
            table_schema||'.'||table_name AS table_name,
            COALESCE((
                SELECT reltuples::bigint 
                FROM pg_class 
                WHERE pg_class.oid = format('%I.%I', table_schema, table_name)::regclass
            ), 0)::text AS row_count
        FROM information_schema.tables
        WHERE table_schema IN ('public', 'storage', 'auth')
        ORDER BY table_schema, table_name;
    "
    run_psql_with_fallback "$output_file.row_counts" "table row counts" "$ref" "$password" "$pooler_region" "$pooler_port" "$row_counts_query"
    
    # RLS policies (list)
    local policies_query="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname IN ('public', 'storage') ORDER BY schemaname, tablename, policyname;"
    run_psql_with_fallback "$output_file.policies" "RLS policy list" "$ref" "$password" "$pooler_region" "$pooler_port" "$policies_query"
    
    # Detailed JSON metadata
    local columns_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY table_schema, table_name, ordinal_position), '[]'::json) FROM ( SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default, ordinal_position, character_maximum_length, numeric_precision, numeric_scale, is_identity, identity_generation, generation_expression FROM information_schema.columns WHERE table_schema IN ('public','storage','auth') ) t;"
    run_psql_with_fallback "$output_file.columns.json" "column metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$columns_json_query"

    local indexes_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY schemaname, tablename, indexname), '[]'::json) FROM ( SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes WHERE schemaname IN ('public','storage','auth') ) t;"
    run_psql_with_fallback "$output_file.indexes.json" "index metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$indexes_json_query"

    local functions_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY schema, name), '[]'::json) FROM ( SELECT n.nspname AS schema, p.proname AS name, pg_get_function_arguments(p.oid) AS arguments, pg_get_function_result(p.oid) AS result_type, pg_get_functiondef(p.oid) AS definition FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname IN ('public','storage','auth') ) t;"
    run_psql_with_fallback "$output_file.functions.json" "function definitions" "$ref" "$password" "$pooler_region" "$pooler_port" "$functions_json_query"

    local views_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY table_schema, table_name), '[]'::json) FROM ( SELECT table_schema AS schema, table_name, view_definition FROM information_schema.views WHERE table_schema IN ('public','storage','auth') ) t;"
    run_psql_with_fallback "$output_file.views.json" "view definitions" "$ref" "$password" "$pooler_region" "$pooler_port" "$views_json_query"

    local triggers_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY schema, table_name, trigger_name), '[]'::json) FROM ( SELECT n.nspname AS schema, c.relname AS table_name, t.tgname AS trigger_name, pg_get_triggerdef(t.oid) AS definition FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname IN ('public','storage','auth') AND t.tgisinternal = false ) t;"
    run_psql_with_fallback "$output_file.triggers.json" "trigger definitions" "$ref" "$password" "$pooler_region" "$pooler_port" "$triggers_json_query"

    local sequences_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY sequence_schema, sequencename), '[]'::json) FROM ( SELECT schemaname AS sequence_schema, sequencename, last_value, increment_by FROM pg_sequences WHERE schemaname IN ('public','storage','auth') ) t;"
    run_psql_with_fallback "$output_file.sequences.json" "sequence metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$sequences_json_query"

    local policies_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY schemaname, tablename, policyname), '[]'::json) FROM ( SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check FROM pg_policies WHERE schemaname IN ('public','storage') ) t;"
    run_psql_with_fallback "$output_file.policies.json" "policy metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$policies_json_query"

    local row_counts_json_query="
        SELECT COALESCE(json_agg(row_to_json(t) ORDER BY table_schema, table_name), '[]'::json)
        FROM (
            SELECT 
                table_schema,
                table_name,
                COALESCE((
                    SELECT reltuples::bigint 
                    FROM pg_class 
                    WHERE pg_class.oid = format('%I.%I', table_schema, table_name)::regclass
                ), 0) AS row_count
            FROM information_schema.tables
            WHERE table_schema IN ('public','storage','auth')
        ) t;
    "
    run_psql_with_fallback "$output_file.row_counts.json" "row count metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$row_counts_json_query"

    rm -f "$output_file.triggers.tmp" "$output_file.sequences.tmp" "$output_file.tables.tmp" "$output_file.views.tmp" "$output_file.db_functions.tmp" "$output_file.row_counts.tmp" "$output_file.policies.tmp"
    rm -f "$output_file.columns.json.tmp" "$output_file.indexes.json.tmp" "$output_file.functions.json.tmp" "$output_file.views.json.tmp" "$output_file.triggers.json.tmp" "$output_file.sequences.json.tmp" "$output_file.policies.json.tmp" "$output_file.row_counts.json.tmp"
    
    log_success "Database schema information collected from $env"
}

# Function to get storage buckets information
get_storage_buckets_info() {
    local env=$1
    local ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local output_file=$6
    
    log_info "Collecting storage buckets information from $env..."
    
    # Get buckets with file counts (legacy text output)
    local buckets_query="
        SELECT 
            b.name,
            b.public::text,
            COALESCE(b.file_size_limit::text, 'NULL'),
            COALESCE(array_to_string(b.allowed_mime_types, ','), 'NULL'),
            COALESCE((
                SELECT COUNT(*)::text 
                FROM storage.objects 
                WHERE bucket_id = b.id
            ), '0') as file_count
        FROM storage.buckets b
        ORDER BY b.name;
    "
    run_psql_with_fallback "$output_file.buckets" "storage buckets list" "$ref" "$password" "$pooler_region" "$pooler_port" "$buckets_query"

    # Bucket metadata as JSON
    local buckets_json_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY name), '[]'::json) FROM ( SELECT b.id, b.name, b.public, b.file_size_limit, b.allowed_mime_types, COALESCE(( SELECT COUNT(*) FROM storage.objects o WHERE o.bucket_id = b.id ), 0) AS file_count FROM storage.buckets b ) t;"
    run_psql_with_fallback "$output_file.buckets.json" "storage buckets metadata" "$ref" "$password" "$pooler_region" "$pooler_port" "$buckets_json_query"

    # Bucket objects (files) as JSON
    local bucket_objects_query="SELECT COALESCE(json_agg(row_to_json(t) ORDER BY bucket_name, object_name), '[]'::json) FROM ( SELECT b.name AS bucket_name, o.name AS object_name, CASE WHEN (o.metadata ->> 'size') ~ '^[0-9]+$' THEN (o.metadata ->> 'size')::bigint ELSE NULL END AS size_bytes, o.updated_at, o.metadata FROM storage.objects o JOIN storage.buckets b ON o.bucket_id = b.id ) t;"
    run_psql_with_fallback "$output_file.bucket_objects.json" "storage bucket objects" "$ref" "$password" "$pooler_region" "$pooler_port" "$bucket_objects_query"

    rm -f "$output_file.buckets.tmp" "$output_file.buckets.json.tmp" "$output_file.bucket_objects.json.tmp"
    
    log_success "Storage buckets information collected from $env"
}

# Function to get edge functions information
get_edge_functions_info() {
    local env=$1
    local ref=$2
    local output_file=$3
    
    log_info "Collecting edge functions information from $env..."
    
    local env_token=$(get_env_access_token "$env")
    if [ -z "$env_token" ]; then
        log_error "SUPABASE_${env^^}_ACCESS_TOKEN not set - cannot collect edge functions for $env"
        return 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found - required to parse edge functions for $env"
        return 1
    fi
    
    local raw_file="$output_file.functions_raw"
    local list_file="$output_file.functions"
    local tmp_file="$raw_file.tmp"
    local http_status
    
    http_status=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $env_token" \
        "https://api.supabase.com/v1/projects/${ref}/functions" \
        -o "$tmp_file" 2>/dev/null || echo "000")
    
    if [ "$http_status" != "200" ]; then
        log_error "Failed to fetch edge functions from $env (HTTP $http_status)"
        rm -f "$tmp_file" "$list_file"
        return 1
    fi
    
    mv "$tmp_file" "$raw_file"
    
    if ! jq -e 'type == "array"' "$raw_file" >/dev/null 2>&1; then
        log_error "Unexpected response while retrieving edge functions from $env"
        rm -f "$list_file"
        return 1
    fi
    
    local function_count
    function_count=$(jq 'length' "$raw_file" 2>/dev/null || echo 0)
    if [ "$function_count" -eq 0 ]; then
        log_warning "Edge function API returned zero functions for $env. Continuing with empty set."
        : > "$list_file"
        return 0
    fi
    
    if ! jq -r '.[].name' "$raw_file" 2>/dev/null | sort > "$list_file"; then
        log_error "Unable to parse edge functions response from $env"
        rm -f "$list_file"
        return 1
    fi
    
    log_success "Edge functions information collected from $env"
    return 0
}

# Download edge function code for comparison
download_edge_functions_code() {
    local env=$1
    local ref=$2
    local password=$3
    local functions_list_file=$4
    local destination_dir=$5

    if [ ! -f "$functions_list_file" ] || [ ! -s "$functions_list_file" ]; then
        log_warning "No edge function names available for $env; skipping code download"
        return 0
    fi

    local functions_list
    functions_list=$(get_file_contents "$functions_list_file")
    if [ -z "$functions_list" ]; then
        log_warning "Edge function list for $env is empty; skipping code download"
        return 0
    fi

    mkdir -p "$destination_dir"

    if ! node "$SCRIPT_DIR/../utils/download-edge-functions.js" "$ref" "$functions_list_file" "$destination_dir" "$env" "${password:-}"; then
        log_warning "Failed to download edge function code from $env; continuing without function code"
        return 0
    fi

    return 0
}

# Function to get secrets information
get_secrets_info() {
    local env=$1
    local ref=$2
    local output_file=$3
    
    log_info "Collecting secrets information from $env..."
    
    local env_token=$(get_env_access_token "$env")
    if [ -z "$env_token" ]; then
        log_warning "SUPABASE_${env^^}_ACCESS_TOKEN not set - skipping secrets"
        echo "" > "$output_file.secrets"
        return
    fi
    
    # Get secrets using Management API
    if curl -s -H "Authorization: Bearer $env_token" \
        "https://api.supabase.com/v1/projects/${ref}/secrets" \
        -o "$output_file.secrets_raw" 2>/dev/null; then
        
        # Extract secret names
        if command -v jq >/dev/null 2>&1; then
            jq -r '.[].name' "$output_file.secrets_raw" 2>/dev/null | sort > "$output_file.secrets" || echo "" > "$output_file.secrets"
        else
            log_warning "jq not found - cannot parse secrets"
            echo "" > "$output_file.secrets"
        fi
    else
        log_warning "Failed to fetch secrets from $env"
        echo "" > "$output_file.secrets"
    fi
    
    log_success "Secrets information collected from $env"
}

# Collect source information
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Source Environment Information"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

SOURCE_INFO="$TEMP_DIR/source"
get_db_schema_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SOURCE_INFO"
get_storage_buckets_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$SOURCE_INFO"
if ! get_edge_functions_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_INFO"; then
    log_error "Unable to retrieve edge function metadata from $SOURCE_ENV"
    exit 1
fi
get_secrets_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_INFO"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Target Environment Information"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

TARGET_INFO="$TEMP_DIR/target"
get_db_schema_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$TARGET_INFO"
get_storage_buckets_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$TARGET_INFO"
if ! get_edge_functions_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_INFO"; then
    log_error "Unable to retrieve edge function metadata from $TARGET_ENV"
    exit 1
fi
get_secrets_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_INFO"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Generating Detailed Migration Plan"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

EDGE_SOURCE_DIR="$TEMP_DIR/edge_functions_source"
EDGE_TARGET_DIR="$TEMP_DIR/edge_functions_target"
rm -rf "$EDGE_SOURCE_DIR" "$EDGE_TARGET_DIR"
mkdir -p "$EDGE_SOURCE_DIR" "$EDGE_TARGET_DIR"

if ! download_edge_functions_code "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_INFO.functions" "$EDGE_SOURCE_DIR"; then
    log_error "Failed to download edge function code from $SOURCE_ENV"
    exit 1
fi
if ! download_edge_functions_code "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_INFO.functions" "$EDGE_TARGET_DIR"; then
    log_error "Failed to download edge function code from $TARGET_ENV"
    exit 1
fi

log_info "Building detailed migration planner report..."

export MP_HTML_FILE="$HTML_FILE"
export MP_SOURCE_ENV="$SOURCE_ENV"
export MP_TARGET_ENV="$TARGET_ENV"
export MP_SOURCE_REF="$SOURCE_REF"
export MP_TARGET_REF="$TARGET_REF"
export MP_DIFF_JSON="$DIFF_JSON_FILE"
export MP_SOURCE_COLUMNS_JSON="$SOURCE_INFO.columns.json"
export MP_TARGET_COLUMNS_JSON="$TARGET_INFO.columns.json"
export MP_SOURCE_INDEXES_JSON="$SOURCE_INFO.indexes.json"
export MP_TARGET_INDEXES_JSON="$TARGET_INFO.indexes.json"
export MP_SOURCE_TRIGGERS_JSON="$SOURCE_INFO.triggers.json"
export MP_TARGET_TRIGGERS_JSON="$TARGET_INFO.triggers.json"
export MP_SOURCE_POLICIES_JSON="$SOURCE_INFO.policies.json"
export MP_TARGET_POLICIES_JSON="$TARGET_INFO.policies.json"
export MP_SOURCE_FUNCTIONS_JSON="$SOURCE_INFO.functions.json"
export MP_TARGET_FUNCTIONS_JSON="$TARGET_INFO.functions.json"
export MP_SOURCE_VIEWS_JSON="$SOURCE_INFO.views.json"
export MP_TARGET_VIEWS_JSON="$TARGET_INFO.views.json"
export MP_SOURCE_SEQUENCES_JSON="$SOURCE_INFO.sequences.json"
export MP_TARGET_SEQUENCES_JSON="$TARGET_INFO.sequences.json"
export MP_SOURCE_ROWCOUNTS_JSON="$SOURCE_INFO.row_counts.json"
export MP_TARGET_ROWCOUNTS_JSON="$TARGET_INFO.row_counts.json"
export MP_SOURCE_BUCKETS_JSON="$SOURCE_INFO.buckets.json"
export MP_TARGET_BUCKETS_JSON="$TARGET_INFO.buckets.json"
export MP_SOURCE_BUCKET_OBJECTS_JSON="$SOURCE_INFO.bucket_objects.json"
export MP_TARGET_BUCKET_OBJECTS_JSON="$TARGET_INFO.bucket_objects.json"
export MP_SOURCE_FUNCTIONS_RAW="$SOURCE_INFO.functions_raw"
export MP_TARGET_FUNCTIONS_RAW="$TARGET_INFO.functions_raw"
export MP_SOURCE_SECRETS_RAW="$SOURCE_INFO.secrets_raw"
export MP_TARGET_SECRETS_RAW="$TARGET_INFO.secrets_raw"
export MP_SOURCE_SECRETS_LIST="$SOURCE_INFO.secrets"
export MP_TARGET_SECRETS_LIST="$TARGET_INFO.secrets"
export MP_SOURCE_FUNCTION_LIST="$SOURCE_INFO.functions"
export MP_TARGET_FUNCTION_LIST="$TARGET_INFO.functions"
export MP_EDGE_SOURCE_DIR="$EDGE_SOURCE_DIR"
export MP_EDGE_TARGET_DIR="$EDGE_TARGET_DIR"

python3 <<'PY'
import os
import json
import html
import difflib
from pathlib import Path
from collections import defaultdict
from datetime import datetime, timezone

def env(name, default=''):
    return os.environ.get(name, default)

def load_json(path):
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    try:
        text = p.read_text(encoding='utf-8').strip()
    except Exception:
        return None
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        try:
            return json.loads(text.replace('\n', ''))
        except json.JSONDecodeError:
            return None

def load_json_list(path):
    data = load_json(path)
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return [data]
    return []

def load_text_list(path):
    if not path:
        return []
    p = Path(path)
    if not p.exists():
        return []
    return [line.strip() for line in p.read_text(encoding='utf-8').splitlines() if line.strip()]

def parse_int(value):
    if value is None:
        return 0
    try:
        return int(value)
    except (ValueError, TypeError):
        try:
            return int(float(value))
        except (ValueError, TypeError):
            return 0

def describe_column(col):
    data_type = col.get('data_type') or ''
    length = col.get('character_maximum_length')
    if length and str(length).lower() not in ('', 'none'):
        data_type = f"{data_type}({length})"
    precision = col.get('numeric_precision')
    scale = col.get('numeric_scale')
    if precision and str(precision).lower() not in ('', 'none'):
        if scale and str(scale).lower() not in ('', 'none'):
            data_type = f"{data_type}({precision},{scale})"
        else:
            data_type = f"{data_type}({precision})"
    parts = [data_type.strip()]
    if (col.get('is_nullable') or '').upper() == 'NO':
        parts.append('NOT NULL')
    default = col.get('column_default')
    if default:
        parts.append(f"DEFAULT {default}")
    if (col.get('is_identity') or '').upper() == 'YES':
        parts.append('IDENTITY')
    gen = col.get('generation_expression')
    if gen:
        parts.append(f"GENERATED ({gen})")
    return ' '.join(part for part in parts if part)

def build_columns_map(rows):
    tables = defaultdict(dict)
    for row in rows:
        schema = row.get('table_schema') or row.get('schema')
        table = row.get('table_name')
        column = row.get('column_name')
        if not schema or not table or not column:
            continue
        key = f"{schema}.{table}"
        tables[key][column] = row
    return tables

def build_index_map(rows):
    tables = defaultdict(dict)
    for row in rows:
        schema = row.get('schemaname') or row.get('schema')
        table = row.get('tablename') or row.get('table_name')
        indexname = row.get('indexname')
        indexdef = row.get('indexdef')
        if schema and table and indexname:
            key = f"{schema}.{table}"
            tables[key][indexname] = indexdef
    return tables

def build_trigger_map(rows):
    tables = defaultdict(dict)
    for row in rows:
        schema = row.get('schema')
        table = row.get('table_name')
        trigger = row.get('trigger_name')
        definition = row.get('definition')
        if schema and table and trigger:
            key = f"{schema}.{table}"
            tables[key][trigger] = definition or ''
    return tables

def build_policy_map(rows):
    policies = {}
    for row in rows:
        schema = row.get('schemaname') or row.get('schema')
        table = row.get('tablename') or row.get('table_name')
        policy = row.get('policyname') or row.get('name')
        if schema and table and policy:
            key = f"{schema}.{table}.{policy}"
            policies[key] = row
    return policies

def build_function_map(rows):
    functions = {}
    for row in rows:
        schema = row.get('schema')
        name = row.get('name')
        args = row.get('arguments') or ''
        if schema and name is not None:
            key = f"{schema}.{name}({args})"
            functions[key] = row
    return functions

def build_view_map(rows):
    views = {}
    for row in rows:
        schema = row.get('schema') or row.get('table_schema')
        name = row.get('table_name') or row.get('name')
        if schema and name:
            key = f"{schema}.{name}"
            views[key] = row
    return views

def build_rowcount_map(rows):
    counts = {}
    for row in rows:
        schema = row.get('schemaname') or row.get('schema')
        table = row.get('table_name') or row.get('relname')
        if schema and table:
            key = f"{schema}.{table}"
            counts[key] = parse_int(row.get('row_count'))
    return counts

def build_bucket_map(rows):
    buckets = {}
    for row in rows:
        name = row.get('name')
        if name:
            buckets[name] = row
    return buckets

def build_bucket_objects(rows):
    objs = defaultdict(dict)
    for row in rows:
        bucket = row.get('bucket_name')
        name = row.get('object_name')
        if bucket and name:
            objs[bucket][name] = row
    return objs

def load_function_files(base_dir):
    files = {}
    if not base_dir:
        return files
    base = Path(base_dir)
    if not base.exists():
        return files
    for path in base.rglob('*'):
        if path.is_file():
            rel = str(path.relative_to(base)).replace('\\', '/')
            try:
                content = path.read_text(encoding='utf-8')
            except UnicodeDecodeError:
                content = path.read_text(encoding='utf-8', errors='replace')
            files[rel] = content.replace('\r\n', '\n')
    return files

source_env = env('MP_SOURCE_ENV', 'source')
target_env = env('MP_TARGET_ENV', 'target')
source_ref = env('MP_SOURCE_REF', '')
target_ref = env('MP_TARGET_REF', '')
html_file = env('MP_HTML_FILE')
diff_json_file = env('MP_DIFF_JSON')

source_columns = load_json_list(env('MP_SOURCE_COLUMNS_JSON'))
target_columns = load_json_list(env('MP_TARGET_COLUMNS_JSON'))
source_indexes = load_json_list(env('MP_SOURCE_INDEXES_JSON'))
target_indexes = load_json_list(env('MP_TARGET_INDEXES_JSON'))
source_triggers = load_json_list(env('MP_SOURCE_TRIGGERS_JSON'))
target_triggers = load_json_list(env('MP_TARGET_TRIGGERS_JSON'))
source_policies = load_json_list(env('MP_SOURCE_POLICIES_JSON'))
target_policies = load_json_list(env('MP_TARGET_POLICIES_JSON'))
source_functions = load_json_list(env('MP_SOURCE_FUNCTIONS_JSON'))
target_functions = load_json_list(env('MP_TARGET_FUNCTIONS_JSON'))
source_views = load_json_list(env('MP_SOURCE_VIEWS_JSON'))
target_views = load_json_list(env('MP_TARGET_VIEWS_JSON'))
source_rowcounts = load_json_list(env('MP_SOURCE_ROWCOUNTS_JSON'))
target_rowcounts = load_json_list(env('MP_TARGET_ROWCOUNTS_JSON'))
source_buckets = load_json_list(env('MP_SOURCE_BUCKETS_JSON'))
target_buckets = load_json_list(env('MP_TARGET_BUCKETS_JSON'))
source_bucket_objects = load_json_list(env('MP_SOURCE_BUCKET_OBJECTS_JSON'))
target_bucket_objects = load_json_list(env('MP_TARGET_BUCKET_OBJECTS_JSON'))
source_secrets_raw = load_json_list(env('MP_SOURCE_SECRETS_RAW'))
target_secrets_raw = load_json_list(env('MP_TARGET_SECRETS_RAW'))
source_secrets_list = load_text_list(env('MP_SOURCE_SECRETS_LIST'))
target_secrets_list = load_text_list(env('MP_TARGET_SECRETS_LIST'))
source_function_names = set(load_text_list(env('MP_SOURCE_FUNCTION_LIST')))
target_function_names = set(load_text_list(env('MP_TARGET_FUNCTION_LIST')))

edge_source_dir = env('MP_EDGE_SOURCE_DIR')
edge_target_dir = env('MP_EDGE_TARGET_DIR')

source_columns_map = build_columns_map(source_columns)
target_columns_map = build_columns_map(target_columns)
source_index_map = build_index_map(source_indexes)
target_index_map = build_index_map(target_indexes)
source_trigger_map = build_trigger_map(source_triggers)
target_trigger_map = build_trigger_map(target_triggers)
source_policy_map = build_policy_map(source_policies)
target_policy_map = build_policy_map(target_policies)
source_function_map = build_function_map(source_functions)
target_function_map = build_function_map(target_functions)
source_view_map = build_view_map(source_views)
target_view_map = build_view_map(target_views)
source_rowcount_map = build_rowcount_map(source_rowcounts)
target_rowcount_map = build_rowcount_map(target_rowcounts)
source_bucket_map = build_bucket_map(source_buckets)
target_bucket_map = build_bucket_map(target_buckets)
source_bucket_objects_map = build_bucket_objects(source_bucket_objects)
target_bucket_objects_map = build_bucket_objects(target_bucket_objects)

table_diffs = {}

def ensure_table_entry(table_name):
    entry = table_diffs.setdefault(table_name, {
        'status': 'unchanged',
        'add_columns': [],
        'remove_columns': [],
        'modify_columns': [],
        'index_add': [],
        'index_remove': [],
        'trigger_add': [],
        'trigger_remove': [],
        'trigger_modify': [],
        'row_count': None,
        'notes': []
    })
    return entry

actions = []
actions_seen = set()

all_tables = sorted(set(source_columns_map.keys()) | set(target_columns_map.keys()))

for table in all_tables:
    source_cols = source_columns_map.get(table)
    target_cols = target_columns_map.get(table)
    entry = ensure_table_entry(table)

    if source_cols and not target_cols:
        entry['status'] = 'new'
        entry['add_columns'] = list(source_cols.values())
        action = f"Create table {table} in {target_env} with {len(source_cols)} column(s)"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
        continue
    if target_cols and not source_cols:
        entry['status'] = 'removed'
        entry['remove_columns'] = list(target_cols.values())
        action = f"Review table {table} in {target_env}; not present in {source_env}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
        continue
    if not source_cols or not target_cols:
        continue

    for column, scol in source_cols.items():
        tcol = target_cols.get(column)
        if not tcol:
            entry['add_columns'].append(scol)
            action = f"Add column {table}.{column} ({describe_column(scol)}) to match {source_env}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)
            continue
        changes = []
        for field, label in [
            ('data_type', 'type'),
            ('character_maximum_length', 'length'),
            ('numeric_precision', 'precision'),
            ('numeric_scale', 'scale'),
            ('is_nullable', 'nullability'),
            ('column_default', 'default'),
            ('is_identity', 'identity'),
            ('identity_generation', 'identity generation'),
            ('generation_expression', 'generation expression')
        ]:
            sval = (scol.get(field) or '').strip() if isinstance(scol.get(field), str) else scol.get(field)
            tval = (tcol.get(field) or '').strip() if isinstance(tcol.get(field), str) else tcol.get(field)
            if sval != tval:
                changes.append(f"{label}: {tval or 'NULL'} → {sval or 'NULL'}")
        if changes:
            entry['modify_columns'].append({'column': column, 'source': scol, 'target': tcol, 'changes': changes})
            action = f"Alter column {table}.{column} ({'; '.join(changes)})"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

    for column, tcol in target_cols.items():
        if column not in source_cols:
            entry['remove_columns'].append(tcol)
            action = f"Consider removing column {table}.{column} from {target_env} (absent in {source_env})"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

    source_indexes_for_table = source_index_map.get(table, {})
    target_indexes_for_table = target_index_map.get(table, {})
    for idx, idef in source_indexes_for_table.items():
        tdef = target_indexes_for_table.get(idx)
        if not tdef:
            entry['index_add'].append({'name': idx, 'definition': idef})
            action = f"Create index {idx} on {table}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)
        elif tdef.strip() != idef.strip():
            entry['index_remove'].append({'name': idx, 'definition': tdef})
            entry['index_add'].append({'name': idx, 'definition': idef, 'reason': 'definition differs'})
            action = f"Recreate index {idx} on {table} to match definition in {source_env}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)
    for idx, tdef in target_indexes_for_table.items():
        if idx not in source_indexes_for_table:
            entry['index_remove'].append({'name': idx, 'definition': tdef})
            action = f"Consider dropping index {idx} on {table} (not in {source_env})"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

    source_triggers_for_table = source_trigger_map.get(table, {})
    target_triggers_for_table = target_trigger_map.get(table, {})
    for trig, tdef in source_triggers_for_table.items():
        other = target_triggers_for_table.get(trig)
        if other is None:
            entry['trigger_add'].append({'name': trig, 'definition': tdef})
            action = f"Create trigger {trig} on {table}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)
        elif (other or '').strip() != (tdef or '').strip():
            entry['trigger_modify'].append({'name': trig, 'source': tdef, 'target': other})
            action = f"Alter trigger {trig} on {table}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)
    for trig, tdef in target_triggers_for_table.items():
        if trig not in source_triggers_for_table:
            entry['trigger_remove'].append({'name': trig, 'definition': tdef})
            action = f"Review trigger {trig} on {table} (not in {source_env})"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

    source_count = source_rowcount_map.get(table)
    target_count = target_rowcount_map.get(table)
    if source_count is not None or target_count is not None:
        diff = (source_count or 0) - (target_count or 0)
        if diff != 0:
            entry['row_count'] = {'source': source_count or 0, 'target': target_count or 0, 'diff': diff}

policy_diffs = []
for key in sorted(set(source_policy_map.keys()) | set(target_policy_map.keys())):
    source_policy = source_policy_map.get(key)
    target_policy = target_policy_map.get(key)
    if source_policy and not target_policy:
        policy_diffs.append({'type': 'add', 'policy': source_policy})
        action = f"Create RLS policy {key}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif target_policy and not source_policy:
        policy_diffs.append({'type': 'remove', 'policy': target_policy})
        action = f"Review/removal RLS policy {key} in {target_env}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif source_policy and target_policy:
        comparison_fields = ['permissive', 'roles', 'cmd', 'qual', 'with_check']
        changes = []
        for field in comparison_fields:
            sval = source_policy.get(field)
            tval = target_policy.get(field)
            if sval != tval:
                changes.append(f"{field}: {tval or 'NULL'} → {sval or 'NULL'}")
        if changes:
            policy_diffs.append({'type': 'modify', 'policy': source_policy, 'changes': changes})
            action = f"Alter RLS policy {key}: {'; '.join(changes)}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

function_diffs = []
for key in sorted(set(source_function_map.keys()) | set(target_function_map.keys())):
    src = source_function_map.get(key)
    tgt = target_function_map.get(key)
    if src and not tgt:
        function_diffs.append({'type': 'add', 'function': src})
        action = f"Create database function {key}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif tgt and not src:
        function_diffs.append({'type': 'remove', 'function': tgt})
        action = f"Review database function {key} in {target_env}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif src and tgt:
        src_def = (src.get('definition') or '').strip()
        tgt_def = (tgt.get('definition') or '').strip()
        if src_def != tgt_def:
            diff_lines = list(difflib.unified_diff(
                (tgt_def + '\n').splitlines(),
                (src_def + '\n').splitlines(),
                fromfile=f"{target_env}:{key}",
                tofile=f"{source_env}:{key}",
                lineterm=''
            ))
            function_diffs.append({'type': 'modify', 'function': src, 'diff': diff_lines})
            action = f"Update database function {key}"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

view_diffs = []
for key in sorted(set(source_view_map.keys()) | set(target_view_map.keys())):
    src = source_view_map.get(key)
    tgt = target_view_map.get(key)
    if src and not tgt:
        view_diffs.append({'type': 'add', 'view': src})
        action = f"Create view {key}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif tgt and not src:
        view_diffs.append({'type': 'remove', 'view': tgt})
        action = f"Review view {key} in {target_env}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif src and tgt:
        src_def = (src.get('view_definition') or '').strip()
        tgt_def = (tgt.get('view_definition') or '').strip()
        if src_def != tgt_def:
            diff_lines = list(difflib.unified_diff(
                (tgt_def + '\n').splitlines(),
                (src_def + '\n').splitlines(),
                fromfile=f"{target_env}:{key}",
                tofile=f"{source_env}:{key}",
                lineterm=''
            ))
            view_diffs.append({'type': 'modify', 'view': src, 'diff': diff_lines})
            action = f"Update view {key} definition"
            if action not in actions_seen:
                actions.append(action)
                actions_seen.add(action)

bucket_diffs = []
for bucket in sorted(set(source_bucket_map.keys()) | set(target_bucket_map.keys())):
    src_meta = source_bucket_map.get(bucket)
    tgt_meta = target_bucket_map.get(bucket)
    entry = {'bucket': bucket, 'type': None, 'metadata_changes': [], 'missing_files': [], 'new_files': [], 'changed_files': []}
    if src_meta and not tgt_meta:
        entry['type'] = 'add'
        bucket_diffs.append(entry)
        action = f"Create storage bucket '{bucket}'"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    elif tgt_meta and not src_meta:
        entry['type'] = 'remove'
        bucket_diffs.append(entry)
        action = f"Review storage bucket '{bucket}' in {target_env} (not in {source_env})"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
    else:
        meta_fields = ['public', 'file_size_limit', 'allowed_mime_types']
        for field in meta_fields:
            sval = src_meta.get(field)
            tval = tgt_meta.get(field)
            if sval != tval:
                entry['metadata_changes'].append({'field': field, 'source': sval, 'target': tval})
        src_files = source_bucket_objects_map.get(bucket, {})
        tgt_files = target_bucket_objects_map.get(bucket, {})
        src_names = set(src_files.keys())
        tgt_names = set(tgt_files.keys())
        new_files = sorted(src_names - tgt_names)
        missing_files = sorted(tgt_names - src_names)
        changed_files = []
        for name in sorted(src_names & tgt_names):
            src_obj = src_files.get(name) or {}
            tgt_obj = tgt_files.get(name) or {}
            src_size = parse_int(src_obj.get('size_bytes'))
            tgt_size = parse_int(tgt_obj.get('size_bytes'))
            if src_size != tgt_size:
                changed_files.append({'name': name, 'source_size': src_size, 'target_size': tgt_size})
        entry['new_files'] = new_files
        entry['missing_files'] = missing_files
        entry['changed_files'] = changed_files
        if entry['metadata_changes'] or new_files or missing_files or changed_files:
            entry['type'] = 'modify'
            bucket_diffs.append(entry)
            if entry['metadata_changes']:
                action = f"Update bucket '{bucket}' configuration"
                if action not in actions_seen:
                    actions.append(action)
                    actions_seen.add(action)
            if new_files:
                action = f"Upload {len(new_files)} file(s) to bucket '{bucket}'"
                if action not in actions_seen:
                    actions.append(action)
                    actions_seen.add(action)
            if missing_files:
                action = f"Remove or archive {len(missing_files)} obsolete file(s) from bucket '{bucket}'"
                if action not in actions_seen:
                    actions.append(action)
                    actions_seen.add(action)
            if changed_files:
                action = f"Update {len(changed_files)} changed file(s) in bucket '{bucket}'"
                if action not in actions_seen:
                    actions.append(action)
                    actions_seen.add(action)

edge_diffs = []

source_edge_files = {}
target_edge_files = {}
edge_source_path = Path(edge_source_dir) if edge_source_dir else None
edge_target_path = Path(edge_target_dir) if edge_target_dir else None

if edge_source_path and edge_source_path.exists():
    for child in edge_source_path.iterdir():
        if child.is_dir():
            source_edge_files[child.name] = load_function_files(child)
if edge_target_path and edge_target_path.exists():
    for child in edge_target_path.iterdir():
        if child.is_dir():
            target_edge_files[child.name] = load_function_files(child)

edge_function_names = sorted(set(source_function_names) | set(target_function_names) | set(source_edge_files.keys()) | set(target_edge_files.keys()))

for func in edge_function_names:
    src_has = func in source_function_names or func in source_edge_files
    tgt_has = func in target_function_names or func in target_edge_files
    entry = {'function': func, 'type': None, 'diff': []}
    if src_has and not tgt_has:
        entry['type'] = 'add'
        edge_diffs.append(entry)
        action = f"Deploy edge function '{func}' to {target_env}"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
        continue
    if tgt_has and not src_has:
        entry['type'] = 'remove'
        edge_diffs.append(entry)
        action = f"Review edge function '{func}' in {target_env} (not in {source_env})"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)
        continue
    src_files = source_edge_files.get(func, {})
    tgt_files = target_edge_files.get(func, {})
    if not src_files and not tgt_files:
        continue
    diff_lines = []
    for path in sorted(set(src_files.keys()) | set(tgt_files.keys())):
        s = src_files.get(path, '')
        t = tgt_files.get(path, '')
        if s != t:
            diff_lines.extend(difflib.unified_diff(
                (t + '\n').splitlines(),
                (s + '\n').splitlines(),
                fromfile=f"{target_env}:{func}/{path}",
                tofile=f"{source_env}:{func}/{path}",
                lineterm=''
            ))
    if diff_lines:
        entry['type'] = 'modify'
        entry['diff'] = diff_lines
        edge_diffs.append(entry)
        action = f"Redeploy edge function '{func}'"
        if action not in actions_seen:
            actions.append(action)
            actions_seen.add(action)

source_secret_names = {item.get('name') for item in source_secrets_raw if isinstance(item, dict) and item.get('name')}
target_secret_names = {item.get('name') for item in target_secrets_raw if isinstance(item, dict) and item.get('name')}
if source_secrets_list:
    source_secret_names.update(source_secrets_list)
if target_secrets_list:
    target_secret_names.update(target_secrets_list)

secret_add = sorted(source_secret_names - target_secret_names)
secret_remove = sorted(target_secret_names - source_secret_names)

if secret_add:
    action = f"Create {len(secret_add)} new secret key(s)"
    if action not in actions_seen:
        actions.append(action)
        actions_seen.add(action)
if secret_remove:
    action = f"Review {len(secret_remove)} secret key(s) present only in {target_env}"
    if action not in actions_seen:
        actions.append(action)
        actions_seen.add(action)

actions_sorted = actions

summary = {
    'tables_new': sum(1 for entry in table_diffs.values() if entry['status'] == 'new'),
    'tables_removed': sum(1 for entry in table_diffs.values() if entry['status'] == 'removed'),
    'tables_modified': sum(1 for entry in table_diffs.values() if entry['status'] == 'unchanged' and (entry['add_columns'] or entry['remove_columns'] or entry['modify_columns'] or entry['index_add'] or entry['index_remove'] or entry['trigger_add'] or entry['trigger_remove'] or entry['trigger_modify'])),
    'cols_added': sum(len(entry['add_columns']) for entry in table_diffs.values()),
    'cols_removed': sum(len(entry['remove_columns']) for entry in table_diffs.values()),
    'cols_modified': sum(len(entry['modify_columns']) for entry in table_diffs.values()),
    'policies_add': sum(1 for diff in policy_diffs if diff['type'] == 'add'),
    'policies_remove': sum(1 for diff in policy_diffs if diff['type'] == 'remove'),
    'policies_modify': sum(1 for diff in policy_diffs if diff['type'] == 'modify'),
    'functions_add': sum(1 for diff in function_diffs if diff['type'] == 'add'),
    'functions_remove': sum(1 for diff in function_diffs if diff['type'] == 'remove'),
    'functions_modify': sum(1 for diff in function_diffs if diff['type'] == 'modify'),
    'views_add': sum(1 for diff in view_diffs if diff['type'] == 'add'),
    'views_remove': sum(1 for diff in view_diffs if diff['type'] == 'remove'),
    'views_modify': sum(1 for diff in view_diffs if diff['type'] == 'modify'),
    'buckets_changed': len(bucket_diffs),
    'edge_add': sum(1 for diff in edge_diffs if diff['type'] == 'add'),
    'edge_remove': sum(1 for diff in edge_diffs if diff['type'] == 'remove'),
    'edge_modify': sum(1 for diff in edge_diffs if diff['type'] == 'modify'),
    'secrets_add': len(secret_add),
    'secrets_remove': len(secret_remove),
    'actions': len(actions_sorted)
}

timestamp_utc = datetime.now(timezone.utc)
timestamp_display = timestamp_utc.strftime('%Y-%m-%d %H:%M:%S UTC')

css = """
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    background: #f1f5f9;
    color: #0f172a;
    line-height: 1.6;
    padding: 32px;
}
.page-wrapper {
    max-width: 1200px;
    margin: 0 auto;
}
.hero {
    background: linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%);
    color: white;
    padding: 48px;
    border-radius: 24px;
    box-shadow: 0 24px 60px rgba(15, 23, 42, 0.18);
    margin-bottom: 36px;
}
.hero h1 {
    font-size: 2.6rem;
    margin-bottom: 12px;
    letter-spacing: -0.5px;
}
.hero p {
    font-size: 1.1rem;
    opacity: 0.92;
}
.hero-meta {
    margin-top: 18px;
    font-size: 0.95rem;
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
}
.env-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    border-radius: 999px;
    font-weight: 600;
    background: rgba(255, 255, 255, 0.18);
    border: 1px solid rgba(255, 255, 255, 0.25);
}
.env-chip span {
    opacity: 0.85;
    font-weight: 500;
}
.section-block {
    background: white;
    border-radius: 24px;
    border: 1px solid rgba(99, 102, 241, 0.16);
    box-shadow: 0 24px 48px rgba(15, 23, 42, 0.12);
    padding: 32px 36px;
    margin-bottom: 32px;
}
.section-block h2 {
    font-size: 1.7rem;
    margin-bottom: 20px;
    color: #312e81;
}
.summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px;
}
.summary-card {
    border-radius: 16px;
    border: 1px solid rgba(99, 102, 241, 0.18);
    padding: 20px;
    background: linear-gradient(135deg, rgba(79,70,229,0.08) 0%, rgba(124,58,237,0.05) 100%);
    box-shadow: inset 0 1px 0 rgba(255,255,255,0.35);
}
.summary-card h3 {
    font-size: 0.95rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #4338ca;
    margin-bottom: 8px;
}
.summary-card p {
    font-size: 2rem;
    font-weight: 700;
    color: #1e1b4b;
}
.timeline {
    display: grid;
    gap: 12px;
}
.timeline-item {
    position: relative;
    padding-left: 20px;
    color: #1f2937;
}
.timeline-item::before {
    content: '';
    position: absolute;
    left: 6px;
    top: 4px;
    width: 8px;
    height: 8px;
    background: #4f46e5;
    border-radius: 999px;
}
.timeline-item::after {
    content: '';
    position: absolute;
    left: 9px;
    top: 16px;
    bottom: -12px;
    width: 2px;
    background: rgba(79, 70, 229, 0.25);
}
.timeline-item:last-child::after {
    display: none;
}
.data-card {
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 18px;
    padding: 24px;
    margin-bottom: 20px;
    background: linear-gradient(180deg, rgba(248, 250, 252, 0.95) 0%, rgba(241, 245, 249, 0.9) 100%);
}
.data-card h3 {
    font-size: 1.15rem;
    margin-bottom: 12px;
    color: #312e81;
    display: flex;
    align-items: center;
    gap: 10px;
}
.status-new,
.status-review,
.status-update {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
}
.status-new { background: rgba(16, 185, 129, 0.18); color: #047857; }
.status-review { background: rgba(248, 113, 113, 0.18); color: #b91c1c; }
.status-update { background: rgba(255, 186, 8, 0.2); color: #a16207; }
.item-list { margin-left: 18px; margin-top: 8px; }
.item-list li { margin-bottom: 6px; }
.diff-box {
    margin-top: 12px;
    background: #0f172a;
    color: #e2e8f0;
    border-radius: 12px;
    padding: 16px;
    font-family: 'JetBrains Mono', 'Fira Code', monospace;
    font-size: 0.85rem;
    overflow-x: auto;
}
.footer-note {
    margin-top: 32px;
    text-align: right;
    font-size: 0.88rem;
    color: #475569;
}
@media (max-width: 768px) {
    body { padding: 24px; }
    .hero { padding: 32px; }
    .section-block { padding: 26px; }
}
"""

html_parts = [
    "<!DOCTYPE html>",
    "<html lang='en'>",
    "<head>",
    "<meta charset='UTF-8'>",
    "<meta name='viewport' content='width=device-width, initial-scale=1.0'>",
    f"<title>Migration Plan: {html.escape(source_env)} → {html.escape(target_env)}</title>",
    f"<style>{css}</style>",
    "</head>",
    "<body>",
    "<div class='page-wrapper'>"
]

hero_markup = f"""
<section class='hero'>
    <div class='hero-head'>
        <h1>Migration Plan</h1>
        <p>Synchronize <strong>{html.escape(source_env)}</strong> → <strong>{html.escape(target_env)}</strong></p>
            </div>
    <div class='hero-meta'>
        <span>Project refs</span>
        <span class='env-chip'>Source<span>{html.escape(source_ref or 'n/a')}</span></span>
        <span class='env-chip'>Target<span>{html.escape(target_ref or 'n/a')}</span></span>
        <span class='env-chip'>Generated<span>{timestamp_display}</span></span>
        <span class='env-chip'>Actions<span>{summary['actions']}</span></span>
                        </div>
</section>
"""

html_parts.append(hero_markup)

html_parts.append("<section class='section-block'><h2>Executive Summary</h2><div class='summary-grid'>")

summary_items = [
    ("New Tables", summary['tables_new']),
    ("Tables to Review", summary['tables_removed']),
    ("Tables with Updates", summary['tables_modified']),
    ("Columns Added", summary['cols_added']),
    ("Columns Removed", summary['cols_removed']),
    ("Columns Modified", summary['cols_modified']),
    ("RLS Policies (add/update/remove)", f"{summary['policies_add']}/{summary['policies_modify']}/{summary['policies_remove']}") ,
    ("Functions (add/update/remove)", f"{summary['functions_add']}/{summary['functions_modify']}/{summary['functions_remove']}") ,
    ("Views (add/update/remove)", f"{summary['views_add']}/{summary['views_modify']}/{summary['views_remove']}") ,
    ("Buckets to Review", summary['buckets_changed']),
    ("Edge Functions (add/update/remove)", f"{summary['edge_add']}/{summary['edge_modify']}/{summary['edge_remove']}") ,
    ("Secrets (add/remove)", f"{summary['secrets_add']}/{summary['secrets_remove']}") ,
    ("Recommended Actions", summary['actions'])
]

for label, value in summary_items:
    html_parts.append(f"<div class='summary-card'><h3>{html.escape(str(label))}</h3><p>{html.escape(str(value))}</p></div>")

html_parts.append("</div></section>")

html_parts.append("<section class='section-block'><h2>Action Plan</h2>")
if actions_sorted:
    html_parts.append("<div class='timeline'>")
    for action in actions_sorted:
        html_parts.append(f"<div class='timeline-item'>{html.escape(action)}</div>")
    html_parts.append("</div>")
else:
    html_parts.append("<p>✅ Target environment already matches source. No actions required.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Database Schema Details</h2>")
if table_diffs:
    for table in sorted(table_diffs.keys()):
        entry = table_diffs[table]
        status_chip = ""
        if entry['status'] == 'new':
            status_chip = "<span class='status-new'>New</span>"
        elif entry['status'] == 'removed':
            status_chip = "<span class='status-review'>Only in target</span>"
        elif entry['add_columns'] or entry['remove_columns'] or entry['modify_columns']:
            status_chip = "<span class='status-update'>Updates</span>"
        html_parts.append(f"<div class='data-card'><h3>{html.escape(table)} {status_chip}</h3>")
        if entry['status'] == 'new':
            html_parts.append("<p>Table exists only in source.</p><ul class='item-list'>")
            for col in entry['add_columns']:
                html_parts.append(f"<li>{html.escape(col.get('column_name',''))}: {html.escape(describe_column(col))}</li>")
            html_parts.append("</ul>")
        elif entry['status'] == 'removed':
            html_parts.append("<p>Table exists only in target.</p>")
        else:
            if entry['add_columns']:
                html_parts.append("<p><strong>Columns to add:</strong></p><ul class='item-list'>")
                for col in entry['add_columns']:
                    html_parts.append(f"<li>{html.escape(col.get('column_name',''))}: {html.escape(describe_column(col))}</li>")
                html_parts.append("</ul>")
            if entry['remove_columns']:
                html_parts.append("<p><strong>Columns present only in target:</strong></p><ul class='item-list'>")
                for col in entry['remove_columns']:
                    html_parts.append(f"<li>{html.escape(col.get('column_name',''))}</li>")
                html_parts.append("</ul>")
            if entry['modify_columns']:
                html_parts.append("<p><strong>Columns to alter:</strong></p><ul class='item-list'>")
                for mod in entry['modify_columns']:
                    html_parts.append(f"<li>{html.escape(mod['column'])}: {html.escape('; '.join(mod['changes']))}</li>")
                html_parts.append("</ul>")
            if entry['index_add'] or entry['index_remove']:
                if entry['index_add']:
                    html_parts.append("<p><strong>Indexes to create:</strong></p><ul class='item-list'>")
                    for idx in entry['index_add']:
                        html_parts.append(f"<li>{html.escape(idx['name'])}</li>")
                    html_parts.append("</ul>")
                if entry['index_remove']:
                    html_parts.append("<p><strong>Indexes to review/remove:</strong></p><ul class='item-list'>")
                    for idx in entry['index_remove']:
                        html_parts.append(f"<li>{html.escape(idx['name'])}</li>")
                    html_parts.append("</ul>")
            if entry['trigger_add'] or entry['trigger_remove'] or entry['trigger_modify']:
                if entry['trigger_add']:
                    html_parts.append("<p><strong>Triggers to create:</strong></p><ul class='item-list'>")
                    for trig in entry['trigger_add']:
                        html_parts.append(f"<li>{html.escape(trig['name'])}</li>")
                    html_parts.append("</ul>")
                if entry['trigger_remove']:
                    html_parts.append("<p><strong>Triggers to review:</strong></p><ul class='item-list'>")
                    for trig in entry['trigger_remove']:
                        html_parts.append(f"<li>{html.escape(trig['name'])}</li>")
                    html_parts.append("</ul>")
                if entry['trigger_modify']:
                    html_parts.append("<p><strong>Triggers with definition changes:</strong></p><ul class='item-list'>")
                    for trig in entry['trigger_modify']:
                        html_parts.append(f"<li>{html.escape(trig['name'])}</li>")
                    html_parts.append("</ul>")
            if entry['row_count']:
                rc = entry['row_count']
                html_parts.append(f"<p><strong>Data difference:</strong> {rc['source']} rows (source) vs {rc['target']} rows (target) → Δ {rc['diff']}</p>")
        html_parts.append("</div>")
else:
    html_parts.append("<p>Database structures are identical between source and target.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>RLS Policies</h2>")
if policy_diffs:
    for diff in policy_diffs:
        policy = diff['policy']
        title = html.escape(f"{policy.get('schemaname')}.{policy.get('tablename')}.{policy.get('policyname')}")
        if diff['type'] == 'add':
            chip = "<span class='status-new'>Create</span>"
            html_parts.append(f"<div class='data-card'><h3>{title} {chip}</h3><p>Roles: {html.escape(str(policy.get('roles')))} • Command: {html.escape(str(policy.get('cmd')))}</p></div>")
        elif diff['type'] == 'remove':
            chip = "<span class='status-review'>Review</span>"
            html_parts.append(f"<div class='data-card'><h3>{title} {chip}</h3><p>Present only in target. Review necessity.</p></div>")
        else:
            chip = "<span class='status-update'>Alter</span>"
            html_parts.append(f"<div class='data-card'><h3>{title} {chip}</h3><ul class='item-list'>")
            for change in diff.get('changes', []):
                html_parts.append(f"<li>{html.escape(change)}</li>")
            html_parts.append("</ul></div>")
else:
    html_parts.append("<p>No RLS differences.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Database Functions</h2>")
if function_diffs:
    for diff in function_diffs:
        func = diff['function']
        name = html.escape(diff['function'].get('schema','') + '.' + diff['function'].get('name',''))
        if diff['type'] == 'add':
            chip = "<span class='status-new'>Create</span>"
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3></div>")
        elif diff['type'] == 'remove':
            chip = "<span class='status-review'>Review</span>"
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3></div>")
        else:
            chip = "<span class='status-update'>Alter</span>"
            diff_lines = diff.get('diff', [])
            preview = diff_lines[:120]
            text = '\n'.join(preview)
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3><div class='diff-box'>{html.escape(text) if text else 'Definition differs'}</div></div>")
else:
    html_parts.append("<p>No function differences.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Views</h2>")
if view_diffs:
    for diff in view_diffs:
        view = diff['view']
        name = html.escape(diff['view'].get('schema','') + '.' + diff['view'].get('table_name',''))
        if diff['type'] == 'add':
            chip = "<span class='status-new'>Create</span>"
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3></div>")
        elif diff['type'] == 'remove':
            chip = "<span class='status-review'>Review</span>"
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3></div>")
        else:
            chip = "<span class='status-update'>Alter</span>"
            diff_lines = diff.get('diff', [])
            preview = diff_lines[:120]
            text = '\n'.join(preview)
            html_parts.append(f"<div class='data-card'><h3>{name} {chip}</h3><div class='diff-box'>{html.escape(text) if text else 'Definition differs'}</div></div>")
else:
    html_parts.append("<p>No view differences.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Storage Buckets</h2>")
if bucket_diffs:
    for diff in bucket_diffs:
        bucket = html.escape(diff['bucket'])
        if diff['type'] == 'add':
            chip = "<span class='status-new'>Create</span>"
            html_parts.append(f"<div class='data-card'><h3>{bucket} {chip}</h3><p>Bucket exists only in source.</p></div>")
        elif diff['type'] == 'remove':
            chip = "<span class='status-review'>Review</span>"
            html_parts.append(f"<div class='data-card'><h3>{bucket} {chip}</h3><p>Bucket exists only in target.</p></div>")
        else:
            chip = "<span class='status-update'>Update</span>"
            html_parts.append(f"<div class='data-card'><h3>{bucket} {chip}</h3>")
            if diff['metadata_changes']:
                html_parts.append("<p><strong>Metadata changes:</strong></p><ul class='item-list'>")
                for change in diff['metadata_changes']:
                    html_parts.append(f"<li>{html.escape(change['field'])}: {html.escape(str(change['target']))} → {html.escape(str(change['source']))}</li>")
                html_parts.append("</ul>")
            if diff['new_files']:
                html_parts.append(f"<p><strong>Files to upload ({len(diff['new_files'])}):</strong></p><ul class='item-list'>")
                for name in diff['new_files'][:10]:
                    html_parts.append(f"<li>{html.escape(name)}</li>")
                if len(diff['new_files']) > 10:
                    html_parts.append(f"<li>… {len(diff['new_files']) - 10} more</li>")
                html_parts.append("</ul>")
            if diff['missing_files']:
                html_parts.append(f"<p><strong>Files only in target ({len(diff['missing_files'])}):</strong></p><ul class='item-list'>")
                for name in diff['missing_files'][:10]:
                    html_parts.append(f"<li>{html.escape(name)}</li>")
                if len(diff['missing_files']) > 10:
                    html_parts.append(f"<li>… {len(diff['missing_files']) - 10} more</li>")
                html_parts.append("</ul>")
            if diff['changed_files']:
                html_parts.append(f"<p><strong>Files with size differences ({len(diff['changed_files'])}):</strong></p><ul class='item-list'>")
                for item in diff['changed_files'][:10]:
                    html_parts.append(f"<li>{html.escape(item['name'])}: {item['target_size']} → {item['source_size']} bytes</li>")
                if len(diff['changed_files']) > 10:
                    html_parts.append(f"<li>… {len(diff['changed_files']) - 10} more</li>")
                html_parts.append("</ul>")
            html_parts.append("</div>")
else:
    html_parts.append("<p>No storage differences.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Edge Functions</h2>")
if edge_diffs:
    for diff in edge_diffs:
        func = html.escape(diff['function'])
        if diff['type'] == 'add':
            chip = "<span class='status-new'>Deploy</span>"
            html_parts.append(f"<div class='data-card'><h3>{func} {chip}</h3></div>")
        elif diff['type'] == 'remove':
            chip = "<span class='status-review'>Review</span>"
            html_parts.append(f"<div class='data-card'><h3>{func} {chip}</h3></div>")
        else:
            chip = "<span class='status-update'>Update</span>"
            diff_lines = diff.get('diff', [])
            preview = diff_lines[:200]
            text = '\n'.join(preview)
            if not text:
                text = 'Code differs between environments.'
            html_parts.append(f"<div class='data-card'><h3>{func} {chip}</h3><div class='diff-box'>{html.escape(text)}</div></div>")
else:
    html_parts.append("<p>No edge function differences detected or code comparison unavailable.</p>")
html_parts.append("</section>")

html_parts.append("<section class='section-block'><h2>Secrets</h2>")
if secret_add or secret_remove:
    if secret_add:
        html_parts.append("<p><strong>Secrets to add:</strong></p><ul class='item-list'>")
        for name in secret_add:
            html_parts.append(f"<li>{html.escape(name)}</li>")
        html_parts.append("</ul>")
    if secret_remove:
        html_parts.append("<p><strong>Secrets only in target:</strong></p><ul class='item-list'>")
        for name in secret_remove:
            html_parts.append(f"<li>{html.escape(name)}</li>")
        html_parts.append("</ul>")
else:
    html_parts.append("<p>No secret key differences.</p>")
html_parts.append("</section>")

html_parts.append(f"<div class='footer-note'>Report generated on {timestamp_display}</div>")
html_parts.append("</div></body></html>")

planner_data = {
    'source_env': source_env,
    'target_env': target_env,
    'source_ref': source_ref,
    'target_ref': target_ref,
    'generated_at': timestamp_utc.isoformat(),
    'summary': summary,
    'database': {
        'tables': table_diffs,
        'policies': policy_diffs,
        'functions': function_diffs,
        'views': view_diffs,
    },
    'storage': bucket_diffs,
    'edge_functions': edge_diffs,
    'secrets': {
        'to_create': secret_add,
        'only_in_target': secret_remove
    },
    'actions': actions_sorted
}

Path(html_file).write_text('\n'.join(html_parts), encoding='utf-8')

if diff_json_file:
    Path(diff_json_file).write_text(json.dumps(planner_data, indent=2, ensure_ascii=False), encoding='utf-8')

print(f"[INFO] Detailed planner created with {summary['actions']} recommended action(s)")
PY

if [ $? -ne 0 ]; then
    log_error "Failed to generate migration plan report"
    exit 1
fi

log_success "Migration plan generated successfully!"
log_info ""
log_info "📄 Report saved to: $HTML_FILE"
log_info "📦 Diff JSON saved to: $DIFF_JSON_FILE"
log_info ""
log_info "You can open it in your browser:"
log_info "  open $HTML_FILE"

exit 0

