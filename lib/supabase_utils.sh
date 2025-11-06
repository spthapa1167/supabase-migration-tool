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
        exit 1
    fi
    
    source .env.local
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_error "SUPABASE_ACCESS_TOKEN not set in .env.local"
        exit 1
    fi
    
    export SUPABASE_ACCESS_TOKEN
}

# Get project reference by name
get_project_ref() {
    local env_name=$1
    case $env_name in
        prod|production|main)
            echo "$SUPABASE_PROD_PROJECT_REF"
            ;;
        test|staging)
            echo "$SUPABASE_TEST_PROJECT_REF"
            ;;
        dev|develop)
            echo "$SUPABASE_DEV_PROJECT_REF"
            ;;
        *)
            log_error "Unknown environment: $env_name"
            log_info "Valid environments: prod, test, dev"
            exit 1
            ;;
    esac
}

# Get database password by environment name
get_db_password() {
    local env_name=$1
    case $env_name in
        prod|production|main)
            echo "$SUPABASE_PROD_DB_PASSWORD"
            ;;
        test|staging)
            echo "$SUPABASE_TEST_DB_PASSWORD"
            ;;
        dev|develop)
            echo "$SUPABASE_DEV_DB_PASSWORD"
            ;;
        *)
            log_error "Unknown environment: $env_name"
            exit 1
            ;;
    esac
}

# Get pooler hostname (tries common regions, can be overridden)
get_pooler_host() {
    local project_ref=$1
    
    # First, try to determine from project ref by checking environment-specific pooler region
    # This is the most reliable method if configured in .env.local
    if [ "$project_ref" = "$SUPABASE_PROD_PROJECT_REF" ] && [ -n "${SUPABASE_PROD_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_PROD_POOLER_REGION}.pooler.supabase.com"
        return 0
    elif [ "$project_ref" = "$SUPABASE_TEST_PROJECT_REF" ] && [ -n "${SUPABASE_TEST_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_TEST_POOLER_REGION}.pooler.supabase.com"
        return 0
    elif [ "$project_ref" = "$SUPABASE_DEV_PROJECT_REF" ] && [ -n "${SUPABASE_DEV_POOLER_REGION:-}" ]; then
        echo "${SUPABASE_DEV_POOLER_REGION}.pooler.supabase.com"
        return 0
    fi
    
    # Try to get pooler URL from Supabase API if available
    if [ -n "$SUPABASE_ACCESS_TOKEN" ]; then
        local api_response=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${project_ref}/config/database/pooler" 2>/dev/null)
        
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
    
    if [ "$source" = "$target" ]; then
        log_error "Source and target environments cannot be the same!"
        exit 1
    fi
    
    local valid_envs="prod test dev production staging develop main"
    if ! echo "$valid_envs" | grep -q "\b${source}\b"; then
        log_error "Invalid source environment: $source"
        exit 1
    fi
    
    if ! echo "$valid_envs" | grep -q "\b${target}\b"; then
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

