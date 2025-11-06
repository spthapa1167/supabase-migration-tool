#!/bin/bash
# Edge Functions Migration Script
# Migrates edge functions from source to target using delta comparison
# Uses Node.js utility for edge function migration
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
Usage: $0 <source_env> <target_env> [migration_dir]

Migrates edge functions from source to target using delta comparison

Arguments:
  source_env     Source environment (prod, test, dev)
  target_env     Target environment (prod, test, dev)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)

Examples:
  $0 prod test                          # Migrate edge functions from prod to test
  $0 dev test /path/to/backup           # Migrate with custom backup directory

Returns:
  0 on success, 1 on failure

EOF
    exit 1
}

# Check arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

# Get project references
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="edge_functions"
    MIGRATION_DIR=$(create_backup_dir "edge_functions" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="edge_functions"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting edge functions migration from $SOURCE_ENV to $TARGET_ENV"

log_info "⚡ Edge Functions Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
echo ""

# Check for Node.js
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js not found - please install Node.js to use edge functions migration"
    log_error "Install from: https://nodejs.org/"
    exit 1
fi

# Check for SUPABASE_ACCESS_TOKEN
if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    log_error "SUPABASE_ACCESS_TOKEN not set - cannot use Node.js utility"
    log_error "Please ensure SUPABASE_ACCESS_TOKEN is set in your environment"
    exit 1
fi

# Check if edge-functions-migration.js exists
EDGE_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/edge-functions-migration.js"
if [ ! -f "$EDGE_FUNCTIONS_UTIL" ]; then
    log_error "Edge functions migration utility not found: $EDGE_FUNCTIONS_UTIL"
    exit 1
fi

# Check for Supabase CLI (required for downloading/deploying functions)
if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - please install Supabase CLI"
    log_error "Install from: https://supabase.com/docs/guides/cli/getting-started"
    exit 1
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Using Node.js utility for edge functions migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Running Node.js edge functions migration utility..."
log_info "  Script: $EDGE_FUNCTIONS_UTIL"
log_info "  Source: $SOURCE_REF"
log_info "  Target: $TARGET_REF"
log_info "  Note: Using Supabase Management API and CLI"
log_info ""

# Run Node.js utility and capture output
# Pass: source_ref, target_ref, migration_dir
# Environment variables are loaded from .env.local by the Node.js script
MIGRATION_SUCCESS=false
if node "$EDGE_FUNCTIONS_UTIL" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$MIGRATION_DIR" \
    2>&1 | tee -a "${LOG_FILE:-$MIGRATION_DIR/migration.log}"; then
    MIGRATION_SUCCESS=true
    COMPONENT_NAME="Edge Functions Migration"
    log_success "Edge functions migration completed successfully using Node.js utility"
    log_to_file "$LOG_FILE" "Edge functions migrated successfully"
else
    COMPONENT_NAME="Edge Functions Migration"
    log_error "Node.js utility failed with errors"
    log_error "Check the logs above for details"
    log_to_file "$LOG_FILE" "Edge functions migration had errors"
fi

# Generate HTML report
if [ "$MIGRATION_SUCCESS" = "true" ]; then
    STATUS="success"
else
    STATUS="failed"
fi

# Extract migration statistics from log
MIGRATED_COUNT=$(grep -c "✓ Migrated\|✓ Deployed\|✓ Created" "$LOG_FILE" 2>/dev/null || echo "0")
SKIPPED_COUNT=$(grep -c "⏭️.*Skipping\|already exists\|identical" "$LOG_FILE" 2>/dev/null || echo "0")
FAILED_COUNT=$(grep -c "✗ Failed\|ERROR" "$LOG_FILE" 2>/dev/null || echo "0")
REMOVED_COUNT=$(grep -c "✓ Removed\|✓ Deleted" "$LOG_FILE" 2>/dev/null || echo "0")

# Generate details section
DETAILS_SECTION=$(format_migration_details "$LOG_FILE" "edge_functions")

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



