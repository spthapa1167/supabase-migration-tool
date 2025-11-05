#!/bin/bash
# Generate Diff Files for Migration
# Captures schema state before and after migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 <migration_name> <environment> [--before|--after|--both]

Generates diff files for a migration by capturing schema state.

Arguments:
  migration_name    Name or pattern of the migration
  environment       Source environment (prod, test, dev)
  --before          Capture schema before migration (default)
  --after           Capture schema after migration
  --both            Capture both before and after

Examples:
  $0 add_user_table prod --before
  $0 add_user_table prod --after
  $0 add_user_table prod --both

EOF
    exit 1
}

# Parse arguments
MIGRATION_NAME=${1:-}
SOURCE_ENV=${2:-}
DIFF_MODE="before"

if [ -z "$MIGRATION_NAME" ] || [ -z "$SOURCE_ENV" ]; then
    usage
fi

case "${3:-}" in
    --before)
        DIFF_MODE="before"
        ;;
    --after)
        DIFF_MODE="after"
        ;;
    --both)
        DIFF_MODE="both"
        ;;
    "")
        DIFF_MODE="before"
        ;;
    *)
        usage
        ;;
esac

# Load environment
load_env

# Find migration folder
MIGRATION_FOLDER=$(find_migration_folder "$MIGRATION_NAME")

if [ -z "$MIGRATION_FOLDER" ]; then
    log_error "Migration not found: $MIGRATION_NAME"
    exit 1
fi

# Get project details
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")

log_info "Generating diff for: $(basename "$MIGRATION_FOLDER")"
log_info "Source environment: $SOURCE_ENV ($SOURCE_REF)"

# Link to source
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

# Capture schema
POOLER_HOST=$(get_pooler_host "$SOURCE_REF")

if [ "$DIFF_MODE" = "before" ] || [ "$DIFF_MODE" = "both" ]; then
    log_info "Capturing schema state (before)..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${SOURCE_REF} \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "${MIGRATION_FOLDER}/diff_before.sql" \
        2>&1 | head -20
    
    if [ -f "${MIGRATION_FOLDER}/diff_before.sql" ]; then
        log_success "Created diff_before.sql"
    fi
fi

if [ "$DIFF_MODE" = "after" ] || [ "$DIFF_MODE" = "both" ]; then
    log_info "Capturing schema state (after)..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${SOURCE_REF} \
        -d postgres \
        --schema-only \
        --no-owner \
        --no-acl \
        -f "${MIGRATION_FOLDER}/diff_after.sql" \
        2>&1 | head -20
    
    if [ -f "${MIGRATION_FOLDER}/diff_after.sql" ]; then
        log_success "Created diff_after.sql"
    fi
fi

# Unlink
supabase unlink --yes 2>/dev/null || true

log_success "Diff files generated in: $MIGRATION_FOLDER"

exit 0

