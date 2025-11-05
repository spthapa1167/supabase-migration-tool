#!/bin/bash
# Script to pull schema from production environment
# Works with organized migration folder structure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
cd "$PROJECT_ROOT"

# Load environment variables
if [ -f .env.local ]; then
    source .env.local
else
    echo "Error: .env.local file not found. Please create it first."
    exit 1
fi

export SUPABASE_ACCESS_TOKEN=$SUPABASE_ACCESS_TOKEN

# Source migration utilities
source "$PROJECT_ROOT/lib/migration_utils.sh" 2>/dev/null || true

echo "🔗 Linking to Production environment..."
supabase link --project-ref $SUPABASE_PROD_PROJECT_REF --password "$SUPABASE_PROD_DB_PASSWORD"

echo "📥 Pulling schema from production..."
supabase db pull --password "$SUPABASE_PROD_DB_PASSWORD"

echo "✅ Production schema pulled successfully!"

# Convert any new flat migration files to organized structure
if command -v convert_old_migration &> /dev/null; then
    echo "🔄 Organizing new migrations..."
    MIGRATIONS_DIR=$(get_migrations_dir)
    
    # Find flat SQL files that aren't in folders
    for migration_file in "$MIGRATIONS_DIR"/*.sql; do
        if [ -f "$migration_file" ]; then
            # Check if it's a flat file (not in a subdirectory)
            if [[ "$migration_file" != *"/"*"_"*"/"* ]]; then
                log_info "Converting: $(basename "$migration_file")"
                convert_old_migration "$migration_file" > /dev/null
                rm "$migration_file"
            fi
        fi
    done
    
    # Recreate compatibility symlinks
    create_supabase_compat_links
fi

echo "📝 Migration files organized in supabase/migrations/"

