#!/bin/bash
# Rollback Utilities Library
# Functions for generating rollback SQL scripts

# Capture target database state as SQL for rollback
# This creates a rollback_db.sql file that can be run in Supabase SQL editor
capture_target_state_for_rollback() {
    local target_ref=$1
    local target_password=$2
    local output_file=$3
    local mode=${4:-"schema"}  # "schema" or "full" (schema+data)
    
    log_info "Capturing target database state for rollback..."
    
    local pooler_host=$(get_pooler_host "$target_ref")
    local temp_output=$(mktemp)
    
    # Create header comment
    cat > "$output_file" << EOF
-- ============================================================================
-- ROLLBACK SQL SCRIPT
-- ============================================================================
-- This script restores the target database to its state BEFORE migration
-- Generated: $(date)
-- Target Project: $target_ref
-- 
-- INSTRUCTIONS:
-- 1. Open Supabase Dashboard -> SQL Editor
-- 2. Select the target project
-- 3. Copy and paste this entire script into the SQL Editor
-- 4. Click "Run" to execute
-- 
-- WARNING: This will DROP and RECREATE all database objects!
-- Make sure you have a backup before running this script.
-- ============================================================================

BEGIN;

-- Disable triggers temporarily during rollback
SET session_replication_role = replica;

EOF

    # Export in plain SQL format (schema + data if full mode)
    set +e
    if [ "$mode" = "full" ]; then
        log_info "Capturing full database state (schema + data) as SQL..."
        PGPASSWORD="$target_password" pg_dump \
            -h "$pooler_host" \
            -p 6543 \
            -U postgres.${target_ref} \
            -d postgres \
            --no-owner \
            --no-acl \
            --clean \
            --if-exists \
            >> "$temp_output" 2>&1 || {
            if check_direct_connection_available "$target_ref"; then
                log_warning "Pooler failed for export, trying direct connection..."
                PGPASSWORD="$target_password" pg_dump \
                    -h db.${target_ref}.supabase.co \
                    -p 5432 \
                    -U postgres.${target_ref} \
                    -d postgres \
                    --no-owner \
                    --no-acl \
                    --clean \
                    --if-exists \
                    >> "$temp_output" 2>&1 || {
                    log_error "Failed to capture target database state"
                    rm -f "$temp_output"
                    return 1
                }
            else
                log_error "Failed to capture target database state"
                rm -f "$temp_output"
                return 1
            fi
        }
    else
        # Schema only
        log_info "Capturing database schema as SQL..."
        PGPASSWORD="$target_password" pg_dump \
            -h "$pooler_host" \
            -p 6543 \
            -U postgres.${target_ref} \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-acl \
            --clean \
            --if-exists \
            >> "$temp_output" 2>&1 || {
            if check_direct_connection_available "$target_ref"; then
                log_warning "Pooler failed for schema export, trying direct connection..."
                PGPASSWORD="$target_password" pg_dump \
                    -h db.${target_ref}.supabase.co \
                    -p 5432 \
                    -U postgres.${target_ref} \
                    -d postgres \
                    --schema-only \
                    --no-owner \
                    --no-acl \
                    --clean \
                    --if-exists \
                    >> "$temp_output" 2>&1 || {
                    log_error "Failed to capture target database state"
                    rm -f "$temp_output"
                    return 1
                }
            else
                log_error "Failed to capture target database state"
                rm -f "$temp_output"
                return 1
            fi
        }
    fi
    set -e
    
    # Append the SQL dump to the output file (keeping all SQL statements)
    cat "$temp_output" >> "$output_file"
    
    # Add footer
    cat >> "$output_file" << 'EOF'

-- Re-enable triggers
SET session_replication_role = DEFAULT;

COMMIT;

-- ============================================================================
-- ROLLBACK COMPLETE
-- ============================================================================
-- The database has been restored to its pre-migration state
-- Verify the results and test your application
-- ============================================================================
EOF
    
    rm -f "$temp_output"
    
    # Check if file was created and has content
    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        log_error "Failed to create rollback SQL file"
        return 1
    fi
    
    log_success "Rollback SQL captured: $output_file ($(du -h "$output_file" | cut -f1))"
    return 0
}

# Generate rollback SQL that drops new objects and restores old ones
# For schema-only migrations, this creates SQL to reverse incremental changes
generate_incremental_rollback_sql() {
    local target_ref=$1
    local target_password=$2
    local backup_dir=$3
    local source_schema_sql="$backup_dir/source_schema_pre_restore.sql"
    
    log_info "Generating incremental rollback SQL..."
    
    # Capture current target state (before migration) if not already captured
    if [ ! -f "$source_schema_sql" ]; then
        log_info "Capturing pre-migration target schema..."
        capture_target_state_for_rollback "$target_ref" "$target_password" "$source_schema_sql" "schema"
    fi
    
    # The rollback SQL is the captured pre-migration state
    # We'll need to drop current state and restore from backup
    local rollback_file="$backup_dir/rollback_db.sql"
    
    cat > "$rollback_file" << EOF
-- ============================================================================
-- ROLLBACK SQL SCRIPT (Incremental Schema Changes)
-- ============================================================================
-- This script restores the target database schema to its pre-migration state
-- Generated: $(date)
-- Target Project: $target_ref
-- 
-- INSTRUCTIONS:
-- 1. Open Supabase Dashboard -> SQL Editor
-- 2. Select the target project
-- 3. Copy and paste this entire script into the SQL Editor
-- 4. Click "Run" to execute
-- 
-- WARNING: This will DROP modified objects and restore previous schema!
-- ============================================================================

BEGIN;

-- Disable triggers temporarily
SET session_replication_role = replica;

-- Note: The pre-migration schema backup is saved in: source_schema_pre_restore.sql
-- For full rollback, you can:
-- 1. Drop all modified objects manually, OR
-- 2. Use pg_restore with target_backup.dump file
-- 
-- This file contains the schema state BEFORE migration was applied.

EOF

    # Append the pre-migration schema
    if [ -f "$source_schema_sql" ]; then
        cat "$source_schema_sql" >> "$rollback_file"
    else
        cat >> "$rollback_file" << 'EOF'
-- ERROR: Pre-migration schema backup not found
-- Please restore from target_backup.dump using pg_restore instead
EOF
    fi
    
    cat >> "$rollback_file" << 'EOF'

-- Re-enable triggers
SET session_replication_role = DEFAULT;

COMMIT;

-- ============================================================================
-- ROLLBACK COMPLETE
-- ============================================================================
EOF

    log_success "Incremental rollback SQL generated: $rollback_file"
    return 0
}
