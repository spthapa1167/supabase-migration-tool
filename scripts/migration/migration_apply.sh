#!/bin/bash
# Apply Migration to Environment
# Applies a migration to the specified environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 <migration_name> <environment> [--dry-run]

Applies a migration to the specified environment.

Arguments:
  migration_name    Name or pattern of the migration to apply
  environment       Target environment (prod, test, dev)
  --dry-run         Show what would be executed without applying

Examples:
  $0 add_user_table prod
  $0 add_user_table test --dry-run
  $0 initial prod

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
confirm_production_operation "APPLY MIGRATION" "$TARGET_ENV"

# Find migration folder
MIGRATION_FOLDER=$(find_migration_folder "$MIGRATION_NAME")

if [ -z "$MIGRATION_FOLDER" ]; then
    log_error "Migration not found: $MIGRATION_NAME"
    log_info "Available migrations:"
    list_migration_folders | while read folder; do
        echo "  - $(basename "$folder")"
    done
    exit 1
fi

MIGRATION_FILE="${MIGRATION_FOLDER}/migration.sql"

if [ ! -f "$MIGRATION_FILE" ]; then
    log_error "Migration file not found: $MIGRATION_FILE"
    exit 1
fi

# Get project details
TARGET_REF=$(get_project_ref "$TARGET_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

log_info "Applying migration: $(basename "$MIGRATION_FOLDER")"
log_info "Target environment: $TARGET_ENV ($TARGET_REF)"

# Link to target
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    exit 1
fi

# Create backup
BACKUP_DIR=$(create_backup_dir)
LOG_FILE="$BACKUP_DIR/migration_apply.log"

log_info "Creating backup..."
POOLER_HOST=$(get_pooler_host "$TARGET_REF")
PGPASSWORD="$TARGET_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -Fc \
    -f "$BACKUP_DIR/pre_migration_backup.dump" \
    2>&1 | tee -a "$LOG_FILE" || log_warning "Backup may have failed"

# Show migration content
echo ""
log_info "Migration SQL:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$MIGRATION_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY RUN - Migration not applied"
    log_info "Remove --dry-run flag to apply migration"
    exit 0
fi

# Apply migration
log_info "Applying migration..."
log_to_file "$LOG_FILE" "Applying migration: $MIGRATION_FOLDER to $TARGET_ENV"

PGPASSWORD="$TARGET_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -f "$MIGRATION_FILE" \
    2>&1 | tee -a "$LOG_FILE"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_success "Migration applied successfully!"
    update_migration_status "$MIGRATION_FOLDER" "applied_${TARGET_ENV}"
    log_to_file "$LOG_FILE" "Migration applied successfully"
else
    log_error "Migration failed!"
    log_to_file "$LOG_FILE" "Migration failed with exit code ${PIPESTATUS[0]}"
    exit 1
fi

# Unlink
supabase unlink --yes 2>/dev/null || true

log_info "Backup saved: $BACKUP_DIR/pre_migration_backup.dump"
log_info "Log file: $LOG_FILE"

exit 0

