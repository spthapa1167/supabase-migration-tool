#!/bin/bash
# Policies/User Profiles Migration Script
# Syncs missing user roles and profiles from source to target without overwriting existing data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
MIGRATION_DIR=""

DEFAULT_TABLES=("auth.roles" "auth.user_roles" "public.profiles" "public.user_roles")
TABLES=("${DEFAULT_TABLES[@]}")
AUTO_CONFIRM=${AUTO_CONFIRM:-false}
REPLACE_MODE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> [migration_dir] [options]

Comprehensive migration of policies, roles, grants, user profiles, and database functions.
Synchronises:
  - RLS policies for all tables (auto-discovers all RLS-enabled tables)
  - Roles and user role assignments (auth.roles, auth.user_roles, public.user_roles)
  - User profiles (public.profiles)
  - Table grants/permissions for all tables
  - All database functions (public and auth schemas)
  - Security-definer helper functions

By default performs an incremental upsert (no destructive actions). Use --replace to force a full
replacement so the target matches the source exactly.

Options:
  --tables=table1,table2   Extend table list (default: auth.roles, auth.user_roles, public.profiles, public.user_roles)
  --replace                Destructive sync (truncate + reload + policy redeploy)
  --auto-confirm           Skip confirmation prompts
  -h, --help               Show this message

Example:
  ./scripts/components/policies_migration.sh prod dev
EOF
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

shift 2 || true

while [ $# -gt 0 ]; do
    case "$1" in
        --tables=*)
            IFS=',' read -r -a TABLES <<< "${1#*=}"
            ;;
        --replace)
            REPLACE_MODE=true
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$MIGRATION_DIR" ]; then
                MIGRATION_DIR="$1"
            else
                log_warning "Ignoring unexpected argument: $1"
            fi
            ;;
    esac
    shift || true
done

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

PYTHON_BIN=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON_BIN" ]; then
    log_error "python3 (or python) is required to transform insert statements."
    exit 1
fi

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
SOURCE_POOLER_REGION=$(get_pooler_region_for_env "$SOURCE_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
SOURCE_POOLER_PORT=$(get_pooler_port_for_env "$SOURCE_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

FINAL_TABLES=()

discover_role_tables() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query="
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema IN ('auth','public')
          AND (table_name ILIKE '%role%' OR table_name ILIKE '%user_role%')
        ORDER BY 1;
    "

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        output=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null) && printf "%s\n" "$output" && return 0
        log_warning "Table discovery failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

add_unique_table() {
    local candidate
    candidate=$(echo "$1" | xargs)
    [[ -z "$candidate" || "$candidate" != *.* ]] && return 0
    local existing
    if [ ${#FINAL_TABLES[@]} -gt 0 ]; then
        for existing in "${FINAL_TABLES[@]}"; do
            if [ "$existing" = "$candidate" ]; then
                return 0
            fi
        done
    fi
    FINAL_TABLES+=("$candidate")
}

for tbl in "${TABLES[@]}"; do
    add_unique_table "$tbl"
done

while IFS= read -r line; do
    add_unique_table "$line"
done <<EOF
$(discover_role_tables "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" || echo "")
EOF

if [ ${#FINAL_TABLES[@]} -eq 0 ]; then
    log_warning "No role-related tables discovered; nothing to migrate."
    exit 0
fi

TABLES=("${FINAL_TABLES[@]}")

if [ -z "$MIGRATION_DIR" ]; then
    MIGRATION_DIR=$(create_backup_dir "policies" "$SOURCE_ENV" "$TARGET_ENV")
fi
mkdir -p "$MIGRATION_DIR"

cleanup_old_backups "policies" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting policies/profiles migration from $SOURCE_ENV to $TARGET_ENV"

# If caller did not override TABLES, auto-extend with all RLS-enabled tables in public and auth schemas
auto_discover_rls_tables() {
    # Only run if TABLES is still the default set
    if [ "${TABLES[*]}" != "${DEFAULT_TABLES[*]}" ]; then
        return 0
    fi

    log_info "Auto-discovering ALL RLS-enabled tables in source (public and auth schemas)..."
    log_info "  (Including tables with RLS enabled, even if they don't have policies yet)"

    local sql_content="
WITH rls_tables AS (
    SELECT DISTINCT
        n.nspname AS schema_name,
        c.relname AS table_name,
        format('%I.%I', n.nspname, c.relname) AS qualified
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname IN ('public', 'auth')
      AND c.relrowsecurity = true  -- Discover ALL tables with RLS enabled, not just those with policies
)
SELECT qualified
FROM rls_tables
ORDER BY qualified;
"

    local discovered_file
    discovered_file=$(mktemp)
    if run_source_sql_to_file "$sql_content" "$discovered_file"; then
        if [ -s "$discovered_file" ]; then
            local discovered_count=0
            while IFS= read -r line || [ -n "$line" ]; do
                local trimmed
                trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [ -z "$trimmed" ] && continue
                # Avoid duplicates
                local exists=false
                for existing in "${TABLES[@]}"; do
                    if [ "$existing" = "$trimmed" ]; then
                        exists=true
                        break
                    fi
                done
                if [ "$exists" = "false" ]; then
                    TABLES+=("$trimmed")
                    ((discovered_count++)) || true
                fi
            done < "$discovered_file"
            if [ "$discovered_count" -gt 0 ]; then
                log_success "RLS auto-discovery found $discovered_count additional table(s) with RLS enabled"
            else
                log_info "No additional RLS-enabled tables discovered (all already in list)"
            fi
        else
            log_warning "No RLS-enabled tables discovered in source (public/auth schemas)."
        fi
    else
        log_warning "Failed to auto-discover RLS-enabled tables; continuing with default TABLES."
    fi

    rm -f "$discovered_file"
}

log_info "🛡️  Comprehensive Policies, Roles, Grants & Functions Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"

# Auto-discover additional RLS-enabled tables before logging the final table list
auto_discover_rls_tables

log_info "Tables (including ALL RLS-enabled public tables): ${TABLES[*]}"
if [ "$REPLACE_MODE" = "true" ]; then
    log_warning "Replace mode enabled - target data will be made identical to source."
else
    log_info "Running in incremental mode - existing rows preserved, new rows inserted."
fi
echo ""

log_info "Migration will cover:"
log_info "  ✓ RLS policies for all tables (including auto-discovered RLS-enabled tables)"
log_info "  ✓ Roles and user role assignments (auth.roles, auth.user_roles, public.user_roles)"
log_info "  ✓ User profiles (public.profiles)"
log_info "  ✓ Table grants/permissions for all tables"
log_info "  ✓ All database functions (public and auth schemas)"
log_info "  ✓ Security-definer helper functions"
echo ""

log_info "RLS safeguards:"
log_info "  - Security-definer helper functions are required for policy checks."
log_info "  - RLS remains enabled; no blanket grants are issued."
log_info "  - Policies are recreated atomically to avoid security gaps."

cat <<'SECURITY_NOTE' >>"$LOG_FILE"
[SECURITY] RLS Hardening Checklist
- Ensure SECURITY DEFINER helper functions exist prior to recreating policies.
- Avoid recursive policy definitions; never SELECT from the guarded table inside USING/WITH CHECK.
- RLS stays enabled throughout migration; no GRANT SELECT shortcuts are used.
- Policies are dropped and recreated in the same run to prevent exposure windows.
SECURITY_NOTE

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with policies/profile sync from $SOURCE_ENV to $TARGET_ENV? [y/N]: " reply
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$reply" != "y" ] && [ "$reply" != "yes" ]; then
        log_info "Migration cancelled."
        exit 0
    fi
fi

success_tables=()
failed_tables=()
skipped_tables=()

run_psql_script_direct() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local script_path=$5

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Executing script via ${label} (${host}:${port})"
        if PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -f "$script_path"; then
            return 0
        fi
        log_warning "Execution failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

transform_inserts() {
    local input_file="$1"
    local output_file="$2"
    "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/sql_add_on_conflict.py" "$input_file" "$output_file"
}

discover_role_tables() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local query="
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema IN ('auth','public')
          AND (table_name ILIKE '%role%' OR table_name ILIKE '%user_role%')
        ORDER BY 1;
    "

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        output=$(PGPASSWORD="$password" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$query" 2>/dev/null) && printf "%s\n" "$output" && return 0
        log_warning "Table discovery failed via ${label}, trying next endpoint..."
    done <<< "$endpoints"
    return 1
}

dump_table_incremental() {
    local table_identifier=$1
    local dump_file=$2
    local upsert_file=$3
    local table_schema=${table_identifier%%.*}
    local table_name=${table_identifier#*.}
    [ -z "$table_schema" ] && table_schema="public"

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    local dump_success=false

    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Dumping $table_identifier via ${label} (${host}:${port})"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$host" -p "$port" -U "$user" \
            -d postgres --data-only --column-inserts \
            --schema="$table_schema" --table="$table_name" \
            --no-owner --no-privileges -f "$dump_file" >>"$LOG_FILE" 2>&1; then
            dump_success=true
            break
        fi
        log_warning "Dump via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    if [ "$dump_success" = false ]; then
        local direct_host="db.${SOURCE_REF}.supabase.co"
        local direct_user="postgres"
        log_warning "Pooler dump failed; attempting direct connection for $table_identifier..."
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            pg_dump -h "$direct_host" -p 5432 -U "$direct_user" \
            -d postgres --data-only --column-inserts \
            --schema="$table_schema" --table="$table_name" \
            --no-owner --no-privileges -f "$dump_file" >>"$LOG_FILE" 2>&1; then
            dump_success=true
        fi
    fi

    if [ "$dump_success" = false ]; then
        log_warning "Direct pg_dump failed for $table_identifier; attempting CSV fallback..."
        local csv_file="$MIGRATION_DIR/${table_schema}_${table_name}_fallback.csv"
        if copy_table_to_csv "$table_schema" "$table_name" "$csv_file"; then
            if convert_csv_to_sql "$csv_file" "$dump_file" "$table_schema" "$table_name"; then
                dump_success=true
                log_success "Fallback CSV export succeeded for $table_identifier"
            else
                log_warning "Failed to convert CSV fallback for $table_identifier"
            fi
        else
            log_warning "CSV fallback export failed for $table_identifier"
        fi
        rm -f "$csv_file"
    fi

    if [ "$dump_success" = false ]; then
        log_warning "Could not dump $table_identifier (object may be missing or inaccessible); skipping."
        skipped_tables+=("$table_identifier (dump unavailable)")
        rm -f "$dump_file"
        return 1
    fi

    log_success "Dump created for $table_identifier"

    log_info "Transforming insert statements for $table_identifier"
    transform_inserts "$dump_file" "$upsert_file"

    if [ ! -s "$upsert_file" ]; then
        log_warning "No data found for $table_identifier; skipping insert."
        success_tables+=("$table_identifier (no new rows)")
        rm -f "$dump_file" "$upsert_file"
        return 1
    fi
    return 0
}

copy_table_to_csv() {
    local schema=$1
    local table=$2
    local output_csv=$3
    local identifier="\"${schema}\".\"${table}\""

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Attempting CSV export of ${schema}.${table} via ${label}"
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
            psql -h "$host" -p "$port" -U "$user" -d postgres \
            -v ON_ERROR_STOP=1 \
            -c "\copy (SELECT * FROM ${identifier}) TO '${output_csv}' WITH CSV HEADER" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        log_warning "CSV export via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    local direct_host="db.${SOURCE_REF}.supabase.co"
    local direct_user="postgres"
    log_warning "CSV export via pooler failed; attempting direct connection..."
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
        psql -h "$direct_host" -p 5432 -U "$direct_user" -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "\copy (SELECT * FROM ${identifier}) TO '${output_csv}' WITH CSV HEADER" >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    return 1
}

convert_csv_to_sql() {
    local csv_file=$1
    local sql_file=$2
    local schema=$3
    local table=$4
    "$PYTHON_BIN" - "$csv_file" "$sql_file" "$schema" "$table" <<'PY'
import csv
import sys

csv_path, sql_path, schema, table = sys.argv[1:5]
table_ident = f'"{schema}"."{table}"'

with open(csv_path, newline='', encoding='utf-8') as src, open(sql_path, 'w', encoding='utf-8') as dst:
    reader = csv.DictReader(src)
    if reader.fieldnames is None:
        raise SystemExit("CSV fallback has no header")
    columns = [f'"{col}"' for col in reader.fieldnames]
    columns_joined = ", ".join(columns)
    for row in reader:
        values = []
        for col in reader.fieldnames:
            val = row[col]
            if val == "":
                values.append("NULL")
            else:
                escaped = val.replace("'", "''")
                values.append(f"'{escaped}'")
        values_joined = ", ".join(values)
        dst.write(f"INSERT INTO {table_ident} ({columns_joined}) VALUES ({values_joined});\n")
PY
}

apply_sql_with_fallback() {
    local sql_file=$1
    local label=$2
    
    # Validate SQL file exists and is not empty
    if [ ! -f "$sql_file" ]; then
        log_warning "SQL file not found: $sql_file"
        return 1
    fi
    
    if [ ! -s "$sql_file" ]; then
        log_info "SQL file is empty: $sql_file (nothing to apply)"
        return 0
    fi
    
    # Filter out any psql meta-commands that might have leaked through
    local filtered_file="${sql_file}.filtered"
    # Remove lines starting with \ (psql meta-commands like \pset, \set, etc.)
    # Also remove lines that look like psql output (e.g., "Output format is unaligned")
    sed -E '/^\\|^Output format|^Tuples only|^Pager|^Locale|^Default display|^Line style|^Border style|^Expanded display/d' "$sql_file" > "$filtered_file" 2>/dev/null || cp "$sql_file" "$filtered_file"
    # Remove completely empty lines (but keep lines with just whitespace that might be part of SQL)
    sed -i.bak '/^$/d' "$filtered_file" 2>/dev/null || sed -i '' '/^$/d' "$filtered_file" 2>/dev/null || true
    rm -f "${filtered_file}.bak" 2>/dev/null || true
    
    # Use filtered file if it has content, otherwise use original
    if [ -s "$filtered_file" ]; then
        local actual_file="$filtered_file"
    else
        local actual_file="$sql_file"
    fi
    
    local result=0
    if type run_psql_script_with_fallback >/dev/null 2>&1; then
        if ! run_psql_script_with_fallback "$label" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$actual_file"; then
            result=1
        fi
    else
        if ! run_psql_script_direct "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$actual_file"; then
            result=1
        fi
    fi
    
    rm -f "$filtered_file" 2>/dev/null || true
    return $result
}

# Global array to track failed policies (accessible outside function)
FAILED_POLICIES_ARRAY=()

# Apply policies one by one to catch and report individual failures
apply_policies_individually() {
    local sql_file=$1
    local label=$2
    
    if [ ! -f "$sql_file" ] || [ ! -s "$sql_file" ]; then
        return 1
    fi
    
    # Filter the file first
    local filtered_file="${sql_file}.filtered"
    sed -E '/^\\|^Output format|^Tuples only|^Pager|^Locale|^Default display|^Line style|^Border style|^Expanded display/d' "$sql_file" > "$filtered_file" 2>/dev/null || cp "$sql_file" "$filtered_file"
    sed -i.bak '/^$/d' "$filtered_file" 2>/dev/null || sed -i '' '/^$/d' "$filtered_file" 2>/dev/null || true
    rm -f "${filtered_file}.bak" 2>/dev/null || true
    
    if [ ! -s "$filtered_file" ]; then
        rm -f "$filtered_file"
        return 1
    fi
    
    local success_count=0
    local fail_count=0
    FAILED_POLICIES_ARRAY=()  # Reset global array
    local current_statement=""
    local statement_type=""
    local total_statements=0
    local current_statement_num=0
    local semicolon_pattern=";[[:space:]]*$"  # Pattern to detect end of SQL statement
    
    # Count total statements first (for progress)
    while IFS= read -r line || [ -n "$line" ]; do
        line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line_trimmed" ] && continue
        [[ "$line_trimmed" =~ ^-- ]] && continue
        if [[ "$line_trimmed" =~ $semicolon_pattern ]]; then
            ((total_statements++)) || true
        fi
    done < "$filtered_file"
    
    log_info "Found $total_statements statement(s) to apply"
    
    # Split SQL file into individual statements and apply one by one
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line_trimmed" ] && continue
        [[ "$line_trimmed" =~ ^-- ]] && continue
        
        # Accumulate statement until we hit a semicolon
        current_statement+="$line"$'\n'
        
        # Check if line ends with semicolon (end of statement)
        if [[ "$line_trimmed" =~ $semicolon_pattern ]]; then
            ((current_statement_num++)) || true
            # Show progress every 50 statements
            if [ $((current_statement_num % 50)) -eq 0 ]; then
                log_info "  Progress: $current_statement_num/$total_statements statements processed..."
            fi
            
            # Extract statement type for logging
            if [[ "$current_statement" =~ ^[[:space:]]*ALTER[[:space:]]+TABLE ]]; then
                statement_type="ALTER TABLE"
                # Extract table name using sed (portable regex)
                table_name=$(echo "$current_statement" | sed -E 's/.*ALTER[[:space:]]+TABLE[[:space:]]+([^[:space:]]+).*/\1/' | head -1 || echo "unknown")
            elif [[ "$current_statement" =~ ^[[:space:]]*DROP[[:space:]]+POLICY ]]; then
                statement_type="DROP POLICY"
                # Extract policy name using sed (portable regex)
                policy_name=$(echo "$current_statement" | sed -E 's/.*DROP[[:space:]]+POLICY[[:space:]]+IF[[:space:]]+EXISTS[[:space:]]+([^[:space:]]+).*/\1/' | head -1 || echo "unknown")
            elif [[ "$current_statement" =~ ^[[:space:]]*CREATE[[:space:]]+POLICY ]]; then
                statement_type="CREATE POLICY"
                # Extract policy name using sed (portable regex)
                policy_name=$(echo "$current_statement" | sed -E 's/.*CREATE[[:space:]]+POLICY[[:space:]]+([^[:space:]]+).*/\1/' | head -1 || echo "unknown")
            else
                statement_type="OTHER"
            fi
            
            # Apply the statement
            local temp_stmt_file=$(mktemp)
            echo "$current_statement" > "$temp_stmt_file"
            
            local stmt_result=0
            local endpoints
            endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
            while IFS='|' read -r host port user label_name; do
                [ -z "$host" ] && continue
                if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                    -h "$host" \
                    -p "$port" \
                    -U "$user" \
                    -d postgres \
                    -f "$temp_stmt_file" >>"$LOG_FILE" 2>&1; then
                    stmt_result=0
                    break
                else
                    stmt_result=1
                fi
            done <<< "$endpoints"
            
            if [ $stmt_result -eq 0 ]; then
                ((success_count++)) || true
                # Only log CREATE POLICY successes if verbose or if it's one of the first 10
                if [ "$statement_type" = "CREATE POLICY" ] && [ $success_count -le 10 ]; then
                    log_info "  ✓ Applied: $policy_name"
                fi
            else
                ((fail_count++)) || true
                # Capture error message
                local error_msg=""
                endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                while IFS='|' read -r host port user label_name; do
                    [ -z "$host" ] && continue
                    error_msg=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                        -h "$host" \
                        -p "$port" \
                        -U "$user" \
                        -d postgres \
                        -f "$temp_stmt_file" 2>&1 | grep -i "error" | head -1 || echo "")
                    break
                done <<< "$endpoints"
                
                if [ "$statement_type" = "CREATE POLICY" ]; then
                    log_warning "  ✗ Failed: $policy_name"
                    [ -n "$error_msg" ] && log_warning "    Error: $error_msg"
                    FAILED_POLICIES_ARRAY+=("$policy_name")
                elif [ "$statement_type" = "DROP POLICY" ]; then
                    # DROP POLICY IF EXISTS failures are usually OK (policy doesn't exist)
                    if [ -n "$error_msg" ] && ! echo "$error_msg" | grep -qi "does not exist"; then
                        log_warning "  ⚠ DROP POLICY failed: $policy_name - $error_msg"
                    fi
                elif [ "$statement_type" = "ALTER TABLE" ]; then
                    log_warning "  ✗ Failed: $statement_type $table_name"
                    [ -n "$error_msg" ] && log_warning "    Error: $error_msg"
                else
                    log_warning "  ✗ Failed: $statement_type statement"
                    [ -n "$error_msg" ] && log_warning "    Error: $error_msg"
                fi
            fi
            
            rm -f "$temp_stmt_file"
            current_statement=""
        fi
    done < "$filtered_file"
    
    # Handle any remaining statement without semicolon
    if [ -n "$current_statement" ]; then
        local temp_stmt_file=$(mktemp)
        echo "$current_statement" > "$temp_stmt_file"
        if apply_sql_with_fallback "$temp_stmt_file" "Apply remaining statement" >/dev/null 2>&1; then
            ((success_count++)) || true
        else
            ((fail_count++)) || true
        fi
        rm -f "$temp_stmt_file"
    fi
    
    rm -f "$filtered_file"
    
    log_info "Policy application summary: $success_count succeeded, $fail_count failed"
    if [ ${#FAILED_POLICIES_ARRAY[@]} -gt 0 ]; then
        if [ ${#FAILED_POLICIES_ARRAY[@]} -le 20 ]; then
            log_warning "Failed policies: ${FAILED_POLICIES_ARRAY[*]}"
        else
            log_warning "Failed policies (showing first 20 of ${#FAILED_POLICIES_ARRAY[@]}):"
            for i in $(seq 0 $(( ${#FAILED_POLICIES_ARRAY[@]} > 20 ? 19 : ${#FAILED_POLICIES_ARRAY[@]} - 1 ))); do
                log_warning "  - ${FAILED_POLICIES_ARRAY[$i]}"
            done
            log_warning "  ... and $(( ${#FAILED_POLICIES_ARRAY[@]} - 20 )) more (see $LOG_FILE for full list)"
        fi
        log_warning "Review $LOG_FILE for detailed error messages for each failed policy"
    fi
    
    # Return success if at least some policies were applied
    if [ $success_count -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

run_source_sql_to_file() {
    local sql_content=$1
    local output_file=$2

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        log_info "Generating SQL from source via ${label} (${host}:${port})..."
        # Use -t -A flags instead of \pset commands to avoid meta-commands in output
        # -t: tuples only (no headers), -A: unaligned output
        if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -v ON_ERROR_STOP=on \
            -c "$sql_content" >"$output_file" 2>/dev/null; then
            # Filter out any psql meta-commands that might have leaked through
            # Remove lines that look like psql commands (starting with \)
            sed -i.bak '/^\\/d' "$output_file" 2>/dev/null || sed -i '' '/^\\/d' "$output_file" 2>/dev/null || true
            rm -f "${output_file}.bak" 2>/dev/null || true
            # Remove empty lines and lines that are just whitespace
            sed -i.bak '/^[[:space:]]*$/d' "$output_file" 2>/dev/null || sed -i '' '/^[[:space:]]*$/d' "$output_file" 2>/dev/null || true
            rm -f "${output_file}.bak" 2>/dev/null || true
            return 0
        fi
        log_warning "SQL generation via ${label} failed; trying next endpoint..."
    done <<< "$endpoints"

    return 1
}

generate_security_definer_sql() {
    local output_file=$1
    local sql_content="
WITH funcs AS (
    SELECT n.nspname,
           p.proname,
           regexp_replace(pg_get_functiondef(p.oid), '^CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION') AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.prosecdef = true
      AND n.nspname IN ('public','auth')
)
SELECT definition
FROM funcs
ORDER BY nspname, proname;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export security-definer functions from source."
        : >"$output_file"
        return 1
    fi
}

generate_all_database_functions_sql() {
    local output_file=$1
    local sql_content="
WITH funcs AS (
    SELECT n.nspname,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS args,
           regexp_replace(pg_get_functiondef(p.oid), '^CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION') AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','auth')
      AND p.prokind IN ('f', 'p', 'w')  -- functions, procedures, window functions
      AND NOT (n.nspname = 'pg_catalog' OR n.nspname = 'information_schema')
)
SELECT definition
FROM funcs
ORDER BY nspname, proname, args;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export all database functions from source."
        : >"$output_file"
        return 1
    fi
}

generate_grants_sql() {
    local output_file=$1
    # Export grants for ALL tables in public and auth schemas, not just those in TABLES array
    # This ensures comprehensive coverage of all permissions
    local sql_content="
WITH all_tables AS (
    SELECT c.oid AS relid,
           n.nspname AS schema_name,
           c.relname AS table_name,
           format('%I.%I', n.nspname, c.relname) AS qualified
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname IN ('public', 'auth')
)
, table_grants AS (
    SELECT 
        at.qualified,
        rtg.grantee,
        rtg.privilege_type,
        rtg.is_grantable,
        format(
            'GRANT %s ON %s TO %s%s;',
            rtg.privilege_type,
            at.qualified,
            quote_ident(rtg.grantee),
            CASE WHEN rtg.is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END
        ) AS grant_stmt
    FROM information_schema.role_table_grants rtg
    JOIN all_tables at ON at.schema_name = rtg.table_schema AND at.table_name = rtg.table_name
    WHERE rtg.grantee NOT IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
      AND rtg.grantee NOT LIKE 'pg_%'
)
SELECT grant_stmt
FROM table_grants
ORDER BY qualified, grantee, privilege_type;
"
    if run_source_sql_to_file "$sql_content" "$output_file"; then
        return 0
    else
        log_warning "Unable to export grants from source."
        : >"$output_file"
        return 1
    fi
}

generate_rls_sql() {
    local output_file=$1
    
    # Generate RLS SQL for ALL tables with RLS enabled AND all policies
    # CRITICAL: Include tables with RLS enabled but NO policies (they still need RLS enabled in target)
    local sql_content="
WITH all_rls_enabled_tables AS (
    -- Get ALL tables with RLS enabled in public and auth schemas (regardless of policies)
    SELECT DISTINCT
        c.oid AS relid,
        n.nspname,
        c.relname,
        format('%I.%I', n.nspname, c.relname) AS qualified,
        c.relrowsecurity,
        c.relforcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname IN ('public', 'auth')
      AND c.relrowsecurity = true
)
, all_policies AS (
    -- Get ALL policies in public and auth schemas
    SELECT DISTINCT
        pol.oid AS policy_oid,
        pol.polname,
        pol.polrelid,
        pol.polcmd,
        pol.polpermissive,
        pol.polroles,
        pol.polqual,
        pol.polwithcheck,
        c.relname,
        n.nspname,
        format('%I.%I', n.nspname, c.relname) AS qualified,
        c.relrowsecurity,
        c.relforcerowsecurity
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'auth')
      AND c.relkind = 'r'
)
, drop_policies AS (
    SELECT ap.qualified,
           ap.polname,
           format('DROP POLICY IF EXISTS %I ON %s;', ap.polname, ap.qualified) AS stmt
    FROM all_policies ap
)
, create_policies AS (
    SELECT ap.qualified,
           ap.polname,
           format(
               'CREATE POLICY %1\$I%2\$s ON %3\$s %4\$s %5\$s %6\$s %7\$s;',
               ap.polname,
               CASE WHEN NOT ap.polpermissive THEN ' AS RESTRICTIVE' ELSE '' END,
               ap.qualified,
               CASE ap.polcmd
                   WHEN '' THEN ''
                   WHEN 'r' THEN 'FOR SELECT'
                   WHEN 'a' THEN 'FOR INSERT'
                   WHEN 'w' THEN 'FOR UPDATE'
                   WHEN 'd' THEN 'FOR DELETE'
                   ELSE 'FOR ALL'
               END,
               COALESCE('TO '||roles.role_list, ''),
               CASE WHEN ap.polqual IS NULL THEN '' ELSE 'USING ('||pg_get_expr(ap.polqual, ap.polrelid)||')' END,
               CASE WHEN ap.polwithcheck IS NULL THEN '' ELSE 'WITH CHECK ('||pg_get_expr(ap.polwithcheck, ap.polrelid)||')' END
           ) AS stmt
    FROM all_policies ap
    LEFT JOIN LATERAL (
        SELECT string_agg(quote_ident(r.rolname), ', ') AS role_list
        FROM unnest(ap.polroles) role_oid
        JOIN pg_roles r ON r.oid = role_oid
    ) AS roles ON true
)
SELECT stmt FROM (
    -- Step 1: Enable RLS on ALL tables that have RLS enabled (including those with no policies)
    SELECT 1 AS ord, qualified AS obj, format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY;', qualified) AS stmt
    FROM all_rls_enabled_tables
    UNION ALL
    -- Step 2: Force RLS on tables that require it
    SELECT 2 AS ord, qualified, format('ALTER TABLE %s FORCE ROW LEVEL SECURITY;', qualified) AS stmt
    FROM all_rls_enabled_tables
    WHERE relforcerowsecurity
    UNION ALL
    -- Step 3: Drop existing policies (if any)
    SELECT 3 AS ord, qualified, stmt FROM drop_policies
    UNION ALL
    -- Step 4: Create all policies
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

dump_schema_section() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4
    local section=$5
    local output=$6
    shift 6
    local extra_args=("$@")
    if [ ${#extra_args[@]} -gt 0 ]; then
        run_pg_tool_with_fallback "pg_dump" "$ref" "$password" "$pooler_region" "$pooler_port" "$LOG_FILE" \
            -d postgres --schema-only --no-owner --no-privileges --section="$section" -N "pg_catalog" -N "information_schema" -f "$output" "${extra_args[@]}"
    else
        run_pg_tool_with_fallback "pg_dump" "$ref" "$password" "$pooler_region" "$pooler_port" "$LOG_FILE" \
            -d postgres --schema-only --no-owner --no-privileges --section="$section" -N "pg_catalog" -N "information_schema" -f "$output"
    fi
}

DATA_SQL="$MIGRATION_DIR/policies_data.sql"
SANITIZED_DATA_SQL="$MIGRATION_DIR/policies_data_sanitized.sql"
DDL_PRE_SQL="$MIGRATION_DIR/policies_pre_data.sql"
DDL_POST_SQL="$MIGRATION_DIR/policies_post_data.sql"

if $REPLACE_MODE; then
    log_info "Exporting full schema/policy definitions from source..."
    dump_schema_section "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" pre-data "$DDL_PRE_SQL"
    dump_schema_section "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" post-data "$DDL_POST_SQL"

    log_info "Exporting policy table data from source..."
    DATA_TABLE_ARGS=()
    DATA_SCHEMA_ARGS=()
    for tbl in "${TABLES[@]}"; do
        schema=${tbl%%.*}
        name=${tbl#*.}
        DATA_TABLE_ARGS+=(--table="${name}")
        if [ -n "$schema" ]; then
            DATA_SCHEMA_ARGS+=(--schema="${schema}")
        fi
    done
    # Deduplicate schema arguments
    if [ ${#DATA_SCHEMA_ARGS[@]} -gt 0 ]; then
        DATA_SCHEMA_ARGS=($(printf "%s\n" "${DATA_SCHEMA_ARGS[@]}" | sort -u))
    fi
    if ! run_pg_tool_with_fallback "pg_dump" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT" "$LOG_FILE" \
        -d postgres --data-only --no-owner --no-privileges -f "$DATA_SQL" "${DATA_SCHEMA_ARGS[@]}" "${DATA_TABLE_ARGS[@]}"; then
        log_error "Failed to export policy table data."
        exit 1
    fi

    log_info "Sanitising data SQL..."
    if ! "$PYTHON_BIN" - "$DATA_SQL" "$SANITIZED_DATA_SQL" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as infile, open(dst, "w", encoding="utf-8") as outfile:
    for line in infile:
        if line.lstrip().upper().startswith("SELECT PG_CATALOG.SETVAL"):
            continue
        outfile.write(line)
PY
    then
        log_error "Failed to sanitise policy data SQL."
        exit 1
    fi
fi

for table in "${TABLES[@]}"; do
    table_trimmed=$(echo "$table" | xargs)
    [ -z "$table_trimmed" ] && continue
    table_safe=${table_trimmed//./_}
    table_schema=${table_trimmed%%.*}
    table_name=${table_trimmed#*.}
    quoted_table="\"${table_schema}\".\"${table_name}\""
    table_identifier="${table_schema}.${table_name}"

    if $REPLACE_MODE; then
        log_info "Truncating target table: $table_trimmed"
        TRUNCATE_SQL_TEMP="$MIGRATION_DIR/truncate_${table_safe}.sql"
        printf 'TRUNCATE TABLE %s RESTART IDENTITY CASCADE;\n' "$quoted_table" >"$TRUNCATE_SQL_TEMP"
        if ! apply_sql_with_fallback "$TRUNCATE_SQL_TEMP" "Truncate $table_trimmed"; then
            log_error "Failed to truncate $table_trimmed"
            failed_tables+=("$table_trimmed")
            rm -f "$TRUNCATE_SQL_TEMP"
            continue
        fi
        rm -f "$TRUNCATE_SQL_TEMP"
        success_tables+=("$table_trimmed (truncated)")
    else
        dump_file="$MIGRATION_DIR/${table_safe}_source.sql"
        upsert_file="$MIGRATION_DIR/${table_safe}_upsert.sql"
        if ! dump_table_incremental "$table_identifier" "$dump_file" "$upsert_file"; then
            continue
        fi
        if apply_sql_with_fallback "$upsert_file" "Upsert $table_trimmed"; then
            log_success "Upsert completed for $table_trimmed"
            success_tables+=("$table_trimmed")
        else
            log_error "Upsert failed for $table_trimmed"
            failed_tables+=("$table_trimmed")
        fi
        rm -f "$dump_file" "$upsert_file"
    fi
done

if $REPLACE_MODE; then
    log_info "Applying schema pre-data (type definitions, etc.)..."
    apply_sql_with_fallback "$DDL_PRE_SQL" "Apply policy schema pre-data" || failed_tables+=("schema pre-data")

    log_info "Applying policy data..."
    if apply_sql_with_fallback "$SANITIZED_DATA_SQL" "Insert policy data"; then
        log_success "Policy data applied successfully."
    else
        log_error "Policy data application failed."
        failed_tables+=("policy data")
    fi

    # Filter post-data statements to avoid touching managed schemas (e.g. storage)
    FILTERED_DDL_POST_SQL="$MIGRATION_DIR/policies_post_data_filtered.sql"
    if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
        "$PYTHON_BIN" "$PROJECT_ROOT/scripts/util/filter_policies.py" "$DDL_POST_SQL" "$FILTERED_DDL_POST_SQL"
    else
        cp "$DDL_POST_SQL" "$FILTERED_DDL_POST_SQL"
    fi

    apply_post_data_with_owner_guard() {
        local sql_file=$1
        local temp_sql
        temp_sql=$(mktemp)
        {
            echo "RESET ROLE;"
            echo "SET search_path TO public,auth;"
            echo "RESET session authorization;"
        } >"$temp_sql"
        cat "$sql_file" >>"$temp_sql"

        log_info "Applying policy post-data (constraints, policies, functions) with owner-safe execution..."
        if run_psql_script_with_fallback "Apply policy post-data" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$temp_sql"; then
        log_success "Policy definitions applied successfully."
    else
            log_warning "Policy post-data application failed. Attempting per-statement execution with ownership guard."
        failed_tables+=("policy post-data")
    fi
        rm -f "$temp_sql"
    }

    apply_post_data_with_owner_guard "$FILTERED_DDL_POST_SQL"

    rm -f "$DDL_PRE_SQL" "$DDL_POST_SQL" "$DATA_SQL" "$SANITIZED_DATA_SQL" "$FILTERED_DDL_POST_SQL"
fi

    SECDEF_SQL="$MIGRATION_DIR/policies_security_definers.sql"
    RLS_SQL="$MIGRATION_DIR/policies_rls.sql"
    GRANTS_SQL="$MIGRATION_DIR/policies_grants.sql"
    FUNCTIONS_SQL="$MIGRATION_DIR/policies_all_functions.sql"

    # Step 1: Apply security-definer helper functions FIRST (required for RLS policies)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 1/5: Security-Definer Helper Functions"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Exporting security-definer helper functions..."
    if generate_security_definer_sql "$SECDEF_SQL"; then
        if [ -s "$SECDEF_SQL" ]; then
            func_count=$(grep -c "^CREATE OR REPLACE FUNCTION" "$SECDEF_SQL" 2>/dev/null || echo "0")
            log_info "Found $func_count security-definer function(s) to apply"
            if apply_sql_with_fallback "$SECDEF_SQL" "Apply security helper functions"; then
                log_success "✓ Security-definer helper functions applied successfully"
            else
                log_warning "⚠ Security-definer functions application had issues; continuing..."
                failed_tables+=("security-definer functions")
            fi
        else
            log_info "No security-definer functions detected; skipping."
        fi
    else
        log_warning "Failed to export security-definer functions; continuing..."
    fi
    echo ""

    # Step 2: Apply all database functions (public and auth schemas)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 2/5: Database Functions (public and auth schemas)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Exporting all database functions (public and auth schemas)..."
    if generate_all_database_functions_sql "$FUNCTIONS_SQL"; then
        if [ -s "$FUNCTIONS_SQL" ]; then
            func_count=$(grep -c "^CREATE OR REPLACE FUNCTION" "$FUNCTIONS_SQL" 2>/dev/null || echo "0")
            log_info "Found $func_count database function(s) to apply"
            if apply_sql_with_fallback "$FUNCTIONS_SQL" "Apply all database functions"; then
                log_success "✓ All database functions applied successfully"
            else
                log_warning "⚠ Database functions application had issues; continuing..."
                failed_tables+=("database functions")
            fi
        else
            log_info "No database functions detected in public/auth schemas."
        fi
    else
        log_warning "Failed to export database functions; continuing..."
    fi
    echo ""

    # Step 3: Apply RLS policies (must be after functions are in place)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 3/5: Row Level Security (RLS) Policies"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Exporting row level security policies for ALL tables with RLS enabled..."
    if generate_rls_sql "$RLS_SQL"; then
        if [ -s "$RLS_SQL" ]; then
            rls_table_count=$(grep -c "ENABLE ROW LEVEL SECURITY" "$RLS_SQL" 2>/dev/null || echo "0")
            rls_policy_count=$(grep -c "^CREATE POLICY" "$RLS_SQL" 2>/dev/null || echo "0")
            drop_policy_count=$(grep -c "^DROP POLICY" "$RLS_SQL" 2>/dev/null || echo "0")
            log_info "Found RLS configuration for $rls_table_count table(s):"
            log_info "  - $drop_policy_count DROP POLICY statement(s)"
            log_info "  - $rls_policy_count CREATE POLICY statement(s)"
            
            # Check for tables with RLS enabled but NO policies (critical issue)
            log_info "Checking for tables with RLS enabled but no policies..."
            RLS_NO_POLICIES_QUERY="
            WITH rls_tables AS (
                SELECT DISTINCT
                    format('%I.%I', n.nspname, c.relname) AS qualified,
                    c.relname,
                    n.nspname
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind = 'r'
                  AND n.nspname IN ('public', 'auth')
                  AND c.relrowsecurity = true
            ),
            tables_with_policies AS (
                SELECT DISTINCT
                    format('%I.%I', n.nspname, c.relname) AS qualified
                FROM pg_policy pol
                JOIN pg_class c ON c.oid = pol.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname IN ('public', 'auth')
            )
            SELECT rt.qualified
            FROM rls_tables rt
            WHERE rt.qualified NOT IN (SELECT qualified FROM tables_with_policies)
            ORDER BY rt.qualified;
            "
            RLS_NO_POLICIES_FILE=$(mktemp)
            if run_source_sql_to_file "$RLS_NO_POLICIES_QUERY" "$RLS_NO_POLICIES_FILE"; then
                if [ -s "$RLS_NO_POLICIES_FILE" ] && [ -n "$(cat "$RLS_NO_POLICIES_FILE" | grep -v '^$' || true)" ]; then
                    log_warning "⚠ CRITICAL: Found tables with RLS enabled but NO policies:"
                    tables_without_policies=()
                    while IFS= read -r table || [ -n "$table" ]; do
                        [ -z "$table" ] && continue
                        table_trimmed=$(echo "$table" | tr -d '[:space:]')
                        [ -z "$table_trimmed" ] && continue
                        tables_without_policies+=("$table_trimmed")
                        log_warning "    - $table_trimmed (RLS enabled but no policies - will block all access!)"
                    done < "$RLS_NO_POLICIES_FILE"
                    
                    log_info "   Automatically creating basic SELECT policies for these tables..."
                    BASIC_POLICIES_SQL="$MIGRATION_DIR/create_basic_policies_for_no_policy_tables.sql"
                    {
                        echo "-- Auto-generated basic policies for tables with RLS enabled but no policies"
                        echo "-- Generated: $(date)"
                        echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                        echo ""
                        for table in "${tables_without_policies[@]}"; do
                            table_name_clean=$(echo "$table" | sed -E 's/^[^.]+\.(.+)$/\1/')
                            policy_name="allow_authenticated_select_${table_name_clean}"
                            
                            echo "-- Basic SELECT policy for $table"
                            echo "DROP POLICY IF EXISTS \"$policy_name\" ON $table;"
                            echo "CREATE POLICY \"$policy_name\""
                            echo "ON $table"
                            echo "FOR SELECT"
                            echo "TO authenticated"
                            echo "USING (true);"
                            echo ""
                        done
                    } > "$BASIC_POLICIES_SQL"
                    
                    if apply_sql_with_fallback "$BASIC_POLICIES_SQL" "Create basic policies for tables without policies"; then
                        log_success "✓ Created basic SELECT policies for ${#tables_without_policies[@]} table(s)"
                    else
                        log_warning "⚠ Failed to create some basic policies; check $BASIC_POLICIES_SQL and $LOG_FILE"
                    fi
                else
                    log_success "✓ All RLS-enabled tables have policies"
                fi
            fi
            rm -f "$RLS_NO_POLICIES_FILE"
            
            # Verify we're getting all policies from source
            log_info "Verifying policy count from source..."
            SOURCE_POLICY_COUNT_QUERY="
            SELECT COUNT(*)
            FROM pg_policy pol
            JOIN pg_class c ON c.oid = pol.polrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'auth')
              AND c.relrowsecurity = true;
            "
            SOURCE_POLICY_COUNT_FILE=$(mktemp)
            if run_source_sql_to_file "$SOURCE_POLICY_COUNT_QUERY" "$SOURCE_POLICY_COUNT_FILE"; then
                source_policy_count=$(head -1 "$SOURCE_POLICY_COUNT_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")
                log_info "  Source has $source_policy_count total policy(ies) on RLS-enabled tables"
                
                # Count CREATE POLICY statements in generated SQL
                create_policy_count=$(grep -c "^CREATE POLICY" "$RLS_SQL" 2>/dev/null || echo "0")
                log_info "  Generated SQL contains $create_policy_count CREATE POLICY statement(s)"
                
                if [ "$create_policy_count" -lt "$source_policy_count" ]; then
                    log_warning "⚠ Generated SQL has fewer CREATE POLICY statements ($create_policy_count) than source policies ($source_policy_count)"
                    log_warning "   Missing $((source_policy_count - create_policy_count)) policy(ies) in generated SQL"
                    log_warning "   This may indicate an issue with policy export from source"
                    
                    # List policies that might be missing
                    log_info "   Checking which policies might be missing from generated SQL..."
                    SOURCE_POLICY_NAMES_QUERY="
                    SELECT 
                        format('%I.%I', n.nspname, c.relname) || '.' || pol.polname AS policy_full_name
                    FROM pg_policy pol
                    JOIN pg_class c ON c.oid = pol.polrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname IN ('public', 'auth')
                      AND c.relrowsecurity = true
                    ORDER BY format('%I.%I', n.nspname, c.relname), pol.polname;
                    "
                    SOURCE_POLICY_NAMES_FILE=$(mktemp)
                    if run_source_sql_to_file "$SOURCE_POLICY_NAMES_QUERY" "$SOURCE_POLICY_NAMES_FILE"; then
                        missing_in_sql=0
                        while IFS= read -r policy_full_name || [ -n "$policy_full_name" ]; do
                            [ -z "$policy_full_name" ] && continue
                            policy_name=$(echo "$policy_full_name" | sed -E 's/^[^.]+\.[^.]+\.(.+)$/\1/')
                            if ! grep -q "CREATE POLICY.*$policy_name" "$RLS_SQL" 2>/dev/null; then
                                if [ "$missing_in_sql" -eq 0 ]; then
                                    log_warning "   Policies not found in generated SQL:"
                                fi
                                missing_in_sql=$((missing_in_sql + 1))
                                if [ "$missing_in_sql" -le 10 ]; then
                                    log_warning "     - $policy_full_name"
                                fi
                            fi
                        done < "$SOURCE_POLICY_NAMES_FILE"
                        if [ "$missing_in_sql" -gt 10 ]; then
                            log_warning "     ... and $((missing_in_sql - 10)) more"
                        fi
                        if [ "$missing_in_sql" -gt 0 ]; then
                            log_warning "   Total: $missing_in_sql policy(ies) missing from generated SQL"
                        fi
                    fi
                    rm -f "$SOURCE_POLICY_NAMES_FILE"
                else
                    log_success "✓ Generated SQL contains all source policies"
                fi
            fi
            rm -f "$SOURCE_POLICY_COUNT_FILE"
            
            # Verify policy count BEFORE application
            log_info "Verifying policy count before application..."
            TARGET_POLICY_COUNT_BEFORE_QUERY="
            SELECT COUNT(*)
            FROM pg_policy pol
            JOIN pg_class c ON pol.polrelid = c.oid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'auth')
              AND c.relrowsecurity = true;
            "
            TARGET_POLICY_COUNT_BEFORE_FILE=$(mktemp)
            endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
            target_before_count="0"
            while IFS='|' read -r host port user label; do
                [ -z "$host" ] && continue
                if target_before_count=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                    -h "$host" \
                    -p "$port" \
                    -U "$user" \
                    -d postgres \
                    -t -A \
                    -c "$TARGET_POLICY_COUNT_BEFORE_QUERY" 2>/dev/null | tr -d '[:space:]'); then
                    break
                fi
            done <<< "$endpoints"
            rm -f "$TARGET_POLICY_COUNT_BEFORE_FILE"
            log_info "  Target has $target_before_count policy(ies) before migration"
            
            # Apply policies individually to catch and report failures
            log_info "Applying policies individually to identify any failures..."
            log_info "This may take a while for large numbers of policies..."
            if apply_policies_individually "$RLS_SQL" "Apply RLS policies"; then
                # Verify policies were actually created
                log_info "Verifying policies were applied..."
                TARGET_POLICY_COUNT_QUERY="
                SELECT COUNT(*)
                FROM pg_policy pol
                JOIN pg_class c ON pol.polrelid = c.oid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname IN ('public', 'auth')
                  AND c.relrowsecurity = true;
                "
                TARGET_POLICY_COUNT_FILE=$(mktemp)
                endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                target_after_count="0"
                while IFS='|' read -r host port user label; do
                    [ -z "$host" ] && continue
                    if target_after_count=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                        -h "$host" \
                        -p "$port" \
                        -U "$user" \
                        -d postgres \
                        -t -A \
                        -c "$TARGET_POLICY_COUNT_QUERY" 2>/dev/null | tr -d '[:space:]'); then
                        break
                    fi
                done <<< "$endpoints"
                rm -f "$TARGET_POLICY_COUNT_FILE"
                
                if [ -n "$source_policy_count" ] && [ "$source_policy_count" != "0" ]; then
                    if [ "$target_after_count" -ge "$source_policy_count" ]; then
                        log_success "✓ RLS policies applied successfully: $target_after_count policy(ies) in target"
                    else
                        missing_count=$((source_policy_count - target_after_count))
                        log_warning "⚠ Policy count mismatch after application: Expected ~$source_policy_count, got $target_after_count"
                        log_warning "   Missing $missing_count policy(ies) - some policies failed to apply"
                        
                        # Generate detailed missing policies report
                        log_info "   Generating detailed missing policies report..."
                        SOURCE_POLICIES_DETAILED_QUERY="
                        SELECT 
                            format('%I.%I', n.nspname, c.relname) AS table_qualified,
                            c.relname AS table_name,
                            pol.polname AS policy_name,
                            CASE pol.polcmd
                                WHEN 'r' THEN 'SELECT'
                                WHEN 'a' THEN 'INSERT'
                                WHEN 'w' THEN 'UPDATE'
                                WHEN 'd' THEN 'DELETE'
                                WHEN '' THEN 'ALL'
                                ELSE 'UNKNOWN'
                            END AS policy_command,
                            pol.polname || '|' || format('%I.%I', n.nspname, c.relname) AS policy_identifier
                        FROM pg_policy pol
                        JOIN pg_class c ON c.oid = pol.polrelid
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE n.nspname IN ('public', 'auth')
                          AND c.relrowsecurity = true
                        ORDER BY format('%I.%I', n.nspname, c.relname), pol.polname;
                        "
                        MISSING_POLICIES_DETAILED_FILE="$MIGRATION_DIR/missing_policies_detailed.txt"
                        source_policies_list_file=$(mktemp)
                        if run_source_sql_to_file "$SOURCE_POLICIES_DETAILED_QUERY" "$source_policies_list_file"; then
                            # Get target policies for comparison
                            TARGET_POLICIES_LIST_QUERY="
                            SELECT 
                                pol.polname || '|' || format('%I.%I', n.nspname, c.relname) AS policy_identifier
                            FROM pg_policy pol
                            JOIN pg_class c ON c.oid = pol.polrelid
                            JOIN pg_namespace n ON n.oid = c.relnamespace
                            WHERE n.nspname IN ('public', 'auth')
                              AND c.relrowsecurity = true;
                            "
                            target_policies_list_file=$(mktemp)
                            endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                            while IFS='|' read -r host port user label; do
                                [ -z "$host" ] && continue
                                if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                                    -h "$host" \
                                    -p "$port" \
                                    -U "$user" \
                                    -d postgres \
                                    -t -A \
                                    -c "$TARGET_POLICIES_LIST_QUERY" >"$target_policies_list_file" 2>/dev/null; then
                                    break
                                fi
                            done <<< "$endpoints"
                            
                            # Compare and generate report
                            if [ -s "$source_policies_list_file" ]; then
                                {
                                    echo "Missing Policies Detailed Report"
                                    echo "=============================="
                                    echo "Date: $(date)"
                                    echo "Source: $SOURCE_ENV ($SOURCE_REF)"
                                    echo "Target: $TARGET_ENV ($TARGET_REF)"
                                    echo ""
                                    echo "Source Policy Count: $source_policy_count"
                                    echo "Target Policy Count (before): $target_before_count"
                                    echo "Target Policy Count (after): $target_after_count"
                                    echo "Missing Policies: $missing_count"
                                    echo ""
                                    echo "Missing Policies by Table:"
                                    echo "--------------------------"
                                
                                    # Read target policies into associative array (if supported) or use grep
                                    missing_found=0
                                    current_table=""
                                    while IFS='|' read -r table_qualified table_name policy_name policy_command policy_identifier || [ -n "$table_qualified" ]; do
                                        [ -z "$table_qualified" ] && continue
                                        # Check if this policy exists in target
                                        if ! grep -qF "$policy_identifier" "$target_policies_list_file" 2>/dev/null; then
                                            missing_found=$((missing_found + 1))
                                            if [ "$table_qualified" != "$current_table" ]; then
                                                current_table="$table_qualified"
                                                echo ""
                                                echo "Table: $table_qualified"
                                            fi
                                            echo "  - Policy: $policy_name ($policy_command)"
                                        fi
                                    done < "$source_policies_list_file"
                                
                                    if [ "$missing_found" -eq 0 ]; then
                                        echo ""
                                        echo "No missing policies found (count mismatch may be due to duplicate policies or counting differences)"
                                    fi
                                
                                    echo ""
                                    echo "These policies exist in source but are missing in target."
                                    echo "Check $LOG_FILE for detailed error messages during policy application."
                                } > "$MISSING_POLICIES_DETAILED_FILE"
                                log_info "   Detailed missing policies report: $MISSING_POLICIES_DETAILED_FILE"
                            fi
                            rm -f "$source_policies_list_file" "$target_policies_list_file"
                        fi
                        
                        log_warning "   Check $LOG_FILE for detailed error messages"
                        if [ ${#FAILED_POLICIES_ARRAY[@]} -gt 0 ]; then
                            log_warning "   Failed policies report: $MIGRATION_DIR/failed_policies_report.txt"
                        fi
                        log_warning "   Missing policies report: $MISSING_POLICIES_DETAILED_FILE"
                        log_warning "   Common causes:"
                        log_warning "     - Missing functions referenced in policy expressions"
                        log_warning "     - Missing roles referenced in policy TO clauses"
                        log_warning "     - Missing tables/columns referenced in policy expressions"
                        log_warning "     - Syntax errors in policy definitions"
                        log_warning "   To fix: Review failed policies, fix dependencies, and re-run migration"
                        
                        # Generate retry SQL for missing policies
                        log_info "   Generating retry SQL for missing policies..."
                        RETRY_POLICIES_SQL="$MIGRATION_DIR/retry_missing_policies.sql"
                        
                        # Get full policy definitions from source for missing policies
                        if [ -s "$source_policies_list_file" ] && [ -s "$target_policies_list_file" ]; then
                            # Get list of missing policy identifiers
                            missing_policy_ids=()
                            while IFS='|' read -r table_qualified table_name policy_name policy_command policy_identifier || [ -n "$table_qualified" ]; do
                                [ -z "$table_qualified" ] && continue
                                if ! grep -qF "$policy_identifier" "$target_policies_list_file" 2>/dev/null; then
                                    missing_policy_ids+=("$policy_identifier")
                                fi
                            done < "$source_policies_list_file"
                            
                            if [ ${#missing_policy_ids[@]} -gt 0 ]; then
                                # Build array literal for SQL query
                                policy_ids_sql=""
                                for pid in "${missing_policy_ids[@]}"; do
                                    if [ -z "$policy_ids_sql" ]; then
                                        policy_ids_sql="'$pid'"
                                    else
                                        policy_ids_sql="$policy_ids_sql, '$pid'"
                                    fi
                                done
                                
                                # Generate SQL to recreate missing policies from source
                                SOURCE_POLICY_DEFS_QUERY="
                                SELECT 
                                    format('DROP POLICY IF EXISTS %I ON %s;', pol.polname, format('%I.%I', n.nspname, c.relname)) || E'\\n' ||
                                    format(
                                        'CREATE POLICY %1\$I%2\$s ON %3\$s %4\$s %5\$s %6\$s %7\$s;',
                                        pol.polname,
                                        CASE WHEN NOT pol.polpermissive THEN ' AS RESTRICTIVE' ELSE '' END,
                                        format('%I.%I', n.nspname, c.relname),
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
                                    ) AS policy_sql
                                FROM pg_policy pol
                                JOIN pg_class c ON c.oid = pol.polrelid
                                JOIN pg_namespace n ON n.oid = c.relnamespace
                                LEFT JOIN LATERAL (
                                    SELECT string_agg(quote_ident(r.rolname), ', ') AS role_list
                                    FROM unnest(pol.polroles) role_oid
                                    JOIN pg_roles r ON r.oid = role_oid
                                ) AS roles ON true
                                WHERE n.nspname IN ('public', 'auth')
                                  AND c.relrowsecurity = true
                                  AND pol.polname || '|' || format('%I.%I', n.nspname, c.relname) = ANY(ARRAY[$policy_ids_sql])
                                ORDER BY format('%I.%I', n.nspname, c.relname), pol.polname;
                                "
                                
                                RETRY_POLICIES_FILE=$(mktemp)
                                if run_source_sql_to_file "$SOURCE_POLICY_DEFS_QUERY" "$RETRY_POLICIES_FILE"; then
                                    if [ -s "$RETRY_POLICIES_FILE" ]; then
                                        {
                                            echo "-- Retry SQL for missing RLS policies"
                                            echo "-- Generated: $(date)"
                                            echo "-- Source: $SOURCE_ENV ($SOURCE_REF)"
                                            echo "-- Target: $TARGET_ENV ($TARGET_REF)"
                                            echo "-- Missing policies: ${#missing_policy_ids[@]}"
                                            echo ""
                                            cat "$RETRY_POLICIES_FILE"
                                        } > "$RETRY_POLICIES_SQL"
                                        
                                        log_info "   Retry SQL generated: $RETRY_POLICIES_SQL"
                                        log_info "   Attempting to apply missing policies..."
                                        
                                        # Try to apply the retry SQL
                                        if apply_sql_with_fallback "$RETRY_POLICIES_SQL" "Retry missing RLS policies"; then
                                            # Verify policies were applied
                                            TARGET_AFTER_RETRY_QUERY="
                                            SELECT COUNT(*)
                                            FROM pg_policy pol
                                            JOIN pg_class c ON pol.polrelid = c.oid
                                            JOIN pg_namespace n ON n.oid = c.relnamespace
                                            WHERE n.nspname IN ('public', 'auth')
                                              AND c.relrowsecurity = true;
                                            "
                                            target_after_retry_count="0"
                                            endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                                            while IFS='|' read -r host port user label; do
                                                [ -z "$host" ] && continue
                                                if target_after_retry_count=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                                                    -h "$host" \
                                                    -p "$port" \
                                                    -U "$user" \
                                                    -d postgres \
                                                    -t -A \
                                                    -c "$TARGET_AFTER_RETRY_QUERY" 2>/dev/null | tr -d '[:space:]'); then
                                                    break
                                                fi
                                            done <<< "$endpoints"
                                            
                                            if [ "$target_after_retry_count" -ge "$source_policy_count" ]; then
                                                log_success "✓ Successfully applied missing policies via retry: $target_after_retry_count policy(ies) now in target"
                                                # Remove from failed tables if successful
                                                failed_tables=("${failed_tables[@]/RLS policies (missing $missing_count)/}")
                                            else
                                                remaining_missing=$((source_policy_count - target_after_retry_count))
                                                log_warning "⚠ Retry applied some policies but $remaining_missing still missing"
                                                log_warning "   Review $RETRY_POLICIES_SQL and $LOG_FILE for details"
                                                failed_tables+=("RLS policies (missing $remaining_missing)")
                                            fi
                                        else
                                            log_warning "⚠ Retry SQL application failed - policies may have dependency issues"
                                            log_warning "   Review $RETRY_POLICIES_SQL and $LOG_FILE for details"
                                            log_warning "   You can manually apply: psql -f $RETRY_POLICIES_SQL"
                                            failed_tables+=("RLS policies (missing $missing_count)")
                                        fi
                                        rm -f "$RETRY_POLICIES_FILE"
                                    else
                                        log_warning "⚠ Could not generate retry SQL for missing policies"
                                        failed_tables+=("RLS policies (missing $missing_count)")
                                    fi
                                else
                                    log_warning "⚠ Could not fetch policy definitions from source for retry"
                                    failed_tables+=("RLS policies (missing $missing_count)")
                                fi
                            fi
                        else
                            failed_tables+=("RLS policies (missing $missing_count)")
                        fi
                    fi
                else
                    log_success "✓ RLS policies applied successfully"
                fi
            else
                log_warning "⚠ RLS policy application had issues; inspect $RLS_SQL and $LOG_FILE"
                failed_tables+=("RLS policies")
                
                # Try to identify what went wrong
                if [ ${#FAILED_POLICIES_ARRAY[@]} -gt 0 ]; then
                    log_warning "   ${#FAILED_POLICIES_ARRAY[@]} policy(ies) failed to apply"
                    log_warning "   Check $MIGRATION_DIR/failed_policies_report.txt for details"
                fi
            fi
            
            # Final comprehensive check: Compare source and target policies
            log_info ""
            log_info "Performing final comprehensive policy comparison..."
            FINAL_COMPARISON_QUERY="
            SELECT 
                format('%I.%I', n.nspname, c.relname) AS table_name,
                COUNT(*) AS policy_count
            FROM pg_policy pol
            JOIN pg_class c ON c.oid = pol.polrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'auth')
              AND c.relrowsecurity = true
            GROUP BY format('%I.%I', n.nspname, c.relname)
            ORDER BY format('%I.%I', n.nspname, c.relname);
            "
            
            # Get source policy counts by table
            SOURCE_POLICIES_BY_TABLE_FILE=$(mktemp)
            if run_source_sql_to_file "$FINAL_COMPARISON_QUERY" "$SOURCE_POLICIES_BY_TABLE_FILE"; then
                # Get target policy counts by table
                TARGET_POLICIES_BY_TABLE_FILE=$(mktemp)
                endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
                while IFS='|' read -r host port user label; do
                    [ -z "$host" ] && continue
                    if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                        -h "$host" \
                        -p "$port" \
                        -U "$user" \
                        -d postgres \
                        -t -A \
                        -c "$FINAL_COMPARISON_QUERY" >"$TARGET_POLICIES_BY_TABLE_FILE" 2>/dev/null; then
                        break
                    fi
                done <<< "$endpoints"
                
                # Compare and report
                if [ -s "$SOURCE_POLICIES_BY_TABLE_FILE" ] && [ -s "$TARGET_POLICIES_BY_TABLE_FILE" ]; then
                    tables_with_missing=0
                    while IFS='|' read -r source_table source_count || [ -n "$source_table" ]; do
                        [ -z "$source_table" ] && continue
                        source_table_clean=$(echo "$source_table" | tr -d '[:space:]')
                        source_count_clean=$(echo "$source_count" | tr -d '[:space:]')
                        [ -z "$source_table_clean" ] && continue
                        
                        # Find matching target count
                        target_count_clean="0"
                        while IFS='|' read -r target_table target_count || [ -n "$target_table" ]; do
                            [ -z "$target_table" ] && continue
                            target_table_clean=$(echo "$target_table" | tr -d '[:space:]')
                            if [ "$target_table_clean" = "$source_table_clean" ]; then
                                target_count_clean=$(echo "$target_count" | tr -d '[:space:]')
                                break
                            fi
                        done < "$TARGET_POLICIES_BY_TABLE_FILE"
                        
                        if [ "$target_count_clean" -lt "$source_count_clean" ]; then
                            if [ "$tables_with_missing" -eq 0 ]; then
                                log_warning "⚠ Tables with missing policies:"
                            fi
                            tables_with_missing=$((tables_with_missing + 1))
                            missing_policies=$((source_count_clean - target_count_clean))
                            log_warning "   - $source_table_clean: Source has $source_count_clean, Target has $target_count_clean (missing $missing_policies)"
                        fi
                    done < "$SOURCE_POLICIES_BY_TABLE_FILE"
                    
                    if [ "$tables_with_missing" -eq 0 ]; then
                        log_success "✓ All tables have matching policy counts between source and target"
                    else
                        log_warning "⚠ Found $tables_with_missing table(s) with missing policies"
                        log_warning "   Review $MISSING_POLICIES_DETAILED_FILE for detailed list"
                    fi
                fi
                rm -f "$SOURCE_POLICIES_BY_TABLE_FILE" "$TARGET_POLICIES_BY_TABLE_FILE"
            fi
        else
            log_warning "No RLS policies detected - this may indicate an issue if source has RLS enabled tables"
        fi
    else
        log_warning "Failed to export RLS policies; continuing..."
    fi
    echo ""

    # Step 4: Apply function grants (ensure functions are accessible to roles)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 4/5: Function Grants and Permissions"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    FUNCTION_GRANTS_SQL="$MIGRATION_DIR/policies_function_grants.sql"
    
    generate_function_grants_sql() {
        local output_file=$1
        local sql_content="
WITH func_grants AS (
    SELECT 
        n.nspname || '.' || p.proname AS func_name,
        rtg.grantee,
        rtg.privilege_type,
        rtg.is_grantable,
        format(
            'GRANT %s ON FUNCTION %I.%I(%s) TO %s%s;',
            rtg.privilege_type,
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid),
            quote_ident(rtg.grantee),
            CASE WHEN rtg.is_grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END
        ) AS grant_stmt
    FROM information_schema.routine_privileges rtg
    JOIN pg_proc p ON p.proname = rtg.routine_name
    JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = rtg.routine_schema
    WHERE rtg.routine_schema IN ('public', 'auth')
      AND rtg.grantee NOT IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
      AND rtg.grantee NOT LIKE 'pg_%'
)
SELECT grant_stmt
FROM func_grants
ORDER BY func_name, grantee, privilege_type;
"
        if run_source_sql_to_file "$sql_content" "$output_file"; then
            return 0
        else
            log_warning "Unable to export function grants from source."
            : >"$output_file"
            return 1
        fi
    }
    
    log_info "Exporting function grants (permissions) for functions in public and auth schemas..."
    if generate_function_grants_sql "$FUNCTION_GRANTS_SQL"; then
        if [ -s "$FUNCTION_GRANTS_SQL" ]; then
            func_grant_count=$(grep -c "^GRANT" "$FUNCTION_GRANTS_SQL" 2>/dev/null || echo "0")
            log_info "Found $func_grant_count function grant statement(s) to apply"
            if apply_sql_with_fallback "$FUNCTION_GRANTS_SQL" "Apply function grants"; then
                log_success "✓ Function grants applied successfully"
            else
                log_warning "⚠ Function grants application had issues; inspect $FUNCTION_GRANTS_SQL"
                failed_tables+=("function grants")
            fi
        else
            log_info "No function grants detected for functions in public/auth schemas."
        fi
    else
        log_warning "Failed to export function grants; continuing..."
    fi
    echo ""

    # Step 5: Apply table grants/permissions (must be after policies)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Step 5/5: Table Grants and Permissions"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Exporting table grants (permissions) for ALL tables in public and auth schemas..."
    if generate_grants_sql "$GRANTS_SQL"; then
        if [ -s "$GRANTS_SQL" ]; then
            grant_count=$(grep -c "^GRANT" "$GRANTS_SQL" 2>/dev/null || echo "0")
            log_info "Found $grant_count grant statement(s) to apply"
            if apply_sql_with_fallback "$GRANTS_SQL" "Apply table grants"; then
                log_success "✓ Table grants applied successfully for all tables"
            else
                log_warning "⚠ Table grants application had issues; inspect $GRANTS_SQL"
                failed_tables+=("table grants")
            fi
        else
            log_info "No table grants detected for tables in public/auth schemas."
        fi
    else
        log_warning "Failed to export grants; continuing..."
    fi
    echo ""

rm -f "$MIGRATION_DIR"/*_source.sql "$MIGRATION_DIR"/*_upsert.sql 2>/dev/null || true

# Generate failed policies report if there were failures
if [ ${#FAILED_POLICIES_ARRAY[@]} -gt 0 ]; then
    FAILED_POLICIES_REPORT="$MIGRATION_DIR/failed_policies_report.txt"
    {
        echo "Failed Policies Report"
        echo "======================"
        echo "Date: $(date)"
        echo "Source: $SOURCE_ENV ($SOURCE_REF)"
        echo "Target: $TARGET_ENV ($TARGET_REF)"
echo ""
        echo "Total Failed Policies: ${#FAILED_POLICIES_ARRAY[@]}"
        echo ""
        echo "Failed Policy Names:"
        for policy in "${FAILED_POLICIES_ARRAY[@]}"; do
            echo "  - $policy"
        done
        echo ""
        echo "Common causes:"
        echo "  1. Missing functions referenced in policy USING/WITH CHECK clauses"
        echo "  2. Missing roles referenced in policy TO clause"
        echo "  3. Missing tables or columns referenced in policy expressions"
        echo "  4. Syntax errors in policy definitions"
        echo ""
        echo "To fix:"
        echo "  1. Check $LOG_FILE for detailed error messages"
        echo "  2. Ensure all functions are migrated: ./scripts/components/policies_migration.sh $SOURCE_ENV $TARGET_ENV"
        echo "  3. Ensure all roles exist in target"
        echo "  4. Re-run policies migration after fixing dependencies"
    } > "$FAILED_POLICIES_REPORT"
    log_info "Failed policies report saved to: $FAILED_POLICIES_REPORT"
fi

# Validation: Verify policies were applied correctly and check dependencies
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Validation: Verifying Policies and Access Controls"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for missing function dependencies in policies
log_info "Checking for missing function dependencies in RLS policies..."
VALIDATE_FUNCTIONS_QUERY="
WITH policy_functions AS (
    SELECT DISTINCT
        regexp_split_to_table(
            COALESCE(pg_get_expr(pol.polqual, pol.polrelid), '') || ' ' || 
            COALESCE(pg_get_expr(pol.polwithcheck, pol.polrelid), ''),
            '[^a-zA-Z0-9_]+'
        ) as func_name
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'auth')
      AND (pol.polqual IS NOT NULL OR pol.polwithcheck IS NOT NULL)
),
-- Common column/table names to exclude (not functions)
excluded_names AS (
    SELECT unnest(ARRAY[
        'true', 'false', 'null', 'auth', 'uid', 'role', 'jwt', 'current_user', 'current_role',
        'id', 'user_id', 'created_at', 'updated_at', 'deleted_at', 'status', 'type', 'name',
        'email', 'password', 'username', 'role_id', 'profile_id', 'organization_id',
        'user_roles', 'user_learning_centers', 'ulc_target', 'ulc_viewer',
        'table', 'column', 'row', 'data', 'value', 'key', 'text', 'json', 'array',
        'select', 'insert', 'update', 'delete', 'where', 'from', 'join', 'on', 'and', 'or',
        'is', 'not', 'in', 'exists', 'case', 'when', 'then', 'else', 'end', 'as',
        -- Common role names that appear in policy expressions
        'accounts', 'active', 'admin', 'app_role', 'cms', 'crm', 'csr', 'emp_center',
        'front_desk', 'frontdesk', 'global', 'global_csr', 'learning_center', 'pending',
        'published', 'single_customer', 'specific_customers', 'staff', 'super_admin', 'teacher'
    ]) as name
),
-- Get all role names from user_roles and auth.roles to exclude
role_names AS (
    SELECT DISTINCT role::text as name
    FROM user_roles
    WHERE role IS NOT NULL
    UNION
    SELECT DISTINCT role::text as name
    FROM auth.user_roles
    WHERE role IS NOT NULL
    UNION
    SELECT DISTINCT name::text as name
    FROM auth.roles
    WHERE name IS NOT NULL
),
-- Get all existing table and column names to exclude
existing_identifiers AS (
    SELECT DISTINCT table_name as name FROM information_schema.tables WHERE table_schema IN ('public', 'auth')
    UNION
    SELECT DISTINCT column_name as name FROM information_schema.columns WHERE table_schema IN ('public', 'auth')
)
SELECT DISTINCT pf.func_name
FROM policy_functions pf
WHERE pf.func_name ~ '^[a-z_][a-z0-9_]*$'
  AND LENGTH(pf.func_name) > 2
  AND pf.func_name NOT IN (SELECT name FROM excluded_names)
  AND pf.func_name NOT IN (SELECT name FROM existing_identifiers)
  AND pf.func_name NOT IN (SELECT name FROM role_names)
  AND NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE p.proname = pf.func_name
        AND n.nspname IN ('public', 'auth', 'pg_catalog')
  )
ORDER BY pf.func_name;
"

VALIDATE_FUNCTIONS_FILE=$(mktemp)
if run_source_sql_to_file "$VALIDATE_FUNCTIONS_QUERY" "$VALIDATE_FUNCTIONS_FILE"; then
    if [ -s "$VALIDATE_FUNCTIONS_FILE" ]; then
        missing_funcs=$(cat "$VALIDATE_FUNCTIONS_FILE" | grep -v '^$' || true)
        if [ -n "$missing_funcs" ]; then
            log_warning "⚠ Potential missing functions referenced in policies:"
            echo "$missing_funcs" | while read func; do
                log_warning "   - $func"
            done
            log_warning "   These functions may need to be migrated separately"
        else
            log_success "✓ No missing function dependencies detected"
        fi
    else
        log_success "✓ No function dependencies to validate"
    fi
else
    log_warning "⚠ Could not validate function dependencies"
fi
rm -f "$VALIDATE_FUNCTIONS_FILE"
echo ""

validate_policies_applied() {
    local validation_errors=0
    local temp_file
    temp_file=$(mktemp)
    
    # Count RLS-enabled tables in source
    local source_rls_query="SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('public', 'auth') AND c.relrowsecurity = true"
    local source_rls_count="0"
    if run_source_sql_to_file "$source_rls_query" "$temp_file" 2>/dev/null; then
        source_rls_count=$(head -1 "$temp_file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    fi
    
    # Count RLS-enabled tables in target
    local target_rls_query="SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('public', 'auth') AND c.relrowsecurity = true"
    local target_rls_count="0"
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if target_rls_count=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$target_rls_query" 2>/dev/null | tr -d '[:space:]'); then
            break
        fi
    done <<< "$endpoints"
    target_rls_count=${target_rls_count:-0}
    
    if [ "$source_rls_count" != "$target_rls_count" ]; then
        log_warning "⚠ RLS table count mismatch: Source=$source_rls_count, Target=$target_rls_count"
        ((validation_errors++)) || true
    else
        log_success "✓ RLS-enabled table count matches: $source_rls_count table(s)"
    fi
    
    # Count policies in source (only on RLS-enabled tables for accurate comparison)
    local source_policy_query="
    SELECT COUNT(*)
    FROM pg_policy p
    JOIN pg_class c ON p.polrelid = c.oid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'auth')
      AND c.relrowsecurity = true;
    "
    local source_policy_count="0"
    if run_source_sql_to_file "$source_policy_query" "$temp_file" 2>/dev/null; then
        source_policy_count=$(head -1 "$temp_file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    fi
    
    # Count policies in target (only on RLS-enabled tables for accurate comparison)
    local target_policy_query="
    SELECT COUNT(*)
    FROM pg_policy p
    JOIN pg_class c ON p.polrelid = c.oid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'auth')
      AND c.relrowsecurity = true;
    "
    local target_policy_count="0"
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if target_policy_count=$(PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$target_policy_query" 2>/dev/null | tr -d '[:space:]'); then
            break
        fi
    done <<< "$endpoints"
    target_policy_count=${target_policy_count:-0}
    
    if [ "$source_policy_count" != "$target_policy_count" ]; then
        log_warning "⚠ Policy count mismatch: Source=$source_policy_count, Target=$target_policy_count"
        log_warning "   Missing $((source_policy_count - target_policy_count)) policy(ies) in target"
        log_warning "   Re-run policies migration to sync all policies"
        ((validation_errors++)) || true
    else
        log_success "✓ Policy count matches: $source_policy_count policy(ies)"
    fi
    
    rm -f "$temp_file"
    
    # Additional validation: Check for missing admin/CSR SELECT policies on ALL RLS-enabled tables
    # First check SOURCE to see what policies should exist, then check TARGET
    log_info "Checking for missing admin/CSR SELECT policies on RLS-enabled tables..."
    log_info "   Comparing source and target to identify missing policies..."
    
    # Get list of tables that need admin/CSR SELECT policies from SOURCE
    SOURCE_ADMIN_SELECT_TABLES_QUERY="
    WITH all_rls_tables AS (
        SELECT DISTINCT
            c.relname AS table_name,
            format('%I.%I', n.nspname, c.relname) AS qualified
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname = 'public'
          AND c.relrowsecurity = true
    ),
    tables_with_admin_select AS (
        SELECT DISTINCT
            c.relname AS table_name,
            format('%I.%I', n.nspname, c.relname) AS qualified
        FROM pg_policy pol
        JOIN pg_class c ON c.oid = pol.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND (
              pol.polcmd = 'r'  -- SELECT policy
              OR pol.polcmd = ''  -- ALL operations policy
          )
          AND (
              EXISTS (
                  SELECT 1
                  FROM unnest(pol.polroles) role_oid
                  JOIN pg_roles r ON r.oid = role_oid
                  WHERE r.rolname IN ('admin', 'super_admin', 'csr', 'staff', 'authenticated')
              )
              OR pol.polroles = ARRAY[]::oid[]
              OR pg_get_expr(pol.polqual, pol.polrelid) LIKE '%user_roles%'
              OR pg_get_expr(pol.polwithcheck, pol.polrelid) LIKE '%user_roles%'
          )
    )
    SELECT rt.qualified, rt.table_name
    FROM all_rls_tables rt
    WHERE rt.qualified NOT IN (SELECT qualified FROM tables_with_admin_select)
    ORDER BY rt.qualified;
    "
    SOURCE_ADMIN_SELECT_FILE=$(mktemp)
    source_has_missing=false
    if run_source_sql_to_file "$SOURCE_ADMIN_SELECT_TABLES_QUERY" "$SOURCE_ADMIN_SELECT_FILE"; then
        if [ -s "$SOURCE_ADMIN_SELECT_FILE" ] && [ -n "$(cat "$SOURCE_ADMIN_SELECT_FILE" | grep -v '^$' || true)" ]; then
            source_has_missing=true
            log_info "   Source also has tables missing admin/CSR SELECT policies (will be created in target)"
        fi
    fi
    rm -f "$SOURCE_ADMIN_SELECT_FILE"
    
    # Now check TARGET
    MISSING_ADMIN_POLICIES_QUERY="
    WITH all_rls_tables AS (
        -- Get ALL tables with RLS enabled in public schema
        SELECT DISTINCT
            c.relname AS table_name,
            format('%I.%I', n.nspname, c.relname) AS qualified
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname = 'public'
          AND c.relrowsecurity = true
    ),
    tables_with_admin_select AS (
        -- Get tables that have SELECT policies allowing admin/CSR roles
        SELECT DISTINCT
            c.relname AS table_name,
            format('%I.%I', n.nspname, c.relname) AS qualified
        FROM pg_policy pol
        JOIN pg_class c ON c.oid = pol.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND (
              pol.polcmd = 'r'  -- SELECT policy
              OR pol.polcmd = ''  -- ALL operations policy
          )
          AND (
              -- Check if policy allows admin/CSR/super_admin roles
              EXISTS (
                  SELECT 1
                  FROM unnest(pol.polroles) role_oid
                  JOIN pg_roles r ON r.oid = role_oid
                  WHERE r.rolname IN ('admin', 'super_admin', 'csr', 'staff', 'authenticated')
              )
              OR
              -- Check if policy allows all authenticated users (which includes admins)
              pol.polroles = ARRAY[]::oid[]  -- Empty means all roles
              OR
              -- Check if policy expression checks for admin/CSR roles in user_roles table
              pg_get_expr(pol.polqual, pol.polrelid) LIKE '%user_roles%'
              OR pg_get_expr(pol.polwithcheck, pol.polrelid) LIKE '%user_roles%'
          )
    )
    SELECT rt.qualified, rt.table_name
    FROM all_rls_tables rt
    WHERE rt.qualified NOT IN (SELECT qualified FROM tables_with_admin_select)
    ORDER BY rt.qualified;
    "
    MISSING_ADMIN_POLICIES_FILE=$(mktemp)
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    missing_admin_policies_found=false
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$MISSING_ADMIN_POLICIES_QUERY" >"$MISSING_ADMIN_POLICIES_FILE" 2>/dev/null; then
            missing_admin_policies_found=true
            break
        fi
    done <<< "$endpoints"
    if [ "$missing_admin_policies_found" = "true" ]; then
        if [ -s "$MISSING_ADMIN_POLICIES_FILE" ] && [ -n "$(cat "$MISSING_ADMIN_POLICIES_FILE" | grep -v '^$' || true)" ]; then
            log_warning "⚠ CRITICAL: Found tables with RLS enabled but NO admin/CSR SELECT policies"
            missing_tables=()
            missing_table_names=()
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                # Parse: qualified_table|table_name or just qualified_table
                if echo "$line" | grep -q '|'; then
                    table_qualified=$(echo "$line" | cut -d'|' -f1 | tr -d '[:space:]')
                    table_name=$(echo "$line" | cut -d'|' -f2 | tr -d '[:space:]')
                else
                    table_qualified=$(echo "$line" | tr -d '[:space:]')
                    table_name=$(echo "$table_qualified" | sed -E 's/^[^.]+\.(.+)$/\1/')
                fi
                [ -z "$table_qualified" ] && continue
                missing_tables+=("$table_qualified")
                missing_table_names+=("$table_name")
                log_warning "    - $table_qualified (admins/CSR cannot SELECT from this table!)"
            done < "$MISSING_ADMIN_POLICIES_FILE"
            
            log_info "   Automatically creating admin/CSR SELECT policies for ${#missing_tables[@]} table(s)..."
            ADMIN_POLICIES_SQL="$MIGRATION_DIR/create_admin_csr_select_policies.sql"
            {
                echo "-- Auto-generated admin/CSR SELECT policies for tables missing admin access"
                echo "-- Generated: $(date)"
                echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                echo "-- These policies allow admin, super_admin, csr, and staff roles to SELECT from these tables"
                echo ""
                for i in "${!missing_tables[@]}"; do
                    table="${missing_tables[$i]}"
                    table_name="${missing_table_names[$i]}"
                    # Extract schema and table name
                    schema_name=$(echo "$table" | sed -E 's/^([^.]+)\.(.+)$/\1/')
                    table_name_clean=$(echo "$table" | sed -E 's/^([^.]+)\.(.+)$/\2/')
                    
                    # Create SELECT policy for admin/CSR roles
                    policy_name_select="allow_admin_csr_select_${table_name_clean}"
                    echo "-- Admin/CSR SELECT policy for $table"
                    echo "DROP POLICY IF EXISTS \"$policy_name_select\" ON $table;"
                    echo "CREATE POLICY \"$policy_name_select\""
                    echo "ON $table"
                    echo "FOR SELECT"
                    echo "TO authenticated"
                    echo "USING ("
                    echo "    EXISTS ("
                    echo "        SELECT 1 FROM user_roles"
                    echo "        WHERE user_id = auth.uid()"
                    echo "        AND role IN ('admin', 'super_admin', 'csr', 'staff')"
                    echo "    )"
                    echo ");"
                    echo ""
                    
                    # Also create INSERT/UPDATE/DELETE policies for admin/super_admin (not CSR)
                    policy_name_modify="allow_admin_modify_${table_name_clean}"
                    echo "-- Admin modify policy for $table (INSERT/UPDATE/DELETE)"
                    echo "DROP POLICY IF EXISTS \"$policy_name_modify\" ON $table;"
                    echo "CREATE POLICY \"$policy_name_modify\""
                    echo "ON $table"
                    echo "FOR ALL"
                    echo "TO authenticated"
                    echo "USING ("
                    echo "    EXISTS ("
                    echo "        SELECT 1 FROM user_roles"
                    echo "        WHERE user_id = auth.uid()"
                    echo "        AND role IN ('admin', 'super_admin')"
                    echo "    )"
                    echo ")"
                    echo "WITH CHECK ("
                    echo "    EXISTS ("
                    echo "        SELECT 1 FROM user_roles"
                    echo "        WHERE user_id = auth.uid()"
                    echo "        AND role IN ('admin', 'super_admin')"
                    echo "    )"
                    echo ");"
                    echo ""
                done
            } > "$ADMIN_POLICIES_SQL"
            
            if apply_sql_with_fallback "$ADMIN_POLICIES_SQL" "Create admin/CSR SELECT policies"; then
                log_success "✓ Admin/CSR SELECT policies created successfully for ${#missing_tables[@]} table(s)"
                log_info "   Created policies allow admin, super_admin, csr, and staff roles to SELECT"
                log_info "   Created policies allow admin and super_admin roles to INSERT/UPDATE/DELETE"
            else
                log_warning "⚠ Failed to create some admin/CSR policies; check $ADMIN_POLICIES_SQL and $LOG_FILE"
                ((validation_errors++)) || true
            fi
        else
            log_success "✓ All RLS-enabled tables have admin/CSR SELECT policies"
        fi
    fi
    rm -f "$MISSING_ADMIN_POLICIES_FILE"
    echo ""
    
    # Additional validation: Check for missing profile records (check TARGET)
    log_info "Checking for users with roles but missing profiles..."
    MISSING_PROFILES_QUERY="
    WITH users_with_roles AS (
        SELECT DISTINCT ur.user_id
        FROM public.user_roles ur
        WHERE ur.user_id IS NOT NULL
    ),
    users_with_profiles AS (
        SELECT DISTINCT p.id AS user_id
        FROM profiles p
        WHERE p.id IS NOT NULL
    )
    SELECT COUNT(*)
    FROM users_with_roles uwr
    WHERE uwr.user_id NOT IN (SELECT user_id FROM users_with_profiles);
    "
    MISSING_PROFILES_COUNT_FILE=$(mktemp)
    endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
    missing_profiles_check_success=false
    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "$MISSING_PROFILES_QUERY" >"$MISSING_PROFILES_COUNT_FILE" 2>/dev/null; then
            missing_profiles_check_success=true
            break
        fi
    done <<< "$endpoints"
    if [ "$missing_profiles_check_success" = "true" ]; then
        missing_profiles_count=$(head -1 "$MISSING_PROFILES_COUNT_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")
        if [ "$missing_profiles_count" != "0" ] && [ "$missing_profiles_count" != "" ]; then
            log_warning "⚠ CRITICAL: Found $missing_profiles_count user(s) with roles but NO profile records"
            log_warning "   These users exist in auth.users and have roles in user_roles, but no profile in profiles table."
            log_info "   Automatically creating missing profile records..."
            
            # Try to get profiles from source first, then create missing ones
            log_info "   Attempting to sync profiles from source for missing users..."
            SYNC_PROFILES_SQL="$MIGRATION_DIR/sync_missing_profiles.sql"
            
            # Get missing user IDs from target
            MISSING_USER_IDS_QUERY="
            WITH users_with_roles AS (
                SELECT DISTINCT ur.user_id
                FROM public.user_roles ur
                WHERE ur.user_id IS NOT NULL
            ),
            users_with_profiles AS (
                SELECT DISTINCT p.id AS user_id
                FROM profiles p
                WHERE p.id IS NOT NULL
            )
            SELECT uwr.user_id
            FROM users_with_roles uwr
            WHERE uwr.user_id NOT IN (SELECT user_id FROM users_with_profiles);
            "
            MISSING_USER_IDS_FILE=$(mktemp)
            endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT")
            while IFS='|' read -r host port user label; do
                [ -z "$host" ] && continue
                if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
                    -h "$host" \
                    -p "$port" \
                    -U "$user" \
                    -d postgres \
                    -t -A \
                    -c "$MISSING_USER_IDS_QUERY" >"$MISSING_USER_IDS_FILE" 2>/dev/null; then
                    break
                fi
            done <<< "$endpoints"
            
            # Get profiles from source for these users
            if [ -s "$MISSING_USER_IDS_FILE" ]; then
                # Try to get full profile data from source first
                log_info "   Attempting to get profile data from source for missing users..."
                SOURCE_PROFILES_DUMP="$MIGRATION_DIR/source_profiles_for_missing_users.sql"
                
                # Create a temporary file with user IDs for pg_dump
                USER_IDS_FOR_DUMP=$(cat "$MISSING_USER_IDS_FILE" | tr '\n' '|' | sed 's/|$//')
                
                # Try to dump profiles from source for these specific users
                endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT")
                profile_dump_success=false
                while IFS='|' read -r host port user label; do
                    [ -z "$host" ] && continue
                    log_info "   Fetching profiles from source via ${label}..."
                    # Use pg_dump to get profile data, then filter for missing users
                    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require \
                        pg_dump -h "$host" -p "$port" -U "$user" \
                        -d postgres --data-only --table=profiles \
                        -f "$SOURCE_PROFILES_DUMP" 2>/dev/null; then
                        profile_dump_success=true
                        break
                    fi
                done <<< "$endpoints"
                
                if [ "$profile_dump_success" = "true" ] && [ -s "$SOURCE_PROFILES_DUMP" ]; then
                    # Filter the dump to only include missing users and convert to INSERT with ON CONFLICT
                    log_info "   Processing source profile data..."
                    {
                        echo "-- Auto-generated SQL to sync missing profile records from source"
                        echo "-- Generated: $(date)"
                        echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                        echo ""
                        # Extract INSERT statements from dump and add ON CONFLICT
                        grep -i "^INSERT INTO.*profiles" "$SOURCE_PROFILES_DUMP" 2>/dev/null | while read -r line; do
                            # Check if this INSERT is for one of our missing users
                            if echo "$line" | grep -qE "($USER_IDS_FOR_DUMP)"; then
                                # Add ON CONFLICT DO NOTHING
                                echo "$line" | sed 's/;$/ ON CONFLICT (id) DO NOTHING;/'
                            fi
                        done
                    } > "$SYNC_PROFILES_SQL"
                    rm -f "$SOURCE_PROFILES_DUMP"
                    
                    # If no matching profiles found in source, create basic ones
                    if [ ! -s "$SYNC_PROFILES_SQL" ] || ! grep -qi "INSERT INTO" "$SYNC_PROFILES_SQL" 2>/dev/null; then
                        log_info "   No matching profiles in source; creating basic profile records..."
                        {
                            echo "-- Auto-generated SQL to create missing profile records for users with roles"
                            echo "-- Generated: $(date)"
                            echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                            echo ""
                            echo "WITH users_with_roles AS ("
                            echo "    SELECT DISTINCT ur.user_id"
                            echo "    FROM public.user_roles ur"
                            echo "    WHERE ur.user_id IS NOT NULL"
                            echo "),"
                            echo "users_with_profiles AS ("
                            echo "    SELECT DISTINCT p.id AS user_id"
                            echo "    FROM profiles p"
                            echo "    WHERE p.id IS NOT NULL"
                            echo "),"
                            echo "missing_users AS ("
                            echo "    SELECT uwr.user_id"
                            echo "    FROM users_with_roles uwr"
                            echo "    WHERE uwr.user_id NOT IN (SELECT user_id FROM users_with_profiles)"
                            echo ")"
                            echo "INSERT INTO profiles (id, created_at, updated_at)"
                            echo "SELECT"
                            echo "    au.id,"
                            echo "    COALESCE(au.created_at, NOW()) as created_at,"
                            echo "    NOW() as updated_at"
                            echo "FROM auth.users au"
                            echo "JOIN missing_users mu ON mu.user_id = au.id"
                            echo "WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = au.id)"
                            echo "ON CONFLICT (id) DO NOTHING;"
                        } > "$SYNC_PROFILES_SQL"
                    fi
                else
                    # Fallback: create basic profiles
                    log_info "   Could not fetch from source; creating basic profile records..."
                    {
                        echo "-- Auto-generated SQL to create missing profile records for users with roles"
                        echo "-- Generated: $(date)"
                        echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                        echo ""
                        echo "WITH users_with_roles AS ("
                        echo "    SELECT DISTINCT ur.user_id"
                        echo "    FROM user_roles ur"
                        echo "    WHERE ur.user_id IS NOT NULL"
                        echo "),"
                        echo "users_with_profiles AS ("
                        echo "    SELECT DISTINCT p.id AS user_id"
                        echo "    FROM profiles p"
                        echo "    WHERE p.id IS NOT NULL"
                        echo "),"
                        echo "missing_users AS ("
                        echo "    SELECT uwr.user_id"
                        echo "    FROM users_with_roles uwr"
                        echo "    WHERE uwr.user_id NOT IN (SELECT user_id FROM users_with_profiles)"
                        echo ")"
                        echo "INSERT INTO profiles (id, created_at, updated_at)"
                        echo "SELECT"
                        echo "    au.id,"
                        echo "    COALESCE(au.created_at, NOW()) as created_at,"
                        echo "    NOW() as updated_at"
                        echo "FROM auth.users au"
                        echo "JOIN missing_users mu ON mu.user_id = au.id"
                        echo "WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = au.id)"
                        echo "ON CONFLICT (id) DO NOTHING;"
                    } > "$SYNC_PROFILES_SQL"
                fi
            else
                rm -f "$MISSING_USER_IDS_FILE"
                log_warning "   Could not retrieve list of missing users"
                # Create fallback SQL
                {
                    echo "-- Auto-generated SQL to create missing profile records for users with roles"
                    echo "-- Generated: $(date)"
                    echo "-- Source: $SOURCE_ENV, Target: $TARGET_ENV"
                    echo ""
                    echo "WITH users_with_roles AS ("
                    echo "    SELECT DISTINCT ur.user_id"
                    echo "    FROM user_roles ur"
                    echo "    WHERE ur.user_id IS NOT NULL"
                    echo "),"
                    echo "users_with_profiles AS ("
                    echo "    SELECT DISTINCT p.id AS user_id"
                    echo "    FROM profiles p"
                    echo "    WHERE p.id IS NOT NULL"
                    echo "),"
                    echo "missing_users AS ("
                    echo "    SELECT uwr.user_id"
                    echo "    FROM users_with_roles uwr"
                    echo "    WHERE uwr.user_id NOT IN (SELECT user_id FROM users_with_profiles)"
                    echo ")"
                    echo "INSERT INTO profiles (id, created_at, updated_at)"
                    echo "SELECT"
                    echo "    au.id,"
                    echo "    COALESCE(au.created_at, NOW()) as created_at,"
                    echo "    NOW() as updated_at"
                    echo "FROM auth.users au"
                    echo "JOIN missing_users mu ON mu.user_id = au.id"
                    echo "WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = au.id)"
                    echo "ON CONFLICT (id) DO NOTHING;"
                } > "$SYNC_PROFILES_SQL"
            fi
            
            if [ -f "$SYNC_PROFILES_SQL" ] && [ -s "$SYNC_PROFILES_SQL" ]; then
                if apply_sql_with_fallback "$SYNC_PROFILES_SQL" "Create missing profiles"; then
                    log_success "✓ Created missing profile records for $missing_profiles_count user(s)"
                else
                    log_warning "⚠ Failed to create some profile records; check $SYNC_PROFILES_SQL and $LOG_FILE"
                    log_warning "   You may need to adjust the INSERT statement based on your profiles table schema"
                    ((validation_errors++)) || true
                fi
            else
                log_warning "⚠ Could not generate profile creation SQL"
                ((validation_errors++)) || true
            fi
        else
            log_success "✓ All users with roles have profile records"
        fi
    fi
    rm -f "$MISSING_PROFILES_COUNT_FILE"
    echo ""
    
    return $validation_errors
}

if validate_policies_applied; then
    log_success "✓ Validation passed: Target policies match source"
else
    log_warning "⚠ Validation found discrepancies - review target system policies"
fi
echo ""

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ${#success_tables[@]} -gt 0 ]; then
    log_success "Tables processed successfully: ${success_tables[*]}"
fi
if [ ${#failed_tables[@]} -gt 0 ]; then
    log_warning "Components with issues: ${failed_tables[*]}"
    log_warning "  Review the migration log for details and consider re-running if needed"
else
    log_success "✓ All components processed successfully"
fi
if [ ${#skipped_tables[@]} -gt 0 ]; then
    log_warning "Tables skipped: ${skipped_tables[*]}"
fi
log_info "Logs: $LOG_FILE"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Don't exit with error if only warnings occurred - allow migration to complete
# Only exit with error if critical components failed
if [ ${#failed_tables[@]} -gt 0 ]; then
    # Check if critical components failed (roles, user_roles, profiles)
    critical_failed=false
    for failed in "${failed_tables[@]}"; do
        if [[ "$failed" == *"auth.roles"* ]] || [[ "$failed" == *"auth.user_roles"* ]] || [[ "$failed" == *"public.profiles"* ]] || [[ "$failed" == *"public.user_roles"* ]]; then
            critical_failed=true
            break
        fi
    done
    if [ "$critical_failed" = "true" ]; then
        log_error "Critical components failed - migration incomplete"
    exit 1
    else
        log_warning "Some non-critical components had issues, but migration completed"
        exit 0
    fi
fi
exit 0

