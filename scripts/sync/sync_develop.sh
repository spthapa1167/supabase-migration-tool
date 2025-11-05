#!/bin/bash
# Script to push schema to develop environment
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

# Ensure compatibility symlinks exist
if command -v create_supabase_compat_links &> /dev/null; then
    create_supabase_compat_links
fi

echo "🔗 Linking to Develop environment..."
supabase link --project-ref $SUPABASE_DEV_PROJECT_REF --password "$SUPABASE_DEV_DB_PASSWORD"

echo "📤 Pushing migrations to develop environment..."
supabase db push --password "$SUPABASE_DEV_DB_PASSWORD"

echo "✅ Develop environment synchronized successfully!"

