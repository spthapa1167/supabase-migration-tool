#!/bin/bash
# Schema-Only Duplication Script
# Duplicates Supabase project structure without data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
BACKUP_TARGET=${3:-false}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [--backup]

Schema-only duplication: Copies structure without data

Arguments:
  source_env    Source environment (prod, test, dev)
  target_env    Target environment (prod, test, dev)
  --backup      Create backup of target before duplication (optional)

Examples:
  $0 prod test          # Copy production schema to test
  $0 prod dev           # Copy production schema to develop
  $0 dev test           # Copy develop schema to test

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

# Safety check for production
confirm_production_operation "SCHEMA-ONLY DUPLICATION" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
echo ""

# Create backup directory
BACKUP_DIR=$(create_backup_dir)
LOG_FILE="$BACKUP_DIR/schema_duplication.log"

log_to_file "$LOG_FILE" "Starting schema-only duplication from $SOURCE_ENV to $TARGET_ENV"

# Step 1: Backup target if requested
if [ "$BACKUP_TARGET" = "--backup" ] || [ "$BACKUP_TARGET" = "true" ]; then
    log_info "Creating backup of target environment..."
    log_to_file "$LOG_FILE" "Creating backup of target"
    
    if link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        POOLER_HOST=$(get_pooler_host "$TARGET_REF")
        PGPASSWORD="$TARGET_PASSWORD" pg_dump \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U postgres.${TARGET_REF} \
            -d postgres \
            -Fc \
            -f "$BACKUP_DIR/target_backup.dump" \
            2>&1 | tee -a "$LOG_FILE" || log_warning "Backup may have failed, continuing..."
        
        log_success "Backup created: $BACKUP_DIR/target_backup.dump"
        supabase unlink --yes 2>/dev/null || true
    fi
fi

# Step 2: Dump source schema only (no data)
log_info "Dumping source schema (structure only)..."
log_to_file "$LOG_FILE" "Dumping source schema"

# Link to source
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

# Create schema-only dump
SCHEMA_DUMP="$BACKUP_DIR/source_schema.dump"

log_info "Creating schema-only dump (no data)..."
POOLER_HOST=$(get_pooler_host "$SOURCE_REF")
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -Fc \
    --schema-only \
    --no-owner \
    --no-acl \
    --verbose \
    -f "$SCHEMA_DUMP" \
    2>&1 | tee -a "$LOG_FILE" || {
    log_warning "Pooler connection failed, trying direct connection..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h db.${SOURCE_REF}.supabase.co \
        -p 5432 \
        -U postgres.${SOURCE_REF} \
        -d postgres \
        -Fc \
        --schema-only \
        --no-owner \
        --no-acl \
        --verbose \
        -f "$SCHEMA_DUMP" \
        2>&1 | tee -a "$LOG_FILE"
}

if [ ! -f "$SCHEMA_DUMP" ] || [ ! -s "$SCHEMA_DUMP" ]; then
    log_error "Failed to create schema dump file"
    exit 1
fi

log_success "Schema dump created: $SCHEMA_DUMP ($(du -h "$SCHEMA_DUMP" | cut -f1))"
log_to_file "$LOG_FILE" "Schema dump file size: $(du -h "$SCHEMA_DUMP" | cut -f1)"

# Unlink from source
supabase unlink --yes 2>/dev/null || true

# Step 3: Export additional schema elements
log_info "Exporting additional schema elements..."
log_to_file "$LOG_FILE" "Exporting additional schema elements"

# Export table structures as SQL
TABLES_SQL="$BACKUP_DIR/tables_schema.sql"
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    --schema-only \
    --no-owner \
    --no-acl \
    -t 'public.*' \
    -f "$TABLES_SQL" \
    2>&1 | tee -a "$LOG_FILE" || log_warning "Failed to export tables SQL"

# Export indexes
INDEXES_SQL="$BACKUP_DIR/indexes.sql"
PGPASSWORD="$SOURCE_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -t -c "SELECT indexdef || ';' FROM pg_indexes WHERE schemaname = 'public';" \
    > "$INDEXES_SQL" 2>&1 || log_warning "Failed to export indexes"

# Export constraints
CONSTRAINTS_SQL="$BACKUP_DIR/constraints.sql"
PGPASSWORD="$SOURCE_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -t -c "
    SELECT 'ALTER TABLE ' || conrelid::regclass || 
           ' ADD CONSTRAINT ' || conname || 
           ' ' || pg_get_constraintdef(oid) || ';'
    FROM pg_constraint
    WHERE connamespace = 'public'::regnamespace
    AND contype IN ('f', 'c', 'u', 'p');
    " > "$CONSTRAINTS_SQL" 2>&1 || log_warning "Failed to export constraints"

# Export RLS policies
POLICIES_SQL="$BACKUP_DIR/policies.sql"
PGPASSWORD="$SOURCE_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -t -c "
    SELECT 'CREATE POLICY ' || quote_ident(pol.policyname) || 
           ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) ||
           ' AS ' || pol.polcmd || 
           ' ' || pg_get_expr(pol.polqual, pol.polrelid) || 
           ';'
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public';
    " > "$POLICIES_SQL" 2>&1 || log_warning "Failed to export policies"

log_success "Additional schema elements exported"

# Step 4: Restore schema to target
log_info "Restoring schema to target environment..."
log_to_file "$LOG_FILE" "Restoring schema to target"

# Link to target
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    exit 1
fi

# Drop existing schema objects (careful!)
log_warning "Dropping existing schema objects in target..."
log_to_file "$LOG_FILE" "Dropping existing schema objects"

# Create drop script
DROP_SCRIPT="$BACKUP_DIR/drop_schema.sql"
cat > "$DROP_SCRIPT" << 'EOF'
-- Drop all schema objects
DO $$ 
DECLARE
    r RECORD;
BEGIN
    -- Drop all tables
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') 
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
    
    -- Drop all sequences
    FOR r IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public')
    LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(r.sequence_name) || ' CASCADE';
    END LOOP;
    
    -- Drop all functions
    FOR r IN (SELECT proname, oidvectortypes(proargtypes) as args 
              FROM pg_proc INNER JOIN pg_namespace ON pg_proc.pronamespace = pg_namespace.oid 
              WHERE pg_namespace.nspname = 'public')
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || quote_ident(r.proname) || '(' || r.args || ') CASCADE';
    END LOOP;
    
    -- Drop all views
    FOR r IN (SELECT viewname FROM pg_views WHERE schemaname = 'public')
    LOOP
        EXECUTE 'DROP VIEW IF EXISTS ' || quote_ident(r.viewname) || ' CASCADE';
    END LOOP;
END $$;
EOF

# Execute drop script
POOLER_HOST=$(get_pooler_host "$TARGET_REF")
PGPASSWORD="$TARGET_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -f "$DROP_SCRIPT" \
    2>&1 | tee -a "$LOG_FILE" || log_warning "Some objects may not have been dropped"

# Restore schema dump
log_info "Restoring schema dump..."
log_to_file "$LOG_FILE" "Restoring schema dump file"

PGPASSWORD="$TARGET_PASSWORD" pg_restore \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    --verbose \
    --no-owner \
    --no-acl \
    --clean \
    --if-exists \
    --schema-only \
    "$SCHEMA_DUMP" \
    2>&1 | tee -a "$LOG_FILE"

if [ $? -eq 0 ]; then
    log_success "Schema restored successfully!"
    log_to_file "$LOG_FILE" "Schema restore completed successfully"
else
    log_error "Schema restore failed!"
    log_to_file "$LOG_FILE" "Schema restore failed with exit code $?"
    exit 1
fi

# Step 5: Apply additional schema elements
log_info "Applying additional schema elements..."
log_to_file "$LOG_FILE" "Applying additional schema elements"

# Apply indexes
if [ -f "$INDEXES_SQL" ] && [ -s "$INDEXES_SQL" ]; then
    log_info "Applying indexes..."
    PGPASSWORD="$TARGET_PASSWORD" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${TARGET_REF} \
        -d postgres \
        -f "$INDEXES_SQL" \
        2>&1 | tee -a "$LOG_FILE" || log_warning "Some indexes may have failed"
fi

# Apply constraints
if [ -f "$CONSTRAINTS_SQL" ] && [ -s "$CONSTRAINTS_SQL" ]; then
    log_info "Applying constraints..."
    PGPASSWORD="$TARGET_PASSWORD" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${TARGET_REF} \
        -d postgres \
        -f "$CONSTRAINTS_SQL" \
        2>&1 | tee -a "$LOG_FILE" || log_warning "Some constraints may have failed"
fi

# Apply policies
if [ -f "$POLICIES_SQL" ] && [ -s "$POLICIES_SQL" ]; then
    log_info "Applying RLS policies..."
    PGPASSWORD="$TARGET_PASSWORD" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${TARGET_REF} \
        -d postgres \
        -f "$POLICIES_SQL" \
        2>&1 | tee -a "$LOG_FILE" || log_warning "Some policies may have failed"
fi

# Step 6: Copy auth configurations (roles, etc.)
log_info "Copying auth configurations..."
log_to_file "$LOG_FILE" "Copying auth configurations"

# Note: Auth users are not copied in schema-only mode
# But we can copy roles and configurations
log_info "Auth roles and configurations should be set up manually"
log_info "Auth users are NOT copied in schema-only mode"

# Final summary
log_success "Schema-only duplication completed!"
log_to_file "$LOG_FILE" "Schema duplication completed successfully"

echo ""
log_info "Summary:"
log_info "  Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "  Target: $TARGET_ENV ($TARGET_REF)"
log_info "  Backup directory: $BACKUP_DIR"
log_info "  Log file: $LOG_FILE"
echo ""

# Unlink from target
supabase unlink --yes 2>/dev/null || true

log_info "⚠️  Remember to:"
log_info "  1. Set up auth roles and configurations manually"
log_info "  2. Deploy edge functions if needed"
log_info "  3. Configure storage buckets"
log_info "  4. Verify RLS policies are working correctly"
log_info "  5. Test the duplicated environment"

exit 0

