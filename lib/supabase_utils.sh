#!/bin/bash
# Supabase Utilities Library
# Common functions for Supabase project duplication

# Colors for output (only define if not already set, e.g., by logger.sh)
if [ -z "${RED:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Load environment variables
load_env() {
    if [ ! -f .env.local ]; then
        log_error ".env.local file not found!"
        return 1
    fi
    
    # Safely source .env.local using a more robust method
    # This prevents errors from malformed lines or commands
    local temp_error=0
    set +u  # Temporarily disable unbound variable checking for sourcing
    set +e  # Temporarily disable exit on error for sourcing
    
    # Use source with error redirection to catch any issues
    if ! source .env.local 2>/dev/null; then
        # If direct sourcing fails, try parsing line by line
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            # Only process lines that look like variable assignments (VAR=value format)
            if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                local var_name="${BASH_REMATCH[1]}"
                local var_value="${BASH_REMATCH[2]}"
                # Remove quotes if present
                var_value="${var_value#\"}"
                var_value="${var_value%\"}"
                var_value="${var_value#\'}"
                var_value="${var_value%\'}"
                # Export the variable
                export "$var_name"="$var_value" 2>/dev/null || true
            fi
        done < .env.local
    fi
    
    set -e  # Re-enable exit on error
    set -u  # Re-enable unbound variable checking
    
    if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        log_error "SUPABASE_ACCESS_TOKEN not set in .env.local"
        return 1
    fi
    
    export SUPABASE_ACCESS_TOKEN
    return 0
}

# Normalize environment aliases to uppercase keys (PROD, TEST, DEV, BACKUP)
normalize_env_key() {
    local env="${1:-}"
    if [ -z "$env" ]; then
        echo ""
        return 0
    fi
    env=$(echo "$env" | tr '[:upper:]' '[:lower:]')
    case "$env" in
        prod|production|main)
            echo "PROD"
            ;;
        test|staging)
            echo "TEST"
            ;;
        dev|develop)
            echo "DEV"
            ;;
        backup|bkup|bkp)
            echo "BACKUP"
            ;;
        *)
            echo ""
            ;;
    esac
    return 0
}

# Get the friendly project name for a given environment (returns empty string if unset)
get_env_project_name() {
    local env="${1:-}"
    local key
    key=$(normalize_env_key "$env")
    if [ -z "$key" ]; then
        echo ""
        return 0
    fi
    local primary_var="SUPABASE_${key}_PROJECT_NAME"
    local legacy_var="SUPABSE_${key}_PROJECT_NAME"
    local value="${!primary_var:-${!legacy_var:-}}"
    echo "$value"
    return 0
}

# Get the project reference for a given environment (returns empty string if unset)
get_env_project_ref() {
    local env="${1:-}"
    local key
    key=$(normalize_env_key "$env")
    if [ -z "$key" ]; then
        echo ""
        return 0
    fi
    local primary_var="SUPABASE_${key}_PROJECT_REF"
    local legacy_var="SUPABSE_${key}_PROJECT_REF"
    local value="${!primary_var:-${!legacy_var:-}}"
    echo "$value"
    return 0
}

# Get the Supabase app name (supports legacy misspelling)
get_supabase_app_name() {
    local app_name="${SUPABSE_APP_NAME:-${SUPABASE_APP_NAME:-}}"
    echo "$app_name"
    return 0
}

# Log contextual information about the script, app, and related environments
log_script_context() {
    local script_label="${1:-unknown-script}"
    shift || true

    # Prevent duplicate logging for the same script during a single run
    local logged_list="${SCRIPT_CONTEXT_LOGGED_LIST:-}"
    if [[ ":${logged_list}:" == *":${script_label}:"* ]]; then
        return 0
    fi
    if [ -z "$logged_list" ]; then
        SCRIPT_CONTEXT_LOGGED_LIST="$script_label"
    else
        SCRIPT_CONTEXT_LOGGED_LIST="${logged_list}:${script_label}"
    fi

    local app_name
    app_name=$(get_supabase_app_name)

    if [ -n "$app_name" ]; then
        log_info "Context :: ${script_label} | App: ${app_name}"
    else
        log_info "Context :: ${script_label} | App: (set SUPABSE_APP_NAME)"
    fi

    local processed=":"
    while [ $# -gt 0 ]; do
        local env="$1"
        shift || true
        [ -z "$env" ] && continue
        local env_key
        env_key=$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')
        if [[ "$processed" == *":$env_key:"* ]]; then
            continue
        fi
        processed="${processed}${env_key}:"

        local key_upper
        key_upper=$(normalize_env_key "$env")
        local project_name
        project_name=$(get_env_project_name "$env")
        local project_ref
        project_ref=$(get_env_project_ref "$env")

        if [ -n "$project_name" ] || [ -n "$project_ref" ]; then
            if [ -n "$project_name" ] && [ -n "$project_ref" ]; then
                log_info "  Env ${env}: ${project_name} (ref: ${project_ref})"
            elif [ -n "$project_name" ]; then
                log_info "  Env ${env}: ${project_name} (ref: not set)"
            else
                log_info "  Env ${env}: (name not set) (ref: ${project_ref})"
            fi
        else
            if [ -n "$key_upper" ]; then
                log_warning "  Env ${env}: project metadata missing (set SUPABASE_${key_upper}_PROJECT_NAME / _PROJECT_REF)"
            else
                log_warning "  Env ${env}: project metadata missing (unrecognized environment alias)"
            fi
        fi
    done

    return 0
}

# Get project reference by name
get_project_ref() {
    local env_name=$1
    local env_lc
    env_lc=$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')
    case $env_lc in
        prod|production|main)
            echo "$SUPABASE_PROD_PROJECT_REF"
            ;;
        test|staging)
            echo "$SUPABASE_TEST_PROJECT_REF"
            ;;
        dev|develop)
            echo "$SUPABASE_DEV_PROJECT_REF"
            ;;
        backup|bkup|bkp)
            echo "$SUPABASE_BACKUP_PROJECT_REF"
            ;;
        *)
            log_error "Unknown environment: $env_name"
            log_info "Valid environments: prod, test, dev, backup"
            exit 1
            ;;
    esac
}

# Get database password by environment name
get_db_password() {
    local env_name=$1
    local env_lc
    env_lc=$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')
    case $env_lc in
        prod|production|main)
            echo "$SUPABASE_PROD_DB_PASSWORD"
            ;;
        test|staging)
            echo "$SUPABASE_TEST_DB_PASSWORD"
            ;;
        dev|develop)
            echo "$SUPABASE_DEV_DB_PASSWORD"
            ;;
        backup|bkup|bkp)
            echo "$SUPABASE_BACKUP_DB_PASSWORD"
            ;;
        *)
            log_error "Unknown environment: $env_name"
            exit 1
            ;;
    esac
}

# Get pooler hostname for a specific environment
# This is the preferred method - uses POOLER_REGION directly from env vars
# Format: {POOLER_REGION}.pooler.supabase.com
get_pooler_host_for_env() {
    local env_name=$1
    local env_lc
    env_lc=$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')
    
    # Normalize environment name
    case $env_lc in
        prod|production|main)
            env_name="PROD"
            ;;
        test|staging)
            env_name="TEST"
            ;;
        dev|develop)
            env_name="DEV"
            ;;
        backup|bkup|bkp)
            env_name="BACKUP"
            ;;
        *)
            # If it's not a recognized env name, return empty
            return 1
            ;;
    esac
    
    # Get pooler region from environment variable
    local pooler_region_var="SUPABASE_${env_name}_POOLER_REGION"
    local pooler_region="${!pooler_region_var:-}"
    
    # If pooler region is set, construct and return the hostname
    if [ -n "$pooler_region" ]; then
        echo "${pooler_region}.pooler.supabase.com"
        return 0
    fi
    
    # Fallback: return empty (caller should handle)
    return 1
}

# Get pooler hostname (tries common regions, can be overridden)
# This function supports both project_ref and env_name for backward compatibility
get_pooler_host() {
    local project_ref_or_env=$1
    
    # First, try using environment name if it's passed
    if get_pooler_host_for_env "$project_ref_or_env" 2>/dev/null; then
        return 0
    fi
    
    # Try to determine from project ref by checking environment-specific pooler region
    # This is the most reliable method if configured in .env.local
    if [ "$project_ref_or_env" = "$SUPABASE_PROD_PROJECT_REF" ] && [ -n "${SUPABASE_PROD_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_PROD_POOLER_REGION}.pooler.supabase.com"
        return 0
    elif [ "$project_ref_or_env" = "$SUPABASE_TEST_PROJECT_REF" ] && [ -n "${SUPABASE_TEST_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_TEST_POOLER_REGION}.pooler.supabase.com"
        return 0
    elif [ "$project_ref_or_env" = "$SUPABASE_DEV_PROJECT_REF" ] && [ -n "${SUPABASE_DEV_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_DEV_POOLER_REGION}.pooler.supabase.com"
        return 0
    elif [ "$project_ref_or_env" = "$SUPABASE_BACKUP_PROJECT_REF" ] && [ -n "${SUPABASE_BACKUP_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_BACKUP_POOLER_REGION}.pooler.supabase.com"
        return 0
    fi
    
    # Try to get pooler URL from Supabase API if available (only if it looks like a project_ref)
    if [ -n "$SUPABASE_ACCESS_TOKEN" ] && [ ${#project_ref_or_env} -eq 20 ]; then
        local api_response=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${project_ref_or_env}/config/database/pooler" 2>/dev/null)
        
        # Try multiple JSON parsing methods to extract pooler_url
        local pooler_url=""
        if command -v jq >/dev/null 2>&1; then
            pooler_url=$(echo "$api_response" | jq -r '.pooler_url // .connectionString // empty' 2>/dev/null)
        fi
        
        # Fallback to grep if jq not available
        if [ -z "$pooler_url" ] || [ "$pooler_url" = "null" ]; then
            pooler_url=$(echo "$api_response" | grep -o '"pooler_url":"[^"]*"' | cut -d'"' -f4 || echo "")
        fi
        
        if [ -n "$pooler_url" ] && [ "$pooler_url" != "null" ] && [ "$pooler_url" != "" ]; then
            # Extract hostname from URL (e.g., aws-1-us-east-2.pooler.supabase.com)
            local hostname=$(echo "$pooler_url" | sed -E 's|.*://([^:]+)(:[0-9]+)?(/.*)?|\1|' | sed 's|/$||')
            if [ -n "$hostname" ] && [ "$hostname" != "" ]; then
                echo "$hostname"
                return 0
            fi
        fi
    fi
    
    # Default to common pooler hostname (can be overridden via env var)
    echo "${SUPABASE_POOLER_HOST:-aws-1-us-east-2.pooler.supabase.com}"
}

# Retrieve pooler region for an environment (falls back to default shared region)
get_pooler_region_for_env() {
    local env_name=$1
    local env_lc
    env_lc=$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')
    case $env_lc in
        prod|production|main)
            echo "${SUPABASE_PROD_POOLER_REGION:-aws-1-us-east-2}"
            ;;
        test|staging)
            echo "${SUPABASE_TEST_POOLER_REGION:-aws-1-us-east-2}"
            ;;
        dev|develop)
            echo "${SUPABASE_DEV_POOLER_REGION:-aws-1-us-east-2}"
            ;;
        backup|bkup|bkp)
            echo "${SUPABASE_BACKUP_POOLER_REGION:-aws-1-us-east-2}"
            ;;
        *)
            echo "aws-1-us-east-2"
            ;;
    esac
}

# Retrieve pooler port for an environment (defaults to 6543)
get_pooler_port_for_env() {
    local env_name=$1
    local env_lc
    env_lc=$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')
    case $env_lc in
        prod|production|main)
            echo "${SUPABASE_PROD_POOLER_PORT:-6543}"
            ;;
        test|staging)
            echo "${SUPABASE_TEST_POOLER_PORT:-6543}"
            ;;
        dev|develop)
            echo "${SUPABASE_DEV_POOLER_PORT:-6543}"
            ;;
        backup|bkup|bkp)
            echo "${SUPABASE_BACKUP_POOLER_PORT:-6543}"
            ;;
        *)
            echo "6543"
            ;;
    esac
}

# Enumerate connection endpoints (host|port|label) to try for a project
get_supabase_connection_endpoints() {
    local project_ref=$1
    local pooler_region=${2:-aws-1-us-east-2}
    local pooler_port=${3:-6543}

    local shared_pooler_host="${pooler_region}.pooler.supabase.com"
    local dedicated_pooler_host="db.${project_ref}.supabase.co"

    echo "${shared_pooler_host}|${pooler_port}|postgres.${project_ref}|shared_pooler_${pooler_port}"
    echo "${shared_pooler_host}|5432|postgres.${project_ref}|shared_pooler_5432"
    echo "${dedicated_pooler_host}|${pooler_port}|postgres|dedicated_pooler_${pooler_port}"
    echo "${dedicated_pooler_host}|5432|postgres|dedicated_pooler_5432"
}

# Run a PostgreSQL tool (pg_dump, pg_restore, etc.) with fallback connections
run_pg_tool_with_fallback() {
    local tool=$1
    local project_ref=$2
    local password=$3
    local pooler_region=$4
    local pooler_port=$5
    local log_file=$6
    shift 6
    local tool_args=("$@")

    local success=1
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if [ "$tool" = "psql" ]; then
            log_error "run_pg_tool_with_fallback does not support psql; use run_psql_with_fallback instead"
            return 1
        fi

        log_info "Trying ${tool} via ${label} (${host}:${port})"

        local status
        if [ -n "$log_file" ]; then
            PGPASSWORD="$password" PGSSLMODE=require "$tool" \
                -h "$host" -p "$port" -U "$user" "${tool_args[@]}" 2>&1 | tee -a "$log_file"
            status=${PIPESTATUS[0]}
        else
            PGPASSWORD="$password" PGSSLMODE=require "$tool" \
                -h "$host" -p "$port" -U "$user" "${tool_args[@]}"
            status=$?
        fi

        if [ $status -eq 0 ]; then
            log_success "${tool} succeeded via ${label}"
            success=0
            break
        else
            log_warning "${tool} failed via ${label}"
        fi
    done < <(get_supabase_connection_endpoints "$project_ref" "$pooler_region" "$pooler_port")

    if [ $success -ne 0 ]; then
        log_error "${tool} failed for all connection attempts"
    fi

    return $success
}

# Check if direct connection is available (DNS resolution test)
check_direct_connection_available() {
    local project_ref=$1
    local hostname="db.${project_ref}.supabase.co"
    
    # Try DNS resolution (quick check)
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$hostname" >/dev/null 2>&1
        return $?
    elif command -v host >/dev/null 2>&1; then
        host "$hostname" >/dev/null 2>&1
        return $?
    elif command -v dig >/dev/null 2>&1; then
        dig +short "$hostname" >/dev/null 2>&1
        return $?
    fi
    
    # If no DNS tools available, assume it might work
    return 0
}

# Get connection string for pg_dump/pg_restore
get_connection_string() {
    local project_ref=$1
    local password=$2
    local use_pooler=${3:-false}
    
    if [ "$use_pooler" = "true" ]; then
        local pooler_host=$(get_pooler_host "$project_ref")
        echo "postgresql://postgres.${project_ref}:${password}@${pooler_host}:6543/postgres"
    else
        # Try direct connection (may require network restrictions)
        echo "postgresql://postgres.${project_ref}:${password}@db.${project_ref}.supabase.co:5432/postgres"
    fi
}

# Build connection string with URL encoding
get_connection_string_encoded() {
    local project_ref=$1
    local password=$2
    local use_pooler=${3:-false}
    
    # URL encode the password
    local encoded_password=$(printf '%s' "$password" | jq -sRr @uri 2>/dev/null || echo "$password")
    
    if [ "$use_pooler" = "true" ]; then
        local pooler_host=$(get_pooler_host "$project_ref")
        echo "postgresql://postgres.${project_ref}:${encoded_password}@${pooler_host}:6543/postgres"
    else
        echo "postgresql://postgres.${project_ref}:${encoded_password}@db.${project_ref}.supabase.co:5432/postgres"
    fi
}

# Check if environment is production
is_production() {
    local env_name=$1
    case $env_name in
        prod|production|main)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Safety confirmation for production operations
confirm_production_operation() {
    local operation=$1
    local target_env=$2
    
    if is_production "$target_env"; then
        log_warning "⚠️  WARNING: You are about to modify PRODUCTION environment!"
        log_warning "Operation: $operation"
        echo ""
        read -p "Are you absolutely sure? Type 'YES' to confirm: " confirmation
        if [ "$confirmation" != "YES" ]; then
            log_info "Operation cancelled."
            exit 0
        fi
        echo ""
    fi
}

# Link to Supabase project
link_project() {
    local project_ref=$1
    local password=$2
    
    log_info "Linking to project: $project_ref"
    
    if supabase link --project-ref "$project_ref" --password "$password" 2>&1 | tee /tmp/supabase_link.log; then
        log_success "Successfully linked to project"
        return 0
    else
        log_error "Failed to link to project"
        cat /tmp/supabase_link.log
        return 1
    fi
}

# Check if Docker is running
check_docker() {
    if ! docker ps > /dev/null 2>&1; then
        log_error "Docker is not running!"
        log_info "Please start Docker Desktop and try again."
        exit 1
    fi
    log_success "Docker is running"
}

# Create backup directory
create_backup_dir() {
    local mode=${1:-full}  # full or schema
    local source_env=${2:-}
    local target_env=${3:-}
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Create descriptive folder name
    if [ -n "$source_env" ] && [ -n "$target_env" ]; then
        local backup_dir="backups/${mode}_migration_${source_env}_to_${target_env}_${timestamp}"
    else
        local backup_dir="backups/${mode}_migration_${timestamp}"
    fi
    
    mkdir -p "$backup_dir"
    echo "$backup_dir"
}

# Cleanup old migration records in backups folder
# Keeps only the last N migration directories (sorted by modification time)
cleanup_old_migration_records() {
    local keep_count=${1:-3}  # Default: keep last 3 records
    local backups_dir="${PROJECT_ROOT:-.}/backups"
    
    if [ ! -d "$backups_dir" ]; then
        log_warning "Backups directory not found: $backups_dir"
        return 0
    fi
    
    log_info "Cleaning up old migration records (keeping last $keep_count)..."
    
    # Find all migration directories (folders matching migration pattern)
    # Use find with proper grouping for -o operator
    local all_dirs
    all_dirs=$(find "$backups_dir" -maxdepth 1 -type d \( -name "*_migration_*" -o -name "*migration_*" \) 2>/dev/null)
    
    if [ -z "$all_dirs" ]; then
        log_info "No migration directories found to clean up"
        return 0
    fi
    
    # Count total directories
    local total_count
    total_count=$(echo "$all_dirs" | grep -c . || echo "0")
    
    if [ "$total_count" -le "$keep_count" ]; then
        log_info "Only $total_count migration record(s) found, no cleanup needed (keeping last $keep_count)"
        return 0
    fi
    
    # Sort by modification time (newest first) and get directories to delete
    # macOS find doesn't support -printf, so use stat or ls -td instead
    local dirs_to_delete
    if command -v stat >/dev/null 2>&1 && stat -f "%m %N" "$backups_dir" >/dev/null 2>&1; then
        # macOS stat
        dirs_to_delete=$(find "$backups_dir" -maxdepth 1 -type d \( -name "*_migration_*" -o -name "*migration_*" \) -exec stat -f "%m %N" {} \; 2>/dev/null | \
            sort -rn | \
            tail -n +$((keep_count + 1)) | \
            cut -d' ' -f2-)
    elif command -v stat >/dev/null 2>&1; then
        # Linux stat
        dirs_to_delete=$(find "$backups_dir" -maxdepth 1 -type d \( -name "*_migration_*" -o -name "*migration_*" \) -exec stat -c "%Y %n" {} \; 2>/dev/null | \
            sort -rn | \
            tail -n +$((keep_count + 1)) | \
            cut -d' ' -f2-)
    else
        # Fallback: use ls -td (sorts by modification time, newest first)
        dirs_to_delete=$(ls -1td "$backups_dir"/*_migration_* "$backups_dir"/migration_* 2>/dev/null | \
            tail -n +$((keep_count + 1)))
    fi
    
    if [ -z "$dirs_to_delete" ]; then
        log_info "No old migration records to delete"
        return 0
    fi
    
    local deleted_count=0
    while IFS= read -r dir; do
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            log_info "  Deleting old migration record: $(basename "$dir")"
            rm -rf "$dir"
            deleted_count=$((deleted_count + 1))
        fi
    done <<< "$dirs_to_delete"
    
    log_success "Migration records cleanup complete: Kept $keep_count record(s), deleted $deleted_count record(s)"
}

# Cleanup old backup directories of the same type
# This keeps only the current migration folder and removes older ones of the same type
cleanup_old_backups() {
    local backup_type=$1  # e.g., "schema_db", "storage", "edge_functions", "secrets_migration"
    local source_env=${2:-}
    local target_env=${3:-}
    local current_backup_dir=${4:-}
    
    # If no backup type specified, skip cleanup
    [ -z "$backup_type" ] && return 0
    
    # Build pattern to match old backups
    # Note: create_backup_dir creates: backups/${backup_type}_migration_${source_env}_to_${target_env}_${timestamp}
    # So if backup_type is "storage", it creates "storage_migration_..."
    # But we also need to handle the case where backup_type already includes "_migration"
    local pattern="backups/${backup_type}"
    
    # If backup_type doesn't end with "_migration", add it (since create_backup_dir adds it)
    if [[ ! "$backup_type" =~ _migration$ ]]; then
        pattern="${pattern}_migration"
    fi
    
    if [ -n "$source_env" ] && [ -n "$target_env" ]; then
        pattern="${pattern}_${source_env}_to_${target_env}_*"
    else
        pattern="${pattern}_*"
    fi
    
    # Find all matching directories except the current one
    local old_backups=$(ls -td $pattern 2>/dev/null | grep -v "^${current_backup_dir}$" || true)
    
    if [ -n "$old_backups" ]; then
        local count=$(echo "$old_backups" | wc -l | tr -d ' ')
        log_info "Cleaning up $count old backup(s) of type: $backup_type"
        
        # Remove old backups
        echo "$old_backups" | while IFS= read -r old_backup; do
            if [ -n "$old_backup" ] && [ -d "$old_backup" ]; then
                log_info "  Removing: $(basename "$old_backup")"
                rm -rf "$old_backup"
            fi
        done
        
        log_success "Cleaned up $count old backup(s)"
    else
        log_info "No old backups to clean up for type: $backup_type"
    fi
}

# Validate environment names
validate_environments() {
    local source=$1
    local target=$2
    local source_lc
    local target_lc
    source_lc=$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')
    target_lc=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
    
    if [ "$source_lc" = "$target_lc" ]; then
        log_error "Source and target environments cannot be the same!"
        exit 1
    fi
    
    local valid_envs="prod test dev backup production staging develop main bkup bkp"
    if ! echo "$valid_envs" | grep -q "\b${source_lc}\b"; then
        log_error "Invalid source environment: $source"
        exit 1
    fi
    
    if ! echo "$valid_envs" | grep -q "\b${target_lc}\b"; then
        log_error "Invalid target environment: $target"
        exit 1
    fi
}

# Get timestamp for logging
get_timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# Log to file
log_to_file() {
    local log_file=$1
    local message=$2
    echo "[$(get_timestamp)] $message" >> "$log_file"
}

