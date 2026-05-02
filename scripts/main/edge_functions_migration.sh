#!/bin/bash
# Edge Functions Migration Script
# Migrates edge functions from source to target (default: deploy source over target, no target byte-compare)
# Uses Node.js utility for edge function migration
# Can be used independently or as part of a complete migration
#
# IMPORTANT: This script does NOT touch target secrets. It never runs
# "supabase secrets set". Target secret keys and values remain unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/edge_docker_preflight.sh"

# Usage function (must be defined before it's called)
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [[migration_dir]|function_name...] [--migration-dir <path>] [options]

Migrates edge functions from source to target (default: direct deploy from source; use --compare-target for byte diff vs target)

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  function_name  After source/target, bare tokens are function names to deploy only (no \`/\`, not an existing dir)
                 Example: $0 dev test crm-webmail-message-action
  --migration-dir <path>  Migration/output directory (use when the path could be mistaken for a function name)

Options:
  --increment    Prefer incremental/delta operations (skip identical functions)
  --replace      Replace mode: Delete all target functions and redeploy from source
  --retryMissing Only deploy edge functions that are missing in target
  --prune-target   After deploy, delete edge functions on target that are not in source (full name parity)
  --no-prune-target  Do not pass --prune-target to the Node utility (keep target-only functions)
  --compare-target  Download each function from target and diff vs source before deploy (slower; old behavior)
  --yes, -y, --auto-confirm  Skip the \"Proceed?\" prompt (non-interactive / CI)
  --function <name>         Deploy only this function (repeatable)
  --functions=<a,b,...>     Deploy only these functions (comma-separated)
  -h, --help     Show this help message

Environment (Docker):
  EDGE_DOCKER_NO_AUTO_START=true   Do not run open/systemctl; fail if Docker is down
  EDGE_DOCKER_START_WAIT_SEC       Seconds to wait after auto-start (default 120)
  EDGE_DOCKER_PS_TIMEOUT_SEC       Initial docker ps probe timeout (default 30)

Environment (shared _shared seeding in Node utility):
  EDGE_SHARED_EXPLICIT_SEED_MAX       Max CLI retries to populate edge_functions/_shared when empty (default 20)
  EDGE_FUNCTIONS_SHARED_SOURCE_DIR   Absolute path to your app’s supabase/functions/_shared (when CLI omits _shared)
  EDGE_BULK_SHARED_MAX_DOWNLOADS     Cap bulk CLI downloads used to fill _shared from source (0 = unlimited)
  EDGE_BULK_MGMT_SHARED_MAX_DOWNLOADS Cap Management API zip downloads for _shared seed (0 = unlimited; needs access token)
  EDGE_SHARED_SEED_FULL_PROJECT   When migrating a filtered subset, still sweep all source function zips for _shared (default: off; slow)
  EDGE_PARITY_FULL_COMPARE         After migration, byte-compare source vs target zip per function (Management API; slow)
  EDGE_PARITY_MAX_FUNCTIONS        Max functions to include in byte parity (default 300)

Examples:
  $0 prod test                          # Migrate edge functions from prod to test
  $0 test prod --yes                    # Same, without typing y at the prompt
  $0 prod test --compare-target         # Slower: skip deploy only when target bytes match source
  $0 dev test /path/to/backup           # Migrate with custom backup directory
  $0 dev test crm-webmail-message-action # Deploy only that function to target
  $0 dev test --function my-fn --yes    # Explicit single-function deploy

Returns:
  0 on success, 1 on failure

EOF
    exit 0
}

# Handle help flag early
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

# Configuration defaults
INCREMENTAL_MODE="false"
REPLACE_MODE="false"
RETRY_MISSING_MODE="false"
COMPARE_TARGET_MODE="false"
PRUNE_TARGET_EDGE="true"
AUTO_CONFIRM_COMPONENT="${AUTO_CONFIRM:-false}"
SKIP_COMPONENT_CONFIRM="${SKIP_COMPONENT_CONFIRM:-false}"
MIGRATION_DIR=""
EDGE_FUNCTION_NAMES=()

# Argument parsing
if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2
shift 2

while [ $# -gt 0 ]; do
    case "$1" in
        --increment|--incremental)
            INCREMENTAL_MODE="true"
            ;;
        --replace)
            REPLACE_MODE="true"
            ;;
        --retryMissing|--retry-missing)
            RETRY_MISSING_MODE="true"
            ;;
        --compare-target|--compare-with-target)
            COMPARE_TARGET_MODE="true"
            ;;
        --prune-target|--prune-target-edge)
            PRUNE_TARGET_EDGE="true"
            ;;
        --no-prune-target|--no-prune-target-edge)
            PRUNE_TARGET_EDGE="false"
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT="true"
            ;;
        --migration-dir)
            if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                MIGRATION_DIR=$2
                shift
            else
                log_error "--migration-dir requires a path argument"
                exit 1
            fi
            ;;
        --migration-dir=*)
            MIGRATION_DIR="${1#*=}"
            ;;
        --function)
            if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                EDGE_FUNCTION_NAMES+=("$2")
                shift
            else
                log_error "--function requires a function name"
                exit 1
            fi
            ;;
        --function=*)
            EDGE_FUNCTION_NAMES+=("${1#*=}")
            ;;
        --functions=*)
            _csv="${1#*=}"
            _ifs=$IFS
            IFS=,
            # shellcheck disable=SC2206
            _fnparts=($_csv)
            IFS=$_ifs
            for _fn in "${_fnparts[@]}"; do
                _t="${_fn#"${_fn%%[![:space:]]*}"}"
                _t="${_t%"${_t##*[![:space:]]}"}"
                [ -n "$_t" ] && EDGE_FUNCTION_NAMES+=("$_t")
            done
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_warning "Ignoring unknown option: $1"
            ;;
        *)
            # Path / existing directory → migration dir; otherwise bare token → edge function name(s)
            if [[ "$1" == */* ]] || [[ "$1" == . ]] || [[ "$1" == .. ]] || [ -d "$1" ]; then
                if [ -z "$MIGRATION_DIR" ]; then
                    MIGRATION_DIR="$1"
                else
                    log_warning "Ignoring extra path/directory argument (migration directory already set): $1"
                fi
            elif [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
                EDGE_FUNCTION_NAMES+=("$1")
            elif [ -z "$MIGRATION_DIR" ]; then
                MIGRATION_DIR="$1"
            else
                log_warning "Ignoring unexpected argument: $1"
            fi
            ;;
    esac
    shift || true
done

if [ "${#EDGE_FUNCTION_NAMES[@]}" -gt 0 ]; then
    log_info "Deploying only edge function(s): ${EDGE_FUNCTION_NAMES[*]}"
    # Prune is disabled in the Node utility when a filter is set; avoid passing --prune-target for clarity
    PRUNE_TARGET_EDGE="false"
fi

component_prompt_proceed() {
    local title=$1
    local message=${2:-"Proceed?"}

    # Accept common truthy values (env imports, CI)
    case "${AUTO_CONFIRM_COMPONENT}" in
        true|1|yes|YES) return 0 ;;
    esac
    if [ "${SKIP_COMPONENT_CONFIRM}" = "true" ]; then
        return 0
    fi

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  ${title}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "$message"
    log_info "Not frozen — waiting for your keyboard input at the prompt below."
    log_info "  Type ${BOLD}y${NC} then Enter to continue, or ${BOLD}n${NC} or Enter alone to cancel (Ctrl+C aborts)."
    log_info "  Non-interactive: re-run with ${BOLD}--yes${NC} or ${BOLD}--auto-confirm${NC}."
    # bash prints -p prompt on stderr by default
    read -r -p ">>> Proceed with edge functions migration? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    echo ""

    if [ "$response" = "y" ] || [ "$response" = "yes" ]; then
        return 0
    fi
    return 1
}

# Check arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

# Get project references
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="edge_functions"
    MIGRATION_DIR=$(create_backup_dir "edge_functions" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="edge_functions"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"
MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR_ABS/migration.log}"
log_to_file "$LOG_FILE" "Starting edge functions migration from $SOURCE_ENV to $TARGET_ENV"

log_info "⚡ Edge Functions Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR_ABS"
log_info "Incremental mode: $INCREMENTAL_MODE | Compare-with-target: $COMPARE_TARGET_MODE (default false = faster direct deploy) | Prune target-only: $PRUNE_TARGET_EDGE"
if [ "$REPLACE_MODE" = "true" ] && [ "$RETRY_MISSING_MODE" = "true" ]; then
    log_warning "⚠️  Both --replace and --retryMissing are set. Replace mode will delete all target functions, then only missing functions will be deployed."
elif [ "$REPLACE_MODE" = "true" ]; then
    log_warning "⚠️  REPLACE MODE: All target functions will be deleted and replaced with source functions"
elif [ "$RETRY_MISSING_MODE" = "true" ]; then
    log_info "🔄 RETRY MISSING MODE: Only deploying functions missing in target"
fi
echo ""

# Do not call read() at all when auto-confirming (avoids “stuck” appearance in some terminals / automation)
case "${AUTO_CONFIRM_COMPONENT}" in
    true|1|yes|YES)
        log_info "Non-interactive mode: skipping confirmation prompt (--yes / --auto-confirm)."
        ;;
    *)
        if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
            if ! component_prompt_proceed "Edge Functions Migration" "Proceed with edge functions migration from $SOURCE_ENV to $TARGET_ENV?"; then
                log_warning "Edge functions migration skipped by user request."
                log_to_file "$LOG_FILE" "Edge functions migration skipped by user."
                exit 0
            fi
        fi
        ;;
esac

log_info "Preflight: checking Node.js and Supabase CLI…"

# Check for Node.js
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js not found - please install Node.js to use edge functions migration"
    log_error "Install from: https://nodejs.org/"
    exit 1
fi

edge_docker_preflight_or_exit

# Check for environment-specific access tokens
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

if [ -z "$SOURCE_ACCESS_TOKEN" ] && [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access tokens not set for source ($SOURCE_ENV) or target ($TARGET_ENV) environments"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and/or SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN are set in .env.local"
    exit 1
fi

# Note: Node.js utility handles tokens internally based on project_ref
# No need to export SUPABASE_ACCESS_TOKEN - utilities read from SUPABASE_${ENV}_ACCESS_TOKEN directly

# Check if edge-functions-migration.js exists
EDGE_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/edge-functions-migration.js"
if [ ! -f "$EDGE_FUNCTIONS_UTIL" ]; then
    log_error "Edge functions migration utility not found: $EDGE_FUNCTIONS_UTIL"
    exit 1
fi

# Check for Supabase CLI (required for downloading/deploying functions)
if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - please install Supabase CLI"
    log_error "Install from: https://supabase.com/docs/guides/cli/getting-started"
    exit 1
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Using Node.js utility for edge functions migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

log_info "Running Node.js edge functions migration utility..."
log_info "  Script: $EDGE_FUNCTIONS_UTIL"
log_info "  Source: $SOURCE_REF"
log_info "  Target: $TARGET_REF"
log_info "  Note: Using Supabase Management API and CLI"
log_info "  Output streams live below (first lines in ~1s; Docker preflight can take up to ~90s if Docker was stopped)."
log_info ""

# Assemble Node.js command arguments
node_args=("$EDGE_FUNCTIONS_UTIL" "$SOURCE_REF" "$TARGET_REF" "$MIGRATION_DIR_ABS")
if [ "${#EDGE_FUNCTION_NAMES[@]}" -gt 0 ]; then
    IFS=,
    _edge_functions_csv="${EDGE_FUNCTION_NAMES[*]}"
    unset IFS
    node_args+=("--functions=${_edge_functions_csv}")
fi
if [ "$INCREMENTAL_MODE" = "true" ]; then
    node_args+=("--incremental")
fi
if [ "$REPLACE_MODE" = "true" ]; then
    node_args+=("--replace")
fi
if [ "$RETRY_MISSING_MODE" = "true" ]; then
    node_args+=("--retryMissing")
fi
if [ "$COMPARE_TARGET_MODE" = "true" ]; then
    node_args+=("--compare-target")
fi
if [ "$PRUNE_TARGET_EDGE" = "true" ]; then
    node_args+=("--prune-target")
fi
# Pass app name for per-application last-deployed state (SUPABASE_APP_NAME / SUPABSE_APP_NAME from .env.local)
load_env 2>/dev/null || true
APP_NAME_FOR_STATE=""
if type get_supabase_app_name >/dev/null 2>&1; then
    APP_NAME_FOR_STATE=$(get_supabase_app_name 2>/dev/null || true)
fi
if [ -n "$APP_NAME_FOR_STATE" ]; then
    node_args+=("--app-name=$APP_NAME_FOR_STATE")
fi
if [ -n "$TARGET_ENV" ]; then
    node_args+=("--target-env=$TARGET_ENV")
fi

# Run Node.js utility and capture output
# Environment variables are loaded from .env.local by the Node.js script
# stdbuf line-buffers the pipe to tee (GNU coreutils); Node also sets stdout blocking when piped.
MIGRATION_SUCCESS=false
# Use PIPESTATUS to properly capture exit code when using pipes
set +o pipefail  # Temporarily disable pipefail to check exit code manually
if command -v stdbuf >/dev/null 2>&1; then
    _EDGE_NODE_RUN=(stdbuf -oL -eL node)
else
    _EDGE_NODE_RUN=(node)
fi
if "${_EDGE_NODE_RUN[@]}" "${node_args[@]}" 2>&1 | tee -a "${LOG_FILE:-$MIGRATION_DIR/migration.log}"; then
    NODE_EXIT_CODE=${PIPESTATUS[0]}
    if [ "$NODE_EXIT_CODE" -eq 0 ]; then
        MIGRATION_SUCCESS=true
        COMPONENT_NAME="Edge Functions Migration"
        log_success "Edge functions migration completed successfully using Node.js utility"
        log_to_file "$LOG_FILE" "Edge functions migrated successfully"
    else
        COMPONENT_NAME="Edge Functions Migration"
        log_error "Node.js utility failed with exit code $NODE_EXIT_CODE"
        log_error "Check the logs above for details"
        log_to_file "$LOG_FILE" "Edge functions migration had errors (exit code: $NODE_EXIT_CODE)"
    fi
else
    NODE_EXIT_CODE=${PIPESTATUS[0]}
    COMPONENT_NAME="Edge Functions Migration"
    log_error "Node.js utility failed with exit code $NODE_EXIT_CODE"
    log_error "Check the logs above for details"
    log_to_file "$LOG_FILE" "Edge functions migration had errors (exit code: $NODE_EXIT_CODE)"
fi
set -o pipefail  # Re-enable pipefail

FAILED_FUNCTIONS_FILE="$MIGRATION_DIR_ABS/edge_functions_failed.txt"
if [ -f "$FAILED_FUNCTIONS_FILE" ]; then
    if [ -s "$FAILED_FUNCTIONS_FILE" ]; then
        log_warning "Some edge functions failed to deploy. See: $FAILED_FUNCTIONS_FILE"
        log_info "Retry only the failed functions with:"
        log_info "  ./scripts/components/retry_edge_functions.sh $SOURCE_ENV $TARGET_ENV \"$MIGRATION_DIR_ABS\""
    else
        log_info "No edge function failures recorded (empty failure list)."
    fi
fi

if [ "$MIGRATION_SUCCESS" = "true" ]; then
    echo "$MIGRATION_DIR"  # Return migration directory for use by other scripts
    exit 0
else
    exit 1
fi



