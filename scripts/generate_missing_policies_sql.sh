#!/bin/bash
# Generate a SQL file to apply missing RLS policies from source to target.
# Run the generated file on the TARGET database (e.g. via Supabase SQL Editor or psql).
#
# Use after a migration when policy count shows a gap (e.g. source 487, target 455).
# Usage: ./scripts/generate_missing_policies_sql.sh <source_env> <target_env> [output_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Schema filter: same as migration (exclude system/supabase-managed schemas)
SCHEMA_FILTER="n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT IN ('auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor')"

# List of policies: schema.table.policyname (one per line)
POLICY_LIST_QUERY="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor') ORDER BY schemaname, tablename, policyname;"

# Full CREATE POLICY from source (same as migration); we'll match missing by parsing lines
EXTRACT_POLICIES_QUERY="SELECT 'CREATE POLICY ' || quote_ident(pol.polname) || ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' FOR ' || CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' WHEN '*' THEN 'ALL' END || CASE WHEN array_length(pol.polroles, 1) > 0 AND (pol.polroles != ARRAY[0]::oid[]) THEN ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY quote_ident(rol.rolname)) WHEN (pol.polroles = ARRAY[0]::oid[] OR array_length(pol.polroles, 1) IS NULL) THEN ' TO public' ELSE '' END || CASE WHEN pol.polqual IS NOT NULL THEN ' USING (' || REPLACE(pg_get_expr(pol.polqual, pol.polrelid), E'\n', ' ') || ')' ELSE '' END || CASE WHEN pol.polwithcheck IS NOT NULL THEN ' WITH CHECK (' || REPLACE(pg_get_expr(pol.polwithcheck, pol.polrelid), E'\n', ' ') || ')' ELSE '' END || ';' FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles) WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT IN ('auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor') GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, pol.polqual, pol.polrelid, pol.polwithcheck, pol.polroles ORDER BY n.nspname, c.relname, pol.polname;"

usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [output_file]

Generates a SQL file containing CREATE POLICY statements for policies that exist
in source but not in target. Run the generated file on the TARGET database.

Arguments:
  source_env   Source environment (prod, test, dev, backup)
  target_env   Target environment (prod, test, dev, backup)
  output_file  Output SQL file path (optional)
               Default: apply_missing_policies_<source>_to_<target>.sql in project root

Examples:
  $0 dev test
  $0 dev test ./backups/apply_missing_policies_dev_to_test.sql

Requires: .env.local with SUPABASE_<ENV>_PROJECT_REF and SUPABASE_<ENV>_DB_PASSWORD.

EOF
    exit 0
}

run_query() {
    local ref=$1
    local password=$2
    local query=$3
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "" "6543" 2>/dev/null || true)
    while IFS='|' read -r host port user _; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql -h "$host" -p "${port:-6543}" -U "$user" -d postgres -t -A -c "$query" 2>/dev/null; then
            return 0
        fi
    done <<< "$endpoints"
    local direct_host="db.${ref}.supabase.co"
    PGPASSWORD="$password" PGSSLMODE=require psql -h "$direct_host" -p 5432 -U "postgres.${ref}" -d postgres -t -A -c "$query" 2>/dev/null || true
}

# Run a long query from a file (avoids command-line length limits)
run_query_file() {
    local ref=$1
    local password=$2
    local query_file=$3
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "" "6543" 2>/dev/null || true)
    while IFS='|' read -r host port user _; do
        [ -z "$host" ] && continue
        if PGPASSWORD="$password" PGSSLMODE=require psql -h "$host" -p "${port:-6543}" -U "$user" -d postgres -t -A -f "$query_file" 2>/dev/null; then
            return 0
        fi
    done <<< "$endpoints"
    local direct_host="db.${ref}.supabase.co"
    PGPASSWORD="$password" PGSSLMODE=require psql -h "$direct_host" -p 5432 -U "postgres.${ref}" -d postgres -t -A -f "$query_file" 2>/dev/null || true
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
OUTPUT_FILE="${3:-$PROJECT_ROOT/apply_missing_policies_${SOURCE_ENV}_to_${TARGET_ENV}.sql}"
MIGRATION_DIR="${4:-}"

# If migration dir provided and has failed policy files, use them directly
if [ -n "$MIGRATION_DIR" ] && [ -d "$MIGRATION_DIR" ]; then
    SYNC_FAILED="$MIGRATION_DIR/policy_sync_failed.sql"
    FAILED_POLICIES="$MIGRATION_DIR/failed_policies.sql"
    if [ -s "$SYNC_FAILED" ] || [ -s "$FAILED_POLICIES" ]; then
        log_info "Using failed policy files from: $MIGRATION_DIR"
        {
            echo "-- Apply missing RLS policies: $SOURCE_ENV -> $TARGET_ENV"
            echo "-- Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC"). Run on TARGET database."
            echo ""
            echo "-- Create missing policies (CREATE POLICY only; run on target)"
            [ -s "$SYNC_FAILED" ] && grep "^CREATE POLICY" "$SYNC_FAILED"
            [ -s "$FAILED_POLICIES" ] && grep "^CREATE POLICY" "$FAILED_POLICIES"
        } > "$OUTPUT_FILE"
        n=$(grep -c "^CREATE POLICY" "$OUTPUT_FILE" 2>/dev/null || echo "0")
        log_success "Wrote: $OUTPUT_FILE ($n CREATE POLICY statements)"
        exit 0
    fi
fi

load_env 2>/dev/null || true

SOURCE_REF=$(get_project_ref "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_REF=$(get_project_ref "$TARGET_ENV" 2>/dev/null || echo "")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV" 2>/dev/null || echo "")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV" 2>/dev/null || echo "")

if [ -z "$SOURCE_REF" ] || [ -z "$SOURCE_PASSWORD" ]; then
    log_error "Could not load source env ($SOURCE_ENV). Set SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF and _DB_PASSWORD in .env.local"
    exit 1
fi
if [ -z "$TARGET_REF" ] || [ -z "$TARGET_PASSWORD" ]; then
    log_error "Could not load target env ($TARGET_ENV). Set SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF and _DB_PASSWORD in .env.local"
    exit 1
fi

log_info "Source: $SOURCE_ENV (${SOURCE_REF:0:8}...) | Target: $TARGET_ENV (${TARGET_REF:0:8}...)"

# Get policy lists
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

log_info "Querying source policy list..."
run_query "$SOURCE_REF" "$SOURCE_PASSWORD" "$POLICY_LIST_QUERY" | sort -u > "$tmpdir/source.txt"

log_info "Querying target policy list..."
run_query "$TARGET_REF" "$TARGET_PASSWORD" "$POLICY_LIST_QUERY" | sort -u > "$tmpdir/target.txt"

comm -23 "$tmpdir/source.txt" "$tmpdir/target.txt" > "$tmpdir/missing.txt"
missing_count=$(wc -l < "$tmpdir/missing.txt" | tr -d '[:space:]' || echo "0")

if [ "$missing_count" -eq 0 ]; then
    log_success "No missing policies: target already has all source policies."
    exit 0
fi

log_info "Found $missing_count policy(ies) in source that are missing in target."

# Build list of tables that need RLS enabled (schema.table from missing schema.table.policyname)
sed 's/\.[^.]*$//' "$tmpdir/missing.txt" | sort -u > "$tmpdir/tables_with_missing.txt"

# Get full CREATE POLICY from source (same query as migration)
log_info "Extracting full CREATE POLICY statements from source..."
echo "$EXTRACT_POLICIES_QUERY" > "$tmpdir/extract_query.sql"
run_query_file "$SOURCE_REF" "$SOURCE_PASSWORD" "$tmpdir/extract_query.sql" > "$tmpdir/source_full.txt" 2>/dev/null || true

if [ ! -s "$tmpdir/source_full.txt" ] && [ -n "$MIGRATION_DIR" ] && [ -d "$MIGRATION_DIR" ]; then
    BP="$MIGRATION_DIR/policies_from_source_db.sql"
    [ -s "$BP" ] && grep "^CREATE POLICY" "$BP" > "$tmpdir/source_full.txt" 2>/dev/null || true
fi

if [ ! -s "$tmpdir/source_full.txt" ]; then
    log_error "Could not extract policy definitions from source."
    log_info "Tip: Pass migration backup dir as 4th arg to use policies_from_source_db.sql from that backup."
    exit 1
fi

# Build key (schema.table.policyname) for each line: parse CREATE POLICY "name" ON schema.table FOR ...
# and output only lines whose key is in missing.txt
missing_sql_file="$tmpdir/missing_policies.sql"
> "$missing_sql_file"
while IFS= read -r line; do
    [ -z "$line" ] || [[ ! "$line" =~ ^CREATE\ POLICY ]] && continue
    # Extract policy name (first quoted string after CREATE POLICY)
    policyname=$(echo "$line" | sed -n 's/.*CREATE POLICY "\([^"]*\)".*/\1/p')
    # Extract part after ON until FOR (schema.table or "schema"."table")
    table_part=$(echo "$line" | sed -n 's/.* ON \(.*\) FOR .*/\1/p')
    [ -z "$table_part" ] && continue
    # Normalize: "public"."users" -> public.users (remove quotes)
    schema_table=$(echo "$table_part" | tr -d '"')
    key="${schema_table}.${policyname}"
    if grep -Fxq "$key" "$tmpdir/missing.txt" 2>/dev/null; then
        echo "$line" >> "$missing_sql_file"
    fi
done < "$tmpdir/source_full.txt"

# Generate SQL file: ENABLE RLS for affected tables, then CREATE POLICY for each missing
{
    echo "-- Apply missing RLS policies: $SOURCE_ENV -> $TARGET_ENV"
    echo "-- Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "-- Run this script on the TARGET database (e.g. Supabase SQL Editor or psql)."
    echo "-- Missing policies: $missing_count"
    echo ""
    echo "-- Ensure RLS is enabled on tables that have missing policies"
    while IFS= read -r schema_table; do
        [ -z "$schema_table" ] && continue
        schema="${schema_table%.*}"
        table="${schema_table##*.}"
        [ -z "$schema" ] || [ -z "$table" ] && continue
        echo "ALTER TABLE \"$schema\".\"$table\" ENABLE ROW LEVEL SECURITY;"
    done < "$tmpdir/tables_with_missing.txt"
    echo ""
    echo "-- Create missing policies"
    cat "$missing_sql_file"
} > "$OUTPUT_FILE"

log_success "Wrote: $OUTPUT_FILE"
log_info "Run it on the target database, e.g.:"
log_info "  psql -h db.<TARGET_REF>.supabase.co -p 5432 -U postgres.<TARGET_REF> -d postgres -f \"$OUTPUT_FILE\""
log_info "Or paste the contents into Supabase Dashboard -> SQL Editor for the target project."
