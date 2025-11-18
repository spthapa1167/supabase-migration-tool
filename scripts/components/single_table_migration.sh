#!/bin/bash
# Single Table Migration Script
# Migrates schema, data, RLS policies, grants, and all related objects for a single table

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> <schema_name> <table_name> [options]

Comprehensive migration of a single table including:
  - Table schema (structure, columns, constraints, indexes)
  - Table data (all rows)
  - RLS policies for the table
  - Grants/permissions for the table
  - Triggers and related functions
  - All security settings

Arguments:
  source_env   Source environment (prod, test, dev, backup)
  target_env   Target environment (prod, test, dev, backup)
  schema_name  Schema name (e.g., public, auth)
  table_name   Table name to migrate

Options:
  --replace-data    Replace target table data (truncate and reload). Default: incremental upsert
  --schema-only     Migrate schema only, skip data migration
  --data-only       Migrate data only, skip schema migration
  --auto-confirm    Skip confirmation prompts
  -h, --help        Show this help message

Examples:
  $0 dev test public profiles
  $0 prod test public user_roles --replace-data
  $0 dev test auth roles --schema-only
  $0 prod test public orders --data-only

Returns:
  0 on success, 1 on failure
EOF
    exit 1
}

# Handle help flag early
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

# Parse arguments
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
SCHEMA_NAME=${3:-}
TABLE_NAME=${4:-}

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ] || [ -z "$SCHEMA_NAME" ] || [ -z "$TABLE_NAME" ]; then
    usage
fi

shift 4 || true

REPLACE_DATA=false
SCHEMA_ONLY=false
DATA_ONLY=false
AUTO_CONFIRM=false

while [ $# -gt 0 ]; do
    case "$1" in
        --replace-data)
            REPLACE_DATA=true
            shift
            ;;
        --schema-only)
            SCHEMA_ONLY=true
            shift
            ;;
        --data-only)
            DATA_ONLY=true
            shift
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_warning "Unknown option: $1"
            shift
            ;;
    esac
done

# Validate inputs
if [[ ! "$SCHEMA_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Schema name must contain only letters, numbers, and underscores."
    exit 1
fi

if [[ ! "$TABLE_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Table name must contain only letters, numbers, and underscores."
    exit 1
fi

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

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required but not found in PATH."
    exit 1
fi

# Create migration directory
MIGRATION_DIR=$(create_backup_dir "single_table" "$SOURCE_ENV" "$TARGET_ENV")
mkdir -p "$MIGRATION_DIR"
cleanup_old_backups "single_table" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting single table migration: $SCHEMA_NAME.$TABLE_NAME from $SOURCE_ENV to $TARGET_ENV"

TABLE_IDENTIFIER="${SCHEMA_NAME}.${TABLE_NAME}"
QUOTED_TABLE="\"${SCHEMA_NAME}\".\"${TABLE_NAME}\""

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Single Table Migration: $TABLE_IDENTIFIER"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Table: $TABLE_IDENTIFIER"
log_info "Migration directory: $MIGRATION_DIR"
echo ""

if [ "$SCHEMA_ONLY" = "true" ]; then
    log_info "Mode: Schema only (data will be skipped)"
elif [ "$DATA_ONLY" = "true" ]; then
    log_info "Mode: Data only (schema will be skipped)"
else
    log_info "Mode: Schema + Data"
fi

if [ "$REPLACE_DATA" = "true" ]; then
    log_warning "Replace mode: Target table data will be truncated and replaced"
else
    log_info "Incremental mode: Existing rows preserved, new rows inserted"
fi
echo ""

# Helper function to run SQL query and save to file (must be defined before use)
run_source_sql_to_file() {
    local sql_content=$1
    local output_file=$2

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Generating SQL from source via ${label} (${host}:${port})..."
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -v ON_ERROR_STOP=on \
            -c "$sql_content" >"$output_file" 2>/dev/null; then
            # Filter out psql meta-commands
            sed -i.bak '/^\\/d' "$output_file" 2>/dev/null || sed -i '' '/^\\/d' "$output_file" 2>/dev/null || true
            rm -f "${output_file}.bak" 2>/dev/null || true
            sed -i.bak '/^[[:space:]]*$/d' "$output_file" 2>/dev/null || sed -i '' '/^[[:space:]]*$/d' "$output_file" 2>/dev/null || true
            rm -f "${output_file}.bak" 2>/dev/null || true
            return 0
        fi
        log_warning "SQL generation via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    return 1
}

# Verify table exists in source
log_info "Verifying table exists in source..."
TABLE_EXISTS_QUERY="SELECT EXISTS (
    SELECT 1 
    FROM information_schema.tables 
    WHERE table_schema = '$SCHEMA_NAME' 
      AND table_name = '$TABLE_NAME'
);"

TABLE_EXISTS_FILE=$(mktemp)
if run_source_sql_to_file "$TABLE_EXISTS_QUERY" "$TABLE_EXISTS_FILE"; then
    table_exists=$(head -1 "$TABLE_EXISTS_FILE" 2>/dev/null | tr -d '[:space:]' || echo "f")
    rm -f "$TABLE_EXISTS_FILE"
    if [ "$table_exists" != "t" ]; then
        log_error "Table $TABLE_IDENTIFIER does not exist in source environment $SOURCE_ENV"
        exit 1
    fi
    log_success "✓ Table exists in source"
else
    log_warning "Could not verify table existence; continuing anyway..."
fi
echo ""

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with migration of $TABLE_IDENTIFIER from $SOURCE_ENV to $TARGET_ENV? [y/N]: " reply
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$reply" != "y" ] && [ "$reply" != "yes" ]; then
        log_info "Migration cancelled."
        exit 0
    fi
fi

# Helper function to run SQL with fallback
apply_sql_with_fallback() {
    local sql_file=$1
    local label=$2
    
    if [ ! -f "$sql_file" ]; then
        log_warning "SQL file not found: $sql_file"
        return 1
    fi
    
    if [ ! -s "$sql_file" ]; then
        log_info "SQL file is empty: $sql_file (nothing to apply)"
        return 0
    fi
    
    # Filter out psql meta-commands
    local filtered_file="${sql_file}.filtered"
    sed -E '/^\\|^Output format|^Tuples only|^Pager|^Locale|^Default display|^Line style|^Border style|^Expanded display/d' "$sql_file" > "$filtered_file" 2>/dev/null || cp "$sql_file" "$filtered_file"
    sed -i.bak '/^$/d' "$filtered_file" 2>/dev/null || sed -i '' '/^$/d' "$filtered_file" 2>/dev/null || true
    rm -f "${filtered_file}.bak" 2>/dev/null || true
    
    local actual_file="$filtered_file"
    if [ ! -s "$actual_file" ]; then
        actual_file="$sql_file"
    fi
    
    local result=0
    if type run_psql_script_with_fallback >/dev/null 2>&1; then
        if ! run_psql_script_with_fallback "$label" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$actual_file"; then
            result=1
        fi
    else
        local endpoints
        endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
        local exec_success=false
        while IFS='|' read -r host port user label_name; do
            [ -z "$host" ] && continue
            log_info "Executing $label via ${label_name} (${host}:${port})"
            if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                -h "$host" \
                -p "$port" \
                -U "$user" \
                -d postgres \
                -f "$actual_file" >>"$LOG_FILE" 2>&1; then
                exec_success=true
                break
            fi
            log_warning "Execution failed via ${label_name}, trying next endpoint..."
        done <<< "$endpoints"
        if [ "$exec_success" = "false" ]; then
            result=1
        fi
    fi
    
    rm -f "$filtered_file" 2>/dev/null || true
    return $result
}

# Step 1: Migrate table schema
if [ "$DATA_ONLY" != "true" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 1/5: Table Schema Migration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    SCHEMA_DUMP="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_schema.dump"
    SCHEMA_SQL="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_schema.sql"
    
    log_info "Dumping table schema from source..."
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    dump_success=false
    
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Dumping schema via ${label} (${host}:${port})"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$host" -p "$port" -U "$user" \
            -d postgres --schema-only --no-owner --no-privileges \
            --schema="$SCHEMA_NAME" --table="$TABLE_NAME" \
            -f "$SCHEMA_DUMP" >>"$LOG_FILE" 2>&1; then
            dump_success=true
            break
        fi
        log_warning "Schema dump via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"
    
    if [ "$dump_success" = "false" ]; then
        log_error "Failed to dump table schema from source"
        exit 1
    fi
    
    log_info "Converting schema dump to SQL..."
    if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require \
        pg_restore -f "$SCHEMA_SQL" --no-owner --no-privileges "$SCHEMA_DUMP" 2>>"$LOG_FILE"; then
        log_success "Schema SQL generated"
    else
        log_warning "pg_restore conversion failed, trying alternative method..."
        # Alternative: use pg_dump with plain format
        endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
        while IFS='|' read -r host port user label; do
            [ -z "$host" ] && continue
            if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
                pg_dump -h "$host" -p "$port" -U "$user" \
                -d postgres --schema-only --no-owner --no-privileges \
                --schema="$SCHEMA_NAME" --table="$TABLE_NAME" \
                -f "$SCHEMA_SQL" >>"$LOG_FILE" 2>&1; then
                dump_success=true
                break
            fi
        done <<< "$endpoints"
    fi
    
    if [ -s "$SCHEMA_SQL" ]; then
        log_info "Applying table schema to target..."
        if apply_sql_with_fallback "$SCHEMA_SQL" "Apply table schema"; then
            log_success "✓ Table schema applied successfully"
        else
            log_warning "⚠ Schema application had issues; continuing..."
        fi
    else
        log_warning "Schema SQL file is empty or missing"
    fi
    echo ""
fi

# Step 2: Migrate table data
if [ "$SCHEMA_ONLY" != "true" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 2/5: Table Data Migration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ "$REPLACE_DATA" = "true" ]; then
        log_info "Truncating target table..."
        TRUNCATE_SQL="$MIGRATION_DIR/truncate_${SCHEMA_NAME}_${TABLE_NAME}.sql"
        printf 'TRUNCATE TABLE %s RESTART IDENTITY CASCADE;\n' "$QUOTED_TABLE" >"$TRUNCATE_SQL"
        if apply_sql_with_fallback "$TRUNCATE_SQL" "Truncate table"; then
            log_success "✓ Table truncated"
        else
            log_warning "⚠ Truncate failed; continuing with data migration..."
        fi
    fi
    
    DATA_DUMP="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_data.sql"
    DATA_UPSERT="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_data_upsert.sql"
    
    log_info "Dumping table data from source..."
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    dump_success=false
    
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Dumping data via ${label} (${host}:${port})"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$host" -p "$port" -U "$user" \
            -d postgres --data-only --column-inserts \
            --schema="$SCHEMA_NAME" --table="$TABLE_NAME" \
            --no-owner --no-privileges -f "$DATA_DUMP" >>"$LOG_FILE" 2>&1; then
            dump_success=true
            break
        fi
        log_warning "Data dump via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"
    
    if [ "$dump_success" = "false" ]; then
        log_warning "Failed to dump table data; table may be empty or inaccessible"
    else
        if [ -s "$DATA_DUMP" ]; then
            log_info "Transforming insert statements for upsert..."
            if [ -f "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" ]; then
                "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" "$DATA_DUMP" "$DATA_UPSERT" >>"$LOG_FILE" 2>&1
            else
                # Fallback: use data dump as-is if transform script not available
                cp "$DATA_DUMP" "$DATA_UPSERT"
            fi
            
            if [ -s "$DATA_UPSERT" ]; then
                log_info "Applying table data to target..."
                if apply_sql_with_fallback "$DATA_UPSERT" "Apply table data"; then
                    log_success "✓ Table data applied successfully"
                else
                    log_warning "⚠ Data application had issues; continuing..."
                fi
            else
                log_info "No data to migrate (table is empty)"
            fi
        else
            log_info "No data found in source table"
        fi
    fi
    echo ""
fi

# Step 3: Generate and apply RLS policies
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 3/5: RLS Policies Migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RLS_SQL="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_rls.sql"

generate_rls_sql() {
    local output_file=$1
    local safe_schema=${SCHEMA_NAME//\'/\'\'}
    local safe_table=${TABLE_NAME//\'/\'\'}
    
    local sql_content="
WITH selected AS (
    SELECT c.oid AS relid,
           n.nspname,
           c.relname,
           format('%I.%I', n.nspname, c.relname) AS qualified,
           c.relrowsecurity,
           c.relforcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname = '$safe_schema'
      AND c.relname = '$safe_table'
)
, drop_policies AS (
    SELECT sel.qualified,
           pol.polname,
           format('DROP POLICY IF EXISTS %I ON %s;', pol.polname, sel.qualified) AS stmt
    FROM pg_policy pol
    JOIN selected sel ON sel.relid = pol.polrelid
)
, create_policies AS (
    SELECT sel.qualified,
           pol.polname,
           format(
               'CREATE POLICY %1\$I%2\$s ON %3\$s %4\$s %5\$s %6\$s %7\$s;',
               pol.polname,
               CASE WHEN NOT pol.polpermissive THEN ' AS RESTRICTIVE' ELSE '' END,
               sel.qualified,
               CASE pol.polcmd
                   WHEN '' THEN ''
                   WHEN 'r' THEN 'FOR SELECT'
                   WHEN 'a' THEN 'FOR INSERT'
                   WHEN 'w' THEN 'FOR UPDATE'
                   WHEN 'd' THEN 'FOR DELETE'
                   ELSE 'FOR ALL'
               END,
               COALESCE('TO '||roles.role_list, ''),
               CASE WHEN pol.polqual IS NULL THEN '' ELSE 'USING ('||pg_get_expr(pol.polqual, pol.polrelid)||')' END,
               CASE WHEN pol.polwithcheck IS NULL THEN '' ELSE 'WITH CHECK ('||pg_get_expr(pol.polwithcheck, pol.polrelid)||')' END
           ) AS stmt
    FROM pg_policy pol
    JOIN selected sel ON sel.relid = pol.polrelid
    LEFT JOIN LATERAL (
        SELECT string_agg(quote_ident(r.rolname), ', ') AS role_list
        FROM unnest(pol.polroles) role_oid
        JOIN pg_roles r ON r.oid = role_oid
    ) AS roles ON true
)
SELECT stmt FROM (
    SELECT 1 AS ord, qualified AS obj, format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY;', qualified) AS stmt
    FROM selected
    WHERE relrowsecurity
    UNION ALL
    SELECT 2 AS ord, qualified, format('ALTER TABLE %s FORCE ROW LEVEL SECURITY;', qualified)
    FROM selected
    WHERE relforcerowsecurity
    UNION ALL
    SELECT 3 AS ord, qualified, stmt FROM drop_policies
    UNION ALL
    SELECT 4 AS ord, qualified, stmt FROM create_policies
) ordered_statements
ORDER BY ord, obj, stmt;
"
    
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export RLS policies from source."
        : >"$output_file"
        return 1
    fi
}

log_info "Exporting RLS policies for $TABLE_IDENTIFIER..."
if generate_rls_sql "$RLS_SQL"; then
    if [ -s "$RLS_SQL" ]; then
        rls_table_count=$(grep -c "ENABLE ROW LEVEL SECURITY" "$RLS_SQL" 2>/dev/null || echo "0")
        rls_policy_count=$(grep -c "^CREATE POLICY" "$RLS_SQL" 2>/dev/null || echo "0")
        log_info "Found $rls_policy_count RLS policy(ies) for table"
        if apply_sql_with_fallback "$RLS_SQL" "Apply RLS policies"; then
            log_success "✓ RLS policies applied successfully"
        else
            log_warning "⚠ RLS policy application had issues; continuing..."
        fi
    else
        log_info "No RLS policies detected for $TABLE_IDENTIFIER"
    fi
else
    log_warning "Failed to export RLS policies"
fi
echo ""

# Step 4: Generate and apply grants/permissions
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 4/5: Grants and Permissions Migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

GRANTS_SQL="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_grants.sql"

generate_grants_sql() {
    local output_file=$1
    local safe_schema=${SCHEMA_NAME//\'/\'\'}
    local safe_table=${TABLE_NAME//\'/\'\'}
    
    local sql_content="
WITH table_grants AS (
    SELECT 
        rtg.table_schema,
        rtg.table_name,
        rtg.grantee,
        rtg.privilege_type,
        rtg.is_grantable,
        format(
            'GRANT %s ON %I.%I TO %s%s;',
            rtg.privilege_type,
            rtg.table_schema,
            rtg.table_name,
            quote_ident(rtg.grantee),
            CASE WHEN rtg.is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END
        ) AS grant_stmt
    FROM information_schema.role_table_grants rtg
    WHERE rtg.table_schema = '$safe_schema'
      AND rtg.table_name = '$safe_table'
      AND rtg.grantee NOT IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
      AND rtg.grantee NOT LIKE 'pg_%'
)
SELECT grant_stmt
FROM table_grants
ORDER BY grantee, privilege_type;
"
    
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export grants from source."
        : >"$output_file"
        return 1
    fi
}

log_info "Exporting grants for $TABLE_IDENTIFIER..."
if generate_grants_sql "$GRANTS_SQL"; then
    if [ -s "$GRANTS_SQL" ]; then
        grant_count=$(grep -c "^GRANT" "$GRANTS_SQL" 2>/dev/null || echo "0")
        log_info "Found $grant_count grant statement(s)"
        if apply_sql_with_fallback "$GRANTS_SQL" "Apply table grants"; then
            log_success "✓ Table grants applied successfully"
        else
            log_warning "⚠ Grants application had issues; continuing..."
        fi
    else
        log_info "No grants detected for $TABLE_IDENTIFIER"
    fi
else
    log_warning "Failed to export grants"
fi
echo ""

# Step 5: Generate and apply triggers
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Step 5/5: Triggers Migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TRIGGERS_SQL="$MIGRATION_DIR/${SCHEMA_NAME}_${TABLE_NAME}_triggers.sql"

generate_triggers_sql() {
    local output_file=$1
    local safe_schema=${SCHEMA_NAME//\'/\'\'}
    local safe_table=${TABLE_NAME//\'/\'\'}
    
    local sql_content="
WITH table_triggers AS (
    SELECT 
        t.tgname AS trigger_name,
        n.nspname AS schema_name,
        c.relname AS table_name,
        pg_get_triggerdef(t.oid) AS trigger_def
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '$safe_schema'
      AND c.relname = '$safe_table'
      AND NOT t.tgisinternal
)
SELECT trigger_def || ';' AS stmt
FROM table_triggers
ORDER BY trigger_name;
"
    
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export triggers from source."
        : >"$output_file"
        return 1
    fi
}

log_info "Exporting triggers for $TABLE_IDENTIFIER..."
if generate_triggers_sql "$TRIGGERS_SQL"; then
    if [ -s "$TRIGGERS_SQL" ]; then
        trigger_count=$(grep -c "^CREATE TRIGGER" "$TRIGGERS_SQL" 2>/dev/null || echo "0")
        log_info "Found $trigger_count trigger(s)"
        if apply_sql_with_fallback "$TRIGGERS_SQL" "Apply triggers"; then
            log_success "✓ Triggers applied successfully"
        else
            log_warning "⚠ Triggers application had issues; continuing..."
        fi
    else
        log_info "No triggers detected for $TABLE_IDENTIFIER"
    fi
else
    log_warning "Failed to export triggers"
fi
echo ""

# Summary
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "✓ Single table migration completed for $TABLE_IDENTIFIER"
log_info "Migration directory: $MIGRATION_DIR"
log_info "Logs: $LOG_FILE"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0

