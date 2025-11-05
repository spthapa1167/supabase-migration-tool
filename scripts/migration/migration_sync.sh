#!/bin/bash
# Sync Migration from Source Environment
# Pulls migration from source and creates organized migration folder

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> [migration_name]

Pulls schema from source environment and creates a new migration.

Arguments:
  source_env       Source environment (prod, test, dev)
  migration_name   Optional name for the migration (default: auto-generated)

Examples:
  $0 prod
  $0 prod "sync_from_production"
  $0 test "update_from_test"

EOF
    exit 1
}

# Parse arguments
SOURCE_ENV=${1:-}
MIGRATION_NAME=${2:-}

if [ -z "$SOURCE_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "prod" "$SOURCE_ENV" 2>/dev/null || true

# Generate migration name if not provided
if [ -z "$MIGRATION_NAME" ]; then
    MIGRATION_NAME="sync_from_${SOURCE_ENV}_$(date +%Y%m%d)"
fi

# Get project details
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")

log_info "Pulling schema from: $SOURCE_ENV ($SOURCE_REF)"
log_info "Creating migration: $MIGRATION_NAME"

# Create migration folder
MIGRATION_PATH=$(create_complete_migration "$MIGRATION_NAME" "Synced from $SOURCE_ENV environment" "" "$SOURCE_ENV")

# Link to source
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

# Capture current schema
POOLER_HOST=$(get_pooler_host "$SOURCE_REF")
MIGRATION_FILE="${MIGRATION_PATH}/migration.sql"

log_info "Capturing current schema..."

PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    --schema-only \
    --no-owner \
    --no-acl \
    -f "$MIGRATION_FILE" \
    2>&1 | head -20

if [ ! -f "$MIGRATION_FILE" ] || [ ! -s "$MIGRATION_FILE" ]; then
    log_error "Failed to capture schema"
    exit 1
fi

# Also save as diff_after
cp "$MIGRATION_FILE" "${MIGRATION_PATH}/diff_after.sql"

log_success "Schema captured and saved to: $MIGRATION_FILE"
log_info "Migration folder: $MIGRATION_PATH"

# Unlink
supabase unlink --yes 2>/dev/null || true

log_info "Next steps:"
echo "  1. Review $MIGRATION_FILE"
echo "  2. Edit if needed"
echo "  3. Create rollback.sql if needed"
echo "  4. Apply to target: ./scripts/migration_apply.sh $MIGRATION_NAME <target_env>"

exit 0

