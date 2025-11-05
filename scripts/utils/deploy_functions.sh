#!/bin/bash
# Helper script to deploy edge functions after migration
# Usage: ./deploy_functions.sh <target_env> [functions_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"

TARGET_ENV=${1:-}
FUNCTIONS_DIR=${2:-"$PROJECT_ROOT/supabase/functions"}

if [ -z "$TARGET_ENV" ]; then
    echo "Usage: $0 <target_env> [functions_dir]"
    echo "Example: $0 test"
    exit 1
fi

load_env
TARGET_REF=$(get_project_ref "$TARGET_ENV")

if [ ! -d "$FUNCTIONS_DIR" ]; then
    log_error "Functions directory not found: $FUNCTIONS_DIR"
    exit 1
fi

log_info "Deploying edge functions to $TARGET_ENV ($TARGET_REF)..."

for func_dir in "$FUNCTIONS_DIR"/*; do
    if [ -d "$func_dir" ]; then
        func_name=$(basename "$func_dir")
        log_info "Deploying: $func_name"
        if supabase functions deploy "$func_name" --project-ref "$TARGET_REF"; then
            log_success "✓ Deployed: $func_name"
        else
            log_warning "✗ Failed: $func_name"
        fi
    fi
done

log_success "Edge functions deployment completed!"
