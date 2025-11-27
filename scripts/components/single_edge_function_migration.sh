#!/bin/bash
# Single Edge Function Migration
# Deploy a single edge function from source to target environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env> <edge_function_name>

Deploys a single edge function from source environment to target environment.
The function will be downloaded from source and deployed to target.

Arguments:
  source_env         Source environment (prod, test, dev, backup)
  target_env         Target environment (prod, test, dev, backup)
  edge_function_name Name of the edge function to deploy

Options:
  --auto-confirm     Automatically proceed without interactive confirmation
  -h, --help         Show this help message

Examples:
  $0 dev backup my-function
  $0 prod test setup-portal-users
  $0 dev backup update-consent-content --auto-confirm

EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 3 ]; then
    log_error "Missing required arguments"
    usage
    exit 1
fi

SOURCE_ENV=$1
TARGET_ENV=$2
FUNCTION_NAME=$3
shift 3

AUTO_CONFIRM=false

while [ $# -gt 0 ]; do
    case "$1" in
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_warning "Ignoring unknown option: $1"
            ;;
    esac
    shift || true
done

load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

# Get environment-specific access tokens
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

if [ -z "$SOURCE_ACCESS_TOKEN" ] && [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access tokens not set for source ($SOURCE_ENV) or target ($TARGET_ENV) environments"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and/or SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN are set in .env.local"
    exit 1
fi

# Check for Node.js and Supabase CLI
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js not found - please install Node.js"
    exit 1
fi

if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - please install Supabase CLI"
    exit 1
fi

EDGE_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/edge-functions-migration.js"
SHARED_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/migrate-shared-functions.js"

if [ ! -f "$EDGE_FUNCTIONS_UTIL" ]; then
    log_error "Edge functions migration utility not found: $EDGE_FUNCTIONS_UTIL"
    exit 1
fi

if [ ! -f "$SHARED_FUNCTIONS_UTIL" ]; then
    log_error "Shared functions migration utility not found: $SHARED_FUNCTIONS_UTIL"
    exit 1
fi

# Create migration directory for this single function deployment
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MIGRATION_DIR="backups/single_function_${SOURCE_ENV}_to_${TARGET_ENV}_${FUNCTION_NAME}_${TIMESTAMP}"
mkdir -p "$MIGRATION_DIR"
MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Single Edge Function Migration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Function: $FUNCTION_NAME"
log_info "Migration Directory: $MIGRATION_DIR_ABS"
echo ""

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with deploying $FUNCTION_NAME from $SOURCE_ENV to $TARGET_ENV? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$response" != "y" ] && [ "$response" != "yes" ]; then
        log_info "Deployment cancelled"
        exit 0
    fi
fi

echo ""

# Deploy the single function using the Node.js utility
log_info "Deploying function $FUNCTION_NAME from $SOURCE_ENV to $TARGET_ENV..."
log_info "The function will be downloaded from source and deployed to target."

# Run deployment with --functions filter to deploy only this function
DEPLOY_SUCCESS=false
DEPLOY_LOG="$MIGRATION_DIR_ABS/deployment.log"
touch "$DEPLOY_LOG"

set +o pipefail
if node "$EDGE_FUNCTIONS_UTIL" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$MIGRATION_DIR_ABS" \
    --functions="$FUNCTION_NAME" \
    --allow-missing 2>&1 | tee -a "$DEPLOY_LOG"; then
    NODE_EXIT=${PIPESTATUS[0]}
    if [ "$NODE_EXIT" -eq 0 ]; then
        DEPLOY_SUCCESS=true
    fi
else
    NODE_EXIT=${PIPESTATUS[0]}
fi
set -o pipefail

# Check if function was actually deployed or skipped
SKIPPED_SHARED=false
FUNCTION_WAS_MIGRATED=false

if [ -f "$DEPLOY_LOG" ]; then
    # Check if function was skipped due to shared files
    if grep -qi "Functions with shared files skipped.*${FUNCTION_NAME}" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "Has shared files dependency" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "edge_functions_skipped_shared" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "will be migrated using migrate_shared_edge_functions" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "skipped.*shared.*${FUNCTION_NAME}" "$DEPLOY_LOG" 2>/dev/null; then
        SKIPPED_SHARED=true
    fi
    
    # Check if function was actually migrated (not skipped)
    # Look for positive deployment indicators
    if grep -qi "✓.*deployed.*${FUNCTION_NAME}" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "Functions migrated: [1-9]" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "Deployed function: ${FUNCTION_NAME}" "$DEPLOY_LOG" 2>/dev/null || \
       grep -qi "Successfully.*${FUNCTION_NAME}" "$DEPLOY_LOG" 2>/dev/null; then
        FUNCTION_WAS_MIGRATED=true
    fi
    
    # If "Functions migrated: 0" and function was skipped for shared files, confirm it wasn't migrated
    if grep -qi "Functions migrated: 0" "$DEPLOY_LOG" 2>/dev/null && [ "$SKIPPED_SHARED" = "true" ]; then
        FUNCTION_WAS_MIGRATED=false
    fi
fi

# If function was skipped due to shared files and not migrated, use shared functions utility
if [ "$SKIPPED_SHARED" = "true" ] && [ "$FUNCTION_WAS_MIGRATED" = "false" ]; then
    log_info ""
    log_warning "Function $FUNCTION_NAME uses shared files and was skipped in main migration."
    log_info "Attempting deployment using shared functions migration utility..."
    echo ""
    
    SHARED_DEPLOY_LOG="$MIGRATION_DIR_ABS/shared_deployment.log"
    touch "$SHARED_DEPLOY_LOG"
    
    set +o pipefail
    if node "$SHARED_FUNCTIONS_UTIL" \
        "$SOURCE_REF" \
        "$TARGET_REF" \
        "$MIGRATION_DIR_ABS" \
        --functions="$FUNCTION_NAME" 2>&1 | tee -a "$SHARED_DEPLOY_LOG"; then
        SHARED_NODE_EXIT=${PIPESTATUS[0]}
        if [ "$SHARED_NODE_EXIT" -eq 0 ]; then
            # Check if it actually deployed (not just exited successfully)
            if grep -q "Deployed.*${FUNCTION_NAME}" "$SHARED_DEPLOY_LOG" 2>/dev/null || \
               grep -q "✓.*${FUNCTION_NAME}" "$SHARED_DEPLOY_LOG" 2>/dev/null; then
                DEPLOY_SUCCESS=true
                FUNCTION_WAS_MIGRATED=true
            else
                DEPLOY_SUCCESS=false
            fi
        else
            DEPLOY_SUCCESS=false
        fi
    else
        SHARED_NODE_EXIT=${PIPESTATUS[0]}
        DEPLOY_SUCCESS=false
    fi
    set -o pipefail
    
    DEPLOY_LOG="$SHARED_DEPLOY_LOG"
    NODE_EXIT=${SHARED_NODE_EXIT:-$NODE_EXIT}
fi

# Check results
if [ "$DEPLOY_SUCCESS" = "true" ] && [ "$FUNCTION_WAS_MIGRATED" = "true" ]; then
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "  ✓ Function $FUNCTION_NAME deployed successfully!"
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "Migration directory: $MIGRATION_DIR_ABS"
    log_info "Deployment log: $DEPLOY_LOG"
    exit 0
else
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error "  ✗ Function $FUNCTION_NAME deployment failed (exit code: $NODE_EXIT)"
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error ""
    log_error "Check the deployment log for details: $DEPLOY_LOG"
    log_error ""
    log_error "Common issues:"
    log_error "  - Function may not exist in source environment"
    log_error "  - Access tokens may not have required permissions"
    log_error "  - Docker may not be running (required for function download/deploy)"
    log_error "  - Function may have incompatible dependencies"
    if [ "$SKIPPED_SHARED" = "true" ]; then
        log_error "  - Shared files may not be available or accessible"
        log_error ""
        log_info "You can try manually deploying with:"
        log_info "  ./scripts/main/migrate_shared_edge_functions.sh $SOURCE_ENV $TARGET_ENV --functions=$FUNCTION_NAME"
    fi
    exit 1
fi

