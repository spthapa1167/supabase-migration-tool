#!/bin/bash
# List All Migrations
# Shows all migrations with their status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/lib/migration_utils.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Migration List"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

MIGRATIONS_DIR=$(get_migrations_dir)

if [ ! -d "$MIGRATIONS_DIR" ] || [ -z "$(ls -A "$MIGRATIONS_DIR" 2>/dev/null)" ]; then
    echo "No migrations found in $MIGRATIONS_DIR"
    exit 0
fi

# Count migrations
MIGRATION_COUNT=$(list_migration_folders | wc -l | tr -d ' ')
echo "Total migrations: $MIGRATION_COUNT"
echo ""

# List migrations
printf "%-30s %-20s %-15s %s\n" "Migration" "Timestamp" "Status" "Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for migration_folder in $(list_migration_folders); do
    folder_name=$(basename "$migration_folder")
    timestamp=$(echo "$folder_name" | grep -o '^[0-9]\{8\}_[0-9]\{6\}' || echo "unknown")
    migration_name=$(echo "$folder_name" | sed "s/^[0-9]\{8\}_[0-9]\{6\}_//" || echo "$folder_name")
    
    # Get status
    status=$(get_migration_status "$migration_folder")
    
    # Count files
    file_count=$(find "$migration_folder" -type f | wc -l | tr -d ' ')
    
    # Color code status
    case "$status" in
        *applied*)
            status_color="${GREEN}"
            ;;
        *pending*)
            status_color="${YELLOW}"
            ;;
        *rolled_back*)
            status_color="${RED}"
            ;;
        *)
            status_color="${BLUE}"
            ;;
    esac
    
    printf "%-30s %-20s ${status_color}%-15s${NC} %s files\n" \
        "$migration_name" \
        "$timestamp" \
        "$status" \
        "$file_count"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To view details of a migration:"
echo "  ls -la supabase/migrations/<migration_folder>/"
echo ""
echo "To apply a migration:"
echo "  ./scripts/migration_apply.sh <migration_name> <environment>"
echo ""

exit 0

