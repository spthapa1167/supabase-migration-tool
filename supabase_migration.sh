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
        rm -rf "$temp_dir"
        return 2  # Special return code: projects are identical
    else
        log_info "⚠️  Differences found between source and target schemas"
        local diff_lines=$(diff "$source_normalized" "$target_normalized" | wc -l)
        log_info "   Found approximately $diff_lines lines of differences"
        echo ""
        
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
    
    local result_file="$migration_dir/result.md"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local target_ref=$(get_project_ref "$TARGET_ENV")
    local target_password=$(get_db_password "$TARGET_ENV")
    local pooler_host=$(get_pooler_host "$target_ref")
    local backup_file="$migration_dir/target_backup.dump"
    local has_backup="false"
    
    # Check if backup file exists
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        has_backup="true"
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
**Source**: $SOURCE_ENV ($(get_project_ref "$SOURCE_ENV"))  
**Target**: $TARGET_ENV ($target_ref)  
**Mode**: $MODE

## Summary

$([ "$status" = "⏭️  Skipped (Projects Identical)" ] && echo "Migration from **$SOURCE_ENV** to **$TARGET_ENV** was **skipped** because projects are identical." || echo "Migration from **$SOURCE_ENV** to **$TARGET_ENV** completed with status: **$status**")

## Migration Details

- **Mode**: $MODE ($([ "$MODE" = "full" ] && echo "Schema + Data" || echo "Schema Only"))
- **Backup Created**: $([ "$has_backup" = "true" ] && echo "Yes" || echo "No")
- **Dry Run**: $([ "$DRY_RUN" = "true" ] && echo "Yes" || echo "No")
$([ "$status" = "⏭️  Skipped (Projects Identical)" ] && echo "- **Reason**: Source and target database schemas are identical - no migration needed" || echo "")

## Rollback Instructions

### Manual Rollback via Supabase SQL Editor

A **`rollback_db.sql`** file has been generated in the backup folder that contains all SQL statements needed to restore the database to its pre-migration state. This file can be run directly in the Supabase SQL Editor:

1. Open Supabase Dashboard → SQL Editor
2. Select the target project
3. Open the file: `$migration_dir/rollback_db.sql`
4. Copy the entire contents
5. Paste into the SQL Editor
6. Click "Run" to execute

**File Location**: `$migration_dir/rollback_db.sql`

⚠️ **Warning**: This will restore the database to its state before migration. Make sure you have reviewed the script before running it.

### Quick Rollback (Copy & Paste)

If a backup was created, you can use this complete rollback script:

\`\`\`bash
$rollback_script_content
\`\`\`

**To use:**
1. Copy the entire script block above (from \`#!/bin/bash\` to \`exit 0\`)
2. Save it to a file: \`rollback.sh\` in the migration directory
3. Make it executable: \`chmod +x rollback.sh\`
4. Run it: \`./rollback.sh\`

Or execute directly:

\`\`\`bash
$rollback_script_content
\`\`\`

### Manual Rollback Steps

1. **If backup exists** (\`target_backup.dump\`):
   \`\`\`bash
   cd "$migration_dir"
   source ../../.env.local
   export SUPABASE_ACCESS_TOKEN
   
   # Link to target
   supabase link --project-ref "$target_ref" --password "$target_password"
   
   # Restore from backup
   PGPASSWORD="$target_password" pg_restore \\
       -h "$pooler_host" \\
       -p 6543 \\
       -U postgres.${target_ref} \\
       -d postgres \\
       --clean --if-exists --no-owner --no-acl \\
       target_backup.dump
   
   # Unlink
   supabase unlink --yes
   \`\`\`

2. **If no backup**, you'll need to manually reverse the changes based on the migration files.

## Migration Files

- **Migration directory**: \`$migration_dir\`
- **Backup file**: $([ "$has_backup" = "true" ] && echo "\`$backup_file\`" || echo "Not available")
- **Log file**: \`migration.log\`
- **Source dump**: \`source_full.dump\` (or \`source_schema.dump\` for schema-only)

## Next Steps

1. ✅ Verify the migration was successful
2. ✅ Test the target environment
3. ✅ Update any environment-specific configurations if needed

---

**Generated by**: Supabase Migration Utility  
**Tool Version**: 1.0
EOF
    
    log_success "Result summary generated: $result_file"
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
    
    # Step 3: Run diff comparison
    local diff_result
    step_diff_comparison "$source" "$target"
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
    
    # Generate result.md in the actual migration directory
    if [ $exit_code -eq 0 ]; then
        generate_result_md "$actual_migration_dir" "✅ Completed"
        log_success "Migration completed: $actual_migration_dir"
    else
        generate_result_md "$actual_migration_dir" "❌ Failed (check migration.log)"
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
