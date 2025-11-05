#!/bin/bash
# Rollback Migration from Environment
# Rolls back a migration from the specified environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 <migration_name> <environment> [--dry-run]

Rolls back a migration from the specified environment.

Arguments:
  migration_name    Name or pattern of the migration to rollback
  environment       Target environment (prod, test, dev)
  --dry-run         Show what would be executed without rolling back

Examples:
  $0 add_user_table prod
  $0 add_user_table test --dry-run

EOF
    exit 1
}

# Parse arguments
MIGRATION_NAME=${1:-}
TARGET_ENV=${2:-}
DRY_RUN=false

if [ -z "$MIGRATION_NAME" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

if [ "${3:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Load environment
load_env
validate_environments "prod" "$TARGET_ENV" 2>/dev/null || true

# Safety check for production
confirm_production_operation "ROLLBACK MIGRATION" "$TARGET_ENV"

# Find migration folder
MIGRATION_FOLDER=$(find_migration_folder "$MIGRATION_NAME")

if [ -z "$MIGRATION_FOLDER" ]; then
    log_error "Migration not found: $MIGRATION_NAME"
    exit 1
fi

ROLLBACK_FILE="${MIGRATION_FOLDER}/rollback.sql"

if [ ! -f "$ROLLBACK_FILE" ]; then
    log_error "Rollback file not found: $ROLLBACK_FILE"
    log_info "Create rollback.sql in the migration folder first"
    exit 1
fi

# Check if rollback file is empty or contains only comments
if ! grep -q -v '^[[:space:]]*--\|^[[:space:]]*$' "$ROLLBACK_FILE"; then
    log_warning "Rollback file appears to be empty or contains only comments"
    log_info "Please edit $ROLLBACK_FILE with rollback SQL statements"
    exit 1
fi

# Get project details
TARGET_REF=$(get_project_ref "$TARGET_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

log_info "Rolling back migration: $(basename "$MIGRATION_FOLDER")"
log_info "Target environment: $TARGET_ENV ($TARGET_REF)"

# Link to target
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    exit 1
fi

# Create backup
BACKUP_DIR=$(create_backup_dir)
LOG_FILE="$BACKUP_DIR/migration_rollback.log"

log_info "Creating backup before rollback..."
POOLER_HOST=$(get_pooler_host "$TARGET_REF")
PGPASSWORD="$TARGET_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -Fc \
    -f "$BACKUP_DIR/pre_rollback_backup.dump" \
    2>&1 | tee -a "$LOG_FILE" || log_warning "Backup may have failed"

# Show rollback content
echo ""
log_info "Rollback SQL:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$ROLLBACK_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY RUN - Rollback not applied"
    log_info "Remove --dry-run flag to apply rollback"
    exit 0
fi

# Apply rollback
log_info "Applying rollback..."
log_to_file "$LOG_FILE" "Rolling back migration: $MIGRATION_FOLDER from $TARGET_ENV"

PGPASSWORD="$TARGET_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -f "$ROLLBACK_FILE" \
    2>&1 | tee -a "$LOG_FILE"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_success "Rollback applied successfully!"
    update_migration_status "$MIGRATION_FOLDER" "rolled_back_${TARGET_ENV}"
    log_to_file "$LOG_FILE" "Rollback applied successfully"
else
    log_error "Rollback failed!"
    log_to_file "$LOG_FILE" "Rollback failed with exit code ${PIPESTATUS[0]}"
    exit 1
fi

# Unlink
supabase unlink --yes 2>/dev/null || true

log_info "Backup saved: $BACKUP_DIR/pre_rollback_backup.dump"
log_info "Log file: $LOG_FILE"

exit 0

