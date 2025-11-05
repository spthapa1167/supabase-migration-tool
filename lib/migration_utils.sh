#!/bin/bash
# Migration Utilities Library
# Handles organized migration folder structure with all related files

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get migration directory path
get_migrations_dir() {
    echo "supabase/migrations"
}

# Create migration folder with timestamp
create_migration_folder() {
    local migration_name=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local folder_name="${timestamp}_${migration_name}"
    local migrations_dir=$(get_migrations_dir)
    local migration_path="${migrations_dir}/${folder_name}"
    
    mkdir -p "$migration_path"
    echo "$migration_path"
}

# Get latest migration folder
get_latest_migration_folder() {
    local migrations_dir=$(get_migrations_dir)
    ls -td "${migrations_dir}"/[0-9]*_* 2>/dev/null | head -1
}

# List all migration folders in order
list_migration_folders() {
    local migrations_dir=$(get_migrations_dir)
    ls -td "${migrations_dir}"/[0-9]*_* 2>/dev/null
}

# Get migration folder by name pattern
find_migration_folder() {
    local pattern=$1
    local migrations_dir=$(get_migrations_dir)
    ls -td "${migrations_dir}"/[0-9]*_*${pattern}* 2>/dev/null | head -1
}

# Create migration SQL file
create_migration_file() {
    local migration_path=$1
    local content=${2:-""}
    
    local migration_file="${migration_path}/migration.sql"
    
    if [ -n "$content" ]; then
        echo "$content" > "$migration_file"
    else
        touch "$migration_file"
    fi
    
    echo "$migration_file"
}

# Create rollback file
create_rollback_file() {
    local migration_path=$1
    local rollback_sql=${2:-""}
    
    local rollback_file="${migration_path}/rollback.sql"
    
    if [ -n "$rollback_sql" ]; then
        echo "$rollback_sql" > "$rollback_file"
    else
        cat > "$rollback_file" << 'EOF'
-- Rollback script for this migration
-- This file contains SQL statements to reverse the changes made in migration.sql
-- Edit this file to add rollback statements

-- Example:
-- DROP TABLE IF EXISTS table_name;
-- DROP FUNCTION IF EXISTS function_name();
EOF
    fi
    
    echo "$rollback_file"
}

# Create diff files
create_diff_files() {
    local migration_path=$1
    local before_sql=${2:-""}
    local after_sql=${3:-""}
    
    if [ -n "$before_sql" ]; then
        echo "$before_sql" > "${migration_path}/diff_before.sql"
    else
        touch "${migration_path}/diff_before.sql"
    fi
    
    if [ -n "$after_sql" ]; then
        echo "$after_sql" > "${migration_path}/diff_after.sql"
    else
        touch "${migration_path}/diff_after.sql"
    fi
}

# Create metadata file
create_metadata_file() {
    local migration_path=$1
    local migration_name=$2
    local description=${3:-""}
    local author=${4:-""}
    local environment=${5:-""}
    
    local metadata_file="${migration_path}/metadata.json"
    
    cat > "$metadata_file" << EOF
{
  "name": "${migration_name}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "description": "${description}",
  "author": "${author:-$(git config user.name 2>/dev/null || echo "unknown")}",
  "environment": "${environment}",
  "files": {
    "migration": "migration.sql",
    "rollback": "rollback.sql",
    "diff_before": "diff_before.sql",
    "diff_after": "diff_after.sql"
  },
  "status": "pending"
}
EOF
    
    echo "$metadata_file"
}

# Create README for migration
create_migration_readme() {
    local migration_path=$1
    local migration_name=$2
    local description=${3:-""}
    
    local readme_file="${migration_path}/README.md"
    
    cat > "$readme_file" << EOF
# Migration: ${migration_name}

**Created**: $(date)

## Description
${description}

## Files

- \`migration.sql\` - Forward migration script
- \`rollback.sql\` - Rollback script to reverse changes
- \`diff_before.sql\` - Schema state before migration
- \`diff_after.sql\` - Schema state after migration
- \`metadata.json\` - Migration metadata
- \`README.md\` - This file

## Usage

### Apply Migration
\`\`\`bash
# Apply this migration
psql -f migration.sql
\`\`\`

### Rollback Migration
\`\`\`bash
# Rollback this migration
psql -f rollback.sql
\`\`\`

## Status

- [ ] Not applied
- [ ] Applied to production
- [ ] Applied to test
- [ ] Applied to develop
EOF
    
    echo "$readme_file"
}

# Generate complete migration structure
create_complete_migration() {
    local migration_name=$1
    local description=${2:-""}
    local author=${3:-""}
    local environment=${4:-""}
    
    # Create folder
    local migration_path=$(create_migration_folder "$migration_name")
    log_info "Created migration folder: $migration_path"
    
    # Create files
    create_migration_file "$migration_path"
    create_rollback_file "$migration_path"
    create_diff_files "$migration_path"
    create_metadata_file "$migration_path" "$migration_name" "$description" "$author" "$environment"
    create_migration_readme "$migration_path" "$migration_name" "$description"
    
    log_success "Migration structure created: $migration_path"
    echo "$migration_path"
}

# Get migration SQL from folder (for Supabase CLI compatibility)
get_migration_sql_path() {
    local migration_folder=$1
    echo "${migration_folder}/migration.sql"
}

# Convert old migration format to new format
convert_old_migration() {
    local old_file=$1
    local basename_file=$(basename "$old_file" .sql)
    
    # Try to extract timestamp (format: YYYYMMDDHHMMSS_name or YYYYMMDD_HHMMSS_name)
    local timestamp=""
    local migration_name=""
    
    if [[ "$basename_file" =~ ^([0-9]{8})([0-9]{6})_(.+)$ ]]; then
        # Format: YYYYMMDDHHMMSS_name
        timestamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        migration_name="${BASH_REMATCH[3]}"
    elif [[ "$basename_file" =~ ^([0-9]{8})_([0-9]{6})_(.+)$ ]]; then
        # Format: YYYYMMDD_HHMMSS_name (already formatted)
        timestamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        migration_name="${BASH_REMATCH[3]}"
    else
        # Fallback: use current timestamp
        log_warning "Could not parse timestamp from: $old_file, using current timestamp"
        timestamp=$(date +%Y%m%d%H%M%S)
        migration_name="$basename_file"
    fi
    
    # Create new folder structure
    local formatted_timestamp="${timestamp:0:8}_${timestamp:8:6}"
    local migrations_dir=$(get_migrations_dir)
    local migration_path="${migrations_dir}/${formatted_timestamp}_${migration_name}"
    
    # Skip if folder already exists
    if [ -d "$migration_path" ]; then
        log_info "Skipping (already converted): $old_file → $migration_path"
        echo "$migration_path"
        return 0
    fi
    
    mkdir -p "$migration_path"
    
    # Copy migration SQL
    cp "$old_file" "${migration_path}/migration.sql"
    
    # Create other files
    create_rollback_file "$migration_path"
    create_diff_files "$migration_path"
    create_metadata_file "$migration_path" "$migration_name" "Migrated from old format" "" ""
    create_migration_readme "$migration_path" "$migration_name" "Migrated from old format"
    
    log_success "Converted: $old_file → $migration_path"
    echo "$migration_path"
}

# Generate symlinks for Supabase CLI compatibility
create_supabase_compat_links() {
    local migrations_dir=$(get_migrations_dir)
    local compat_dir="${migrations_dir}/.supabase_compat"
    
    mkdir -p "$compat_dir"
    
    # Remove old symlinks first
    rm -f "$compat_dir"/*.sql 2>/dev/null || true
    
    # Create symlinks for each migration
    for migration_folder in $(list_migration_folders); do
        local folder_name=$(basename "$migration_folder")
        local timestamp_part=$(echo "$folder_name" | grep -o '^[0-9]\{8\}_[0-9]\{6\}' || echo "")
        local migration_name=$(echo "$folder_name" | sed "s/^[0-9]\{8\}_[0-9]\{6\}_//")
        
        if [ -z "$timestamp_part" ]; then
            continue
        fi
        
        # Convert YYYYMMDD_HHMMSS to YYYYMMDDHHMMSS
        local timestamp=$(echo "$timestamp_part" | tr -d '_')
        local compat_file="${compat_dir}/${timestamp}_${migration_name}.sql"
        local migration_sql="${migration_folder}/migration.sql"
        
        if [ -f "$migration_sql" ] && [ ! -e "$compat_file" ]; then
            ln -sf "../${folder_name}/migration.sql" "$compat_file"
        fi
    done
    
    log_info "Created/updated compatibility symlinks in $compat_dir"
}

# Get migration status
get_migration_status() {
    local migration_folder=$1
    local metadata_file="${migration_folder}/metadata.json"
    
    if [ -f "$metadata_file" ]; then
        grep -o '"status":"[^"]*"' "$metadata_file" | cut -d'"' -f4
    else
        echo "unknown"
    fi
}

# Update migration status
update_migration_status() {
    local migration_folder=$1
    local status=$2
    local metadata_file="${migration_folder}/metadata.json"
    
    if [ -f "$metadata_file" ]; then
        # Update status in JSON
        if command -v jq &> /dev/null; then
            jq ".status = \"$status\"" "$metadata_file" > "${metadata_file}.tmp" && mv "${metadata_file}.tmp" "$metadata_file"
        else
            # Fallback: sed replacement
            sed -i.bak "s/\"status\": \"[^\"]*\"/\"status\": \"$status\"/" "$metadata_file" && rm -f "${metadata_file}.bak"
        fi
        log_success "Updated status to: $status"
    else
        log_warning "Metadata file not found: $metadata_file"
    fi
}

