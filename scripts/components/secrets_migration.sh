#!/usr/bin/env bash

# Secrets Migration Component Script
# Migrates secret keys (names only) from source to target with blank values
# Only creates new keys if they don't exist in target
# Skips secrets starting with 'SUPABASE' (reserved)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env>

Migrates secret keys (names only) from source to target with blank values.
Only creates new keys if they don't already exist in target.
Skips secrets starting with 'SUPABASE' (reserved by Supabase).

Arguments:
  source_env     Source environment (prod, test, dev)
  target_env     Target environment (prod, test, dev)

Examples:
  $0 dev test    # Migrate secret keys from dev to test

EOF
    exit 1
}

# Check arguments
if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

# Initialize LOG_FILE if not set (for component scripts)
if [ -z "${LOG_FILE:-}" ]; then
    LOG_FILE="/dev/null"  # Default to /dev/null if not set by parent script
fi

log_script_context "$(basename "$0")" "$SOURCE_ENV" "$TARGET_ENV"

# Get project references and access tokens
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

# Validate access tokens (required for Management API)
if [ -z "$SOURCE_ACCESS_TOKEN" ]; then
    log_error "Access token not set for source environment ($SOURCE_ENV)"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN is set in .env.local"
    exit 1
fi

if [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access token not set for target environment ($TARGET_ENV)"
    log_error "Please ensure SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN is set in .env.local"
    exit 1
fi

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq not found - required for parsing secrets JSON"
    log_error "Please install jq: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Create temporary directory for JSON files
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

SOURCE_SECRETS_FILE="$TEMP_DIR/source_secrets.json"
TARGET_SECRETS_FILE="$TEMP_DIR/target_secrets.json"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Secrets Migration: $SOURCE_ENV → $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

# Step 1: Fetch secrets from source
log_info "Step 1/3: Fetching secrets from source project ($SOURCE_ENV)..."
if ! curl -s -H "Authorization: Bearer $SOURCE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/${SOURCE_REF}/secrets" \
    -o "$SOURCE_SECRETS_FILE" 2>/dev/null; then
    log_error "Failed to fetch secrets from source project"
    log_error "Please check SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and network connection"
    exit 1
fi

# Validate JSON
if ! jq empty "$SOURCE_SECRETS_FILE" 2>/dev/null; then
    log_error "Invalid JSON response from source secrets API"
    exit 1
fi

source_secret_count=$(jq '. | length' "$SOURCE_SECRETS_FILE" 2>/dev/null || echo "0")
log_success "Found $source_secret_count secret(s) in source project"

if [ "$source_secret_count" -eq 0 ]; then
    log_info "No secrets found in source project - nothing to migrate"
    exit 0
fi

# Step 2: Fetch existing secrets from target
log_info "Step 2/3: Fetching existing secrets from target project ($TARGET_ENV)..."
if ! curl -s -H "Authorization: Bearer $TARGET_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/${TARGET_REF}/secrets" \
    -o "$TARGET_SECRETS_FILE" 2>/dev/null; then
    log_warning "Failed to fetch target secrets - will proceed with migration"
    echo "[]" > "$TARGET_SECRETS_FILE"  # Empty array as fallback
fi

# Validate target JSON
if ! jq empty "$TARGET_SECRETS_FILE" 2>/dev/null; then
    log_warning "Invalid JSON response from target secrets API - will proceed with migration"
    echo "[]" > "$TARGET_SECRETS_FILE"  # Empty array as fallback
fi

target_secret_count=$(jq '. | length' "$TARGET_SECRETS_FILE" 2>/dev/null || echo "0")
log_success "Found $target_secret_count existing secret(s) in target project"

# Extract secret names
source_secret_names=$(jq -r '.[].name' "$SOURCE_SECRETS_FILE" 2>/dev/null || echo "")
target_secret_names=$(jq -r '.[].name' "$TARGET_SECRETS_FILE" 2>/dev/null || echo "")

# Step 3: Migrate secrets to target
log_info "Step 3/3: Migrating secrets to target project..."
log_info ""

# Skip linking - not needed when using access token
# The CLI will authenticate using SUPABASE_ACCESS_TOKEN environment variable
# Linking is only needed for local development, not for remote operations

migrated_count=0
skipped_existing=0
skipped_reserved=0
failed_count=0

# Process each source secret
for secret_name in $source_secret_names; do
    secret_name=$(echo "$secret_name" | xargs)
    [ -z "$secret_name" ] && continue
    
    # Skip secrets starting with 'SUPABASE' (reserved) - case-insensitive check
    secret_name_upper=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]')
    if [[ "$secret_name_upper" == SUPABASE_* ]]; then
        log_info "  ⏭️  Skipping reserved secret: $secret_name (starts with SUPABASE_)"
        skipped_reserved=$((skipped_reserved + 1))
        continue
    fi
    
    # Check if secret already exists in target
    exists_in_target=false
    if [ -n "$target_secret_names" ]; then
        if echo "$target_secret_names" | grep -qFx "$secret_name" 2>/dev/null; then
            exists_in_target=true
        fi
    fi
    
    if [ "$exists_in_target" = "true" ]; then
        log_info "  ⏭️  Skipping: $secret_name (already exists in target)"
        skipped_existing=$((skipped_existing + 1))
        continue
    fi
    
    # Create secret with blank value
    log_info "  Creating: $secret_name"
    
    # Try to set secret using Management API (more reliable than CLI)
    tmp_output=$(mktemp)
    secret_created=false
    
    # Function to set secret via CLI (Management API doesn't support creating secrets)
    set_secret_via_cli() {
        local secret_value=$1
        local cli_output
        
        # Try to set secret using Supabase CLI with access token
        # Export access token for CLI to use
        export SUPABASE_ACCESS_TOKEN="$TARGET_ACCESS_TOKEN"
        
        # Try to set secret using Supabase CLI
        cli_output=$(supabase secrets set "${secret_name}=${secret_value}" --project-ref "$TARGET_REF" 2>&1)
        local exit_code=$?
        
        # Save output for error reporting
        echo "$cli_output" > "$tmp_output"
        
        # Log CLI output
        if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then
            echo "CLI Output for $secret_name: $cli_output" >> "$LOG_FILE" 2>/dev/null || true
        fi
        
        if [ $exit_code -eq 0 ]; then
            return 0
        else
            return 1
        fi
    }
    
    # Try blank value first via CLI
    if set_secret_via_cli ""; then
        log_success "    ✓ Created: $secret_name (blank value - UPDATE REQUIRED)"
        migrated_count=$((migrated_count + 1))
        secret_created=true
    else
        # Try with placeholder if blank doesn't work
        log_info "    Blank value failed, trying placeholder..."
        if set_secret_via_cli "PLACEHOLDER_UPDATE_REQUIRED"; then
            log_success "    ✓ Created: $secret_name (placeholder - UPDATE REQUIRED)"
            migrated_count=$((migrated_count + 1))
            secret_created=true
        else
            log_error "    ✗ Failed: $secret_name"
            # Show error details if available
            if [ -s "$tmp_output" ]; then
                # Use sed to get first few lines (macOS compatible)
                error_msg=$(sed -n '1,3p' "$tmp_output" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' || echo "Unknown error")
                log_error "    Error: $error_msg"
            fi
            log_warning "    Note: CLI authentication may be required. Try running: supabase login"
            failed_count=$((failed_count + 1))
        fi
    fi
    
    # Log output to LOG_FILE if it's set and not /dev/null
    if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ] && [ -f "$LOG_FILE" ]; then
        cat "$tmp_output" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    rm -f "$tmp_output"
done

# Summary
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "  Created:        $migrated_count secret(s)"
log_info "  Skipped (existing): $skipped_existing secret(s)"
log_info "  Skipped (reserved): $skipped_reserved secret(s)"
log_info "  Failed:         $failed_count secret(s)"
log_info ""

if [ "$migrated_count" -gt 0 ]; then
    log_warning "⚠️  IMPORTANT: All migrated secrets have blank/placeholder values"
    log_warning "   You must manually update each secret value in the target project:"
    log_info ""
    log_info "   supabase secrets set SECRET_NAME=your_value --project-ref $TARGET_REF"
    log_info ""
fi

if [ "$failed_count" -gt 0 ]; then
    log_error "Some secrets failed to migrate. Please check the logs above."
    exit 1
fi

log_success "✅ Secrets migration completed successfully"
exit 0

