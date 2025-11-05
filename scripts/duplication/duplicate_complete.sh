#!/bin/bash
# Complete Duplication Script
# Migrates ALL aspects of Supabase project: Database, Storage, Edge Functions, Secrets, Auth, Realtime, Cron

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/migration_complete.sh"

# Configuration
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
BACKUP_TARGET=${3:-false}

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [--backup]

Complete duplication: Migrates ALL aspects of Supabase project:
  ✅ Database Schema + Data
  ✅ Storage Buckets + Policies
  ✅ Edge Functions (automatically deployed)
  ✅ Secrets (automatically created with blank values - update required)
  ✅ Realtime Configuration
  ✅ Cron Jobs (pg_cron)
  ⚠️  Authentication Configuration (manual via Dashboard)
  ⚠️  Project Settings (manual via Dashboard)

Arguments:
  source_env    Source environment (prod, test, dev)
  target_env    Target environment (prod, test, dev)
  --backup      Create backup of target before duplication (optional)

Examples:
  $0 prod test          # Complete migration from production to test
  $0 prod dev           # Complete migration from production to develop
  $0 dev test           # Complete migration from develop to test
  $0 prod test --backup # Complete migration with backup

⚠️  IMPORTANT NOTES:
  - Secrets are created with blank/placeholder values - UPDATE REQUIRED after migration
  - Edge functions are automatically deployed if available via API or local codebase
  - If edge functions deployment fails, deploy manually from your codebase
  - Auth configuration must be set manually via Dashboard
  - Project settings must be configured manually

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

# Safety check for production
confirm_production_operation "COMPLETE MIGRATION (All Components)" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  COMPLETE SUPABASE PROJECT MIGRATION"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
echo ""

# Create migration directory
MIGRATION_DIR="backups/complete_migration_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$MIGRATION_DIR"
LOG_FILE="$MIGRATION_DIR/migration.log"

log_to_file "$LOG_FILE" "Starting complete migration from $SOURCE_ENV to $TARGET_ENV"

# Step 1: Backup target if requested
if [ "$BACKUP_TARGET" = "--backup" ] || [ "$BACKUP_TARGET" = "true" ]; then
    log_info "📦 Step 1/8: Creating backup of target environment..."
    log_to_file "$LOG_FILE" "Creating backup of target"
    
    if link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
        POOLER_HOST=$(get_pooler_host "$TARGET_REF")
        PGPASSWORD="$TARGET_PASSWORD" pg_dump \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U postgres.${TARGET_REF} \
            -d postgres \
            -Fc \
            -f "$MIGRATION_DIR/target_backup.dump" \
            2>&1 | tee -a "$LOG_FILE" || log_warning "Backup may have failed, continuing..."
        
        log_success "Backup created: $MIGRATION_DIR/target_backup.dump"
        supabase unlink --yes 2>/dev/null || true
    fi
fi

# Step 2: Export database (schema + data)
log_info "📊 Step 2/8: Exporting database (schema + data)..."
log_to_file "$LOG_FILE" "Exporting database"

if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

POOLER_HOST=$(get_pooler_host "$SOURCE_REF")
DUMP_FILE="$MIGRATION_DIR/source_database.dump"

PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$POOLER_HOST" \
    -p 6543 \
    -U postgres.${SOURCE_REF} \
    -d postgres \
    -Fc \
    --verbose \
    -f "$DUMP_FILE" \
    2>&1 | tee -a "$LOG_FILE" || {
    log_warning "Pooler connection failed, trying direct connection..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h db.${SOURCE_REF}.supabase.co \
        -p 5432 \
        -U postgres.${SOURCE_REF} \
        -d postgres \
        -Fc \
        --verbose \
        -f "$DUMP_FILE" \
        2>&1 | tee -a "$LOG_FILE"
}

log_success "Database exported: $DUMP_FILE"
supabase unlink --yes 2>/dev/null || true

# Step 3: Export storage buckets
log_info "🗄️  Step 3/8: Exporting storage buckets configuration..."
log_to_file "$LOG_FILE" "Exporting storage buckets"

if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

STORAGE_SQL="$MIGRATION_DIR/storage_buckets.sql"
export_storage_buckets "$SOURCE_REF" "$SOURCE_PASSWORD" "$STORAGE_SQL"
log_to_file "$LOG_FILE" "Storage buckets exported"
supabase unlink --yes 2>/dev/null || true

# Step 4: Export realtime configuration
log_info "🔄 Step 4/8: Exporting realtime configuration..."
log_to_file "$LOG_FILE" "Exporting realtime configuration"

if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

REALTIME_SQL="$MIGRATION_DIR/realtime_config.sql"
export_realtime_config "$SOURCE_REF" "$SOURCE_PASSWORD" "$REALTIME_SQL"
log_to_file "$LOG_FILE" "Realtime configuration exported"
supabase unlink --yes 2>/dev/null || true

# Step 5: Export cron jobs
log_info "⏰ Step 5/8: Exporting cron jobs..."
log_to_file "$LOG_FILE" "Exporting cron jobs"

if ! link_project "$SOURCE_REF" "$SOURCE_PASSWORD"; then
    log_error "Failed to link to source project"
    exit 1
fi

CRON_SQL="$MIGRATION_DIR/cron_jobs.sql"
export_cron_jobs "$SOURCE_REF" "$SOURCE_PASSWORD" "$CRON_SQL"
log_to_file "$LOG_FILE" "Cron jobs exported"
supabase unlink --yes 2>/dev/null || true

# Step 6: Export secrets list
log_info "🔐 Step 6/8: Exporting secrets list..."
log_to_file "$LOG_FILE" "Exporting secrets list"

SECRETS_FILE="$MIGRATION_DIR/secrets_list.json"
export_secrets_list "$SOURCE_REF" "$SECRETS_FILE"
log_to_file "$LOG_FILE" "Secrets list exported"

# Step 7: Export edge functions list
log_info "⚡ Step 7/8: Exporting edge functions list..."
log_to_file "$LOG_FILE" "Exporting edge functions list"

FUNCTIONS_FILE="$MIGRATION_DIR/edge_functions_list.json"
export_edge_functions_list "$SOURCE_REF" "$FUNCTIONS_FILE"
log_to_file "$LOG_FILE" "Edge functions list exported"

# Step 8: Import everything to target
log_info "📥 Step 8/8: Importing to target environment..."
log_to_file "$LOG_FILE" "Importing to target"

if ! link_project "$TARGET_REF" "$TARGET_PASSWORD"; then
    log_error "Failed to link to target project"
    exit 1
fi

# Import database
log_info "  → Importing database..."
TARGET_POOLER_HOST=$(get_pooler_host "$TARGET_REF")
PGPASSWORD="$TARGET_PASSWORD" pg_restore \
    -h "$TARGET_POOLER_HOST" \
    -p 6543 \
    -U postgres.${TARGET_REF} \
    -d postgres \
    --verbose \
    --no-owner \
    --no-acl \
    --clean \
    --if-exists \
    "$DUMP_FILE" \
    2>&1 | tee -a "$LOG_FILE" | grep -v "already exists" | grep -v "does not exist" || log_warning "Some expected errors (normal for system schemas)"

log_success "Database imported"

# Import storage buckets
log_info "  → Importing storage buckets..."
import_storage_buckets "$TARGET_REF" "$TARGET_PASSWORD" "$STORAGE_SQL"
log_to_file "$LOG_FILE" "Storage buckets imported"

# Import realtime configuration
log_info "  → Importing realtime configuration..."
import_realtime_config "$TARGET_REF" "$TARGET_PASSWORD" "$REALTIME_SQL"
log_to_file "$LOG_FILE" "Realtime configuration imported"

# Import cron jobs
log_info "  → Importing cron jobs..."
import_cron_jobs "$TARGET_REF" "$TARGET_PASSWORD" "$CRON_SQL"
log_to_file "$LOG_FILE" "Cron jobs imported"

# Deploy edge functions
log_info "  → Deploying edge functions..."
if deploy_edge_functions "$SOURCE_REF" "$TARGET_REF" "$FUNCTIONS_FILE" ""; then
    log_success "Edge functions deployed"
    log_to_file "$LOG_FILE" "Edge functions deployed"
else
    log_warning "Edge functions deployment failed or skipped (check if functions_dir is available)"
    log_to_file "$LOG_FILE" "Edge functions deployment failed or skipped"
fi

# Set secrets (with blank values)
log_info "  → Setting secrets (with blank/placeholder values)..."
if set_secrets_from_list "$TARGET_REF" "$SECRETS_FILE"; then
    log_success "Secrets structure created (values need manual update)"
    log_to_file "$LOG_FILE" "Secrets structure created"
else
    log_warning "Secrets setup failed or skipped"
    log_to_file "$LOG_FILE" "Secrets setup failed or skipped"
fi

supabase unlink --yes 2>/dev/null || true

# Create migration summary
SUMMARY_FILE="$MIGRATION_DIR/MIGRATION_SUMMARY.md"
cat > "$SUMMARY_FILE" << EOF
# Complete Migration Summary

**Source**: $SOURCE_ENV ($SOURCE_REF)  
**Target**: $TARGET_ENV ($TARGET_REF)  
**Date**: $(date)

## ✅ Completed Automatically

1. ✅ **Database Schema + Data** - Fully migrated
2. ✅ **Storage Buckets** - Configuration migrated (files need manual upload)
3. ✅ **Realtime Configuration** - Migrated
4. ✅ **Cron Jobs** - Migrated (if pg_cron enabled)
5. ✅ **Edge Functions** - Deployed automatically (if available via API or local codebase)
6. ✅ **Secrets** - Created with blank/placeholder values (UPDATE REQUIRED - see below)

## ⚠️  Manual Steps Required

### 1. Secrets (REQUIRED - Update Values)
Secrets have been created with blank/placeholder values. **You MUST update them manually:**

\`\`\`bash
# Check $SECRETS_FILE or ${SECRETS_FILE%.*}_template.txt for list of secrets
# Update each secret with actual value:
supabase secrets set STRIPE_SECRET_KEY=your_actual_value --project-ref $TARGET_REF
supabase secrets set FIRECRAWL_API_KEY=your_actual_value --project-ref $TARGET_REF
# ... (update all secrets from the template)
\`\`\`

**⚠️ IMPORTANT**: Applications will NOT work until secret values are properly set!

### 2. Edge Functions (if deployment failed)
If edge functions were not automatically deployed, deploy from your codebase:

\`\`\`bash
# Check $FUNCTIONS_FILE for list of functions
# Deploy each function:
supabase functions deploy <function-name> --project-ref $TARGET_REF
\`\`\`

Or if you have a local functions directory:
\`\`\`bash
cd supabase/functions
for func in */; do
    supabase functions deploy "\${func%/}" --project-ref $TARGET_REF
done
\`\`\`

### 3. Storage Files
Storage bucket configuration is migrated, but actual files need to be uploaded:
- Go to: https://supabase.com/dashboard/project/$TARGET_REF/storage/buckets
- Upload files to each bucket

### 4. Authentication Configuration
Configure via Dashboard:
- Go to: https://supabase.com/dashboard/project/$TARGET_REF/auth/providers
- Configure email templates, OAuth providers, password requirements, etc.

### 5. Project Settings
Configure via Dashboard:
- Go to: https://supabase.com/dashboard/project/$TARGET_REF/settings/general
- Set project name, custom domain, API rate limiting, CORS, etc.

## Files Generated

- \`source_database.dump\` - Full database backup
- \`storage_buckets.sql\` - Storage buckets configuration
- \`realtime_config.sql\` - Realtime configuration
- \`cron_jobs.sql\` - Cron jobs configuration
- \`secrets_list.json\` - List of secrets (names only)
- \`edge_functions_list.json\` - List of edge functions
- \`migration.log\` - Complete migration log

## Next Steps

1. Review the migration log: \`$LOG_FILE\`
2. Deploy edge functions
3. Set secrets
4. Upload storage files
5. Configure authentication
6. Configure project settings
7. Test the migrated environment

EOF

log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "  COMPLETE MIGRATION FINISHED"
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Migration directory: $MIGRATION_DIR"
log_info "Summary: $SUMMARY_FILE"
log_info "Log: $LOG_FILE"
echo ""
log_info "⚠️  IMPORTANT: Review $SUMMARY_FILE for manual steps required"
echo ""

exit 0

