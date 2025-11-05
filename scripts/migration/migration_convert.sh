#!/bin/bash
# Convert Old Migration Format to New Organized Format
# Converts flat migration files to organized folder structure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/migration_utils.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 [--all|--file <file>] [--backup]

Converts old migration format (flat files) to new organized format (folders).

Options:
  --all           Convert all old migration files
  --file <file>   Convert specific migration file
  --backup        Keep original files after conversion

Examples:
  $0 --all
  $0 --file supabase/migrations/20250914060248_initial.sql
  $0 --all --backup

EOF
    exit 1
}

# Parse arguments
CONVERT_ALL=false
CONVERT_FILE=""
KEEP_BACKUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            CONVERT_ALL=true
            shift
            ;;
        --file)
            CONVERT_FILE="$2"
            shift 2
            ;;
        --backup)
            KEEP_BACKUP=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ "$CONVERT_ALL" = "false" ] && [ -z "$CONVERT_FILE" ]; then
    usage
fi

MIGRATIONS_DIR=$(get_migrations_dir)

# Create backup of old migrations if converting all
if [ "$CONVERT_ALL" = "true" ] && [ "$KEEP_BACKUP" = "true" ]; then
    BACKUP_DIR="backups/migrations_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r "$MIGRATIONS_DIR"/*.sql "$BACKUP_DIR/" 2>/dev/null || true
    log_info "Old migrations backed up to: $BACKUP_DIR"
fi

# Convert files
if [ "$CONVERT_ALL" = "true" ]; then
    log_info "Converting all old migration files..."
    
    for old_file in "$MIGRATIONS_DIR"/*.sql; do
        if [ -f "$old_file" ]; then
            # Check if it's already in new format (has folder structure)
            if [[ "$old_file" == *"/"*"_"*"/"* ]]; then
                log_info "Skipping (already converted): $(basename "$old_file")"
                continue
            fi
            
            MIGRATION_PATH=$(convert_old_migration "$old_file")
            
            if [ "$KEEP_BACKUP" = "false" ]; then
                rm "$old_file"
                log_info "Removed old file: $(basename "$old_file")"
            fi
        fi
    done
elif [ -n "$CONVERT_FILE" ]; then
    if [ ! -f "$CONVERT_FILE" ]; then
        log_error "File not found: $CONVERT_FILE"
        exit 1
    fi
    
    MIGRATION_PATH=$(convert_old_migration "$CONVERT_FILE")
    
    if [ "$KEEP_BACKUP" = "false" ]; then
        rm "$CONVERT_FILE"
        log_info "Removed old file: $(basename "$CONVERT_FILE")"
    fi
fi

# Create Supabase CLI compatibility symlinks
create_supabase_compat_links

log_success "Conversion complete!"
log_info "New migration structure created"
log_info "Compatibility symlinks created for Supabase CLI"

exit 0

