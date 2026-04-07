#!/bin/bash
# Policy Migration Complete
# Standalone script to copy all RLS policies from source to target.
# Usage: ./scripts/policy_migration_complete.sh <source_env> <target_env>
# Example: ./scripts/policy_migration_complete.sh dev test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat << EOF
Usage: $0 <source_env> <target_env>

Migrates all RLS policies from source to target database. Use when policy counts
differ after a schema migration (e.g. source 498, target 455).

Arguments:
  source_env   Source environment (e.g. dev, test, prod)
  target_env   Target environment (e.g. test, prod)

Requires .env.local with SUPABASE_<ENV>_PROJECT_REF and SUPABASE_<ENV>_DB_PASSWORD.

Example:
  $0 dev test

EOF
    exit 0
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ $# -lt 2 ]; then
    log_error "Missing arguments."
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2

# Load env and resolve refs/passwords/pooler
load_env 2>/dev/null || true

SOURCE_REF=$(get_project_ref "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_REF=$(get_project_ref "$TARGET_ENV" 2>/dev/null || echo "")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV" 2>/dev/null || echo "")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV" 2>/dev/null || echo "")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV" 2>/dev/null || echo "")

if [ -z "$SOURCE_REF" ]; then
    log_error "Source project reference not found for environment: $SOURCE_ENV"
    log_error "Set SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF in .env.local"
    exit 1
fi
if [ -z "$TARGET_REF" ]; then
    log_error "Target project reference not found for environment: $TARGET_ENV"
    log_error "Set SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF in .env.local"
    exit 1
fi
if [ -z "$SOURCE_PASSWORD" ]; then
    log_error "Source database password not found for environment: $SOURCE_ENV"
    exit 1
fi
if [ -z "$TARGET_PASSWORD" ]; then
    log_error "Target database password not found for environment: $TARGET_ENV"
    exit 1
fi

# Work directory and log
WORK_DIR=$(create_backup_dir "policy" "$SOURCE_ENV" "$TARGET_ENV")
WORK_DIR_ABS="$(cd "$WORK_DIR" && pwd)"
LOG_FILE="$WORK_DIR_ABS/migration.log"
mkdir -p "$WORK_DIR_ABS"

log_info "Policy migration: $SOURCE_ENV -> $TARGET_ENV"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Work directory: $WORK_DIR_ABS"
log_to_file "$LOG_FILE" "Policy migration started: $SOURCE_ENV -> $TARGET_ENV"

# Policy count query (same as database_and_policy_migration.sh)
COUNT_POLICIES_QUERY="SELECT COUNT(*) FROM pg_policies WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor');"

SOURCE_DB_POLICY_COUNT=$(run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$COUNT_POLICIES_QUERY" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
TARGET_DB_POLICY_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$COUNT_POLICIES_QUERY" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
[ -z "$SOURCE_DB_POLICY_COUNT" ] || ! [[ "$SOURCE_DB_POLICY_COUNT" =~ ^[0-9]+$ ]] && SOURCE_DB_POLICY_COUNT=0
[ -z "$TARGET_DB_POLICY_COUNT" ] || ! [[ "$TARGET_DB_POLICY_COUNT" =~ ^[0-9]+$ ]] && TARGET_DB_POLICY_COUNT=0

log_info "Policy counts before sync: source=$SOURCE_DB_POLICY_COUNT, target=$TARGET_DB_POLICY_COUNT"

if [ "$SOURCE_DB_POLICY_COUNT" -eq 0 ]; then
    log_info "Source has no policies to migrate. Exiting."
    log_to_file "$LOG_FILE" "No policies on source - exit 0"
    exit 0
fi

# Extract policies from source (use query from generate_missing_policies_sql.sh: REPLACE newlines, ORDER BY quote_ident(rol.rolname))
EXTRACT_POLICIES_QUERY="SELECT 'CREATE POLICY ' || quote_ident(pol.polname) || ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' FOR ' || CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' WHEN '*' THEN 'ALL' END || CASE WHEN array_length(pol.polroles, 1) > 0 AND (pol.polroles != ARRAY[0]::oid[]) THEN ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY quote_ident(rol.rolname)) WHEN (pol.polroles = ARRAY[0]::oid[] OR array_length(pol.polroles, 1) IS NULL) THEN ' TO public' ELSE '' END || CASE WHEN pol.polqual IS NOT NULL THEN ' USING (' || REPLACE(pg_get_expr(pol.polqual, pol.polrelid), E'\n', ' ') || ')' ELSE '' END || CASE WHEN pol.polwithcheck IS NOT NULL THEN ' WITH CHECK (' || REPLACE(pg_get_expr(pol.polwithcheck, pol.polrelid), E'\n', ' ') || ')' ELSE '' END || ';' FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles) WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT IN ('auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor') GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, pol.polqual, pol.polrelid, pol.polwithcheck, pol.polroles ORDER BY n.nspname, c.relname, pol.polname;"

POLICIES_FROM_DB="$WORK_DIR_ABS/policies_from_source_db.sql"
run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$EXTRACT_POLICIES_QUERY" > "$POLICIES_FROM_DB" 2>/dev/null || true

if [ ! -s "$POLICIES_FROM_DB" ]; then
    log_warning "Could not extract policies from source DB (empty file or query failed)"
    log_to_file "$LOG_FILE" "WARNING: Could not extract policies from source DB"
else
    SYNC_POLICY_COUNT=$(grep -c "^CREATE POLICY" "$POLICIES_FROM_DB" 2>/dev/null || echo "0")
    SYNC_POLICY_COUNT=$(echo "$SYNC_POLICY_COUNT" | head -1 | tr -d '[:space:]')
    [ -z "$SYNC_POLICY_COUNT" ] || ! [[ "$SYNC_POLICY_COUNT" =~ ^[0-9]+$ ]] && SYNC_POLICY_COUNT=0

    if [ "$SYNC_POLICY_COUNT" -gt 0 ]; then
        log_to_file "$LOG_FILE" "Policy sync: extracting from source DB and applying to target"

        # Enable RLS on target tables (from source list)
        ENABLE_RLS_QUERY="SELECT DISTINCT 'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' ENABLE ROW LEVEL SECURITY;' FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT IN ('auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor') AND c.relkind = 'r' ORDER BY 1;"
        ENABLE_RLS_FILE="$WORK_DIR_ABS/enable_rls_target.sql"
        run_psql_query_with_fallback "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$ENABLE_RLS_QUERY" > "$ENABLE_RLS_FILE" 2>/dev/null || true
        if [ -s "$ENABLE_RLS_FILE" ]; then
            RLS_BATCH_SIZE=50
            rls_batch_file="$WORK_DIR_ABS/enable_rls_batch.sql"
            log_info "Enabling RLS on target tables (batches of $RLS_BATCH_SIZE)..."
            set +e
            rls_batch=0
            > "$rls_batch_file"
            while IFS= read -r rls_line; do
                [ -z "$rls_line" ] || [[ ! "$rls_line" =~ ALTER\ TABLE ]] && continue
                echo "$rls_line" >> "$rls_batch_file"
                rls_batch=$((rls_batch + 1))
                if [ "$rls_batch" -ge "$RLS_BATCH_SIZE" ]; then
                    run_psql_script_with_fallback "Enable RLS batch" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$rls_batch_file" || true
                    > "$rls_batch_file"
                    rls_batch=0
                fi
            done < "$ENABLE_RLS_FILE"
            [ -s "$rls_batch_file" ] && run_psql_script_with_fallback "Enable RLS batch (final)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$rls_batch_file" || true
            rm -f "$rls_batch_file"
            set -e
        fi

        # Drop existing target policies in batches
        DROP_TARGET_POLICIES_QUERY="SELECT 'DROP POLICY IF EXISTS ' || quote_ident(pol.polname) || ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';'
            FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT IN ('auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor')
            ORDER BY n.nspname, c.relname, pol.polname;"
        DROP_POLICIES_FILE="$WORK_DIR_ABS/drop_target_policies_sync.sql"
        run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$DROP_TARGET_POLICIES_QUERY" > "$DROP_POLICIES_FILE" 2>/dev/null || true
        if [ -s "$DROP_POLICIES_FILE" ]; then
            drop_count=$(grep -c "^DROP POLICY" "$DROP_POLICIES_FILE" 2>/dev/null || echo "0")
            DROP_BATCH_SIZE=100
            drop_batch_file="$WORK_DIR_ABS/drop_policies_batch.sql"
            log_info "Dropping existing target policies (batches of $DROP_BATCH_SIZE, $drop_count total)..."
            set +e
            drop_batch=0
            > "$drop_batch_file"
            while IFS= read -r drop_line; do
                [ -z "$drop_line" ] || [[ ! "$drop_line" =~ ^DROP\ POLICY ]] && continue
                echo "$drop_line" >> "$drop_batch_file"
                drop_batch=$((drop_batch + 1))
                if [ "$drop_batch" -ge "$DROP_BATCH_SIZE" ]; then
                    run_psql_script_with_fallback "Drop policy batch" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$drop_batch_file" || true
                    > "$drop_batch_file"
                    drop_batch=0
                fi
            done < "$DROP_POLICIES_FILE"
            [ -s "$drop_batch_file" ] && run_psql_script_with_fallback "Drop policy batch (final)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$drop_batch_file" || true
            rm -f "$drop_batch_file"
            set -e
        fi

        # Apply CREATE POLICY from source in batches; fallback one-by-one; retry failed up to 3 times
        log_info "Applying $SYNC_POLICY_COUNT policies (batches of 40, up to 3 retries for failures)..."
        SYNC_APPLIED=0
        SYNC_FAILED=0
        SYNC_FAILED_FILE="$WORK_DIR_ABS/policy_sync_failed.sql"
        POLICY_SYNC_BATCH_SIZE=40
        policy_sync_batch_file="$WORK_DIR_ABS/policy_sync_batch.sql"
        > "$SYNC_FAILED_FILE"
        set +e
        batch_count=0
        > "$policy_sync_batch_file"
        while IFS= read -r policy_line; do
            policy_line=$(echo "$policy_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$policy_line" ] || [[ ! "$policy_line" =~ ^CREATE\ POLICY ]] && continue
            echo "$policy_line" >> "$policy_sync_batch_file"
            batch_count=$((batch_count + 1))
            if [ "$batch_count" -ge "$POLICY_SYNC_BATCH_SIZE" ]; then
                if run_psql_script_with_fallback "Policy sync batch" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$policy_sync_batch_file"; then
                    SYNC_APPLIED=$((SYNC_APPLIED + batch_count))
                else
                    while IFS= read -r pl; do
                        [ -z "$pl" ] || [[ ! "$pl" =~ ^CREATE\ POLICY ]] && continue
                        if run_psql_command_with_fallback "Policy sync" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$pl"; then
                            SYNC_APPLIED=$((SYNC_APPLIED + 1))
                        else
                            SYNC_FAILED=$((SYNC_FAILED + 1))
                            echo "$pl" >> "$SYNC_FAILED_FILE"
                        fi
                    done < "$policy_sync_batch_file"
                fi
                > "$policy_sync_batch_file"
                batch_count=0
            fi
        done < "$POLICIES_FROM_DB"
        if [ -s "$policy_sync_batch_file" ]; then
            if run_psql_script_with_fallback "Policy sync batch (final)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$policy_sync_batch_file"; then
                SYNC_APPLIED=$((SYNC_APPLIED + batch_count))
            else
                while IFS= read -r pl; do
                    [ -z "$pl" ] || [[ ! "$pl" =~ ^CREATE\ POLICY ]] && continue
                    if run_psql_command_with_fallback "Policy sync" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$pl"; then
                        SYNC_APPLIED=$((SYNC_APPLIED + 1))
                    else
                        SYNC_FAILED=$((SYNC_FAILED + 1))
                        echo "$pl" >> "$SYNC_FAILED_FILE"
                    fi
                done < "$policy_sync_batch_file"
            fi
        fi
        rm -f "$policy_sync_batch_file"
        set -e

        # Retry failed policies up to 2 more times (3 attempts total)
        for retry_pass in 1 2; do
            if [ "$SYNC_FAILED" -gt 0 ] && [ -s "$SYNC_FAILED_FILE" ]; then
                log_info "Retry pass $((retry_pass + 1))/3: retrying $SYNC_FAILED failed policy(ies)..."
                SYNC_FAILED_NEW="$WORK_DIR_ABS/policy_sync_failed_new.sql"
                > "$SYNC_FAILED_NEW"
                RETRY_APPLIED=0
                while IFS= read -r policy_line; do
                    [ -z "$policy_line" ] || [[ ! "$policy_line" =~ ^CREATE\ POLICY ]] && continue
                    if run_psql_command_with_fallback "Policy sync retry" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$policy_line"; then
                        SYNC_APPLIED=$((SYNC_APPLIED + 1))
                        RETRY_APPLIED=$((RETRY_APPLIED + 1))
                        SYNC_FAILED=$((SYNC_FAILED - 1))
                    else
                        echo "$policy_line" >> "$SYNC_FAILED_NEW"
                    fi
                done < "$SYNC_FAILED_FILE"
                mv "$SYNC_FAILED_NEW" "$SYNC_FAILED_FILE"
                [ "$RETRY_APPLIED" -gt 0 ] && log_success "  Retry applied $RETRY_APPLIED policy(ies)"
            fi
        done
        SYNC_FAILED=$(grep -c "^CREATE POLICY" "$SYNC_FAILED_FILE" 2>/dev/null || echo "0")
        [ -z "$SYNC_FAILED" ] || ! [[ "$SYNC_FAILED" =~ ^[0-9]+$ ]] && SYNC_FAILED=0
        if [ "$SYNC_APPLIED" -gt 0 ]; then
            log_success "Policy sync: applied $SYNC_APPLIED policies from source DB"
            log_to_file "$LOG_FILE" "Policy sync: applied $SYNC_APPLIED policies from source DB"
        fi
        if [ "$SYNC_FAILED" -gt 0 ]; then
            log_warning "Policy sync: $SYNC_FAILED policy(ies) could not be applied - see $SYNC_FAILED_FILE"
            log_to_file "$LOG_FILE" "WARNING: $SYNC_FAILED policies could not be applied - see $SYNC_FAILED_FILE"
        fi
    else
        log_warning "Extracted policy file has no CREATE POLICY lines"
        log_to_file "$LOG_FILE" "WARNING: Policy extraction produced no policies"
    fi
fi

# Re-count target after sync
TARGET_DB_POLICY_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$COUNT_POLICIES_QUERY" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
[ -z "$TARGET_DB_POLICY_COUNT" ] || ! [[ "$TARGET_DB_POLICY_COUNT" =~ ^[0-9]+$ ]] && TARGET_DB_POLICY_COUNT=0
log_info "Policy count after sync: source=$SOURCE_DB_POLICY_COUNT, target=$TARGET_DB_POLICY_COUNT"

# Delta loop: generate missing policies SQL and apply up to 3 passes
DELTA_MAX_PASSES=3
delta_pass=0
while [ "$TARGET_DB_POLICY_COUNT" -lt "$SOURCE_DB_POLICY_COUNT" ] && [ "$delta_pass" -lt "$DELTA_MAX_PASSES" ]; do
    delta_pass=$((delta_pass + 1))
    log_info "Policy gap: $((SOURCE_DB_POLICY_COUNT - TARGET_DB_POLICY_COUNT)) missing. Delta pass $delta_pass/$DELTA_MAX_PASSES..."
    log_to_file "$LOG_FILE" "Policy gap: delta pass $delta_pass"
    APPLY_MISSING_AUTO="$WORK_DIR_ABS/apply_missing_policies_auto.sql"
    if [ -x "$PROJECT_ROOT/scripts/generate_missing_policies_sql.sh" ]; then
        if "$PROJECT_ROOT/scripts/generate_missing_policies_sql.sh" "$SOURCE_ENV" "$TARGET_ENV" "$APPLY_MISSING_AUTO" "$WORK_DIR_ABS" >>"$LOG_FILE" 2>&1; then
            if [ -s "$APPLY_MISSING_AUTO" ] && grep -q "^CREATE POLICY" "$APPLY_MISSING_AUTO" 2>/dev/null; then
                auto_count=$(grep -c "^CREATE POLICY" "$APPLY_MISSING_AUTO" 2>/dev/null || echo "0")
                log_info "Applying $auto_count delta policy(ies) to target..."
                set +e
                if run_psql_script_with_fallback "Policy delta (auto)" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$APPLY_MISSING_AUTO"; then
                    log_success "Delta policies applied to target"
                    log_to_file "$LOG_FILE" "Delta policies applied successfully"
                else
                    log_warning "Some delta policy statements may have failed (check log)"
                    log_to_file "$LOG_FILE" "WARNING: Some delta policies may have failed"
                fi
                set -e
            fi
        fi
    else
        log_warning "generate_missing_policies_sql.sh not found or not executable"
        break
    fi
    TARGET_DB_POLICY_COUNT=$(run_psql_query_with_fallback "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$COUNT_POLICIES_QUERY" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
    [ -z "$TARGET_DB_POLICY_COUNT" ] || ! [[ "$TARGET_DB_POLICY_COUNT" =~ ^[0-9]+$ ]] && TARGET_DB_POLICY_COUNT=0
    log_info "Policy count after delta pass $delta_pass: source=$SOURCE_DB_POLICY_COUNT, target=$TARGET_DB_POLICY_COUNT"
done

# If gap remains, generate manual SQL and exit 1
if [ "$TARGET_DB_POLICY_COUNT" -lt "$SOURCE_DB_POLICY_COUNT" ]; then
    REMAINING_GAP=$((SOURCE_DB_POLICY_COUNT - TARGET_DB_POLICY_COUNT))
    APPLY_MISSING_MANUAL="$WORK_DIR_ABS/apply_missing_policies_manual_${SOURCE_ENV}_to_${TARGET_ENV}.sql"
    log_warning "Policy gap remains: $REMAINING_GAP policy(ies) still missing on target."
    if [ -x "$PROJECT_ROOT/scripts/generate_missing_policies_sql.sh" ]; then
        if "$PROJECT_ROOT/scripts/generate_missing_policies_sql.sh" "$SOURCE_ENV" "$TARGET_ENV" "$APPLY_MISSING_MANUAL" "$WORK_DIR_ABS" >>"$LOG_FILE" 2>&1; then
            if [ -s "$APPLY_MISSING_MANUAL" ]; then
                manual_count=$(grep -c "^CREATE POLICY" "$APPLY_MISSING_MANUAL" 2>/dev/null || echo "0")
                log_warning "Run the following SQL file in Supabase SQL Editor (target project) to apply remaining $manual_count policy(ies):"
                log_warning "  $APPLY_MISSING_MANUAL"
                log_to_file "$LOG_FILE" "Manual policy file generated: $APPLY_MISSING_MANUAL (run in Supabase console)"
            fi
        fi
    fi
    log_info "Log file: $LOG_FILE"
    exit 1
fi

log_success "Policy migration complete: source=$SOURCE_DB_POLICY_COUNT, target=$TARGET_DB_POLICY_COUNT"
log_to_file "$LOG_FILE" "Policy migration completed successfully"
exit 0
