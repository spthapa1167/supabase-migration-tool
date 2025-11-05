#!/bin/bash
# Create New Migration with Complete Structure
# Creates a new migration folder with all related files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 <migration_name> [description] [--author <author>] [--env <environment>]

Creates a new migration folder with complete structure:
  - migration.sql (forward migration)
  - rollback.sql (rollback script)
  - diff_before.sql (schema before)
  - diff_after.sql (schema after)
  - metadata.json (migration metadata)
  - README.md (documentation)

Arguments:
  migration_name    Name of the migration (e.g., "add_user_table")
  description       Optional description of the migration
  --author          Author name (default: git config user.name)
  --env             Environment this migration targets (prod, test, dev)

Examples:
  $0 add_user_table "Add user management tables"
  $0 update_schema "Update user schema" --author "John Doe" --env prod
  $0 create_indexes "Add performance indexes"

EOF
    exit 1
}

# Parse arguments
MIGRATION_NAME=${1:-}
DESCRIPTION=${2:-}
AUTHOR=""
ENVIRONMENT=""

if [ -z "$MIGRATION_NAME" ]; then
    usage
fi

# Parse optional arguments
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --author)
            AUTHOR="$2"
            shift 2
            ;;
        --env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ -z "$DESCRIPTION" ]; then
                DESCRIPTION="$1"
            fi
            shift
            ;;
    esac
done

# Validate migration name (alphanumeric and underscores only)
if ! [[ "$MIGRATION_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    log_error "Migration name must contain only alphanumeric characters and underscores"
    exit 1
fi

log_info "Creating new migration: $MIGRATION_NAME"

# Create complete migration structure
MIGRATION_PATH=$(create_complete_migration "$MIGRATION_NAME" "$DESCRIPTION" "$AUTHOR" "$ENVIRONMENT")

echo ""
log_success "Migration created successfully!"
echo ""
log_info "Migration folder: $MIGRATION_PATH"
log_info "Files created:"
echo "  - migration.sql     (edit this file with your migration SQL)"
echo "  - rollback.sql     (edit this file with rollback SQL)"
echo "  - diff_before.sql  (schema state before migration)"
echo "  - diff_after.sql    (schema state after migration)"
echo "  - metadata.json    (migration metadata)"
echo "  - README.md        (documentation)"
echo ""
log_info "Next steps:"
echo "  1. Edit $MIGRATION_PATH/migration.sql with your SQL"
echo "  2. Edit $MIGRATION_PATH/rollback.sql with rollback SQL"
echo "  3. Run migration: ./scripts/migration_apply.sh $MIGRATION_NAME"

exit 0

