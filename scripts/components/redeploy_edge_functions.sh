#!/bin/bash
# Redeploy Edge Functions with Shared Files
# Standalone script for redeploying edge functions with proper shared file handling
# Can work with existing migration directory or fresh deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<EOF
Usage: $0 <source_env> <target_env> <function_name> [migration_dir] [options]

Redeploys a specific edge function with shared files to the target environment.
Ensures shared files are properly located and copied before deployment.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  function_name  Name of the edge function to redeploy
  migration_dir  Optional: Migration directory containing downloaded functions (auto-detected if not provided)

Options:
  --download     Download function from source if not in migration directory
  --no-shared    Skip shared file handling (not recommended)
  --auto-confirm Automatically proceed without interactive confirmation
  -h, --help     Show this help message

Examples:
  $0 prod test my-function
  $0 dev test my-function backups/edge_functions_migration_dev_to_test_20251123_123245
  $0 prod test my-function --download

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

MIGRATION_DIR=""
DOWNLOAD_FUNCTION=false
SKIP_SHARED=false
AUTO_CONFIRM=false

while [ $# -gt 0 ]; do
    case "$1" in
        --download)
            DOWNLOAD_FUNCTION=true
            ;;
        --no-shared)
            SKIP_SHARED=true
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
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
        -h|--help)
            usage
            exit 0
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

SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")

# Find migration directory if not provided
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
fi

# Check for Node.js and required dependencies
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

if ! command -v supabase >/dev/null 2>&1; then
    log_error "Supabase CLI not found - please install Supabase CLI"
    exit 1
fi

EDGE_FUNCTIONS_UTIL="$PROJECT_ROOT/utils/edge-functions-migration.js"
if [ ! -f "$EDGE_FUNCTIONS_UTIL" ]; then
    log_error "Edge functions migration utility not found: $EDGE_FUNCTIONS_UTIL"
    exit 1
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Redeploy Edge Function: $FUNCTION_NAME"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Function: $FUNCTION_NAME"
if [ -n "$MIGRATION_DIR" ]; then
    log_info "Migration Directory: $MIGRATION_DIR"
else
    log_info "Migration Directory: Will be created"
fi
echo ""

if [ "$AUTO_CONFIRM" != "true" ]; then
    read -r -p "Proceed with redeployment? [y/N]: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$response" != "y" ] && [ "$response" != "yes" ]; then
        log_info "Redeployment cancelled"
        exit 0
    fi
fi

# Create temporary migration directory if needed
TEMP_MIGRATION_DIR=""
if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    if [ "$DOWNLOAD_FUNCTION" = "true" ]; then
        TEMP_MIGRATION_DIR=$(mktemp -d -t edge_redeploy_XXXXXX)
        MIGRATION_DIR="$TEMP_MIGRATION_DIR"
        log_info "Created temporary migration directory: $MIGRATION_DIR"
    else
        log_error "Migration directory not found and --download not specified"
        log_error "Either provide a migration directory or use --download flag"
        exit 1
    fi
fi

MIGRATION_DIR_ABS="$(cd "$MIGRATION_DIR" && pwd)"
FUNCTIONS_DIR="$MIGRATION_DIR_ABS/edge_functions"

# Ensure functions directory exists
if [ ! -d "$FUNCTIONS_DIR" ]; then
    mkdir -p "$FUNCTIONS_DIR"
fi

FUNCTION_DIR="$FUNCTIONS_DIR/$FUNCTION_NAME"

# Download function if needed
if [ ! -d "$FUNCTION_DIR" ] || [ ! -f "$FUNCTION_DIR/index.ts" ] && [ ! -f "$FUNCTION_DIR/index.js" ]; then
    if [ "$DOWNLOAD_FUNCTION" = "true" ]; then
        log_info "Downloading function $FUNCTION_NAME from source..."
        log_info "Running edge functions migration utility to download function..."
        
        # Use the Node.js utility to download the function
        if node "$EDGE_FUNCTIONS_UTIL" \
            "$SOURCE_REF" \
            "$TARGET_REF" \
            "$MIGRATION_DIR_ABS" \
            --functions="$FUNCTION_NAME" \
            --allow-missing 2>&1 | tee -a "$MIGRATION_DIR_ABS/redeploy.log"; then
            log_success "Function downloaded successfully"
        else
            log_error "Failed to download function"
            [ -n "$TEMP_MIGRATION_DIR" ] && rm -rf "$TEMP_MIGRATION_DIR"
            exit 1
        fi
    else
        log_error "Function directory not found: $FUNCTION_DIR"
        log_error "Use --download to download the function from source"
        [ -n "$TEMP_MIGRATION_DIR" ] && rm -rf "$TEMP_MIGRATION_DIR"
        exit 1
    fi
fi

if [ ! -d "$FUNCTION_DIR" ]; then
    log_error "Function directory still not found after download attempt: $FUNCTION_DIR"
    [ -n "$TEMP_MIGRATION_DIR" ] && rm -rf "$TEMP_MIGRATION_DIR"
    exit 1
fi

log_info "Function directory found: $FUNCTION_DIR"

# Handle shared files - the Node.js utility will handle this automatically
# But we can verify they exist before deployment
if [ "$SKIP_SHARED" != "true" ]; then
    log_info "Verifying shared files availability..."
    
    # Check for shared files in common locations
    SHARED_LOCATIONS=(
        "$FUNCTIONS_DIR/_shared"
        "$PROJECT_ROOT/supabase/functions/_shared"
        "$FUNCTION_DIR/_shared"
    )
    
    SHARED_FOUND=false
    for shared_loc in "${SHARED_LOCATIONS[@]}"; do
        if [ -d "$shared_loc" ] && [ -n "$(ls -A "$shared_loc" 2>/dev/null)" ]; then
            SHARED_COUNT=$(ls -1 "$shared_loc" 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
            if [ "$SHARED_COUNT" -gt 0 ]; then
                log_info "  Found $SHARED_COUNT shared file(s) at: $shared_loc"
                SHARED_FOUND=true
            fi
        fi
    done
    
    if [ "$SHARED_FOUND" = "true" ]; then
        log_success "Shared files available - will be included in deployment"
    else
        # Check if function actually needs shared files
        if [ -f "$FUNCTION_DIR/index.ts" ]; then
            if grep -q "_shared" "$FUNCTION_DIR/index.ts" 2>/dev/null; then
                log_warning "  Function code references _shared but no shared files found"
                log_warning "  Deployment may fail. Consider downloading shared files first."
            else
                log_info "  No shared files needed for this function"
            fi
        elif [ -f "$FUNCTION_DIR/index.js" ]; then
            if grep -q "_shared" "$FUNCTION_DIR/index.js" 2>/dev/null; then
                log_warning "  Function code references _shared but no shared files found"
                log_warning "  Deployment may fail. Consider downloading shared files first."
            else
                log_info "  No shared files needed for this function"
            fi
        fi
    fi
else
    log_warning "Skipping shared file handling (--no-shared flag)"
fi

# Deploy the function using the Node.js utility
log_info "Deploying function $FUNCTION_NAME to target..."
log_info "Using edge functions migration utility for deployment..."

# Create a filter file with just this function
FILTER_FILE="$MIGRATION_DIR_ABS/redeploy_filter.txt"
echo "$FUNCTION_NAME" > "$FILTER_FILE"

# Run deployment
DEPLOY_SUCCESS=false
if node "$EDGE_FUNCTIONS_UTIL" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$MIGRATION_DIR_ABS" \
    --filter-file="$FILTER_FILE" \
    --allow-missing 2>&1 | tee -a "$MIGRATION_DIR_ABS/redeploy.log"; then
    NODE_EXIT=${PIPESTATUS[0]}
    if [ "$NODE_EXIT" -eq 0 ]; then
        DEPLOY_SUCCESS=true
    fi
else
    NODE_EXIT=${PIPESTATUS[0]}
fi

# Cleanup temp directory if we created it
if [ -n "$TEMP_MIGRATION_DIR" ]; then
    rm -rf "$TEMP_MIGRATION_DIR"
fi

# Check results
if [ "$DEPLOY_SUCCESS" = "true" ]; then
    log_success "Function $FUNCTION_NAME redeployed successfully"
    exit 0
else
    log_error "Function $FUNCTION_NAME redeployment failed (exit code: $NODE_EXIT)"
    log_error "Check $MIGRATION_DIR_ABS/redeploy.log for details"
    exit 1
fi

