#!/bin/bash
# Wrapper that invokes the Node-based edge function comparison utility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

cd "$PROJECT_ROOT"
if ! load_env >/dev/null 2>&1; then
    log_error "Unable to load environment variables from .env.local"
    exit 1
fi

usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env> [output_dir]

Compares edge functions between two Supabase environments using the Node-based
utility. Generates JSON and HTML reports with edge-only information.
EOF
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2
OUTPUT_DIR=${3:-"$PROJECT_ROOT/migration_plans"}

if [ "$SOURCE_ENV" = "$TARGET_ENV" ]; then
    log_error "Source and target environments must be different"
    exit 1
fi

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js is required to compare edge functions"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required to parse comparison results"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TMP_JSON_OUTPUT=$(mktemp)
if ! node "$PROJECT_ROOT/utils/edge-functions-compare.js" "$SOURCE_ENV" "$TARGET_ENV" "$OUTPUT_DIR" >"$TMP_JSON_OUTPUT"; then
    cat "$TMP_JSON_OUTPUT" >&2
    rm -f "$TMP_JSON_OUTPUT"
    exit 1
fi

NODE_OUTPUT=$(cat "$TMP_JSON_OUTPUT")
rm -f "$TMP_JSON_OUTPUT"

JSON_PATH=$(echo "$NODE_OUTPUT" | jq -r '.json_path')
HTML_PATH=$(echo "$NODE_OUTPUT" | jq -r '.html_path')
SUMMARY=$(echo "$NODE_OUTPUT" | jq -c '.summary')

if [ -z "$JSON_PATH" ] || [ "$JSON_PATH" = "null" ]; then
    log_error "Comparison did not return a JSON diff path"
    exit 1
fi

log_success "Edge function comparison completed"
log_info "JSON diff: $JSON_PATH"
log_info "HTML report: $HTML_PATH"
log_info "Summary: $SUMMARY"

echo "EDGE_DIFF_JSON=$JSON_PATH"
echo "EDGE_REPORT_HTML=$HTML_PATH"
echo "EDGE_SUMMARY=$SUMMARY"

exit 0

