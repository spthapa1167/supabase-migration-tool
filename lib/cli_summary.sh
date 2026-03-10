#!/bin/bash
# CLI Summary for Migration
# Prints a concise summary at the end of migration (source/target state, what changed, failures, paths).

# Run a single SQL count query (uses get_supabase_connection_endpoints from supabase_utils).
# Usage: _run_count_query <project_ref> <password> <query>
_run_count_query() {
    local project_ref="$1"
    local password="$2"
    local query="$3"
    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$project_ref" "" "6543" 2>/dev/null || true)
    local result=""
    while IFS='|' read -r host port user _; do
        [ -z "$host" ] && continue
        result=$(PGPASSWORD="$password" PGSSLMODE=require psql -h "$host" -p "${port:-6543}" -U "$user" -d postgres -t -A -c "$query" 2>/dev/null || echo "")
        [ -n "$result" ] && echo "$result" | tr -d '[:space:]' && return 0
    done <<< "$endpoints"
    local direct_host="db.${project_ref}.supabase.co"
    result=$(PGPASSWORD="$password" PGSSLMODE=require psql -h "$direct_host" -p 5432 -U "postgres.${project_ref}" -d postgres -t -A -c "$query" 2>/dev/null || echo "")
    [ -n "$result" ] && echo "$result" | tr -d '[:space:]' || echo "0"
}

# Collect object counts (source vs target) into migration_dir/object_counts.txt.
# Runs source and target counts in parallel. Non-fatal on errors.
# Expects SOURCE_ENV, TARGET_ENV; uses get_project_ref, get_db_password from supabase_utils.
collect_object_counts() {
    local migration_dir="${1:-}"
    [ -z "$migration_dir" ] || [ ! -d "$migration_dir" ] && return 0
    local out_file="$migration_dir/object_counts.txt"
    local source_ref target_ref source_pw target_pw
    source_ref=$(get_project_ref "${SOURCE_ENV:-}" 2>/dev/null || echo "")
    target_ref=$(get_project_ref "${TARGET_ENV:-}" 2>/dev/null || echo "")
    source_pw=$(get_db_password "${SOURCE_ENV:-}" 2>/dev/null || echo "")
    target_pw=$(get_db_password "${TARGET_ENV:-}" 2>/dev/null || echo "")
    [ -z "$source_ref" ] || [ -z "$target_ref" ] && return 0

    local policies_query="SELECT COUNT(*) FROM pg_policies WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'auth', 'vault', 'storage', 'realtime', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor');"
    local tables_query="SELECT COUNT(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'auth', 'storage', 'realtime', 'vault', 'pgbouncer', 'graphql_public', 'supabase_functions', 'supabase_functions_api', 'pgsodium', 'supavisor', 'extensions', 'net', 'cron');"
    local views_query="SELECT COUNT(*) FROM information_schema.views WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'auth', 'storage', 'realtime', 'vault');"
    local functions_query="SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'auth', 'storage', 'realtime', 'vault');"

    local stables sviews spolicies sfuncs ttables tviews tpolicies tfuncs
    (
        stables=$(_run_count_query "$source_ref" "$source_pw" "$tables_query")
        sviews=$(_run_count_query "$source_ref" "$source_pw" "$views_query")
        spolicies=$(_run_count_query "$source_ref" "$source_pw" "$policies_query")
        sfuncs=$(_run_count_query "$source_ref" "$source_pw" "$functions_query")
        echo "tables|${stables:-0}"
        echo "views|${sviews:-0}"
        echo "policies|${spolicies:-0}"
        echo "functions|${sfuncs:-0}"
    ) > "${out_file}.source" 2>/dev/null &
    (
        ttables=$(_run_count_query "$target_ref" "$target_pw" "$tables_query")
        tviews=$(_run_count_query "$target_ref" "$target_pw" "$views_query")
        tpolicies=$(_run_count_query "$target_ref" "$target_pw" "$policies_query")
        tfuncs=$(_run_count_query "$target_ref" "$target_pw" "$functions_query")
        echo "${ttables:-0}"
        echo "${tviews:-0}"
        echo "${tpolicies:-0}"
        echo "${tfuncs:-0}"
    ) > "${out_file}.target" 2>/dev/null &
    wait 2>/dev/null || true
    {
        paste -d '|' "${out_file}.source" "${out_file}.target" 2>/dev/null | while IFS= read -r line; do
            echo "$line"
        done
    } > "$out_file" 2>/dev/null || true
    rm -f "${out_file}.source" "${out_file}.target" 2>/dev/null || true
}

# Print migration summary to stdout and optionally append to migration.log
# Usage: print_migration_summary <migration_dir> <status>
#   migration_dir: path to the migration output directory
#   status: e.g. "✅ Completed" or "❌ Failed"
# Expects SOURCE_ENV, TARGET_ENV, MODE to be set in environment.
print_migration_summary() {
    local migration_dir="${1:-}"
    local status="${2:-Completed}"
    [ -z "$migration_dir" ] && return 0
    [ ! -d "$migration_dir" ] && return 0

    local log_file="$migration_dir/migration.log"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local source_ref=""
    local target_ref=""
    if type get_project_ref >/dev/null 2>&1; then
        source_ref=$(get_project_ref "${SOURCE_ENV:-}" 2>/dev/null || echo "—")
        target_ref=$(get_project_ref "${TARGET_ENV:-}" 2>/dev/null || echo "—")
    fi

    # Header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MIGRATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Source → Target:  ${SOURCE_ENV:-—} → ${TARGET_ENV:-—}"
    echo "  Project refs:     ${source_ref} → ${target_ref}"
    echo "  Mode:             ${MODE:-schema}"
    echo "  Status:           $status"
    echo "  Completed at:     $timestamp"
    echo ""

    # Total execution time
    local start_epoch_file="$migration_dir/migration_start_epoch.txt"
    if [ -f "$start_epoch_file" ]; then
        local start_epoch
        start_epoch=$(cat "$start_epoch_file" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
            local end_epoch
            end_epoch=$(date +%s)
            local elapsed=$((end_epoch - start_epoch))
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            if [ "$mins" -gt 0 ]; then
                echo "  Total execution time: ${mins}m ${secs}s"
            else
                echo "  Total execution time: ${secs}s"
            fi
            echo ""
        fi
    fi

    # Object counts (source vs target)
    local counts_file="$migration_dir/object_counts.txt"
    if [ -f "$counts_file" ] && [ -s "$counts_file" ]; then
        echo "  --- Object counts (Source vs Target) ---"
        printf "  %-16s %10s %10s\n" "Object" "Source" "Target"
        echo "  $(printf '%.0s-' {1..38})"
        while IFS='|' read -r obj src tgt _; do
            [ -z "$obj" ] && continue
            printf "  %-16s %10s %10s\n" "$obj" "${src:-—}" "${tgt:-—}"
        done < "$counts_file"
        echo ""
    fi

    # Source vs target (from comparison file if no object_counts)
    local comparison_file="$migration_dir/comparison_details.txt"
    if [ ! -f "$counts_file" ] || [ ! -s "$counts_file" ]; then
    if [ -f "$comparison_file" ]; then
        echo "  --- Source vs target (counts) ---"
        # Show first 30 lines of comparison to avoid flooding; user can open file for full
        head -30 "$comparison_file" | sed 's/^/  /'
        local lines
        lines=$(wc -l < "$comparison_file" 2>/dev/null || echo "0")
        if [ "${lines:-0}" -gt 30 ]; then
            echo "  ... (see $comparison_file for full comparison)"
        fi
        echo ""
    fi
    fi

    # What was done (from log)
    echo "  --- What was done ---"
    if [ -f "$log_file" ]; then
        if grep -q "Schema.*applied\|Database schema\|policies applied" "$log_file" 2>/dev/null; then
            echo "  • Schema + policies applied"
        fi
        if grep -q "data migrated\|Data migration\|replace.*data" "$log_file" 2>/dev/null; then
            echo "  • Data migrated"
        fi
        if grep -q "Storage buckets\|storage.*migrated\|bucket" "$log_file" 2>/dev/null; then
            echo "  • Storage buckets migrated"
        fi
        if grep -q "Edge functions deployed\|Deployed:" "$log_file" 2>/dev/null; then
            echo "  • Edge functions deployed"
        fi
        if grep -q "Secrets.*created\|Secrets structure\|secret.*set" "$log_file" 2>/dev/null; then
            echo "  • Secrets structure synced"
        fi
    fi
    echo ""

    # Failures / warnings
    local failed_artifacts=()
    [ -f "$migration_dir/failed_policies.sql" ] && failed_artifacts+=("failed_policies.sql")
    [ -f "$migration_dir/policy_sync_failed.sql" ] && failed_artifacts+=("policy_sync_failed.sql")
    [ -f "$migration_dir/grants_failed.sql" ] && failed_artifacts+=("grants_failed.sql")
    if [ ${#failed_artifacts[@]} -gt 0 ]; then
        echo "  --- Failures / warnings ---"
        echo "  Some statements could not be applied; see:"
        for f in "${failed_artifacts[@]}"; do
            echo "    $migration_dir/$f"
        done
        echo ""
    fi
    # Manual policy file (if gap remained after auto delta)
    local manual_policy_file
    manual_policy_file=$(echo "$migration_dir"/apply_missing_policies_manual_*.sql 2>/dev/null)
    if [ -f "$manual_policy_file" ]; then
        echo "  --- Manual step (policy gap) ---"
        echo "  Run this SQL in Supabase SQL Editor (target project) to apply remaining policies:"
        echo "    $manual_policy_file"
        echo ""
    fi
    if [ -f "$log_file" ] && grep -qiE "ERROR|FATAL|failed" "$log_file" 2>/dev/null; then
        echo "  Check migration.log for errors."
        echo ""
    fi

    # Paths
    echo "  --- Paths ---"
    echo "  Migration dir:  $migration_dir"
    echo "  Log file:        $log_file"
    echo "  Result file:     $migration_dir/result.md"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Append summary to migration.log
    if [ -f "$log_file" ]; then
        {
            echo "[$timestamp] [INFO] --- CLI Summary ---"
            echo "  Source → Target: ${SOURCE_ENV:-—} → ${TARGET_ENV:-—} | Mode: ${MODE:-schema} | Status: $status"
            echo "  Migration dir: $migration_dir | Log: $log_file"
            if [ -f "$start_epoch_file" ]; then
                start_epoch=$(cat "$start_epoch_file" 2>/dev/null | tr -d '[:space:]')
                if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
                    end_epoch=$(date +%s)
                    elapsed=$((end_epoch - start_epoch))
                    mins=$((elapsed / 60))
                    secs=$((elapsed % 60))
                    echo "  Total execution time: ${mins}m ${secs}s"
                fi
            fi
        } >> "$log_file" 2>/dev/null || true
    fi
}
