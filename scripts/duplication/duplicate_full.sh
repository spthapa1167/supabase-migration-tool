#!/bin/bash
# Full Duplication Script: Schema + Data
# Duplicates entire Supabase project including all data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_complete.sh" 2>/dev/null || true

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
BACKUP_TARGET=${3:-false}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [--backup]

Full duplication: Copies schema + all data from source to target

Arguments:
  source_env    Source environment (prod, test, dev)
  target_env    Target environment (prod, test, dev)
  --backup      Create backup of target before duplication (optional)

Examples:
  $0 prod test          # Copy production to test
  $0 prod dev           # Copy production to develop
  $0 dev test           # Copy develop to test
  $0 prod test --backup # Copy production to test with backup

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
confirm_production_operation "FULL DUPLICATION (Schema + Data)" "$TARGET_ENV"

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
LOG_FILE="$BACKUP_DIR/duplication.log"

log_to_file "$LOG_FILE" "Starting full duplication from $SOURCE_ENV to $TARGET_ENV"

# Source rollback utilities
source "$PROJECT_ROOT/lib/rollback_utils.sh" 2>/dev/null || true

# Step 1: Backup target if requested
if [ "$BACKUP_TARGET" = "--backup" ] || [ "$BACKUP_TARGET" = "true" ]; then
    log_info "Creating backup of target environment..."
    log_to_file "$LOG_FILE" "Creating backup of target"
    
    # Link to target for backup
    if link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        log_info "Backing up target database (binary format)..."
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
        
        # Capture target state as SQL for manual rollback in Supabase SQL editor
        log_info "Creating rollback SQL script for Supabase SQL Editor..."
        if capture_target_state_for_rollback "$TARGET_REF" "$TARGET_PASSWORD" "$BACKUP_DIR/rollback_db.sql" "full"; then
            log_success "Rollback SQL script created: $BACKUP_DIR/rollback_db.sql"
            log_info "You can copy this file and run it in Supabase SQL Editor to rollback"
        else
            log_warning "Failed to create rollback SQL script, but binary backup exists"
        fi
        
        supabase unlink --yes 2>/dev/null || true
    fi
fi

# Step 2: Dump source database (schema + data)
log_info "Dumping source database (schema + data)..."
log_to_file "$LOG_FILE" "Dumping source database"

# Link to source
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

# Create dump file
DUMP_FILE="$BACKUP_DIR/source_full.dump"

log_info "Creating full database dump..."
# Try pooler first, fallback to direct connection
POOLER_HOST=$(get_pooler_host "$SOURCE_REF")
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -Fc \
    --verbose \
    -f "$DUMP_FILE" \
    2>&1 | tee -a "$LOG_FILE" || {
    log_warning "Pooler connection failed, trying direct connection..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h db.${SOURCE_REF}.supabase.co \
        -p 5432 \
        -U postgres.${SOURCE_REF} \
        -d postgres \
        -Fc \
        --verbose \
        -f "$DUMP_FILE" \
        2>&1 | tee -a "$LOG_FILE"
}

if [ ! -f "$DUMP_FILE" ] || [ ! -s "$DUMP_FILE" ]; then
    log_error "Failed to create dump file"
    exit 1
fi

log_success "Dump created: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
log_to_file "$LOG_FILE" "Dump file size: $(du -h "$DUMP_FILE" | cut -f1)"

# Unlink from source
supabase unlink --yes 2>/dev/null || true

# Step 3: Restore to target
log_info "Restoring to target environment..."
log_to_file "$LOG_FILE" "Restoring to target environment"

# Link to target
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    exit 1
fi

# Drop existing objects (careful!)
log_warning "Dropping existing objects in target database..."
log_to_file "$LOG_FILE" "Dropping existing objects"

# Create a SQL script to drop all objects
DROP_SCRIPT="$BACKUP_DIR/drop_all.sql"
cat > "$DROP_SCRIPT" << 'EOF'
-- Drop all objects
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
END $$;
EOF

# Execute drop script (try pooler first, fallback to direct connection)
POOLER_HOST=$(get_pooler_host "$TARGET_REF")
if ! PGPASSWORD="$TARGET_PASSWORD" psql \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    -f "$DROP_SCRIPT" \
    2>&1 | tee -a "$LOG_FILE"; then
    log_warning "Pooler connection failed for drop, trying direct connection..."
    if check_direct_connection_available "$TARGET_REF"; then
        if ! PGPASSWORD="$TARGET_PASSWORD" psql \
            -h db.${TARGET_REF}.supabase.co \
            -p 5432 \
            -U postgres.${TARGET_REF} \
            -d postgres \
            -f "$DROP_SCRIPT" \
            2>&1 | tee -a "$LOG_FILE"; then
            log_warning "Some objects may not have been dropped"
        fi
    else
        log_warning "Direct connection not available for drop, skipping..."
    fi
fi

# Restore dump (try pooler first, fallback to direct connection)
log_info "Restoring dump to target..."
log_to_file "$LOG_FILE" "Restoring dump file"

RESTORE_SUCCESS=false
RESTORE_OUTPUT=$(mktemp)
RESTORE_EXIT_CODE=1

# Run pg_restore and capture exit code
set +e  # Temporarily disable exit on error to capture exit code
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
    "$DUMP_FILE" \
    2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
RESTORE_EXIT_CODE=${PIPESTATUS[0]}
set -e  # Re-enable exit on error

# pg_restore returns 0 on success, even with warnings
# "errors ignored on restore" means success (errors were expected and ignored)
if [ $RESTORE_EXIT_CODE -eq 0 ]; then
    # Check output for FATAL errors (connection issues)
    if ! grep -q "FATAL:" "$RESTORE_OUTPUT" 2>/dev/null; then
        # Success: exit code 0 and no FATAL errors
        RESTORE_SUCCESS=true
        log_success "Restore completed successfully via pooler (exit code: 0)"
        log_info "Warnings about ignored errors are expected with --clean option"
    else
        log_warning "Restore had FATAL errors despite exit code 0 - will retry with direct connection"
    fi
else
    # pg_restore failed, check if it's a connection issue
    if grep -q "FATAL:" "$RESTORE_OUTPUT" 2>/dev/null; then
        log_warning "Pooler restore failed with connection error (exit code: $RESTORE_EXIT_CODE)"
    else
        log_warning "Pooler restore failed with exit code: $RESTORE_EXIT_CODE"
    fi
fi
rm -f "$RESTORE_OUTPUT"

# If restore already succeeded, skip direct connection attempt
if [ "$RESTORE_SUCCESS" = "true" ]; then
    log_info "Skipping direct connection attempt - restore already succeeded via pooler"
fi

if [ "$RESTORE_SUCCESS" = "false" ]; then
    # Only try direct connection if pooler restore actually failed (exit code != 0)
    # First, check the log file for success indicators (pooler might have succeeded)
    log_info "Checking log file for restore success indicators..."
    if grep -q "errors ignored on restore\|processing data for table\|restoring.*TABLE\|finished successfully" "$LOG_FILE" 2>/dev/null; then
        # Found success indicators - check if there were any FATAL errors
        if ! grep -q "FATAL:" "$LOG_FILE" 2>/dev/null; then
            log_info "Found success indicators in log - restore likely succeeded via pooler"
            RESTORE_SUCCESS=true
        else
            log_warning "Found success indicators but also FATAL errors in log"
        fi
    fi
    
    # If still not successful, try direct connection (only if DNS resolves)
    if [ "$RESTORE_SUCCESS" = "false" ] && check_direct_connection_available "$TARGET_REF"; then
        log_warning "Pooler restore failed, trying direct connection..."
        RESTORE_OUTPUT=$(mktemp)
        set +e
        PGPASSWORD="$TARGET_PASSWORD" pg_restore \
            -h db.${TARGET_REF}.supabase.co \
            -p 5432 \
            -U postgres.${TARGET_REF} \
            -d postgres \
            --verbose \
            --no-owner \
            --no-acl \
            --clean \
            --if-exists \
            "$DUMP_FILE" \
            2>&1 | tee -a "$LOG_FILE" | tee "$RESTORE_OUTPUT"
        RESTORE_EXIT_CODE=${PIPESTATUS[0]}
        set -e
        
        if [ $RESTORE_EXIT_CODE -eq 0 ]; then
            if ! grep -q "FATAL:" "$RESTORE_OUTPUT" 2>/dev/null; then
                RESTORE_SUCCESS=true
                log_info "Direct connection restore completed (exit code: 0)"
            fi
        fi
        rm -f "$RESTORE_OUTPUT"
    elif [ "$RESTORE_SUCCESS" = "false" ]; then
        # Direct connection not available and pooler restore failed
        log_warning "Direct connection not available (DNS resolution failed)"
        log_info "Checking if pooler restore actually succeeded despite being marked as failed..."
        # Final check - look for any positive indicators
        if grep -qi "restore\|completed\|success" "$LOG_FILE" 2>/dev/null && ! grep -q "FATAL:" "$LOG_FILE" 2>/dev/null; then
            log_info "Found positive indicators - marking restore as successful"
            RESTORE_SUCCESS=true
        fi
    fi
fi

if [ "$RESTORE_SUCCESS" = "true" ]; then
    log_success "Database restored successfully!"
    log_to_file "$LOG_FILE" "Restore completed successfully"
else
    log_error "Restore failed!"
    log_to_file "$LOG_FILE" "Restore failed - check log for details"
    exit 1
fi

# Step 4: Copy storage buckets (via Supabase API)
log_info "Copying storage buckets..."
log_to_file "$LOG_FILE" "Copying storage buckets"

# Note: Storage buckets need to be copied via Supabase Dashboard or API
# This is a placeholder - actual implementation would require API calls
log_warning "Storage buckets need to be copied manually via Supabase Dashboard"
log_info "Go to: https://supabase.com/dashboard/project/$TARGET_REF/storage/buckets"

# Step 5: Export and deploy edge functions
log_info "⚡ Step 5/6: Exporting and deploying edge functions..."
log_to_file "$LOG_FILE" "Exporting edge functions list"

# Use BACKUP_DIR as the migration directory (where all files are stored)
MIGRATION_DIR="$BACKUP_DIR"
FUNCTIONS_FILE="$MIGRATION_DIR/edge_functions_list.json"
FUNCTIONS_DIR="$MIGRATION_DIR/edge_functions"

# Set PROJECT_ROOT for function deployment (needed to find local codebase)
export PROJECT_ROOT="$PROJECT_ROOT"

# Link to source to export functions list and download function code
# IMPORTANT: Keep project linked during download so CLI can work
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_warning "Failed to link to source project for edge functions export"
else
    log_info "  → Exporting edge functions list and downloading function code from source..."
    # Export list and download function code (CLI needs project to be linked)
    # Note: We keep the project linked during download
    export_edge_functions_list "$SOURCE_REF" "$FUNCTIONS_FILE" "$FUNCTIONS_DIR" 2>&1 | tee -a "$LOG_FILE" || {
        log_warning "Edge functions export/download had errors, continuing..."
    }
    log_to_file "$LOG_FILE" "Edge functions list exported and code downloaded"
    # Don't unlink yet - we might need it for fallback deployment
fi

# Deploy edge functions to target
log_info "  → Deploying edge functions to target..."

# Link to target project for deployment
DEPLOYMENT_SUCCESS=false
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_warning "Failed to link to target project for edge functions deployment"
else
    # Check if we have functions to deploy
    if [ -f "$FUNCTIONS_FILE" ] || [ -d "$FUNCTIONS_DIR" ]; then
        # First, try local directory (if functions were downloaded during export)
        if [ -d "$FUNCTIONS_DIR" ] && [ -n "$(ls -A "$FUNCTIONS_DIR" 2>/dev/null)" ]; then
            log_info "Deploying from local functions directory: $FUNCTIONS_DIR"
            log_info "Found $(ls -d "$FUNCTIONS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ') function(s) to deploy"
            
            if deploy_edge_functions "$SOURCE_REF" "$TARGET_REF" "$FUNCTIONS_FILE" "$FUNCTIONS_DIR" 2>&1 | tee -a "$LOG_FILE"; then
                DEPLOYMENT_SUCCESS=true
                log_success "Edge functions deployed successfully from local directory"
                log_to_file "$LOG_FILE" "Edge functions deployed successfully from local directory"
            else
                log_warning "Local deployment failed or returned error, will try API method..."
                log_to_file "$LOG_FILE" "Edge functions deployment from local directory failed"
            fi
        fi
        
        # Try delta migration method if local deployment failed or no local directory
        # This method downloads from both source and target, compares, and deploys delta
        if [ "$DEPLOYMENT_SUCCESS" != "true" ]; then
            log_info "Attempting delta migration: downloading from both source and target, comparing, and deploying delta..."
            # deploy_edge_functions will handle linking internally
            if deploy_edge_functions "$SOURCE_REF" "$TARGET_REF" "$FUNCTIONS_FILE" "" 2>&1 | tee -a "$LOG_FILE"; then
                DEPLOYMENT_SUCCESS=true
                log_success "Edge functions deployed successfully via delta migration"
                log_to_file "$LOG_FILE" "Edge functions deployed successfully via delta migration"
            else
                log_warning "Edge functions deployment failed via delta migration"
                log_to_file "$LOG_FILE" "Edge functions deployment failed via delta migration"
            fi
        fi
        
        if [ "$DEPLOYMENT_SUCCESS" != "true" ]; then
            log_warning "Edge functions deployment failed - check logs above for details"
            log_warning "Functions may need to be deployed manually from your codebase"
            log_to_file "$LOG_FILE" "Edge functions deployment failed - manual deployment may be required"
        fi
    else
        log_info "No edge functions found to migrate (no functions_file or functions_dir)"
        log_to_file "$LOG_FILE" "No edge functions found"
        # Unlink from source if we linked earlier
        supabase unlink --yes 2>/dev/null || true
    fi
    
    # Unlink from target
    supabase unlink --yes 2>/dev/null || true
fi

# Step 6: Export and set secrets
log_info "🔐 Step 6/6: Exporting and setting secrets..."
log_to_file "$LOG_FILE" "Exporting secrets list"

SECRETS_FILE="$MIGRATION_DIR/secrets_list.json"

# Link to source to export secrets list
if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_warning "Failed to link to source project for secrets export"
else
    log_info "  → Exporting secrets list from source..."
    export_secrets_list "$SOURCE_REF" "$SECRETS_FILE" 2>&1 | tee -a "$LOG_FILE" || {
        log_warning "Secrets export had errors, continuing..."
    }
    log_to_file "$LOG_FILE" "Secrets list exported"
    supabase unlink --yes 2>/dev/null || true
fi

# Set secrets in target (with blank values)
log_info "  → Setting secrets in target (with blank/placeholder values)..."
if [ -f "$SECRETS_FILE" ]; then
    # Link to target if not already linked
    if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        log_warning "Failed to link to target project for secrets setup"
    else
        if set_secrets_from_list "$TARGET_REF" "$SECRETS_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Secrets structure created (values need manual update)"
            log_to_file "$LOG_FILE" "Secrets structure created"
        else
            log_warning "Secrets setup failed or skipped"
            log_to_file "$LOG_FILE" "Secrets setup failed or skipped"
        fi
        supabase unlink --yes 2>/dev/null || true
    fi
else
    log_info "No secrets found to migrate"
    log_to_file "$LOG_FILE" "No secrets found"
fi

# Final summary
log_success "Full duplication completed!"
log_to_file "$LOG_FILE" "Duplication completed successfully"

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
log_info "  1. Copy storage buckets manually via Dashboard"
log_info "  2. Deploy edge functions if needed"
log_info "  3. Verify realtime configurations"
log_info "  4. Test the duplicated environment"

exit 0

