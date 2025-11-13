#!/bin/bash
# Roll back the most recent migration/clone for a target environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat <<'EOF'
Usage: rollback_last_migration.sh <target_env> [--auto-confirm] [--dry-run] [--backup-dir <path>]

Examples:
  rollback_last_migration.sh test
  rollback_last_migration.sh prod --auto-confirm

Notes:
  - Restores the target environment to its pre-migration state using the most recent backup directory.
  - By default replays database backup and merges stored artefacts (storage files, secrets list).
  - Prompts for confirmation unless --auto-confirm is passed. Production targets require a second confirmation.
EOF
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

TARGET_ENV=""
AUTO_CONFIRM=false
DRY_RUN=false
OVERRIDE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-confirm|--yes|-y)
            AUTO_CONFIRM=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --backup-dir)
            OVERRIDE_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ -z "$TARGET_ENV" ]; then
                TARGET_ENV="$1"
                shift
            else
                log_error "Unexpected argument: $1"
                usage
            fi
            ;;
    esac
done

if [ -z "$TARGET_ENV" ]; then
    usage
fi

load_env
validate_environments "$TARGET_ENV" "$TARGET_ENV"

# Determine latest backup directory
select_backup_dir() {
    local target=$1
    local override=$2

    if [ -n "$override" ]; then
        local override_path="$override"
        [[ "$override_path" != /* ]] && override_path="$PROJECT_ROOT/$override_path"
        if [ ! -d "$override_path" ]; then
            log_error "Specified backup directory not found: $override_path"
            exit 1
        fi
        echo "$override_path"
        return
    fi

    if [ ! -d "$PROJECT_ROOT/backups" ]; then
        log_error "No backups directory found. Cannot perform rollback."
        exit 1
    fi

    local latest_dir
    latest_dir=$(find "$PROJECT_ROOT/backups" -maxdepth 1 -type d -name "*_to_${target}_*" -print0 \
        | xargs -0 ls -td 2>/dev/null | head -n 1)

    if [ -z "$latest_dir" ]; then
        log_error "No backup directories found for target environment '$target'."
        exit 1
    fi

    echo "$latest_dir"
}

BACKUP_DIR=$(select_backup_dir "$TARGET_ENV" "$OVERRIDE_DIR")
BACKUP_NAME=$(basename "$BACKUP_DIR")

log_info "Using backup directory: $BACKUP_DIR"

# Extract source env from directory name (pattern: *_<source>_to_<target>_timestamp)
SOURCE_ENV=$(echo "$BACKUP_NAME" | sed -n 's/.*_\([a-zA-Z0-9-]*\)_to_'"$TARGET_ENV"'.*/\1/p')
[ -z "$SOURCE_ENV" ] && SOURCE_ENV="unknown"

# Inspect artefacts
TARGET_BACKUP_DUMP="$BACKUP_DIR/target_backup.dump"
ROLLBACK_SQL="$BACKUP_DIR/rollback_db.sql"
STORAGE_DIR="$BACKUP_DIR/storage_files"
SECRETS_FILE="$BACKUP_DIR/target_secrets.json"
EDGE_DIR="$BACKUP_DIR/edge_functions"

log_info "Backup summary:"
log_info "  Source environment : $SOURCE_ENV"
log_info "  Target environment : $TARGET_ENV"
log_info "  Database dump      : $( [ -f "$TARGET_BACKUP_DUMP" ] && echo '✅' || echo '❌ Missing' )"
log_info "  Rollback SQL       : $( [ -f "$ROLLBACK_SQL" ] && echo '✅' || echo '❌ Missing' )"
log_info "  Storage snapshot   : $( [ -d "$STORAGE_DIR" ] && echo '✅' || echo '❌ None' )"
log_info "  Secrets snapshot   : $( [ -f "$SECRETS_FILE" ] && echo '✅' || echo '❌ None' )"
log_info "  Edge artefacts     : $( [ -d "$EDGE_DIR" ] && echo '✅' || echo '❌ None' )"

if [ "$DRY_RUN" = "true" ]; then
    log_warning "[DRY RUN] No changes will be made."
fi

# Confirm with user
confirm() {
    local prompt=$1
    local expected=$2
    local response=""

    if [ "$AUTO_CONFIRM" = "true" ]; then
        log_info "Auto-confirm enabled - skipping prompt: $prompt"
        return 0
    fi

    read -rp "$prompt " response
    response=$(echo "$response" | tr '[:lower:]' '[:upper:]')
    if [ "$response" != "$expected" ]; then
        log_warning "Rollback aborted by user."
        exit 0
    fi
}

confirm "Are you sure you want to roll back environment '$TARGET_ENV'? Type YES to continue: " "YES"
if [[ "$TARGET_ENV" =~ ^prod|production|main$ ]]; then
    confirm "Production rollback requires extra confirmation. Type PROD to confirm: " "PROD"
fi

# Stop here if dry-run
if [ "$DRY_RUN" = "true" ]; then
    log_success "[DRY RUN] Confirmation received. No actions executed."
    exit 0
fi

# Fetch credentials
TARGET_REF=$(get_project_ref "$TARGET_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")
TARGET_POOLER_REGION=$(get_pooler_region_for_env "$TARGET_ENV")
TARGET_POOLER_PORT=$(get_pooler_port_for_env "$TARGET_ENV")

# Helper to restore database (prefer pooler then direct)
restore_database() {
    local dump_file=$1

    if [ ! -f "$dump_file" ]; then
        log_warning "Database dump not found: $dump_file"
        return 1
    fi

    log_info "Restoring database from $dump_file ..."
    if run_pg_tool_with_fallback "pg_restore" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_POOLER_REGION" "$TARGET_POOLER_PORT" "$BACKUP_DIR/rollback.log" \
        -d postgres \
        --clean \
        --if-exists \
        --no-owner \
        --no-acl \
        "$dump_file"; then
        log_success "Database restored successfully."
        return 0
    fi

    log_warning "Pooler restore failed, trying direct connection..."
    if check_direct_connection_available "$TARGET_REF"; then
        PGPASSWORD="$TARGET_PASSWORD" pg_restore \
            -h "db.${TARGET_REF}.supabase.co" \
            -p 5432 \
            -U "postgres.${TARGET_REF}" \
            -d postgres \
            --clean \
            --if-exists \
            --no-owner \
            --no-acl \
            "$dump_file" 2>&1 | tee -a "$BACKUP_DIR/rollback.log"
        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
            log_success "Database restored via direct connection."
            return 0
        fi
    fi

    log_error "Database restore failed. Check $BACKUP_DIR/rollback.log for details."
    return 1
}

# Restoration steps
restore_failures=0

link_project "$TARGET_REF" "$TARGET_PASSWORD" || log_warning "Supabase link failed; continuing with direct credentials."

restore_database "$TARGET_BACKUP_DUMP" || restore_failures=$((restore_failures + 1))

# Inform about additional artefacts
if [ -d "$STORAGE_DIR" ]; then
    log_warning "Storage files snapshot detected: $STORAGE_DIR"
    log_warning "Manual upload required to fully restore bucket contents."
fi

if [ -f "$SECRETS_FILE" ]; then
    log_warning "Secrets snapshot available: $SECRETS_FILE"
    log_warning "Run 'supabase secrets set' per result.md instructions to reapply values."
fi

if [ -d "$EDGE_DIR" ]; then
    log_warning "Edge function artefacts located at: $EDGE_DIR"
    log_warning "Redeploy functions using 'supabase functions deploy'."
fi

supabase unlink --yes 2>/dev/null || true

if [ "$restore_failures" -eq 0 ]; then
    log_success "Rollback completed successfully."
else
    log_warning "Rollback finished with $restore_failures issue(s). Review logs above."
fi

