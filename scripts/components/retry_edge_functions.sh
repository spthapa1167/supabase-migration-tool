#!/bin/bash
# Retry failed edge function deployments using the recorded failure list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env> [latest_edge_functions_dir|--dir path] [options]

Retries only the edge functions that previously failed to deploy.
If no directory is provided, the most recent edge functions migration folder
for the source/target pair is used automatically.

Options:
  --dir <path>           Explicit migration directory containing edge_functions_failed.txt
  --failed-file <path>   Override the failed functions list path
  --allow-missing        Ignore missing functions in the retry list (default: enabled)
  -h, --help             Show this help message and exit

Examples:
  $0 prod dev
  $0 prod dev backups/edge_functions_migration_prod_to_dev_20251112_172921
  $0 prod dev --dir backups/edge_functions_retry_migration_prod_to_dev_20251112_181500
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
shift 2 || true

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    log_error "Source and target environments are required."
    usage
    exit 1
fi

MIGRATION_DIR_INPUT=""
FAILED_FILE_INPUT=""
ALLOW_MISSING=true  # Retry flow should tolerate missing names by default

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)
            MIGRATION_DIR_INPUT=${2:-}
            shift
            ;;
        --dir=*)
            MIGRATION_DIR_INPUT="${1#*=}"
            ;;
        --failed-file)
            FAILED_FILE_INPUT=${2:-}
            shift
            ;;
        --failed-file=*)
            FAILED_FILE_INPUT="${1#*=}"
            ;;
        --allow-missing)
            ALLOW_MISSING=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$MIGRATION_DIR_INPUT" ]; then
                MIGRATION_DIR_INPUT="$1"
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

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

find_latest_migration_dir() {
    local pattern_source="backups/edge_functions_migration_${SOURCE_ENV}_to_${TARGET_ENV}_*"
    local pattern_retry="backups/edge_functions_retry_migration_${SOURCE_ENV}_to_${TARGET_ENV}_*"

    local candidates=()
    shopt -s nullglob
    candidates+=($pattern_source)
    candidates+=($pattern_retry)
    shopt -u nullglob

    if [ ${#candidates[@]} -eq 0 ]; then
        echo ""
        return 0
    fi

    local latest
    latest=$(ls -1dt "${candidates[@]}" 2>/dev/null | head -n 1 || true)
    echo "$latest"
}

if [ -z "$MIGRATION_DIR_INPUT" ]; then
    MIGRATION_DIR_INPUT=$(find_latest_migration_dir)
fi

if [ -z "$MIGRATION_DIR_INPUT" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  No Edge Functions Migration Found"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "No edge functions migration directory found for ${SOURCE_ENV} -> ${TARGET_ENV}."
    log_info "This means there's nothing to retry - either:"
    log_info "  • No edge functions migration has been run yet, or"
    log_info "  • All edge functions were successfully deployed (no failures to retry)"
    echo ""
    log_info "To retry specific functions, you can:"
    log_info "  1. Run the main migration first: ./scripts/main/supabase_migration.sh ${SOURCE_ENV} ${TARGET_ENV}"
    log_info "  2. Or provide a migration directory explicitly: $0 ${SOURCE_ENV} ${TARGET_ENV} --dir <path>"
    echo ""
    exit 0
fi

if [ ! -d "$MIGRATION_DIR_INPUT" ]; then
    log_error "Specified migration directory does not exist: $MIGRATION_DIR_INPUT"
    exit 1
fi

MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR_INPUT" && pwd)"
log_info "Using migration directory: $MIGRATION_DIR_ABS"

FAILED_FILE=${FAILED_FILE_INPUT:-"$MIGRATION_DIR_ABS/edge_functions_failed.txt"}
if [ ! -f "$FAILED_FILE" ]; then
    log_error "Failed functions list not found: $FAILED_FILE"
    log_error "Ensure the initial edge functions migration completed and recorded failures."
    exit 1
fi

FAILED_FUNCTIONS=()
while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$trimmed" ] && [[ ! "$trimmed" =~ ^# ]]; then
        FAILED_FUNCTIONS+=("$trimmed")
    fi
done < "$FAILED_FILE"

if [ ${#FAILED_FUNCTIONS[@]} -eq 0 ]; then
    log_success "No failed edge functions recorded in $FAILED_FILE. Nothing to retry."
    exit 0
fi

log_info "Preparing to retry ${#FAILED_FUNCTIONS[@]} edge function(s)."

RETRY_DIR_RELATIVE=$(create_backup_dir "edge_functions_retry" "$SOURCE_ENV" "$TARGET_ENV")
RETRY_DIR_ABS="$(cd "$RETRY_DIR_RELATIVE" && pwd)"
log_info "Retry attempt directory: $RETRY_DIR_ABS"

EDGE_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/edge-functions-migration.js"
if [ ! -f "$EDGE_FUNCTIONS_UTIL" ]; then
    log_error "Edge functions utility not found at $EDGE_FUNCTIONS_UTIL"
    exit 1
fi

RETRY_LOG="$RETRY_DIR_ABS/migration.log"
touch "$RETRY_LOG"

set +o pipefail
if node "$EDGE_FUNCTIONS_UTIL" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$RETRY_DIR_ABS" \
    --filter-file="$FAILED_FILE" \
    ${ALLOW_MISSING:+--allow-missing} \
    2>&1 | tee -a "$RETRY_LOG"; then
    NODE_EXIT=${PIPESTATUS[0]}
else
    NODE_EXIT=${PIPESTATUS[0]}
fi
set -o pipefail

if [ "$NODE_EXIT" -ne 0 ]; then
    log_warning "Node utility returned exit code $NODE_EXIT. Review $RETRY_LOG for details."
fi

RETRY_FAILED_FILE="$RETRY_DIR_ABS/edge_functions_failed.txt"
RETRY_MIGRATED_FILE="$RETRY_DIR_ABS/edge_functions_migrated.txt"
ORIG_MIGRATED_FILE="$MIGRATION_DIR_ABS/edge_functions_migrated.txt"

if [ -f "$RETRY_FAILED_FILE" ] && [ -s "$RETRY_FAILED_FILE" ]; then
    cp "$RETRY_FAILED_FILE" "$FAILED_FILE"
    REMAINING=$(wc -l < "$FAILED_FILE" | tr -d '[:space:]')
    log_warning "$REMAINING edge function(s) still failing after retry. Remaining list saved to $FAILED_FILE"
else
    : > "$FAILED_FILE"
    log_success "All retried edge functions deployed successfully. Cleared failure list at $FAILED_FILE"
fi

python <<'PY' "$(realpath "$FAILED_FILE")" "$(realpath "$ORIG_MIGRATED_FILE")" "$(realpath "$RETRY_MIGRATED_FILE")" >/dev/null 2>&1 || true
import sys
from pathlib import Path

failed_file = Path(sys.argv[1])
orig_migrated = Path(sys.argv[2])
retry_migrated = Path(sys.argv[3])

def read_list(path: Path):
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]

def write_list(path: Path, items):
    if items:
        path.write_text("\n".join(items) + "\n")
    else:
        path.write_text("")

merged_migrated = []
seen = set()
for source in (orig_migrated, retry_migrated):
    for item in read_list(source):
        if item not in seen:
            merged_migrated.append(item)
            seen.add(item)

if merged_migrated:
    write_list(orig_migrated, merged_migrated)

# Ensure failure file has normalized newline formatting
remaining = read_list(failed_file)
write_list(failed_file, remaining)
PY

ORIG_SUMMARY_JSON="$MIGRATION_DIR_ABS/edge_functions_summary.json"
RETRY_SUMMARY_JSON="$RETRY_DIR_ABS/edge_functions_summary.json"

python <<'PY' "$(realpath "$ORIG_SUMMARY_JSON")" "$(realpath "$RETRY_SUMMARY_JSON")" "$(realpath "$FAILED_FILE")" >/dev/null 2>&1 || true
import json
import sys
from pathlib import Path

orig_path = Path(sys.argv[1])
retry_path = Path(sys.argv[2])
failed_path = Path(sys.argv[3])

def load_json(path: Path):
    if path.exists():
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            return {}
    return {}

def read_list(path: Path):
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]

orig = load_json(orig_path)
retry = load_json(retry_path)
failed = read_list(failed_path)

if not orig:
    orig = {}

attempt_history = orig.get("attempt_history", [])
if retry:
    attempt_history.append({
        "timestamp": retry.get("timestamp"),
        "attempted": retry.get("attempted", []),
        "migrated": retry.get("migrated", []),
        "failed": retry.get("failed", []),
        "skipped": retry.get("skipped", [])
    })

merged_migrated = []
seen = set()
for attempt in attempt_history:
    for item in attempt.get("migrated", []):
        if item not in seen:
            merged_migrated.append(item)
            seen.add(item)

orig["attempt_history"] = attempt_history
if retry.get("timestamp"):
    orig["updated_at"] = retry["timestamp"]
if "sourceRef" not in orig and retry.get("sourceRef"):
    orig["sourceRef"] = retry["sourceRef"]
if "targetRef" not in orig and retry.get("targetRef"):
    orig["targetRef"] = retry["targetRef"]

orig["migrated"] = merged_migrated
orig["failed"] = failed

orig_path.write_text(json.dumps(orig, indent=2))
PY

log_success "Retry attempt completed. Detailed logs: $RETRY_LOG"

if [ -s "$FAILED_FILE" ]; then
    log_warning "Remaining functions still need manual attention or additional retries."
    log_info "Use this command to retry again if desired:"
    log_info "  ./scripts/components/retry_edge_functions.sh $SOURCE_ENV $TARGET_ENV \"$RETRY_DIR_ABS\""
else
    log_success "Edge functions for ${SOURCE_ENV} -> ${TARGET_ENV} are fully synchronized."
fi

exit "$NODE_EXIT"

