#!/bin/bash
# Secrets Migration Script
# Migrates Supabase secrets from source to target
# Can be used independently or as part of a complete migration
# Default: Only migrates secret keys with blank/placeholder values
# Use --values flag to attempt migrating secret values (may require manual input)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/html_report_generator.sh" 2>/dev/null || true

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
MIGRATION_DIR=${3:-""}

# Default: only migrate keys with blank values
INCLUDE_VALUES=false
INCREMENTAL_MODE=false
AUTO_CONFIRM_COMPONENT="${AUTO_CONFIRM:-false}"
SKIP_COMPONENT_CONFIRM="${SKIP_COMPONENT_CONFIRM:-false}"

# Parse arguments for flags
for arg in "$@"; do
    case "$arg" in
        --values)
            INCLUDE_VALUES=true
            ;;
        --increment|--incremental)
            INCREMENTAL_MODE=true
            ;;
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM_COMPONENT=true
            ;;
    esac
done

# If the optional migration directory argument is actually a flag, ignore it
if [[ -n "$MIGRATION_DIR" && "$MIGRATION_DIR" == --* ]]; then
    if [[ "$MIGRATION_DIR" == "--values" ]]; then
        INCLUDE_VALUES=true
    elif [[ "$MIGRATION_DIR" == "--increment" || "$MIGRATION_DIR" == "--incremental" ]]; then
        INCREMENTAL_MODE=true
    elif [[ "$MIGRATION_DIR" == "--auto-confirm" || "$MIGRATION_DIR" == "--yes" || "$MIGRATION_DIR" == "-y" ]]; then
        AUTO_CONFIRM_COMPONENT=true
    fi
    MIGRATION_DIR=""
fi

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [migration_dir] [--values]

Migrates Supabase secrets from source to target using delta comparison

Default Behavior:
  By default, only migrates NEW SECRET KEYS with blank/placeholder values.
  Secret values are NOT migrated for security reasons (values are secret).
  IMPORTANT: Only adds new secret keys from source. NEVER modifies or removes existing secrets in target.
  Existing secret keys and values in target are preserved unchanged.
  Use --values flag to attempt migrating values for new keys only (may require manual input or CLI access).
  Use --increment to explicitly request incremental/delta operations (default behaviour).

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)
  --values       Attempt to migrate secret values (if accessible via CLI)
  --increment    Prefer incremental/delta operations (default: enabled)

Examples:
  $0 dev test                          # Migrate secret keys only (default - blank values)
  $0 dev test --values                 # Attempt to migrate keys + values
  $0 prod test /path/to/backup         # Migrate with custom backup directory
  $0 prod test /path/to/backup --values  # Custom directory, attempt to migrate values

Returns:
  0 on success, 1 on failure

EOF
    exit 1
}

component_prompt_proceed() {
    local title=$1
    local message=${2:-"Proceed?"}

    if [ "${AUTO_CONFIRM_COMPONENT}" = "true" ] || [ "${SKIP_COMPONENT_CONFIRM}" = "true" ]; then
        return 0
    fi

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  ${title}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warning "$message"
    read -r -p "Proceed? [y/N]: " response
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

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

# Get environment-specific access tokens
SOURCE_ACCESS_TOKEN=$(get_env_access_token "$SOURCE_ENV")
TARGET_ACCESS_TOKEN=$(get_env_access_token "$TARGET_ENV")

# Validate access tokens (required for Management API)
if [ -z "$SOURCE_ACCESS_TOKEN" ] && [ -z "$TARGET_ACCESS_TOKEN" ]; then
    log_error "Access tokens not set for source ($SOURCE_ENV) or target ($TARGET_ENV) environments"
    log_error "Please ensure SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and/or SUPABASE_${TARGET_ENV^^}_ACCESS_TOKEN are set in .env.local"
    exit 1
fi

# Use source token for reading, target token for writing (fallback to source if target not set)
ACCESS_TOKEN_FOR_READ="${SOURCE_ACCESS_TOKEN:-$TARGET_ACCESS_TOKEN}"
ACCESS_TOKEN_FOR_WRITE="${TARGET_ACCESS_TOKEN:-$SOURCE_ACCESS_TOKEN}"

# Create migration directory if not provided
if [ -z "$MIGRATION_DIR" ]; then
    BACKUP_TYPE="secrets_migration"
    MIGRATION_DIR=$(create_backup_dir "secrets_migration" "$SOURCE_ENV" "$TARGET_ENV")
else
    BACKUP_TYPE="secrets_migration"
fi

# Ensure directory exists
mkdir -p "$MIGRATION_DIR"

# Cleanup old backups of the same type
cleanup_old_backups "$BACKUP_TYPE" "$SOURCE_ENV" "$TARGET_ENV" "$MIGRATION_DIR"

# Set log file
LOG_FILE="${LOG_FILE:-$MIGRATION_DIR/migration.log}"
log_to_file "$LOG_FILE" "Starting secrets migration from $SOURCE_ENV to $TARGET_ENV"

log_info "🔐 Secrets Migration"
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Migration directory: $MIGRATION_DIR"
if [ "$INCLUDE_VALUES" = "true" ]; then
    log_info "Mode: Keys + Values (if accessible)"
else
    log_info "Mode: Keys Only (blank values)"
fi
log_info "Incremental mode: $INCREMENTAL_MODE (secrets migration uses Management API delta comparison)"
echo ""

if [ "$SKIP_COMPONENT_CONFIRM" != "true" ]; then
    if ! component_prompt_proceed "Secrets Migration" "Proceed with secrets migration from $SOURCE_ENV to $TARGET_ENV?"; then
        log_warning "Secrets migration skipped by user request."
        log_to_file "$LOG_FILE" "Secrets migration skipped by user."
        exit 0
    fi
fi

# Step 1: Get secrets from source using Management API
log_info "Step 1/4: Fetching secrets from source project..."
log_to_file "$LOG_FILE" "Fetching secrets from source"

SOURCE_SECRETS_FILE="$MIGRATION_DIR/source_secrets.json"
TARGET_SECRETS_FILE="$MIGRATION_DIR/target_secrets.json"

# Fetch source secrets
if curl -s -H "Authorization: Bearer $ACCESS_TOKEN_FOR_READ" \
    "https://api.supabase.com/v1/projects/${SOURCE_REF}/secrets" \
    -o "$SOURCE_SECRETS_FILE" 2>/dev/null; then
    
    # Validate JSON
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found - required for parsing secrets JSON"
        log_error "Please install jq: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi
    
    if jq empty "$SOURCE_SECRETS_FILE" 2>/dev/null; then
        source_secret_count=$(jq '. | length' "$SOURCE_SECRETS_FILE" 2>/dev/null || echo "0")
        log_success "Found $source_secret_count secret(s) in source project"
        
        if [ "$source_secret_count" -eq 0 ]; then
            log_info "No secrets found in source project - nothing to migrate"
            echo "$MIGRATION_DIR"
            exit 0
        fi
        
        # Display secret names (values are not returned by API for security)
        log_info "Source secrets:"
        jq -r '.[].name' "$SOURCE_SECRETS_FILE" 2>/dev/null | while IFS= read -r secret_name; do
            log_info "  - $secret_name"
        done
    else
        log_warning "Invalid JSON response from source secrets API"
        log_error "Failed to fetch source secrets"
        exit 1
    fi
else
    log_error "Failed to fetch secrets from source project"
    log_error "Please check SUPABASE_${SOURCE_ENV^^}_ACCESS_TOKEN and network connection"
    exit 1
fi

# Step 2: Get existing secrets from target (for delta comparison)
log_info "Step 2/4: Fetching existing secrets from target project..."
log_to_file "$LOG_FILE" "Fetching secrets from target"

if curl -s -H "Authorization: Bearer $ACCESS_TOKEN_FOR_WRITE" \
    "https://api.supabase.com/v1/projects/${TARGET_REF}/secrets" \
    -o "$TARGET_SECRETS_FILE" 2>/dev/null; then
    
    if jq empty "$TARGET_SECRETS_FILE" 2>/dev/null; then
        target_secret_count=$(jq '. | length' "$TARGET_SECRETS_FILE" 2>/dev/null || echo "0")
        log_success "Found $target_secret_count existing secret(s) in target project"
    else
        log_warning "Invalid JSON response from target secrets API - will proceed with migration"
    fi
else
    log_warning "Failed to fetch target secrets - will proceed with migration (non-delta)"
fi

# Step 3: Migrate secrets to target
log_info "Step 3/4: Migrating secrets to target project..."
log_to_file "$LOG_FILE" "Migrating secrets to target"

# Link to target project for CLI operations
if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    log_error "Cannot proceed with secrets migration"
    exit 1
fi

# Extract secret names from source
source_secret_names=$(jq -r '.[].name' "$SOURCE_SECRETS_FILE" 2>/dev/null || echo "")
target_secret_names=""

if [ -f "$TARGET_SECRETS_FILE" ] && jq empty "$TARGET_SECRETS_FILE" 2>/dev/null; then
    target_secret_names=$(jq -r '.[].name' "$TARGET_SECRETS_FILE" 2>/dev/null || echo "")
fi

# Determine which secrets need migration (delta)
secrets_to_migrate=""
skipped_count=0
migrated_count=0
failed_count=0
restricted_count=0
restricted_secrets=""

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Secrets Migration Details"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

for secret_name in $source_secret_names; do
    secret_name=$(echo "$secret_name" | xargs)
    [ -z "$secret_name" ] && continue
    
    # Check if secret already exists in target
    exists_in_target=false
    if [ -n "$target_secret_names" ]; then
        if echo "$target_secret_names" | grep -q "^${secret_name}$" 2>/dev/null; then
            exists_in_target=true
        fi
    fi
    
    if [ "$exists_in_target" = "true" ]; then
        log_info "  ⏭️  Skipping: $secret_name (already exists in target)"
        skipped_count=$((skipped_count + 1))
        continue
    fi
    
    # Secret needs to be migrated
    log_info "  Secret: $secret_name"
    
    if [[ "$secret_name" == SUPABASE_* ]]; then
        log_warning "    ⚠ Skipping Supabase-managed secret (prefix SUPABASE_ is restricted)"
        restricted_count=$((restricted_count + 1))
        restricted_secrets="${restricted_secrets}${secret_name}"$'\n'
        echo ""
        continue
    fi
    
    # Default: migrate keys only with blank values
    # Note: Secret values cannot be retrieved via API/CLI for security reasons
    # The --values flag is mainly for documentation/intent, but values still need manual input
    if [ "$INCLUDE_VALUES" = "true" ]; then
        log_info "    Mode: Attempting to migrate with values (if accessible)..."
        log_warning "    Note: Secret values are typically not accessible via API/CLI for security"
    else
        log_info "    Mode: Migrating key only (blank value)..."
    fi
    
    # Try to set secret with blank value first
    log_info "    Setting secret..."
    
    # Use PIPESTATUS to properly capture exit code when using pipes
    set +o pipefail  # Temporarily disable pipefail to check exit code manually
    if supabase secrets set "${secret_name}=" --project-ref "$TARGET_REF" 2>&1 | tee -a "$LOG_FILE"; then
        SECRET_EXIT_CODE=${PIPESTATUS[0]}
        if [ "$SECRET_EXIT_CODE" -eq 0 ]; then
            log_success "    ✓ Migrated: $secret_name (blank value - UPDATE REQUIRED)"
            migrated_count=$((migrated_count + 1))
        else
            # Try with placeholder if blank doesn't work
            log_info "    Blank value failed, trying placeholder..."
            if supabase secrets set "${secret_name}=PLACEHOLDER_UPDATE_REQUIRED" --project-ref "$TARGET_REF" 2>&1 | tee -a "$LOG_FILE"; then
                SECRET_EXIT_CODE=${PIPESTATUS[0]}
                if [ "$SECRET_EXIT_CODE" -eq 0 ]; then
                    log_success "    ✓ Migrated: $secret_name (placeholder - UPDATE REQUIRED)"
                    migrated_count=$((migrated_count + 1))
                else
                    log_error "    ✗ Failed: $secret_name (exit code: $SECRET_EXIT_CODE)"
                    failed_count=$((failed_count + 1))
                fi
            else
                SECRET_EXIT_CODE=${PIPESTATUS[0]}
                log_error "    ✗ Failed: $secret_name (exit code: $SECRET_EXIT_CODE)"
                failed_count=$((failed_count + 1))
            fi
        fi
    else
        SECRET_EXIT_CODE=${PIPESTATUS[0]}
        # Try with placeholder if blank doesn't work
        log_info "    Blank value failed, trying placeholder..."
        if supabase secrets set "${secret_name}=PLACEHOLDER_UPDATE_REQUIRED" --project-ref "$TARGET_REF" 2>&1 | tee -a "$LOG_FILE"; then
            SECRET_EXIT_CODE=${PIPESTATUS[0]}
            if [ "$SECRET_EXIT_CODE" -eq 0 ]; then
                log_success "    ✓ Migrated: $secret_name (placeholder - UPDATE REQUIRED)"
                migrated_count=$((migrated_count + 1))
            else
                log_error "    ✗ Failed: $secret_name (exit code: $SECRET_EXIT_CODE)"
                failed_count=$((failed_count + 1))
            fi
        else
            SECRET_EXIT_CODE=${PIPESTATUS[0]}
            log_error "    ✗ Failed: $secret_name (exit code: $SECRET_EXIT_CODE)"
            failed_count=$((failed_count + 1))
        fi
    fi
    set -o pipefail  # Re-enable pipefail
    
    echo ""
done

# Step 4: Skip cleanup - never remove or modify existing secrets in target
# Policy: Only add new secret keys from source, never alter existing secrets (keys or values)
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Secrets Cleanup (Skipped)"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "  ✓ Skipping cleanup: Existing secrets in target are preserved"
log_info "  ✓ Only new secret keys from source are added"
log_info "  ✓ Existing secret keys and values in target are never modified"
echo ""

removed_count=0
removed_failed_count=0

# Cleanup
supabase unlink --yes 2>/dev/null || true

# Create summary file
summary_file="$MIGRATION_DIR/secrets_migration_summary.txt"
cat > "$summary_file" << EOF
# Secrets Migration Summary

**Source**: $SOURCE_ENV ($SOURCE_REF)
**Target**: $TARGET_ENV ($TARGET_REF)
**Date**: $(date)
**Mode**: $([ "$INCLUDE_VALUES" = "true" ] && echo "Keys + Values (attempted)" || echo "Keys Only (blank values)")

## Migration Policy

**IMPORTANT**: This migration only ADDS new secret keys from source. It NEVER modifies or removes existing secrets in target.

## Migration Results

- **Migrated**: $migrated_count secret(s) (new keys added)
- **Skipped**: $skipped_count secret(s) (already exist in target - preserved unchanged)
- **Failed**: $failed_count secret(s)
- **Removed**: $removed_count secret(s) (cleanup disabled - existing secrets preserved)
- **Removal Failed**: $removed_failed_count secret(s)

EOF

if [ $restricted_count -gt 0 ]; then
    cat >> "$summary_file" << EOF
- **Reserved Skipped**: $restricted_count secret(s) (Supabase-managed prefix SUPABASE_)

## Reserved Supabase Secrets (Skipped - manage manually)

$(printf '%s' "$restricted_secrets" | sed '/^$/d' | sed 's/^/- /')

EOF
fi

cat >> "$summary_file" << EOF

## Migrated Secrets

EOF

for secret_name in $source_secret_names; do
    secret_name=$(echo "$secret_name" | xargs)
    [ -z "$secret_name" ] && continue
    
    # Check if it was migrated (not skipped)
    if echo "$target_secret_names" | grep -q "^${secret_name}$" 2>/dev/null; then
        continue  # Skipped
    fi
    
    echo "- $secret_name" >> "$summary_file"
done

# Add removed secrets section if any were removed
if [ $removed_count -gt 0 ]; then
    cat >> "$summary_file" << EOF

## Removed Secrets (No Longer in Source)

EOF

    for target_secret_name in $target_secret_names; do
        target_secret_name=$(echo "$target_secret_name" | xargs)
        [ -z "$target_secret_name" ] && continue
        
        # Check if this secret exists in source
        exists_in_source=false
        if [ -n "$source_secret_names" ]; then
            if echo "$source_secret_names" | grep -q "^${target_secret_name}$" 2>/dev/null; then
                exists_in_source=true
            fi
        fi
        
        if [ "$exists_in_source" = "false" ]; then
            echo "- $target_secret_name" >> "$summary_file"
        fi
    done
fi

cat >> "$summary_file" << EOF

## Next Steps

$([ "$INCLUDE_VALUES" = "true" ] && echo "⚠️  **IMPORTANT**: Secret values may not have been migrated due to security restrictions." || echo "⚠️  **IMPORTANT**: Secret values were NOT migrated (keys only).")

You MUST update all secret values manually:

\`\`\`bash
# For each secret, update the value:
supabase secrets set SECRET_NAME=your_actual_value --project-ref $TARGET_REF
\`\`\`

## Secret List

EOF

jq -r '.[].name' "$SOURCE_SECRETS_FILE" 2>/dev/null | while IFS= read -r secret_name; do
    echo "- $secret_name" >> "$summary_file"
done

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_success "Migrated: $migrated_count secret(s)"
log_info "Skipped: $skipped_count secret(s) (already exist in target)"
if [ $restricted_count -gt 0 ]; then
    log_warning "Reserved (SUPABASE_*) skipped: $restricted_count secret(s) - manage manually"
fi
if [ $failed_count -gt 0 ]; then
    log_error "Failed: $failed_count secret(s)"
fi
if [ $removed_count -gt 0 ]; then
    log_success "Removed: $removed_count secret(s) (cleaned up from target)"
fi
if [ $removed_failed_count -gt 0 ]; then
    log_error "Removal Failed: $removed_failed_count secret(s)"
fi
log_info ""
log_info "Summary file: $summary_file"
log_info "Source secrets: $SOURCE_SECRETS_FILE"
log_info "Target secrets: $TARGET_SECRETS_FILE"
log_info ""

if [ "$INCLUDE_VALUES" = "true" ]; then
    log_warning "⚠️  Note: Secret values were NOT migrated due to security restrictions."
    log_warning "   Secret values cannot be retrieved via API/CLI for security reasons."
    log_warning "   The --values flag indicates intent, but values still require manual input."
else
    log_warning "⚠️  IMPORTANT: Secret values were NOT migrated (keys only)."
fi

log_warning "   You MUST update all secret values manually after migration."
log_info ""
log_info "   To update a secret value:"
log_info "     supabase secrets set SECRET_NAME=your_value --project-ref $TARGET_REF"
log_info ""

# Determine overall success
# Success if: (migrated > 0 OR all skipped) AND (removed >= 0 OR removal failed) AND no critical failures
overall_success=true

if [ $failed_count -gt 0 ]; then
    overall_success=false
fi

# Generate HTML report
if [ "$overall_success" = "true" ]; then
    STATUS="success"
    COMPONENT_NAME="Secrets Migration"
    log_success "✅ Secrets migration completed successfully"
    log_to_file "$LOG_FILE" "Secrets migration completed: $migrated_count migrated, $skipped_count skipped, $failed_count failed, $removed_count removed, $removed_failed_count removal failed"
else
    STATUS="partial"
    COMPONENT_NAME="Secrets Migration"
    log_error "❌ Secrets migration completed with errors"
    log_to_file "$LOG_FILE" "Secrets migration completed with errors: $migrated_count migrated, $skipped_count skipped, $failed_count failed, $removed_count removed, $removed_failed_count removal failed"
fi

# Set migration statistics for HTML report
MIGRATED_COUNT=$migrated_count
SKIPPED_COUNT=$skipped_count
FAILED_COUNT=$failed_count
REMOVED_COUNT=$removed_count

# Generate details section
DETAILS_SECTION=$(format_migration_details "$LOG_FILE" "secrets")

# Generate HTML report
export MIGRATED_COUNT SKIPPED_COUNT FAILED_COUNT REMOVED_COUNT DETAILS_SECTION
generate_migration_html_report \
    "$MIGRATION_DIR" \
    "$COMPONENT_NAME" \
    "$SOURCE_ENV" \
    "$TARGET_ENV" \
    "$SOURCE_REF" \
    "$TARGET_REF" \
    "$STATUS" \
    ""

log_info "HTML report generated: $MIGRATION_DIR/result.html"

if [ "$overall_success" = "true" ]; then
    echo "$MIGRATION_DIR"  # Return migration directory for use by other scripts
    exit 0
else
    exit 1
fi

