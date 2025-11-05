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
    
    # Check if checkdiff.sh exists
    if [ ! -f "$PROJECT_ROOT/scripts/utils/checkdiff.sh" ]; then
        log_warning "Diff script not found: scripts/utils/checkdiff.sh"
        log_info "Skipping diff comparison"
        return 0
    fi
    
    log_info "Running diff comparison: $source → $target"
    echo ""
    log_info "This will compare:"
    log_info "  - Database Schema"
    log_info "  - Storage Buckets"
    log_info "  - Realtime Configuration"
    log_info "  - Cron Jobs"
    log_info "  - Edge Functions"
    log_info "  - Secrets"
    echo ""
    
    # Run diff script (capture output)
    local diff_output
    local diff_exit_code
    
    diff_output=$("$PROJECT_ROOT/scripts/utils/checkdiff.sh" "$source" "$target" --env-file "$ENV_FILE" 2>&1)
    diff_exit_code=$?
    
    echo "$diff_output"
    echo ""
    
    # Analyze diff output
    if [ $diff_exit_code -eq 0 ]; then
        log_success "✅ Projects are identical - no differences found"
        echo ""
        log_warning "⚠️  Warning: Source and target are already identical!"
        echo ""
        if ! prompt_proceed "Diff Comparison Complete" "Projects are identical. Do you still want to proceed with migration?"; then
            return 1
        fi
    else
        log_info "⚠️  Differences found between source and target projects"
        echo ""
        log_info "Summary of differences shown above."
        echo ""
        if ! prompt_proceed "Diff Comparison Complete" "Review the differences above. Do you want to proceed with migration?"; then
            return 1
        fi
    fi
    
    return 0
}


# Generate result.md
generate_result_md() {
    local migration_dir=$1
    local status=$2
    
    local result_file="$migration_dir/result.md"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    cat > "$result_file" << EOF
# Migration Result

**Status**: $status  
**Date**: $timestamp  
**Source**: $SOURCE_ENV ($(get_project_ref "$SOURCE_ENV"))  
**Target**: $TARGET_ENV ($(get_project_ref "$TARGET_ENV"))  
**Mode**: $MODE

## Summary

Migration from **$SOURCE_ENV** to **$TARGET_ENV** completed with status: **$status**

## Migration Details

- **Mode**: $MODE ($([ "$MODE" = "full" ] && echo "Schema + Data" || echo "Schema Only"))
- **Backup Created**: $([ "$BACKUP_TARGET" = "true" ] && echo "Yes" || echo "No")
- **Dry Run**: $([ "$DRY_RUN" = "true" ] && echo "Yes" || echo "No")

## Rollback Instructions

If you need to rollback this migration:

### Option 1: Restore from Backup

If a backup was created during migration, you can restore it using:

\`\`\`bash
# Find the backup directory in: $BACKUP_DIR/
# Look for a directory with timestamp matching this migration

# Restore using pg_restore or the rollback script in the migration directory
\`\`\`

### Option 2: Use Rollback Script

If a rollback script was generated:

\`\`\`bash
cd "$migration_dir"
# Review rollback.sql and apply it to the target environment
\`\`\`

### Option 3: Manual Rollback

1. Review the migration files in: \`$migration_dir\`
2. Identify what was changed
3. Manually reverse the changes in the target environment

## Migration Files

- Migration directory: \`$migration_dir\`
- Check the following files for details:
  - \`migration.sql\` - The migration SQL
  - \`rollback.sql\` - Rollback instructions
  - \`metadata.json\` - Migration metadata
  - \`*.log\` - Log files

## Next Steps

1. Verify the migration was successful
2. Test the target environment
3. Update any environment-specific configurations if needed

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
    if ! step_diff_comparison "$source" "$target"; then
        log_error "Diff comparison cancelled by user"
        return 1
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
