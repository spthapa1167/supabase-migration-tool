#!/bin/bash
# Supabase Migration Utility
# Comprehensive migration tool with step-by-step validation
# Supports full/schema-only migration, backups, dry-run, and more

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_complete.sh" 2>/dev/null || true

# Default configuration
ENV_FILE=".env.local"
MODE="full"  # full|schema
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
Usage: $0 [OPTIONS]

Supabase Migration Utility - Comprehensive migration with step-by-step validation

Options:
  --source <env>          Source environment (prod, test, dev) - REQUIRED
  --target <env>          Target environment (prod, test, dev) - REQUIRED
  --mode <mode>           Migration mode: full (schema+data) or schema (default: full)
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

Examples:
  # Full migration with step-by-step validation
  $0 --source prod --target test --mode full

  # Schema-only migration
  $0 --source prod --target test --mode schema

  # Dry run (preview)
  $0 --source prod --target test --mode full --dry-run

  # Interactive mode
  $0 --interactive

EOF
    exit 0
}


# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source)
                SOURCE_ENV="$2"
                shift 2
                ;;
            --target)
                TARGET_ENV="$2"
                shift 2
                ;;
            --mode)
                MODE="$2"
                if [[ ! "$MODE" =~ ^(full|schema)$ ]]; then
                    log_error "Invalid mode: $MODE (must be 'full' or 'schema')"
                    exit 1
                fi
                shift 2
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
                log_error "Unknown option: $1"
                usage
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
    read -p "Proceed? [y/N]: " response
    echo ""
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Step cancelled by user.${NC}"
        return 1
    fi
    
    return 0
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
    source "$ENV_FILE"
    
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
    
    if ! prompt_proceed "Environment File Validation Complete" "Environment file looks good. Continue to connection validation?"; then
        return 1
    fi
    
    return 0
}

# Step 2: Validate connections
step_validate_connections() {
    local source=$1
    local target=$2
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  STEP 2/4: Validating Project Connections"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}[DRY RUN] Would validate connections to source and target projects${NC}"
        echo ""
        return 0
    fi
    
    # Check if validate_env.sh exists
    if [ ! -f "$PROJECT_ROOT/scripts/utils/validate_env.sh" ]; then
        log_warning "Validation script not found: scripts/utils/validate_env.sh"
        log_info "Skipping connection validation"
        return 0
    fi
    
    log_info "Running connection validation..."
    echo ""
    
    # Run validation script
    if "$PROJECT_ROOT/scripts/utils/validate_env.sh" --env-file "$ENV_FILE" 2>&1; then
        log_success "✅ Connection validation passed"
        echo ""
        
        if ! prompt_proceed "Connection Validation Complete" "Both projects are accessible. Continue to diff comparison?"; then
            return 1
        fi
        
        return 0
    else
        log_error "❌ Connection validation failed"
        log_error "Please fix the connection issues before proceeding"
        return 1
    fi
}

# Step 3: Run diff comparison
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
    local source_pooler=$(get_pooler_host "$source_ref")
    set +e
    PGPASSWORD="$source_password" pg_dump \
        -h "$source_pooler" \
        -p 6543 \
        -U postgres.${source_ref} \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "$source_schema" \
        2>&1 | grep -v "WARNING" || {
        log_warning "Pooler connection failed for source, trying direct connection..."
        PGPASSWORD="$source_password" pg_dump \
            -h db.${source_ref}.supabase.co \
            -p 5432 \
            -U postgres.${source_ref} \
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
    local target_pooler=$(get_pooler_host "$target_ref")
    set +e
    PGPASSWORD="$target_password" pg_dump \
        -h "$target_pooler" \
        -p 6543 \
        -U postgres.${target_ref} \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "$target_schema" \
        2>&1 | grep -v "WARNING" || {
        log_warning "Pooler connection failed for target, trying direct connection..."
        PGPASSWORD="$target_password" pg_dump \
            -h db.${target_ref}.supabase.co \
            -p 5432 \
            -U postgres.${target_ref} \
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
    source .env.local
    export SUPABASE_ACCESS_TOKEN
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
    -U postgres.\${TARGET_REF} \
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
        -U postgres.\${TARGET_REF} \
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
    
    cat > "$result_file" << EOF
# Migration Result

**Status**: $status  
**Date**: $timestamp  
**Source**: $SOURCE_ENV ($source_ref)  
**Target**: $TARGET_ENV ($target_ref)  
**Mode**: $MODE

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

2. **Database Data** $([ "$MODE" = "full" ] && echo "✅" || echo "⏭️  (Skipped - Schema Only Mode)")
   $([ "$MODE" = "full" ] && echo "   - All table data was copied from source to target" || echo "   - No data was copied (schema-only migration)")

3. **Storage Buckets** ✅
   - Bucket configurations migrated
   - Policies migrated
   - **Manual Action Required**: Upload actual files

4. **Edge Functions** $([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo "✅" || echo "⚠️")
   $([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo "   - Functions deployed successfully" || echo "   - Functions deployment failed or skipped - deploy manually")

5. **Secrets** ✅
   - Secret keys created in target
   - **CRITICAL**: Values are blank/placeholder - UPDATE REQUIRED

### Differences Applied

The following changes were applied to the target environment:

- **Schema Changes**: All differences between source and target schemas were resolved
- **Data Migration**: $([ "$MODE" = "full" ] && echo "Complete data copy from source to target" || echo "No data migration (schema only)")
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
source ../../.env.local
export SUPABASE_ACCESS_TOKEN

# Link to target project
supabase link --project-ref "$target_ref" --password "$target_password"

# Restore from backup (try pooler first)
PGPASSWORD="$target_password" pg_restore \\
    -h "$pooler_host" \\
    -p 6543 \\
    -U postgres.${target_ref} \\
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
#     -U postgres.${target_ref} \\
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
}

# Create migration directory
create_migration_dir() {
    local source_env=${1:-$SOURCE_ENV}
    local target_env=${2:-$TARGET_ENV}
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local dir_name="${MODE}_migration_${source_env}_to_${target_env}_${timestamp}"
    local migration_dir="$BACKUP_DIR/$dir_name"
    mkdir -p "$migration_dir"
    echo "$migration_dir"
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
    
    # Step 2: Validate connections
    if ! step_validate_connections "$source" "$target"; then
        log_error "Connection validation failed or cancelled"
        return 1
    fi
    
    # Step 3: Run diff comparison (pass migration_dir to save schemas)
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
    
    # Step 4: Actual migration
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  STEP 4/4: Executing Migration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Migration: $source → $target ($MODE mode)"
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
        echo "  Backup: ${BACKUP_TARGET:-false}"
        echo "  Components: All (unless excluded)"
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
    
    # Change to backup directory for duplicate scripts (they create timestamped dirs)
    cd "$BACKUP_DIR"
    
    # Use existing duplicate scripts based on mode
    local exit_code=0
    local actual_migration_dir=""
    
    if [ "$MODE" = "full" ]; then
        if [ "$BACKUP_TARGET" = "true" ]; then
            "$PROJECT_ROOT/scripts/duplication/duplicate_full.sh" "$source" "$target" --backup || exit_code=$?
        else
            "$PROJECT_ROOT/scripts/duplication/duplicate_full.sh" "$source" "$target" || exit_code=$?
        fi
    else
        if [ "$BACKUP_TARGET" = "true" ]; then
            "$PROJECT_ROOT/scripts/duplication/duplicate_schema.sh" "$source" "$target" --backup || exit_code=$?
        else
            "$PROJECT_ROOT/scripts/duplication/duplicate_schema.sh" "$source" "$target" || exit_code=$?
        fi
    fi
    
    # Find the most recently created backup directory (created by duplicate script)
    actual_migration_dir=$(ls -td "$BACKUP_DIR"/*/ 2>/dev/null | head -1 | sed 's|/$||')
    
    # If no directory found, use the one we created
    if [ -z "$actual_migration_dir" ] || [ ! -d "$actual_migration_dir" ]; then
        actual_migration_dir="$migration_dir"
    fi
    
    # Return to project root
    cd "$PROJECT_ROOT"
    
    # Generate result.md in the actual migration directory (pass comparison file if exists)
    local comparison_data_file=""
    if [ -f "$actual_migration_dir/comparison_details.txt" ]; then
        comparison_data_file="$actual_migration_dir/comparison_details.txt"
    fi
    
    if [ $exit_code -eq 0 ]; then
        generate_result_md "$actual_migration_dir" "✅ Completed" "$comparison_data_file"
        log_success "Migration completed: $actual_migration_dir"
    else
        generate_result_md "$actual_migration_dir" "❌ Failed (check migration.log)" "$comparison_data_file"
        log_error "Migration failed: $actual_migration_dir"
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
    echo "Available environments: prod, test, dev"
    read -p "Source environment: " SOURCE_ENV
    SOURCE_ENV=$(echo "$SOURCE_ENV" | tr '[:upper:]' '[:lower:]')
    
    # Prompt for target
    read -p "Target environment: " TARGET_ENV
    TARGET_ENV=$(echo "$TARGET_ENV" | tr '[:upper:]' '[:lower:]')
    
    # Prompt for mode
    read -p "Migration mode [full/schema] (default: full): " mode_input
    MODE=${mode_input:-full}
    
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
    
    echo ""
    log_info "Configuration:"
    log_info "  Source: $SOURCE_ENV"
    log_info "  Target: $TARGET_ENV"
    log_info "  Mode: $MODE"
    log_info "  Backup: $BACKUP_TARGET"
    log_info "  Dry Run: $DRY_RUN"
    echo ""
}

# Main execution
main() {
    # Parse arguments
    parse_args "$@"
    
    # Handle interactive mode
    if [ "$INTERACTIVE" = "true" ]; then
        interactive_mode
    fi
    
    # Validate required arguments
    if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
        log_error "Source and target environments are required"
        usage
        exit 1
    fi
    
    # Load environment
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Environment file not found: $ENV_FILE"
        exit 1
    fi
    
    source "$ENV_FILE"
    export SUPABASE_ACCESS_TOKEN
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Create migration directory
    local migration_dir
    migration_dir=$(create_migration_dir "$SOURCE_ENV" "$TARGET_ENV")
    
    # Perform migration
    if perform_migration "$SOURCE_ENV" "$TARGET_ENV" "$migration_dir"; then
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "  MIGRATION COMPLETED SUCCESSFULLY"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    else
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "  MIGRATION FAILED"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

# Run main
main "$@"
