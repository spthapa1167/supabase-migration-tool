#!/bin/bash
# Helper script to set secrets after migration
# Usage: ./set_secrets.sh <target_env> [secrets_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"

TARGET_ENV=${1:-}
SECRETS_FILE=${2:-"$PROJECT_ROOT/.secrets.local"}

if [ -z "$TARGET_ENV" ]; then
    echo "Usage: $0 <target_env> [secrets_file]"
    echo "Example: $0 test .secrets.local"
    exit 1
fi

load_env
TARGET_REF=$(get_project_ref "$TARGET_ENV")

if [ ! -f "$SECRETS_FILE" ]; then
    log_error "Secrets file not found: $SECRETS_FILE"
    log_info "Create a file with format: KEY=value (one per line)"
    exit 1
fi

log_info "Setting secrets for $TARGET_ENV ($TARGET_REF)..."

set_count=0
while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    
    # Parse KEY=value
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        
        # Remove quotes if present
        value=$(echo "$value" | sed "s/^['\"]//; s/['\"]$//")
        
        log_info "Setting: $key"
        if supabase secrets set "${key}=${value}" --project-ref "$TARGET_REF"; then
            log_success "✓ Set: $key"
            set_count=$((set_count + 1))
        else
            log_warning "✗ Failed: $key"
        fi
    fi
done < "$SECRETS_FILE"

log_success "Set $set_count secret(s)!"
