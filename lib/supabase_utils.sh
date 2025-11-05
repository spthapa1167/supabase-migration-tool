#!/bin/bash
# Supabase Utilities Library
# Common functions for Supabase project duplication

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    
    # Try to get pooler URL from Supabase API if available
    if [ -n "$SUPABASE_ACCESS_TOKEN" ]; then
        local pooler_url=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${project_ref}/config/database/pooler" 2>/dev/null | \
            grep -o '"pooler_url":"[^"]*"' | cut -d'"' -f4 || echo "")
        
        if [ -n "$pooler_url" ]; then
            # Extract hostname from URL (e.g., aws-1-us-east-2.pooler.supabase.com)
            echo "$pooler_url" | sed -E 's|.*://([^:]+):.*|\1|' || echo "aws-1-us-east-2.pooler.supabase.com"
            return
        fi
    fi
    
    # Default to common pooler hostname (can be overridden via env var)
    echo "${SUPABASE_POOLER_HOST:-aws-1-us-east-2.pooler.supabase.com}"
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
    local backup_dir="backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "$backup_dir"
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

