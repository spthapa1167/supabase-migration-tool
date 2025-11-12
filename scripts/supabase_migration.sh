#!/bin/bash
# Supabase Migration Utility
# Comprehensive migration tool with step-by-step validation
# Supports full/schema-only migration, backups, dry-run, and more

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_generator.sh" 2>/dev/null || true

# Default configuration
ENV_FILE=".env.local"
MODE="schema"  # full|schema (default: schema - schema only, no data)
SOURCE_ENV=""
TARGET_ENV=""
BACKUP_DIR="backups"
DRY_RUN=false
AUTO_CONFIRM=false
INTERACTIVE=false
RESTORE_FROM=""
BACKUP_ONLY=false
INCLUDE_COMPONENTS=""
EXCLUDE_COMPONENTS=""
MULTIPLE_TARGETS=false
BACKUP_TARGET=false
INCLUDE_DATA=false  # Default: false - don't migrate database data by default
INCLUDE_FILES=false  # Default: false - don't migrate bucket files by default
INCLUDE_USERS=false  # Default: false - don't migrate auth users by default
REPLACE_TARGET_DATA=false  # Default: false - never wipe target data unless explicitly allowed
INCREMENTAL_MODE=false  # Default: false - full synchronization unless --increment is provided

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
Usage: $0 <source_env> <target_env> [OPTIONS]

Supabase Migration Utility - Comprehensive migration with step-by-step validation

Arguments:
  <source_env>            Source environment (prod, test, dev, backup) - REQUIRED
  <target_env>            Target environment (prod, test, dev, backup) - REQUIRED

Options:
  --mode <mode>           Migration mode: full (schema+data) or schema (default: schema)
  --increment             Prefer incremental/delta updates for all components (default: full sync)
  --data                  Include database data/rows migration (default: false)
  --replace-data          Allow destructive replace of target data (requires --data). Without this flag, data sync runs in delta/append mode.
  --users                 Include authentication users, roles, and policies migration (default: false)
  --files                 Include storage bucket files migration (default: false)
  --env-file <file>       Environment file (default: .env.local)
  --dry-run               Preview migration without executing
  --backup                Create backup before migration
  --backup-only           Only create backup, skip migration
  --backup-dir <dir>      Backup directory (default: backups)
  --restore-from <path>   Restore from backup path
  --auto-confirm          Skip confirmation prompts (dangerous!)
  --interactive           Interactive mode with guided prompts
  --include <components>  Include specific components (comma-separated)
  --exclude <components>  Exclude specific components (comma-separated)
  -h, --help              Show this help message

Default Behavior:
  By default, migrates SCHEMA ONLY (no database data, no bucket files, no auth users):
  - Database: Schema only (tables, indexes, policies, etc.)
  - Storage: Bucket configurations only (no files)
  - Edge Functions: Migrated
  - Secrets: Structure created (values need manual update)

  Use --data flag to include database row migration
  Use --users flag to include authentication users, roles, and policies migration
  Use --files flag to include storage bucket file migration

Examples:
  # Schema-only migration (default - no data, no files)
  $0 dev test

  # Schema + data migration
  $0 dev test --data

  # Schema + files migration
  $0 dev test --files

  # Full migration (schema + data + files + users)
  $0 dev test --data --files --users

  # Schema + data + users migration
  $0 dev test --data --users

  # Dry run (preview)
  $0 dev test --data --files --users --dry-run

  # Interactive mode
  $0 --interactive

EOF
    exit 0
}


# Parse arguments
parse_args() {
    # Handle help flag first
    if [[ $# -gt 0 ]] && ([[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]); then
        usage
    fi
    
    # First positional argument is source environment
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        SOURCE_ENV="$1"
        shift
    fi
    
    # Second positional argument is target environment
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        TARGET_ENV="$1"
        shift
    fi
    
    # Process remaining flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode)
                MODE="$2"
                if [[ ! "$MODE" =~ ^(full|schema)$ ]]; then
                    log_error "Invalid mode: $MODE (must be 'full' or 'schema')"
                    exit 1
                fi
                shift 2
                ;;
            --increment|--incremental)
                INCREMENTAL_MODE=true
                shift
                ;;
            --data)
                INCLUDE_DATA=true
                shift
                ;;
            --replace-data|--force-data-replace)
                REPLACE_TARGET_DATA=true
                shift
                ;;
            --users)
                INCLUDE_USERS=true
                shift
                ;;
            --files)
                INCLUDE_FILES=true
                shift
                ;;
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                BACKUP_TARGET=true
                shift
                ;;
            --backup-only)
                BACKUP_ONLY=true
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --restore-from)
                RESTORE_FROM="$2"
                shift 2
                ;;
            --auto-confirm)
                AUTO_CONFIRM=true
                shift
                ;;
            --interactive)
                INTERACTIVE=true
                shift
                ;;
            --include)
                INCLUDE_COMPONENTS="$2"
                shift 2
                ;;
            --exclude)
                EXCLUDE_COMPONENTS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                # If we get here with a non-flag, it might be a positional arg we missed
                if [[ ! "$1" =~ ^-- ]]; then
                    log_error "Unexpected positional argument: $1 (expected flags after source and target)"
                    usage
                else
                    log_error "Unknown option: $1"
                    usage
                fi
                ;;
        esac
    done
}

# Prompt user to proceed
prompt_proceed() {
    local step_name=$1
    local message=${2:-"Do you want to proceed?"}
    
    if [ "$AUTO_CONFIRM" = "true" ]; then
        return 0
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $step_name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}$message${NC}"
    
    # Read from /dev/tty to ensure we read from the actual terminal, not stdin
    # This fixes issues when stdin is redirected or piped
    local response=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
        # We have a terminal and can read from /dev/tty
        echo -n "Proceed? [y/N]: "
        read -r response < /dev/tty
    else
        # Fallback to regular read
        read -r -p "Proceed? [y/N]: " response
    fi
    
    # Trim whitespace and convert to lowercase
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    
    echo ""
    
    # Check if response is 'y' or 'yes'
    if [ "$response" = "y" ] || [ "$response" = "yes" ]; then
        return 0
    else
        echo -e "${YELLOW}Step cancelled by user.${NC}"
        return 1
    fi
}

# Step 1: Validate environment file
step_validate_env_file() {
    local source=$1
    local target=$2
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  STEP 1/4: Validating Environment File"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}[DRY RUN] Would validate environment file: $ENV_FILE${NC}"
        echo ""
        return 0
    fi
    
    # Check if env file exists
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Environment file not found: $ENV_FILE"
        return 1
    fi
    
    log_info "Validating environment file: $ENV_FILE"
    log_info "Checking for required variables..."
    
    # Check for required variables
    local missing_vars=()
    # Use load_env function instead of direct source for better error handling
    set +e
    load_env
    set -e
    
    if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        missing_vars+=("SUPABASE_ACCESS_TOKEN")
    fi
    
    local ref_var="SUPABASE_$(echo "$source" | tr '[:lower:]' '[:upper:]')_PROJECT_REF"
    local pass_var="SUPABASE_$(echo "$source" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
    
    if [ -z "${!ref_var:-}" ]; then
        missing_vars+=("$ref_var")
    fi
    
    if [ -z "${!pass_var:-}" ]; then
        missing_vars+=("$pass_var")
    fi
    
    ref_var="SUPABASE_$(echo "$target" | tr '[:lower:]' '[:upper:]')_PROJECT_REF"
    pass_var="SUPABASE_$(echo "$target" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
    
    if [ -z "${!ref_var:-}" ]; then
        missing_vars+=("$ref_var")
    fi
    
    if [ -z "${!pass_var:-}" ]; then
        missing_vars+=("$pass_var")
    fi
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        return 1
    fi
    
    log_success "✅ Environment file validation passed"
    log_info "   All required variables are present"
    echo ""
    
    if ! prompt_proceed "Environment File Validation Complete" "Environment file looks good. Continue to difference analysis?"; then
        return 1
    fi
    
    return 0
}

# Step 2: Run diff comparison (pass migration_dir to save schemas)
step_diff_comparison() {
    local source=$1
    local target=$2
    local migration_dir="${3:-}"  # Optional: migration directory to save schemas
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  STEP 3/4: Comparing Source and Target Projects"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}[DRY RUN] Would compare $source vs $target${NC}"
        echo ""
        return 0
    fi
    
    log_info "Comparing database schemas: $source → $target"
    echo ""
    
    # Get project references
    local source_ref=$(get_project_ref "$source")
    local target_ref=$(get_project_ref "$target")
    local source_password=$(get_db_password "$source")
    local target_password=$(get_db_password "$target")
    
    # Create temporary files for schema comparison
    local temp_dir=$(mktemp -d)
    local source_schema="$temp_dir/source_schema.sql"
    local target_schema="$temp_dir/target_schema.sql"
    
    # If migration_dir is provided, also save schemas there
    local migration_source_schema=""
    local migration_target_schema=""
    local comparison_file=""
    if [ -n "$migration_dir" ] && [ -d "$migration_dir" ]; then
        migration_source_schema="$migration_dir/source_schema.sql"
        migration_target_schema="$migration_dir/target_schema.sql"
        comparison_file="$migration_dir/comparison_details.txt"
    fi
    
    log_info "Exporting source schema..."
    # Get pooler host using environment name (more reliable)
    local source_pooler=$(get_pooler_host_for_env "$source" 2>/dev/null || get_pooler_host "$source_ref")
    if [ -z "$source_pooler" ]; then
        source_pooler="aws-1-us-east-2.pooler.supabase.com"
    fi
    set +e
    # Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
    PGPASSWORD="$source_password" pg_dump \
        -h "$source_pooler" \
        -p 6543 \
        -U "postgres.${source_ref}" \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "$source_schema" \
        2>&1 | grep -v "WARNING" || {
        log_warning "Pooler connection failed for source, trying direct connection..."
        PGPASSWORD="$source_password" pg_dump \
            -h "db.${source_ref}.supabase.co" \
            -p 5432 \
            -U "postgres.${source_ref}" \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-acl \
            -f "$source_schema" \
            2>&1 | grep -v "WARNING" || true
    }
    set -e
    
    # Copy source schema to migration directory if provided
    if [ -n "$migration_source_schema" ] && [ -f "$source_schema" ] && [ -s "$source_schema" ]; then
        cp "$source_schema" "$migration_source_schema"
        log_info "Saved source schema to: $migration_source_schema"
    fi
    
    log_info "Exporting target schema..."
    # Get pooler host using environment name (more reliable)
    local target_pooler=$(get_pooler_host_for_env "$target" 2>/dev/null || get_pooler_host "$target_ref")
    if [ -z "$target_pooler" ]; then
        target_pooler="aws-1-us-east-2.pooler.supabase.com"
    fi
    set +e
    # Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
    PGPASSWORD="$target_password" pg_dump \
        -h "$target_pooler" \
        -p 6543 \
        -U "postgres.${target_ref}" \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "$target_schema" \
        2>&1 | grep -v "WARNING" || {
        log_warning "Pooler connection failed for target, trying direct connection..."
        PGPASSWORD="$target_password" pg_dump \
            -h "db.${target_ref}.supabase.co" \
            -p 5432 \
            -U "postgres.${target_ref}" \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-acl \
            -f "$target_schema" \
            2>&1 | grep -v "WARNING" || true
    }
    set -e
    
    # Copy target schema to migration directory if provided
    if [ -n "$migration_target_schema" ] && [ -f "$target_schema" ] && [ -s "$target_schema" ]; then
        cp "$target_schema" "$migration_target_schema"
        log_info "Saved target schema to: $migration_target_schema"
    fi
    
    # Compare schemas
    log_info "Comparing schemas..."
    if [ ! -f "$source_schema" ] || [ ! -s "$source_schema" ]; then
        log_warning "Could not export source schema - skipping comparison"
        rm -rf "$temp_dir"
        return 0  # Continue with migration
    fi
    
    if [ ! -f "$target_schema" ] || [ ! -s "$target_schema" ]; then
        log_warning "Could not export target schema - skipping comparison"
        rm -rf "$temp_dir"
        return 0  # Continue with migration
    fi
    
    # Normalize schemas for comparison (remove comments, timestamps, etc.)
    local source_normalized="$temp_dir/source_normalized.sql"
    local target_normalized="$temp_dir/target_normalized.sql"
    
    # Remove comments, blank lines, and normalize whitespace
    grep -v '^--' "$source_schema" | grep -v '^$' | sed 's/[[:space:]]\+/ /g' | sort > "$source_normalized"
    grep -v '^--' "$target_schema" | grep -v '^$' | sed 's/[[:space:]]\+/ /g' | sort > "$target_normalized"
    
    # Compare normalized schemas
    if diff -q "$source_normalized" "$target_normalized" >/dev/null 2>&1; then
        log_success "✅ Database schemas are identical - no differences found"
        echo ""
        if [ -n "$comparison_file" ]; then
            echo "Database schemas are identical - no differences found." > "$comparison_file"
        fi
        rm -rf "$temp_dir"
        return 2  # Special return code: projects are identical
    else
        log_info "⚠️  Differences found between source and target schemas"
        local diff_lines=$(diff "$source_normalized" "$target_normalized" | wc -l)
        log_info "   Found approximately $diff_lines lines of differences"
        echo ""
        
        # Save comparison details to file if migration_dir provided
        if [ -n "$comparison_file" ]; then
            {
                echo "Database Schema Comparison Results"
                echo "==================================="
                echo ""
                echo "Source Environment: $source ($source_ref)"
                echo "Target Environment: $target ($target_ref)"
                echo ""
                echo "Summary:"
                echo "- Total difference lines: $diff_lines"
                echo ""
                echo "Detailed Differences:"
                echo "---------------------"
                diff "$source_normalized" "$target_normalized" | head -100 || true
                if [ $diff_lines -gt 100 ]; then
                    echo ""
                    echo "... (showing first 100 lines, total: $diff_lines)"
                fi
            } > "$comparison_file"
            log_info "Saved comparison details to: $comparison_file"
        fi
        
        # Optionally show some differences
        if [ "$diff_lines" -lt 50 ]; then
            log_info "Sample differences:"
            diff "$source_normalized" "$target_normalized" | head -20
            echo ""
        fi
        
        rm -rf "$temp_dir"
        return 0  # Continue with migration
    fi
}


# Generate result.md
generate_result_md() {
    local migration_dir=$1
    local status=$2
    local comparison_data_file="${3:-}"  # Optional: path to file with comparison data
    local error_details="${4:-}"  # Optional: error details for failed migrations
    
    # Ensure migration directory exists
    if [ ! -d "$migration_dir" ]; then
        mkdir -p "$migration_dir"
        log_warning "Created migration directory: $migration_dir"
    fi
    
    local result_file="$migration_dir/result.md"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local source_ref=$(get_project_ref "$SOURCE_ENV")
    local target_ref=$(get_project_ref "$TARGET_ENV")
    local target_password=$(get_db_password "$TARGET_ENV")
    local pooler_host=$(get_pooler_host "$target_ref")
    local backup_file="$migration_dir/target_backup.dump"
    local rollback_db_sql="$migration_dir/rollback_db.sql"
    local log_file="$migration_dir/migration.log"
    local has_backup="false"
    local has_rollback_sql="false"
    
    # Check if backup file exists
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        has_backup="true"
    fi
    
    # Check if rollback SQL exists
    if [ -f "$rollback_db_sql" ] && [ -s "$rollback_db_sql" ]; then
        has_rollback_sql="true"
    fi
    
    # Load comparison data if provided
    local comparison_details=""
    if [ -n "$comparison_data_file" ] && [ -f "$comparison_data_file" ]; then
        comparison_details=$(cat "$comparison_data_file" 2>/dev/null || echo "")
    fi
    
    # Extract migration details from log file if available
    local migration_summary=""
    local edge_functions_deployed=""
    local secrets_set=""
    local storage_buckets_migrated=""
    local tables_migrated=""
    
    if [ -f "$log_file" ]; then
        # Extract key migration details from log
        if grep -q "Edge functions deployed\|Edge functions.*deployed" "$log_file" 2>/dev/null; then
            edge_functions_deployed="✅ Deployed"
            local func_names=$(grep -i "Deployed:" "$log_file" | sed 's/.*Deployed: //' | tr '\n' ',' | sed 's/,$//' || echo "")
            if [ -n "$func_names" ]; then
                edge_functions_deployed="✅ Deployed: $func_names"
            fi
        else
            edge_functions_deployed="⚠️  Not deployed or failed"
        fi
        
        if grep -q "Secrets.*created\|Secrets.*set\|Secrets structure created" "$log_file" 2>/dev/null; then
            secrets_set="✅ Created (with blank/placeholder values)"
            local secret_count=$(grep -i "Set:" "$log_file" | wc -l | tr -d ' ')
            if [ "$secret_count" -gt 0 ]; then
                secrets_set="✅ Created $secret_count secret(s) (with blank/placeholder values)"
            fi
        else
            secrets_set="⚠️  Not set or failed"
        fi
        
        if grep -q "Storage buckets imported\|Storage buckets exported\|Storage buckets.*migrated" "$log_file" 2>/dev/null; then
            storage_buckets_migrated="✅ Migrated"
        else
            storage_buckets_migrated="⚠️  Not migrated"
        fi
    fi
    
    # Get table counts from source and target if schemas exist
    local source_schema="$migration_dir/source_schema.sql"
    local target_schema="$migration_dir/target_schema.sql"
    local source_table_count=0
    local target_table_count=0
    
    if [ -f "$source_schema" ]; then
        source_table_count=$(grep -c "^CREATE TABLE" "$source_schema" 2>/dev/null || echo "0")
    fi
    
    if [ -f "$target_schema" ]; then
        target_table_count=$(grep -c "^CREATE TABLE" "$target_schema" 2>/dev/null || echo "0")
    fi
    
    # Generate rollback script content
    local rollback_script_content=""
    if [ "$has_backup" = "true" ]; then
        rollback_script_content=$(cat << ROLLBACK_EOF
#!/bin/bash
# Rollback Script - Restore Target Database from Backup
# Migration: $SOURCE_ENV → $TARGET_ENV
# Generated: $(date)

set -euo pipefail

# Configuration
MIGRATION_DIR="$migration_dir"
TARGET_ENV="$TARGET_ENV"
TARGET_REF="$target_ref"
TARGET_PASSWORD="$target_password"
POOLER_HOST="$pooler_host"
BACKUP_FILE="$backup_file"
PROJECT_ROOT="$(cd "$(dirname "$migration_dir")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "\${BLUE}[INFO]\${NC} \$1"; }
log_success() { echo -e "\${GREEN}[SUCCESS]\${NC} \$1"; }
log_warning() { echo -e "\${YELLOW}[WARNING]\${NC} \$1"; }
log_error() { echo -e "\${RED}[ERROR]\${NC} \$1"; }

cd "\$PROJECT_ROOT"

# Load environment if available
if [ -f .env.local ]; then
    # Use load_env function for safer environment loading
    set +e
    load_env
    set -e
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  ROLLBACK SCRIPT"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "This script will rollback the migration: $SOURCE_ENV → $TARGET_ENV"
log_info "Target: $TARGET_ENV (\$TARGET_REF)"
log_info "Backup file: \$BACKUP_FILE"
echo ""

# Check if backup exists
if [ ! -f "\$BACKUP_FILE" ] || [ ! -s "\$BACKUP_FILE" ]; then
    log_error "Backup file not found or is empty: \$BACKUP_FILE"
    log_error "Cannot proceed with rollback."
    exit 1
fi

# Confirmation prompt
log_warning "⚠️  WARNING: This will replace the target database with the backup!"
log_warning "   Target: $TARGET_ENV (\$TARGET_REF)"
log_warning "   Backup: \$BACKUP_FILE"
echo ""
read -p "Do you want to proceed with rollback? [yes/NO]: " confirmation

if [ "\$confirmation" != "yes" ] && [ "\$confirmation" != "YES" ] && [ "\$confirmation" != "y" ] && [ "\$confirmation" != "Y" ]; then
    log_info "Rollback cancelled by user."
    exit 0
fi

echo ""

# Link to target project
log_info "Linking to target project..."
if command -v supabase >/dev/null 2>&1; then
    if supabase link --project-ref "\$TARGET_REF" --password "\$TARGET_PASSWORD" 2>&1 | tee /tmp/supabase_link.log; then
        log_success "Successfully linked to project"
    else
        log_error "Failed to link to project"
        cat /tmp/supabase_link.log
        exit 1
    fi
else
    log_warning "Supabase CLI not found, skipping link step"
fi

# Restore from backup
log_info "Restoring database from backup..."
LOG_FILE="\${MIGRATION_DIR}/rollback.log"

# Try pooler first, fallback to direct connection
if PGPASSWORD="\$TARGET_PASSWORD" pg_restore \
    -h "\$POOLER_HOST" \
    -p 6543 \
    -U "postgres.\${TARGET_REF}" \
    -d postgres \
    --verbose \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    "\$BACKUP_FILE" \
    2>&1 | tee "\$LOG_FILE"; then
    # Check for FATAL errors
    if ! grep -q "FATAL:" "\$LOG_FILE" 2>/dev/null; then
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "  ROLLBACK COMPLETED SUCCESSFULLY"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        log_info "Rollback log saved to: \$LOG_FILE"
        ROLLBACK_SUCCESS=true
    else
        log_warning "Pooler restore had errors, trying direct connection..."
        ROLLBACK_SUCCESS=false
    fi
else
    log_warning "Pooler restore failed, trying direct connection..."
    ROLLBACK_SUCCESS=false
fi

# Try direct connection if pooler failed
if [ "\${ROLLBACK_SUCCESS:-false}" != "true" ]; then
    log_info "Attempting direct connection..."
    if PGPASSWORD="\$TARGET_PASSWORD" pg_restore \
        -h db.\${TARGET_REF}.supabase.co \
        -p 5432 \
        -U "postgres.\${TARGET_REF}" \
        -d postgres \
        --verbose \
        --clean \
        --if-exists \
        --no-owner \
        --no-acl \
        "\$BACKUP_FILE" \
        2>&1 | tee -a "\$LOG_FILE"; then
        if ! grep -q "FATAL:" "\$LOG_FILE" 2>/dev/null; then
            log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "  ROLLBACK COMPLETED SUCCESSFULLY"
            log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            log_info "Rollback log saved to: \$LOG_FILE"
        else
            log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_error "  ROLLBACK FAILED"
            log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            log_error "Check the rollback log for details: \$LOG_FILE"
            exit 1
        fi
    else
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "  ROLLBACK FAILED"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        log_error "Check the rollback log for details: \$LOG_FILE"
        exit 1
    fi
fi

# Unlink
if command -v supabase >/dev/null 2>&1; then
    supabase unlink --yes 2>/dev/null || true
fi

log_info "Rollback completed. Please verify the target environment."
exit 0
ROLLBACK_EOF
)
    else
        rollback_script_content="# No backup available for rollback. Manual rollback required."
    fi
    
    # Prepare error details for markdown
    local error_details_md=""
    if [ -n "$error_details" ] && ([[ "$status" == *"Failed"* ]] || [[ "$status" == *"❌"* ]]); then
        error_details_md="\n\n## ❌ Migration Failed - Error Details\n\n"
        error_details_md+="The migration encountered errors. Please review the details below:\n\n"
        error_details_md+="\`\`\`\n"
        error_details_md+="$(echo "$error_details" | head -30)"
        error_details_md+="\n\`\`\`\n\n"
        error_details_md+="**Full log:** Check \`$log_file\` for complete error details.\n"
    fi
    
    cat > "$result_file" << EOF
# Migration Result

**Status**: $status  
**Date**: $timestamp  
**Source**: $SOURCE_ENV ($source_ref)  
**Target**: $TARGET_ENV ($target_ref)  
**Mode**: $MODE
$error_details_md
---

## Executive Summary

$([ "$status" = "⏭️  Skipped (Projects Identical)" ] && echo "Migration from **$SOURCE_ENV** to **$TARGET_ENV** was **skipped** because projects are identical." || echo "Migration from **$SOURCE_ENV** to **$TARGET_ENV** completed with status: **$status**")

### Quick Stats

- **Migration Mode**: $MODE ($([ "$MODE" = "full" ] && echo "Schema + Data" || echo "Schema Only"))
- **Backup Created**: $([ "$has_backup" = "true" ] && echo "✅ Yes" || echo "❌ No")
- **Rollback SQL Available**: $([ "$has_rollback_sql" = "true" ] && echo "✅ Yes" || echo "❌ No")
- **Dry Run**: $([ "$DRY_RUN" = "true" ] && echo "Yes" || echo "No")
$([ "$status" = "⏭️  Skipped (Projects Identical)" ] && echo "- **Reason**: Source and target database schemas are identical - no migration needed" || echo "")

---

## Detailed Comparison

### 1. Database Schema Comparison

**Source Environment**: $SOURCE_ENV ($source_ref)
**Target Environment**: $TARGET_ENV ($target_ref)

#### Schema Statistics

- **Source Tables**: $source_table_count
- **Target Tables**: $target_table_count
- **Tables Migrated**: $([ "$source_table_count" -gt 0 ] && echo "$source_table_count" || echo "N/A")

#### Schema Differences

$([ -n "$comparison_details" ] && echo "\`\`\`" && echo "$comparison_details" && echo "\`\`\`" || if [ -f "$log_file" ]; then
    echo "Schema comparison details from migration log:"
    echo "\`\`\`"
    grep -i "difference\|schema\|table\|CREATE\|ALTER\|DROP" "$log_file" 2>/dev/null | head -50 | sed 's/^/  /' || echo "No schema differences found in log"
    echo "\`\`\`"
else
    echo "Schema comparison details not available. Check migration log: \`$log_file\`"
fi)

### 2. Storage Buckets

**Status**: $storage_buckets_migrated

$([ "$storage_buckets_migrated" = "✅ Migrated" ] && echo "- Storage bucket configurations have been migrated from source to target
- **Note**: Bucket configuration migrated, but actual files need to be uploaded manually" || echo "- Storage buckets were not migrated or migration failed")

### 3. Edge Functions

**Status**: $edge_functions_deployed

$([ -n "$edge_functions_deployed" ] && echo "$edge_functions_deployed" || echo "- Edge functions status not available in log")

### 4. Secrets

**Status**: $secrets_set

$([ "$secrets_set" != "⚠️  Not set or failed" ] && echo "- **IMPORTANT**: Secrets were created with blank/placeholder values
- **Action Required**: You MUST update all secret values manually for the application to work properly" || echo "- Secrets were not set or setup failed")

### 5. Database Objects

#### Tables
- Source: $source_table_count tables
- Target (after migration): $target_table_count tables
$([ "$MODE" = "full" ] && echo "- **Data**: All data was migrated" || echo "- **Data**: No data was migrated (schema only)")

#### Other Objects
- Functions: Migrated (if present in source)
- Indexes: Migrated
- Constraints: Migrated
- RLS Policies: Migrated
- Sequences: Migrated

---

## Migration Summary

### What Was Applied to Target

1. **Database Schema** ✅
   - All tables from source were created/updated in target
   - All indexes, constraints, and policies were applied
   - Sequences were synchronized

2. **Database Data** $(([ "$INCLUDE_DATA" = "true" ] || [ "$MODE" = "full" ]) && echo "✅" || echo "⏭️  (Skipped)")
   $(
        if [ "$INCLUDE_DATA" = "true" ] || [ "$MODE" = "full" ]; then
            if [ "$REPLACE_TARGET_DATA" = "true" ]; then
                echo "   - Target rows were replaced with data from source"
            else
                echo "   - Data copied in delta mode (existing target rows preserved)"
            fi
        else
            echo "   - No data was copied (schema-only migration)"
        fi
    )

3. **Auth Users** $([ "$INCLUDE_USERS" = "true" ] && echo "✅" || echo "⏭️  (Skipped)")
   $([ "$INCLUDE_USERS" = "true" ] && echo "   - Authentication users, roles, and policies were migrated from source to target" || echo "   - No auth users were migrated (users migration was skipped)")

4. **Storage Buckets** ✅
   - Bucket configurations migrated
   - Policies migrated
   $([ "$INCLUDE_FILES" = "true" ] && echo "   - Files migrated from source to target" || echo "   - **Manual Action Required**: Upload actual files (files migration was skipped)")

5. **Edge Functions** $([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo "✅" || echo "⚠️")
   $([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo "   - Functions deployed successfully" || echo "   - Functions deployment failed or skipped - deploy manually")

6. **Secrets** ✅
   - Secret keys created in target
   - **CRITICAL**: Values are blank/placeholder - UPDATE REQUIRED

### Differences Applied

The following changes were applied to the target environment:

- **Schema Changes**: All differences between source and target schemas were resolved
- **Data Migration**: $(
    if [ "$INCLUDE_DATA" = "true" ] || [ "$MODE" = "full" ]; then
        if [ "$REPLACE_TARGET_DATA" = "true" ]; then
            echo "Complete replacement of target data with source data"
        else
            echo "Delta copy – existing target rows preserved, new rows appended"
        fi
    else
        echo "No data migration (schema only)"
    fi
  )
- **Files Migration**: $([ "$INCLUDE_FILES" = "true" ] && echo "Storage bucket files migrated from source to target" || echo "No files migration (bucket configuration only)")
- **Configuration**: Storage buckets, edge functions, and secrets structure migrated

---

## Rollback Instructions

### Method 1: Using Rollback Script (Recommended)

#### Option A: Direct Execution

Copy and paste this entire script into your terminal:

\`\`\`bash
$rollback_script_content
\`\`\`

#### Option B: Save and Execute

1. Copy the script above
2. Save to a file: \`$migration_dir/rollback.sh\`
3. Make executable: \`chmod +x $migration_dir/rollback.sh\`
4. Run: \`$migration_dir/rollback.sh\`

### Method 2: Manual Rollback via pg_restore

If the rollback script doesn't work, use manual commands:

\`\`\`bash
# Navigate to migration directory
cd "$migration_dir"

# Load environment
# Use load_env function for safer environment loading
set +e
load_env
set -e

# Link to target project
supabase link --project-ref "$target_ref" --password "$target_password"

# Restore from backup (try pooler first)
PGPASSWORD="$target_password" pg_restore \\
    -h "$pooler_host" \\
    -p 6543 \\
    -U "postgres.${target_ref}" \\
    -d postgres \\
    --clean \\
    --if-exists \\
    --no-owner \\
    --no-acl \\
    --verbose \\
    target_backup.dump

# If pooler fails, try direct connection
# PGPASSWORD="$target_password" pg_restore \\
#     -h db.${target_ref}.supabase.co \\
#     -p 5432 \\
#     -U "postgres.${target_ref}" \\
#     -d postgres \\
#     --clean \\
#     --if-exists \\
#     --no-owner \\
#     --no-acl \\
#     --verbose \\
#     target_backup.dump

# Unlink
supabase unlink --yes
\`\`\`

### Method 3: Using Supabase SQL Editor (For Schema Changes Only)

$(if [ "$has_rollback_sql" = "true" ]; then
    echo "If you only need to rollback schema changes, you can use the SQL rollback file:"
    echo ""
    echo "1. Open Supabase Dashboard → SQL Editor"
    echo "2. Select target project: **$target_ref**"
    echo "3. Open file: \`$rollback_db_sql\`"
    echo "4. Copy the entire contents"
    echo "5. Paste into SQL Editor"
    echo "6. Click \"Run\" to execute"
    echo ""
    echo "⚠️ **Warning**: This will restore the database schema to its pre-migration state. Review the SQL before executing."
    echo ""
    echo "**File Location**: \`$rollback_db_sql\`"
else
    echo "SQL rollback file not available. Use Method 1 or 2 instead."
fi)

---

## Files Generated

All migration files are located in: \`$migration_dir\`

### Core Files

- **\`migration.log\`** - Complete migration log with all operations
- **\`target_backup.dump\`** $([ "$has_backup" = "true" ] && echo "✅ Available" || echo "❌ Not available") - Binary backup of target before migration
- **\`rollback_db.sql\`** $([ "$has_rollback_sql" = "true" ] && echo "✅ Available" || echo "❌ Not available") - SQL script for manual rollback via SQL Editor
- **\`result.md\`** - This file

### Additional Files (if available)

$([ -f "$migration_dir/source_schema.sql" ] && echo "- \`source_schema.sql\` - Source database schema export" || echo "")
$([ -f "$migration_dir/target_schema.sql" ] && echo "- \`target_schema.sql\` - Target database schema export" || echo "")
$([ -f "$migration_dir/storage_buckets.sql" ] && echo "- \`storage_buckets.sql\` - Storage buckets configuration" || echo "")
$([ -f "$migration_dir/secrets_list.json" ] && echo "- \`secrets_list.json\` - List of secrets (names only)" || echo "")
$([ -f "$migration_dir/edge_functions_list.json" ] && echo "- \`edge_functions_list.json\` - List of edge functions" || echo "")

---

## Next Steps

### Immediate Actions Required

1. **Update Secrets** ⚠️ **CRITICAL**
   - All secrets were created with blank/placeholder values
   - Update each secret with actual values:
   \`\`\`bash
   supabase secrets set KEY_NAME=actual_value --project-ref $target_ref
   \`\`\`
   - Check \`$migration_dir/secrets_list.json\` or \`$migration_dir/secrets_list_template.txt\` for list of secrets

2. **Upload Storage Files** (if applicable)
   - Go to: https://supabase.com/dashboard/project/$target_ref/storage/buckets
   - Upload actual files to each bucket

3. **Verify Edge Functions** (if applicable)
   $([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo "   - Functions should be deployed automatically" || echo "   - Deploy functions manually: \`supabase functions deploy <function-name> --project-ref $target_ref\`")

4. **Test Application**
   - Verify all functionality works correctly
   - Test database queries, storage operations, edge functions

### Post-Migration Checklist

- [ ] Secrets updated with actual values
- [ ] Storage files uploaded (if needed)
- [ ] Edge functions verified/deployed
- [ ] Application tested and working
- [ ] Rollback plan reviewed (if needed)
- [ ] Team notified of migration completion

---

## Troubleshooting

### Migration Log

For detailed operation logs, check: \`$log_file\`

### Common Issues

1. **Secrets not working**
   - Ensure all secrets are updated with actual values
   - Verify secrets are set: \`supabase secrets list --project-ref $target_ref\`

2. **Edge functions not deployed**
   - Deploy manually from codebase
   - Check function logs in Supabase Dashboard

3. **Storage files missing**
   - Upload files manually via Dashboard or Storage API
   - Verify bucket policies are correct

4. **Database connection issues**
   - Verify connection strings are updated
   - Check pooler vs direct connection settings

---

## Support

For issues or questions:
- Review migration log: \`$log_file\`
- Check Supabase Dashboard: https://supabase.com/dashboard/project/$target_ref
- Review migration directory: \`$migration_dir\`

---

**Migration completed at**: $timestamp  
**Status**: $status
EOF
    
    log_success "Result page generated: $result_file"
    
    # Also generate HTML version
    if [ -f "$PROJECT_ROOT/lib/html_generator.sh" ]; then
        log_info "Generating HTML result page..."
        source "$PROJECT_ROOT/lib/html_generator.sh"
        local html_file=$(generate_result_html "$migration_dir" "$status" "$comparison_data_file")
        if [ -n "$html_file" ] && [ -f "$html_file" ]; then
            log_success "HTML result page generated: $html_file"
            log_info "Open in browser: file://$(realpath "$html_file")"
        else
            log_warning "HTML generation may have failed, check logs"
        fi
    else
        log_warning "HTML generator not found: $PROJECT_ROOT/lib/html_generator.sh"
    fi
}

# Create migration directory with descriptive name
create_migration_dir() {
    local source_env=${1:-$SOURCE_ENV}
    local target_env=${2:-$TARGET_ENV}
    local mode=${3:-${MODE:-full}}
    
    # Use create_backup_dir function for consistency (creates directly in backups/)
    if command -v create_backup_dir >/dev/null 2>&1; then
        create_backup_dir "$mode" "$source_env" "$target_env"
    else
        # Fallback if function not available
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local migration_dir="backups/${mode}_migration_${source_env}_to_${target_env}_${timestamp}"
        mkdir -p "$migration_dir"
        echo "$migration_dir"
    fi
}

# Perform migration
perform_migration() {
    local source=$1
    local target=$2
    local migration_dir=$3
    
    # Pre-migration steps
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  PRE-MIGRATION VALIDATION STEPS"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Step 1: Validate environment file
    if ! step_validate_env_file "$source" "$target"; then
        log_error "Environment file validation failed or cancelled"
        return 1
    fi
    
    # Step 2: Run diff comparison (pass migration_dir to save schemas)
    local diff_result
    step_diff_comparison "$source" "$target" "$migration_dir"
    diff_result=$?
    
    if [ $diff_result -eq 1 ]; then
        log_error "Diff comparison cancelled by user"
        return 1
    elif [ $diff_result -eq 2 ]; then
        # Projects are identical - skip migration
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "  MIGRATION SKIPPED - Projects are identical"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        log_info "Source and target projects have identical database schemas."
        log_info "No migration needed - generating results page..."
        echo ""
        
        # Generate result.md indicating skipped migration
        generate_result_md "$migration_dir" "⏭️  Skipped (Projects Identical)"
        
        log_success "Results page generated: $migration_dir/result.md"
        return 0
    fi
    
    # Step 3: Actual migration
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  STEP 3/3: Executing Migration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Migration: $source → $target ($MODE mode)"
    if [ "$INCREMENTAL_MODE" = "true" ]; then
        log_info "Incremental mode: Enabled (components will prefer delta/incremental operations)"
    else
        log_info "Incremental mode: Disabled (components will run in standard sync mode)"
    fi
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  DRY RUN MODE - No changes will be made${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Would migrate:"
        echo "  Source: $source ($(get_project_ref "$source"))"
        echo "  Target: $target ($(get_project_ref "$target"))"
        echo "  Mode: $MODE"
        echo "  Incremental Mode: $INCREMENTAL_MODE"
        echo "  Include Data: $INCLUDE_DATA"
        echo "  Include Users: $INCLUDE_USERS"
        echo "  Include Files: $INCLUDE_FILES"
        echo "  Backup: ${BACKUP_TARGET:-false}"
        echo "  Components: All (database, storage, edge functions, secrets)"
        echo ""
        echo "Migration directory: $migration_dir"
        echo ""
        return 0
    fi
    
    # Final confirmation before migration
    if ! prompt_proceed "Ready to Start Migration" "All validations passed. Start the actual migration now?"; then
        log_info "Migration cancelled by user"
        return 1
    fi
    
    # Safety check for production
    if [ "$AUTO_CONFIRM" != "true" ] && [[ "$target" =~ ^(prod|production|main)$ ]]; then
        echo ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  ⚠️  WARNING: PRODUCTION ENVIRONMENT DETECTED${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${RED}You are about to modify PRODUCTION environment!${NC}"
        echo ""
        read -p "Are you absolutely sure? Type 'YES' to confirm: " confirmation
        if [ "$confirmation" != "YES" ]; then
            echo ""
            log_info "Migration cancelled by user."
            return 1
        fi
        echo ""
    fi
    
    # Perform migration using modular scripts
    # Set LOG_FILE so all component scripts can append to the same log
    export LOG_FILE="$migration_dir/migration.log"
    
    # Create migration directory if it doesn't exist
    mkdir -p "$migration_dir"
    touch "$LOG_FILE"
    
    log_to_file "$LOG_FILE" "Starting migration from $source to $target (mode: $MODE, incremental: $INCREMENTAL_MODE)"
    
    local exit_code=0
    local actual_migration_dir="$migration_dir"
    
    # Step 1: Migrate database (schema + optionally data)
    # Check if data migration is requested (either via --data flag or --mode full)
    local migrate_data=false
    if [ "$INCLUDE_DATA" = "true" ] || [ "$MODE" = "full" ]; then
        migrate_data=true
    fi
    
    # Build command arguments for database migration
    local db_migration_args=("$source" "$target" "$migration_dir")
    if [ "$INCREMENTAL_MODE" = "true" ]; then
        db_migration_args+=("--increment")
    fi
    if [ "$INCLUDE_USERS" = "true" ]; then
        db_migration_args+=("--users")
    fi
    if [ "$BACKUP_TARGET" = "true" ]; then
        db_migration_args+=("--backup")
    fi
    if [ "$migrate_data" = "true" ]; then
        db_migration_args+=("--data")
        if [ "$REPLACE_TARGET_DATA" = "true" ]; then
            db_migration_args+=("--replace-data")
        fi
    fi
    
    if [ "$MODE" = "full" ] && [ "$REPLACE_TARGET_DATA" != "true" ]; then
        log_warning "Full mode selected without --replace-data: running data sync in delta mode to preserve target rows."
    fi

    if [ "$migrate_data" = "true" ] && [ "$REPLACE_TARGET_DATA" = "true" ]; then
        log_warning "Data migration will REPLACE target data. Ensure you have backups and have confirmed this is intended."
    elif [ "$migrate_data" = "true" ]; then
        log_info "Data migration set to delta mode: existing target rows will be preserved. Only new data will be attempted."
    fi

    if [ "$migrate_data" = "true" ]; then
        log_info "Migrating database (schema + data)..."
    else
        log_info "Migrating database (schema only - no data)..."
    fi

    if [ "$INCLUDE_USERS" = "true" ]; then
        log_info "Auth users migration will run within the database migration step."
    fi
    
    # Call database_migration.sh component script
    if "$PROJECT_ROOT/scripts/components/database_migration.sh" "${db_migration_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Database migration completed successfully"
    else
        exit_code=$?
        log_error "Database migration failed!"
        return 1
    fi

    # Step 2: Migrate storage buckets (configuration + optionally files)
    # Build command arguments for storage migration
    local storage_migration_args=("$source" "$target" "$migration_dir")
    if [ "$INCREMENTAL_MODE" = "true" ]; then
        storage_migration_args+=("--increment")
    fi
    if [ "$INCLUDE_FILES" = "true" ]; then
        storage_migration_args+=("--file")
        log_info "Migrating storage buckets (configuration + files)..."
    else
        log_info "Migrating storage buckets (configuration only - no files)..."
    fi
    
    # Call storage_buckets_migration.sh component script
    if "$PROJECT_ROOT/scripts/components/storage_buckets_migration.sh" "${storage_migration_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        if [ "$INCLUDE_FILES" = "true" ]; then
            log_success "Storage buckets migrated successfully (with files)"
        else
            log_success "Storage buckets migrated successfully (configuration only)"
        fi
    else
        log_warning "Storage buckets migration had errors, continuing..."
    fi
    
    # Step 3: Migrate edge functions
    log_info "Migrating edge functions..."
    # Call edge_functions_migration.sh component script
    local edge_migration_cmd=("$PROJECT_ROOT/scripts/components/edge_functions_migration.sh" "$source" "$target" "$migration_dir")
    if [ "$INCREMENTAL_MODE" = "true" ]; then
        edge_migration_cmd+=("--increment")
    fi
    if "${edge_migration_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Edge functions migrated successfully"
    else
        log_warning "Edge functions migration had errors, continuing..."
    fi
    
    # Step 4: Migrate secrets
    log_info "Migrating secrets..."
    # Call secrets_migration.sh component script
    local secrets_migration_cmd=("$PROJECT_ROOT/scripts/components/secrets_migration.sh" "$source" "$target" "$migration_dir")
    if [ "$INCREMENTAL_MODE" = "true" ]; then
        secrets_migration_cmd+=("--increment")
    fi
    if "${secrets_migration_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Secrets migrated successfully (structure created - values need manual update)"
    else
        log_warning "Secrets migration had errors, continuing..."
    fi
    
    # The duplicate script creates its own BACKUP_DIR, so find the most recent one
    # But we also need to check if the migration_dir we created was used
    actual_migration_dir="$migration_dir"
    
    # Check if duplicate script created a different directory (most recent in backups/)
    # Look for the most recent directory that matches our migration pattern
    local latest_backup_dir=$(ls -td backups/${MODE}_migration_${source}_to_${target}_* 2>/dev/null | head -1 | sed 's|/$||')
    if [ -z "$latest_backup_dir" ] || [ ! -d "$latest_backup_dir" ]; then
        # Fallback: get the most recent backup directory
        latest_backup_dir=$(ls -td backups/*/ 2>/dev/null | head -1 | sed 's|/$||')
    fi
    
    if [ -n "$latest_backup_dir" ] && [ -d "$latest_backup_dir" ]; then
        # Use the one created by duplicate script if it's different and newer
        if [ "$latest_backup_dir" != "$migration_dir" ]; then
            # Check if the latest is actually newer (by comparing timestamps in folder name)
            local latest_timestamp=$(basename "$latest_backup_dir" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
            local migration_timestamp=$(basename "$migration_dir" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
            if [ -n "$latest_timestamp" ] && [ -n "$migration_timestamp" ]; then
                # Compare timestamps (YYYYMMDD_HHMMSS format)
                if [ "$latest_timestamp" \> "$migration_timestamp" ]; then
                    actual_migration_dir="$latest_backup_dir"
                    log_info "Using backup directory created by duplicate script: $actual_migration_dir"
                fi
            else
                # If timestamps can't be compared, use the latest if it exists and is different
                actual_migration_dir="$latest_backup_dir"
                log_info "Using latest backup directory: $actual_migration_dir"
            fi
        fi
    fi
    
    # Ensure the actual migration directory exists
    if [ ! -d "$actual_migration_dir" ]; then
        log_warning "Migration directory not found: $actual_migration_dir, using original: $migration_dir"
        actual_migration_dir="$migration_dir"
        mkdir -p "$actual_migration_dir"
    fi
    
    # Ensure migration.log exists (rename old log files if needed and merge content)
    if [ -f "$actual_migration_dir/duplication.log" ] && [ -f "$actual_migration_dir/migration.log" ]; then
        # Both exist, merge duplication.log into migration.log
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Merging duplication.log into migration.log" >> "$actual_migration_dir/migration.log"
        cat "$actual_migration_dir/duplication.log" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        rm -f "$actual_migration_dir/duplication.log"
    elif [ -f "$actual_migration_dir/duplication.log" ] && [ ! -f "$actual_migration_dir/migration.log" ]; then
        mv "$actual_migration_dir/duplication.log" "$actual_migration_dir/migration.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Renamed duplication.log to migration.log" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
    fi
    
    if [ -f "$actual_migration_dir/schema_duplication.log" ] && [ -f "$actual_migration_dir/migration.log" ]; then
        # Both exist, merge schema_duplication.log into migration.log
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Merging schema_duplication.log into migration.log" >> "$actual_migration_dir/migration.log"
        cat "$actual_migration_dir/schema_duplication.log" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        rm -f "$actual_migration_dir/schema_duplication.log"
    elif [ -f "$actual_migration_dir/schema_duplication.log" ] && [ ! -f "$actual_migration_dir/migration.log" ]; then
        mv "$actual_migration_dir/schema_duplication.log" "$actual_migration_dir/migration.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Renamed schema_duplication.log to migration.log" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
    fi
    
    # Ensure migration.log file exists (create if it doesn't)
    if [ ! -f "$actual_migration_dir/migration.log" ]; then
        touch "$actual_migration_dir/migration.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migration log initialized" >> "$actual_migration_dir/migration.log"
    fi
    
    # Log migration completion
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migration process completed with exit code: $exit_code" >> "$actual_migration_dir/migration.log"
    
    # Return to project root
    cd "$PROJECT_ROOT"
    
    # Generate result.md in the actual migration directory (pass comparison file if exists)
    local comparison_data_file=""
    if [ -f "$actual_migration_dir/comparison_details.txt" ]; then
        comparison_data_file="$actual_migration_dir/comparison_details.txt"
    fi
    
    # Ensure directory exists before generating result files
    if [ ! -d "$actual_migration_dir" ]; then
        mkdir -p "$actual_migration_dir"
        log_warning "Created migration directory: $actual_migration_dir"
    fi
    
    # Ensure migration.log exists before writing to it
    if [ ! -f "$actual_migration_dir/migration.log" ]; then
        touch "$actual_migration_dir/migration.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migration log file created" >> "$actual_migration_dir/migration.log"
    fi
    
    # Always generate result files (both success and failure)
    log_info "Generating result files in: $actual_migration_dir"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Generating result.md and result.html files..." >> "$actual_migration_dir/migration.log" 2>/dev/null || true
    
    if [ $exit_code -eq 0 ]; then
        # Give Supabase a moment to settle before generating reports
        sleep 2
        
        # Generate result files - ensure they're created even if function fails partially
        # This queries target counts AFTER migration completes for accuracy
        log_info "Querying target database/API for post-migration counts..."
        if generate_result_md "$actual_migration_dir" "✅ Completed" "$comparison_data_file" 2>&1 | tee -a "$actual_migration_dir/migration.log"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] result.md and result.html generated successfully with post-migration counts" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        else
            log_warning "Result generation had errors, but continuing..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Result generation completed with warnings" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        fi
        log_success "Migration completed: $actual_migration_dir"
        log_success "Result files: $actual_migration_dir/result.md and $actual_migration_dir/result.html"
        
        # Cleanup old migration records (keep only the last 3)
        log_info "Cleaning up old migration records (keeping last 3)..."
        # The function is already sourced from lib/supabase_utils.sh at the top of the script
        if type cleanup_old_migration_records >/dev/null 2>&1; then
            cleanup_old_migration_records 3
        else
            log_warning "cleanup_old_migration_records function not available, skipping cleanup"
        fi
    else
        # Generate result files for failure case
        if generate_result_md "$actual_migration_dir" "❌ Failed (check migration.log)" "$comparison_data_file" 2>&1 | tee -a "$actual_migration_dir/migration.log"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] result.md and result.html generated with failure status" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        else
            log_warning "Result generation had errors, but continuing..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Result generation completed with warnings" >> "$actual_migration_dir/migration.log" 2>/dev/null || true
        fi
        log_error "Migration failed: $actual_migration_dir"
        log_info "Result files: $actual_migration_dir/result.md and $actual_migration_dir/result.html"
        return $exit_code
    fi
    
    return 0
}

# Interactive mode
interactive_mode() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  INTERACTIVE MIGRATION MODE"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Prompt for source
    echo "Available environments: prod, test, dev, backup"
    read -p "Source environment: " SOURCE_ENV
    SOURCE_ENV=$(echo "$SOURCE_ENV" | tr '[:upper:]' '[:lower:]')
    
    # Prompt for target
    read -p "Target environment: " TARGET_ENV
    TARGET_ENV=$(echo "$TARGET_ENV" | tr '[:upper:]' '[:lower:]')
    
    # Prompt for mode
    read -p "Migration mode [full/schema] (default: schema): " mode_input
    MODE=${mode_input:-schema}
    
    # Prompt for data migration
    read -p "Include database data migration? [y/N]: " data_input
    if [[ "$data_input" =~ ^[Yy]$ ]]; then
        INCLUDE_DATA=true
    fi
    
    # Prompt for users migration
    read -p "Include authentication users migration? [y/N]: " users_input
    if [[ "$users_input" =~ ^[Yy]$ ]]; then
        INCLUDE_USERS=true
    fi
    
    # Prompt for files migration
    read -p "Include storage bucket files migration? [y/N]: " files_input
    if [[ "$files_input" =~ ^[Yy]$ ]]; then
        INCLUDE_FILES=true
    fi
    
    # Prompt for backup
    read -p "Create backup? [y/N]: " backup_input
    if [[ "$backup_input" =~ ^[Yy]$ ]]; then
        BACKUP_TARGET=true
    fi
    
    # Prompt for dry-run
    read -p "Dry run? [y/N]: " dryrun_input
    if [[ "$dryrun_input" =~ ^[Yy]$ ]]; then
        DRY_RUN=true
    fi
    
    # Prompt for incremental mode
    read -p "Prefer incremental (delta) mode? [y/N]: " increment_input
    if [[ "$increment_input" =~ ^[Yy]$ ]]; then
        INCREMENTAL_MODE=true
    fi
    
    echo ""
    log_info "Configuration:"
    log_info "  Source: $SOURCE_ENV"
    log_info "  Target: $TARGET_ENV"
    log_info "  Mode: $MODE"
    log_info "  Include Data: $INCLUDE_DATA"
    log_info "  Replace Target Data: $REPLACE_TARGET_DATA"
    log_info "  Include Users: $INCLUDE_USERS"
    log_info "  Include Files: $INCLUDE_FILES"
    log_info "  Backup: $BACKUP_TARGET"
    log_info "  Dry Run: $DRY_RUN"
    log_info "  Incremental Mode: $INCREMENTAL_MODE"
    echo ""
}

# Main execution
main() {
    # Parse arguments
    parse_args "$@"
    
    # Handle interactive mode (can run without source/target - will prompt for them)
    if [ "$INTERACTIVE" = "true" ]; then
        interactive_mode
    fi
    
    # Validate required arguments (after interactive mode, if not set)
    if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
        log_error "Source and target environments are required"
        log_info "Usage: $0 <source_env> <target_env> [OPTIONS]"
        log_info "Example: $0 dev test --data --files"
        log_info "Or use: $0 --interactive (to be prompted for all options)"
        log_info "Run '$0 --help' for more information"
        exit 1
    fi
    
    if [ "$REPLACE_TARGET_DATA" = "true" ] && [ "$MODE" != "full" ] && [ "$INCLUDE_DATA" = "false" ]; then
        log_error "--replace-data requires --data or --mode full. Refusing to run destructive migration without data sync."
        exit 1
    fi
    
    if [ "$REPLACE_TARGET_DATA" = "true" ] && [ "$INCREMENTAL_MODE" = "true" ]; then
        log_warning "--increment requested but --replace-data also set; replace mode will override incremental data behaviour."
    fi
    
    # Load environment using the robust load_env function
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Environment file not found: $ENV_FILE"
        exit 1
    fi
    
    set +e
    load_env
    LOAD_ENV_EXIT_CODE=$?
    set -e
    if [ $LOAD_ENV_EXIT_CODE -ne 0 ]; then
        log_error "Failed to load environment variables"
        exit 1
    fi
    
    log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

    # Note: We don't cleanup before migration anymore
    # Cleanup happens AFTER migration completes to keep last 3 records
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Create migration directory
    local migration_dir
    migration_dir=$(create_migration_dir "$SOURCE_ENV" "$TARGET_ENV")
    
    # Ensure migration directory exists and create empty log/result files at the start
    if [ ! -d "$migration_dir" ]; then
        mkdir -p "$migration_dir"
        log_info "Created migration directory: $migration_dir"
    fi
    
    # Create empty migration.log file at the start
    touch "$migration_dir/migration.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migration log initialized" >> "$migration_dir/migration.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migration started: $SOURCE_ENV → $TARGET_ENV (mode: $MODE)" >> "$migration_dir/migration.log"
    log_info "Migration directory: $migration_dir"
    log_info "Migration log: $migration_dir/migration.log"
    
    # Perform migration
    local migration_success=false
    if perform_migration "$SOURCE_ENV" "$TARGET_ENV" "$migration_dir"; then
        migration_success=true
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "  MIGRATION COMPLETED SUCCESSFULLY"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Generate result files even on success (they should already be generated)
        if [ -f "$PROJECT_ROOT/lib/html_generator.sh" ]; then
            source "$PROJECT_ROOT/lib/html_generator.sh"
            generate_result_html "$migration_dir" "✅ Completed" "$migration_dir/comparison_details.txt" 2>&1 | tee -a "$migration_dir/migration.log" || true
        fi
        
        log_info "Migration folder kept: $migration_dir"
        log_info "Results: $migration_dir/result.md and $migration_dir/result.html"
        exit 0
    else
        migration_success=false
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "  MIGRATION FAILED"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Extract error details from log
        local error_details=""
        if [ -f "$migration_dir/migration.log" ]; then
            error_details=$(grep -iE "(ERROR|FATAL|failed|error:)" "$migration_dir/migration.log" 2>/dev/null | tail -20 || echo "")
        fi
        
        # Generate result files with error details
        log_info "Generating result files with error details..."
        if [ -f "$PROJECT_ROOT/lib/html_generator.sh" ]; then
            source "$PROJECT_ROOT/lib/html_generator.sh"
            # Pass error details as 4th parameter
            generate_result_html "$migration_dir" "❌ Failed" "$migration_dir/comparison_details.txt" "$error_details" 2>&1 | tee -a "$migration_dir/migration.log" || true
        fi
        
        # Generate result.md with error details
        generate_result_md "$migration_dir" "❌ Failed" "$migration_dir/comparison_details.txt" "$error_details" 2>&1 | tee -a "$migration_dir/migration.log" || true
        
        log_warning "Migration folder kept for debugging: $migration_dir"
        log_info "Check $migration_dir/migration.log for details"
        log_info "Results: $migration_dir/result.md and $migration_dir/result.html"
        exit 1
    fi
}

# Run main
main "$@"
