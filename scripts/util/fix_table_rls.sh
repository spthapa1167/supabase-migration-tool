#!/bin/bash
# Quick Fix Script for Table RLS Issues
# Re-applies RLS policies, functions, and grants for a specific table

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> <schema_name> <table_name>

Quick fix for RLS policy issues on a specific table by:
  1. Re-applying security-definer functions
  2. Re-applying all database functions
  3. Re-applying RLS policies for the table
  4. Re-applying grants

Arguments:
  source_env   Source environment (prod, test, dev, backup)
  target_env   Target environment (prod, test, dev, backup)
  schema_name  Schema name (e.g., public)
  table_name   Table name to fix

Example:
  $0 dev prod public setting_categories
EOF
    exit 1
}

if [ $# -lt 4 ]; then
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2
SCHEMA_NAME=$3
TABLE_NAME=$4

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

TABLE_IDENTIFIER="${SCHEMA_NAME}.${TABLE_NAME}"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Quick Fix: RLS Policies for $TABLE_IDENTIFIER"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
echo ""

# Use the single table migration script which handles everything
log_info "Running comprehensive single table migration..."
if [ -f "$PROJECT_ROOT/scripts/components/single_table_migration.sh" ]; then
    "$PROJECT_ROOT/scripts/components/single_table_migration.sh" \
        "$SOURCE_ENV" "$TARGET_ENV" "$SCHEMA_NAME" "$TABLE_NAME" \
        --auto-confirm
else
    log_error "single_table_migration.sh not found"
    exit 1
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "✓ RLS fix completed for $TABLE_IDENTIFIER"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0

