#!/bin/bash
# Cleanup old backup and migration folders
# Keeps only the most recent backup/migration folder

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Function to cleanup backups
cleanup_backups() {
    local keep_count=${1:-1}
    
    log_info "Cleaning up old backup and migration folders..."
    
    if [ "$keep_count" -eq 0 ]; then
        log_info "Deleting all old backup and migration folders (keeping 0)"
    else
        log_info "Keeping the $keep_count most recent folder(s)"
    fi
    
    # Find all backup/migration folders and sort by modification time (most recent first)
    local backup_dirs=()
    # Use ls -td to sort by modification time (newest first)
    # This ensures we get the most recently modified folder
    while IFS= read -r dir; do
        [ -n "$dir" ] && [ "$dir" != "backups" ] && [ -d "$dir" ] && backup_dirs+=("$dir")
    done < <(ls -1td backups/*/ 2>/dev/null | head -100)
    
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        log_info "No backup folders found to clean up"
        return 0
    fi
    
    local total=${#backup_dirs[@]}
    local to_keep=$((keep_count < total ? keep_count : total))
    local to_delete=$((total - to_keep))
    
    log_info "Found $total backup folder(s)"
    log_info "Keeping $to_keep most recent, deleting $to_delete old folder(s)"
    
    # Keep the most recent ones
    local kept=0
    local deleted=0
    
    for dir in "${backup_dirs[@]}"; do
        if [ $kept -lt $to_keep ]; then
            log_info "Keeping: $dir"
            kept=$((kept + 1))
        else
            log_info "Deleting: $dir"
            rm -rf "$dir"
            deleted=$((deleted + 1))
        fi
    done
    
    log_success "Cleanup complete: Kept $kept folder(s), deleted $deleted folder(s)"
}

# Function to cleanup diff results
cleanup_diff_results() {
    log_info "Cleaning up old diff result files..."
    
    if [ ! -d "diff_results" ]; then
        log_info "No diff_results directory found"
        return 0
    fi
    
    # Find all diff result files
    local diff_files=()
    while IFS= read -r file; do
        [ -n "$file" ] && diff_files+=("$file")
    done < <(find diff_results -maxdepth 1 -type f -name "*.md" 2>/dev/null | sort -r)
    
    if [ ${#diff_files[@]} -eq 0 ]; then
        log_info "No diff result files found to clean up"
        return 0
    fi
    
    local total=${#diff_files[@]}
    local to_keep=1
    local to_delete=$((total - to_keep))
    
    log_info "Found $total diff result file(s)"
    log_info "Keeping $to_keep most recent, deleting $to_delete old file(s)"
    
    # Keep the most recent one
    local kept=0
    local deleted=0
    
    for file in "${diff_files[@]}"; do
        if [ $kept -lt $to_keep ]; then
            log_info "Keeping: $file"
            kept=$((kept + 1))
        else
            log_info "Deleting: $file"
            rm -f "$file"
            deleted=$((deleted + 1))
        fi
    done
    
    log_success "Diff cleanup complete: Kept $kept file(s), deleted $deleted file(s)"
}

# Main execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly
    keep_count=${1:-1}
    cleanup_backups "$keep_count"
    cleanup_diff_results
else
    # Script is being sourced
    export -f cleanup_backups
    export -f cleanup_diff_results
fi

