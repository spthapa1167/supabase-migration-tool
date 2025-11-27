#!/bin/bash
# Storage Buckets Migration Script
# Migrates storage buckets (configuration + files) from source to target
# Can be used independently or as part of a complete migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_report_generator.sh" 2>/dev/null || true

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
MIGRATION_DIR=${3:-""}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [migration_dir] [--include-files|--exclude-files]

Migrates storage buckets (configuration + files) from source to target using delta comparison

Default Behavior:
  By default, migrates ONLY NEW BUCKET NAMES (buckets that exist in source but not in target).
  This is incremental mode - only newly added buckets are created in the target.
  No files are migrated by default.

With --files flag:
  Migrates ALL buckets with their files. Creates missing buckets and transfers all files.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  --file, --files  Include file migration (migrates buckets + files)
  --include-files  Include file migration (same as --file/--files)
  --exclude-files  Exclude file migration (default, migrates bucket config only)
  --increment      Prefer incremental/delta operations (default: enabled)

Examples:
  $0 dev test                          # Migrate only NEW bucket names (incremental - no files)
  $0 dev test --file                   # Migrate ALL buckets with files
  $0 dev test --files                  # Migrate ALL buckets with files (same as --file)
  $0 prod test /path/to/backup         # Migrate only new bucket names with custom backup directory
  $0 prod test /path/to/backup --file  # Custom directory, ALL buckets with files

Returns:
  0 on success, 1 on failure

EOF
    exit 1
}

component_prompt_proceed() {
    local title=$1
    local message=${2:-"Proceed?"}

    if [ "${AUTO_CONFIRM_COMPONENT}" = "true" ] || [ "${SKIP_COMPONENT_CONFIRM}" = "true" ]; then
        return 0
    fi

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  ${title}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "$message"
    read -r -p "Proceed? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    echo ""

    if [ "$response" = "y" ] || [ "$response" = "yes" ]; then
        return 0
    fi
    return 1
}

# Parse arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Default: bucket configuration only (no files)
INCLUDE_FILES="false"
INCREMENTAL_MODE="false"
AUTO_CONFIRM_COMPONENT="${AUTO_CONFIRM:-false}"
SKIP_COMPONENT_CONFIRM="${SKIP_COMPONENT_CONFIRM:-false}"

# Parse arguments for flags
for arg in "$@"; do
    case "$arg" in
        --file|--files)
            INCLUDE_FILES="true"
            ;;
        --include-files)
            INCLUDE_FILES="true"
            ;;
        --exclude-files)
            INCLUDE_FILES="false"
            ;;
        --increment|--incremental)
            INCREMENTAL_MODE="true"
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT="true"
            ;;
    esac
done

# Check if 3rd argument is a flag (instead of migration_dir)
if [ -n "$MIGRATION_DIR" ]; then
    if [ "$MIGRATION_DIR" = "--file" ] || [ "$MIGRATION_DIR" = "--files" ] || [ "$MIGRATION_DIR" = "--include-files" ]; then
        INCLUDE_FILES="true"
        MIGRATION_DIR=""
    elif [ "$MIGRATION_DIR" = "--exclude-files" ]; then
        INCLUDE_FILES="false"
        MIGRATION_DIR=""
    elif [ "$MIGRATION_DIR" = "--increment" ] || [ "$MIGRATION_DIR" = "--incremental" ]; then
        INCREMENTAL_MODE="true"
        MIGRATION_DIR=""
    elif [ "$MIGRATION_DIR" = "--auto-confirm" ] || [ "$MIGRATION_DIR" = "--yes" ] || [ "$MIGRATION_DIR" = "-y" ]; then
        AUTO_CONFIRM_COMPONENT="true"
        MIGRATION_DIR=""
    fi
fi

# Check if 4th argument is a flag
if [ -n "${4:-}" ]; then
    if [ "$4" = "--file" ] || [ "$4" = "--files" ] || [ "$4" = "--include-files" ]; then
        INCLUDE_FILES="true"
    elif [ "$4" = "--exclude-files" ]; then
        INCLUDE_FILES="false"
    elif [ "$4" = "--increment" ] || [ "$4" = "--incremental" ]; then
        INCREMENTAL_MODE="true"
    elif [ "$4" = "--auto-confirm" ] || [ "$4" = "--yes" ] || [ "$4" = "-y" ]; then
        AUTO_CONFIRM_COMPONENT="true"
    fi
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

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="storage"
    MIGRATION_DIR=$(create_backup_dir "storage" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="storage"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting storage buckets migration from $SOURCE_ENV to $TARGET_ENV"

log_info "🗄️  Storage Buckets Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
log_info "Incremental mode: $INCREMENTAL_MODE (storage migration utility performs delta syncs by default)"
echo ""

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    if ! component_prompt_proceed "Storage Buckets Migration" "Proceed with storage bucket migration from $SOURCE_ENV to $TARGET_ENV?"; then
        log_warning "Storage buckets migration skipped by user request."
        log_to_file "$LOG_FILE" "Storage buckets migration skipped by user."
        exit 0
    fi
fi

# Check for Node.js and storage migration utility
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js not found - please install Node.js to use storage migration"
    log_error "Install from: https://nodejs.org/"
    exit 1
fi

STORAGE_UTIL="$PROJECT_ROOT/utils/storage-migration.js"
if [ ! -f "$STORAGE_UTIL" ]; then
    log_error "Storage migration utility not found: $STORAGE_UTIL"
    exit 1
fi

# Get environment-specific access tokens
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

# Check for access tokens (at least one should be set)
if [ -z "$SOURCE_ACCESS_TOKEN" ] && [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access tokens not set for source ($SOURCE_ENV) or target ($TARGET_ENV) environments"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and/or SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN are set in .env.local"
    exit 1
fi

# Export for Node.js utility (it will determine which one to use)
export SUPABASE_ACCESS_TOKEN="${SOURCE_ACCESS_TOKEN:-$TARGET_ACCESS_TOKEN}"

# Migrate buckets with delta comparison and file migration using Node.js utility
# Default behavior: Only migrate NEW bucket names (incremental - buckets that exist in source but not in target)
# With --files: Migrate ALL buckets with files
if [ "$INCLUDE_FILES" = "true" ]; then
    log_info "Migrating storage buckets (ALL buckets + files)..."
    INCLUDE_FILES_FLAG="--include-files"
else
    log_info "Migrating storage buckets (incremental mode: only NEW bucket names, no files)..."
    INCLUDE_FILES_FLAG="--exclude-files"
fi

MIGRATION_SUCCESS=false
log_info "Running Node.js storage migration utility..."
log_info "  Script: $STORAGE_UTIL"
log_info "  Source: $SOURCE_REF"
log_info "  Target: $TARGET_REF"
log_info "  Files: $INCLUDE_FILES_FLAG"
log_info ""

# Run Node.js utility and capture output
# Use PIPESTATUS to properly capture exit code when using pipes
set +o pipefail  # Temporarily disable pipefail to check exit code manually
if node "$STORAGE_UTIL" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$MIGRATION_DIR" \
    "$INCLUDE_FILES_FLAG" \
    2>&1 | tee -a "$LOG_FILE"; then
    NODE_EXIT_CODE=${PIPESTATUS[0]}
    if [ "$NODE_EXIT_CODE" -eq 0 ]; then
        MIGRATION_SUCCESS=true
        if [ "$INCLUDE_FILES" = "true" ]; then
            COMPONENT_NAME="Storage Migration (Buckets + Files)"
            log_success "✅ Storage buckets migrated successfully (buckets + files)"
        else
            COMPONENT_NAME="Storage Migration (Buckets Only)"
            log_success "✅ Storage buckets migrated successfully (bucket config only)"
        fi
        log_to_file "$LOG_FILE" "Storage buckets migrated successfully"
    else
        MIGRATION_SUCCESS=false
        COMPONENT_NAME="Storage Migration"
        log_error "❌ Storage buckets migration failed - Node.js utility exited with code $NODE_EXIT_CODE"
        log_error "Check the logs above for details"
        log_to_file "$LOG_FILE" "Storage buckets migration failed (exit code: $NODE_EXIT_CODE)"
    fi
else
    NODE_EXIT_CODE=${PIPESTATUS[0]}
    MIGRATION_SUCCESS=false
    COMPONENT_NAME="Storage Migration"
    log_error "❌ Storage buckets migration failed - Node.js utility exited with code $NODE_EXIT_CODE"
    log_error "Check the logs above for details"
    log_to_file "$LOG_FILE" "Storage buckets migration failed (exit code: $NODE_EXIT_CODE)"
fi
set -o pipefail  # Re-enable pipefail

# Generate HTML report
if [ "$MIGRATION_SUCCESS" = "true" ]; then
    STATUS="success"
else
    STATUS="partial"
fi

# Extract migration statistics from log
MIGRATED_COUNT=$(grep -c "✓ Migrated\|✓ Created\|✓ Updated" "$LOG_FILE" 2>/dev/null || echo "0")
SKIPPED_COUNT=$(grep -c "⏭️.*Skipping\|already exists" "$LOG_FILE" 2>/dev/null || echo "0")
FAILED_COUNT=$(grep -c "✗ Failed\|ERROR" "$LOG_FILE" 2>/dev/null || echo "0")
REMOVED_COUNT=$(grep -c "✓ Removed\|✓ Deleted" "$LOG_FILE" 2>/dev/null || echo "0")

# Generate details section
DETAILS_SECTION=$(format_migration_details "$LOG_FILE" "storage")

# Generate HTML report
export MIGRATED_COUNT SKIPPED_COUNT FAILED_COUNT REMOVED_COUNT DETAILS_SECTION
generate_migration_html_report \
    "$MIGRATION_DIR" \
    "$COMPONENT_NAME" \
    "$SOURCE_ENV" \
    "$TARGET_ENV" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$STATUS" \
    ""

log_info "HTML report generated: $MIGRATION_DIR/result.html"

if [ "$MIGRATION_SUCCESS" = "true" ]; then
    echo "$MIGRATION_DIR"  # Return migration directory for use by other scripts
    exit 0
else
    exit 1
fi

