#!/bin/bash
# Migrate Edge Functions with Shared Files
# Dedicated script for migrating edge functions that have shared file dependencies
# Uses JavaScript utility to handle shared file bundling and deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env> [function_name] [options]

Migrates edge functions with shared files from source to target environment.
This script handles functions that were skipped in the main migration due to shared dependencies.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  function_name  Optional: Name of specific function to migrate (can also use --functions)

Options:
  --functions=<list>    Comma-separated list of specific functions to migrate
  --filter-file=<path>  Path to file containing function names (one per line)
  --migration-dir=<dir> Use existing migration directory
  --auto-confirm        Automatically proceed without interactive confirmation
  -h, --help            Show this help message

Examples:
  $0 dev test
  $0 dev test send-password-change-otp
  $0 dev test --functions="send-password-change-otp,send-chat-notification"
  $0 dev test --filter-file=backups/edge_functions_migration_dev_to_test_*/edge_functions_skipped_shared.txt

EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 2 ]; then
    log_error "Missing required arguments"
    usage
    exit 1
fi

SOURCE_ENV=$1
TARGET_ENV=$2
shift 2

FUNCTION_FILTER=""
FUNCTION_NAME=""
FILTER_FILE=""
MIGRATION_DIR=""
AUTO_CONFIRM=false

# Check if third argument is a function name (not an option)
if [ $# -gt 0 ] && [[ ! "$1" =~ ^-- ]]; then
    FUNCTION_NAME="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --functions=*)
            FUNCTION_FILTER="${1#*=}"
            ;;
        --filter-file=*)
            FILTER_FILE="${1#*=}"
            ;;
        --migration-dir=*)
            MIGRATION_DIR="${1#*=}"
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_warning "Ignoring unexpected argument: $1"
            ;;
    esac
    shift || true
done

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

# Check for Node.js
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js not found - please install Node.js"
    exit 1
fi

# Get environment-specific access tokens
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

if [ -z "$SOURCE_ACCESS_TOKEN" ] && [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access tokens not set for source ($SOURCE_ENV) or target ($TARGET_ENV) environments"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and/or SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN are set in .env.local"
    exit 1
fi

# Note: Node.js utility handles tokens internally based on project_ref
# No need to export SUPABASE_ACCESS_TOKEN - utilities read from SUPABASE_${ENV}_ACCESS_TOKEN directly

# Find or create migration directory
if [ -z "$MIGRATION_DIR" ]; then
    log_info "Searching for migration directory..."
    pattern="backups/edge_functions_migration_${SOURCE_ENV}_to_${TARGET_ENV}_*"
    shopt -s nullglob
    candidates=($pattern)
    shopt -u nullglob
    
    if [ ${#candidates[@]} -gt 0 ]; then
        MIGRATION_DIR=$(ls -1dt "${candidates[@]}" 2>/dev/null | head -n 1 || true)
        if [ -n "$MIGRATION_DIR" ]; then
            log_info "Found migration directory: $MIGRATION_DIR"
        fi
    fi
    
    # If still not found, create new one
    if [ -z "$MIGRATION_DIR" ]; then
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        MIGRATION_DIR="backups/edge_functions_migration_${SOURCE_ENV}_to_${TARGET_ENV}_${TIMESTAMP}"
        mkdir -p "$MIGRATION_DIR"
        log_info "Created new migration directory: $MIGRATION_DIR"
    fi
fi

MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"

# Check for skipped shared functions file
SKIPPED_SHARED_FILE="$MIGRATION_DIR_ABS/edge_functions_skipped_shared.txt"
if [ -n "$FILTER_FILE" ]; then
    if [ -f "$FILTER_FILE" ]; then
        SKIPPED_SHARED_FILE="$FILTER_FILE"
    else
        log_warning "Filter file not found: $FILTER_FILE, using default: $SKIPPED_SHARED_FILE"
    fi
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migrate Edge Functions with Shared Files"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration Directory: $MIGRATION_DIR_ABS"
echo ""

# Determine which functions to migrate
FUNCTIONS_TO_MIGRATE=()

if [ -n "$FUNCTION_NAME" ]; then
    # Use function name from positional argument (highest priority)
    FUNCTIONS_TO_MIGRATE=("$FUNCTION_NAME")
    log_info "Using function name from argument: $FUNCTION_NAME"
elif [ -n "$FUNCTION_FILTER" ]; then
    # Use provided function list
    IFS=',' read -ra FUNC_ARRAY <<< "$FUNCTION_FILTER"
    for func in "${FUNC_ARRAY[@]}"; do
        FUNCTIONS_TO_MIGRATE+=("$(echo "$func" | xargs)")
    done
    log_info "Using provided function list: ${FUNCTIONS_TO_MIGRATE[*]}"
elif [ -f "$SKIPPED_SHARED_FILE" ]; then
    # Read from skipped shared functions file
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | xargs) # trim whitespace
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            FUNCTIONS_TO_MIGRATE+=("$line")
        fi
    done < "$SKIPPED_SHARED_FILE"
    log_info "Found ${#FUNCTIONS_TO_MIGRATE[@]} function(s) in $SKIPPED_SHARED_FILE"
else
    log_warning "No function list provided and $SKIPPED_SHARED_FILE not found"
    log_info "Will attempt to detect functions with shared files from source project"
fi

if [ ${#FUNCTIONS_TO_MIGRATE[@]} -eq 0 ]; then
    log_error "No functions specified for migration"
    log_error "Provide functions via:"
    log_error "  - Function name as third argument: $0 $SOURCE_ENV $TARGET_ENV <function-name>"
    log_error "  - --functions flag: $0 $SOURCE_ENV $TARGET_ENV --functions=<name1,name2>"
    log_error "  - --filter-file flag: $0 $SOURCE_ENV $TARGET_ENV --filter-file=<path>"
    log_error "  - Or ensure $SKIPPED_SHARED_FILE exists"
    exit 1
fi

log_info "Functions to migrate: ${FUNCTIONS_TO_MIGRATE[*]}"
echo ""

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with shared functions migration? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$response" != "y" ] && [ "$response" != "yes" ]; then
        log_info "Migration cancelled"
        exit 0
    fi
fi

# Create JavaScript utility for shared functions migration
SHARED_MIGRATION_SCRIPT="$PROJECT_ROOT/utils/migrate-shared-functions.js"

# Run the JavaScript utility
log_info "Running shared functions migration utility..."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build function filter argument
FILTER_ARG=""
if [ ${#FUNCTIONS_TO_MIGRATE[@]} -gt 0 ]; then
    FILTER_ARG="--functions=$(IFS=','; echo "${FUNCTIONS_TO_MIGRATE[*]}")"
fi

if node "$SHARED_MIGRATION_SCRIPT" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$MIGRATION_DIR_ABS" \
    $FILTER_ARG 2>&1 | tee "$MIGRATION_DIR_ABS/shared_functions_migration.log"; then
    NODE_EXIT=${PIPESTATUS[0]}
    if [ "$NODE_EXIT" -eq 0 ]; then
        log_success "Shared functions migration completed successfully"
        exit 0
    else
        log_error "Shared functions migration failed (exit code: $NODE_EXIT)"
        log_error "Check $MIGRATION_DIR_ABS/shared_functions_migration.log for details"
        exit 1
    fi
else
    NODE_EXIT=${PIPESTATUS[0]}
    log_error "Shared functions migration failed (exit code: $NODE_EXIT)"
    log_error "Check $MIGRATION_DIR_ABS/shared_functions_migration.log for details"
    exit 1
fi

