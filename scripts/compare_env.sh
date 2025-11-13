#!/bin/bash
# Compare Supabase environments and optionally apply incremental patch migration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
AUTO_APPLY=false

usage() {
    cat <<'EOF'
Usage: compare_env.sh <source_env> <target_env> [--auto-apply]

Example:
  ./scripts/compare_env.sh prod dev

Generates table row count differences between source and target, then offers to
run an incremental data patch (supabase_migration.sh --data --increment --users).
EOF
    exit 1
}

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi
shift 2 || true

while [ $# -gt 0 ]; do
    case "$1" in
        --auto-apply|--apply)
            AUTO_APPLY=true
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift || true
done

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
    log_error "python3 or python is required to analyze differences."
    exit 1
fi

collect_table_counts() {
    local ref=$1
    local password=$2
    local pooler_region=$3
    local pooler_port=$4

    local endpoints
    endpoints=$(get_supabase_connection_endpoints "$ref" "$pooler_region" "$pooler_port")

    local output
    local query
    read -r -d '' query <<'SQL' || true
CREATE TEMP TABLE tmp_table_counts(table_name text, row_count bigint);
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_type='BASE TABLE'
          AND table_schema NOT IN ('pg_catalog','information_schema')
    LOOP
        EXECUTE format('INSERT INTO tmp_table_counts VALUES (%L, (SELECT COUNT(*) FROM %I.%I))',
                       rec.table_schema || '.' || rec.table_name,
                       rec.table_schema, rec.table_name);
    END LOOP;
END $$;
SELECT coalesce(jsonb_object_agg(table_name, row_count)::text, '{}'::text) FROM tmp_table_counts;
SQL

    while IFS='|' read -r host port user label; do
        [ -z "$host" ] && continue
        local output
        output=$(PGPASSWORD="$password" PGSSLMODE=require \
            psql -h "$host" -p "$port" -U "$user" -d postgres \
            -v ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
            -c "$query" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$output" ]; then
            # Grab the last non-empty line; DO/NOTICE tags come first.
            local clean_output
            clean_output=$(printf '%s\n' "$output" | awk 'NF {last=$0} END {print last}')
            if [ -n "$clean_output" ]; then
                # Ensure the line is valid JSON before returning.
                if echo "$clean_output" | "$PYTHON_BIN" -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
                    echo "$clean_output"
                    return 0
                fi
            fi
        fi
        log_warning "Failed to gather counts via ${label}; trying next endpoint..." >&2
    done <<< "$endpoints"
    return 1
}

log_info "Collecting table counts from $SOURCE_ENV..."
if ! SOURCE_JSON=$(collect_table_counts "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_POOLER_REGION" "$SOURCE_POOLER_PORT"); then
    log_error "Unable to collect table counts from $SOURCE_ENV"
    exit 1
fi
if [ -z "$SOURCE_JSON" ]; then
    log_error "No table counts received from $SOURCE_ENV"
    exit 1
fi

log_info "Collecting table counts from $TARGET_ENV..."
if ! TARGET_JSON=$(collect_table_counts "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT"); then
    log_error "Unable to collect table counts from $TARGET_ENV"
    exit 1
fi
if [ -z "$TARGET_JSON" ]; then
    log_error "No table counts received from $TARGET_ENV"
    exit 1
fi

DIFF_JSON=$(SOURCE_JSON="$SOURCE_JSON" TARGET_JSON="$TARGET_JSON" "$PYTHON_BIN" <<'PY'
import json, os
src = json.loads(os.environ["SOURCE_JSON"])
tgt = json.loads(os.environ["TARGET_JSON"])
tables = sorted(set(src) | set(tgt))

diff = []
missing = []
extra = []
for tbl in tables:
    sc = src.get(tbl, 0)
    tc = tgt.get(tbl, 0)
    if sc != tc:
        diff.append({"table": tbl, "source": sc, "target": tc, "delta": sc - tc})
        if sc > tc:
            missing.append(tbl)
        elif tc > sc:
            extra.append(tbl)

summary = {
    "source_tables": len(src),
    "target_tables": len(tgt),
    "source_rows": sum(src.values()),
    "target_rows": sum(tgt.values()),
    "diff": diff,
    "missing": missing,
    "extra": extra,
}

print(json.dumps(summary))
PY
)

if [ -z "$DIFF_JSON" ]; then
    echo "[ERROR] No comparison data generated."
    exit 1
fi

diff_count=$(DIFF_JSON="$DIFF_JSON" "$PYTHON_BIN" -c 'import json, os; data=json.loads(os.environ["DIFF_JSON"]); print(len(data["diff"]))')

echo "=================================================================="
echo "Environment Comparison ($SOURCE_ENV ➜ $TARGET_ENV)"
echo "------------------------------------------------------------------"
# Print summary safely
DIFF_SUMMARY=$(DIFF_JSON="$DIFF_JSON" "$PYTHON_BIN" <<'PY'
import json, os, sys

raw = os.environ.get("DIFF_JSON", "").strip()
if not raw:
    print("[ERROR] Comparison data malformed:")
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("[ERROR] Comparison data malformed:")
    print(raw)
    sys.exit(1)

print(f"Source tables : {data['source_tables']}")
print(f"Target tables : {data['target_tables']}")
print(f"Source rows   : {data['source_rows']}")
print(f"Target rows   : {data['target_rows']}")
print("")
if data['diff']:
    print("Tables with mismatched row counts:")
    for row in data['diff']:
        delta=row['delta']
        status="missing" if delta>0 else "extra"
        print(f"  {row['table']:<40} source={row['source']:<8} target={row['target']:<8} ({status} {abs(delta)})")
else:
    print("✅ All table row counts match.")
PY
)
if [ -z "$DIFF_SUMMARY" ]; then
    echo "[ERROR] Comparison data malformed:"
    echo "$DIFF_JSON"
    exit 1
fi
printf '%s\n' "$DIFF_SUMMARY"
echo "=================================================================="

if [ "$diff_count" -eq 0 ]; then
    echo "[INFO] No differences detected. Nothing to patch."
    exit 0
fi

if [ "$AUTO_APPLY" != "true" ]; then
    echo ""
    if [ -t 0 ]; then
        if ! read -r -p "Apply incremental patch migration to fill gaps? [y/N]: " reply; then
            reply=""
        fi
    else
        echo "[INFO] Non-interactive session detected; skipping patch migration."
        exit 2
    fi
    reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$reply" != "y" ] && [ "$reply" != "yes" ]; then
        echo "[INFO] Skipping patch migration."
        exit 2
    fi
fi

PATCH_CMD=(
    "$PROJECT_ROOT/scripts/supabase_migration.sh"
    "$SOURCE_ENV"
    "$TARGET_ENV"
    --data
    --users
    --increment
    --auto-confirm
)

echo "[INFO] Running incremental data patch..."
if ! "${PATCH_CMD[@]}"; then
    echo "[ERROR] Incremental patch failed."
    exit 3
fi

POLICIES_SCRIPT="$PROJECT_ROOT/scripts/policies_migration.sh"
if [ -x "$POLICIES_SCRIPT" ]; then
    echo "[INFO] Syncing custom role/profile tables..."
    "$POLICIES_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --auto-confirm || true
fi

RETRY_SCRIPT="$PROJECT_ROOT/scripts/retry_edge_functions.sh"
if [ -x "$RETRY_SCRIPT" ]; then
    echo "[INFO] Retrying edge functions (if any failed in previous run)..."
    "$RETRY_SCRIPT" "$SOURCE_ENV" "$TARGET_ENV" --allow-missing || true
fi

echo "[SUCCESS] Incremental patch migration completed."
echo "Re-run ./scripts/compare_env.sh $SOURCE_ENV $TARGET_ENV to verify counts."

