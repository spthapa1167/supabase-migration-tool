#!/bin/bash
# Check Diff Between Two Supabase Environments
# Compares database schemas, storage, functions, and other components

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_diff() { echo -e "${CYAN}[DIFF]${NC} $1"; }

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [--env-file <file>]

Compare database schemas and configuration between two Supabase environments.

Arguments:
  source_env    Source environment (prod, test, dev, backup)
  target_env    Target environment (prod, test, dev, backup)
  --env-file    Path to environment file (default: .env.local)

Examples:
  $0 dev test
  $0 dev test --env-file .env.local
  $0 prod test

EOF
    exit 1
}

# Parse arguments
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
ENV_FILE="${PROJECT_ROOT}/.env.local"

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    export SUPABASE_ACCESS_TOKEN
else
    log_error "Environment file not found: $ENV_FILE"
    exit 1
fi

# Validate environments
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Comparing Environments: $SOURCE_ENV → $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get project references
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
echo ""

# Create temporary directory for comparison
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

SOURCE_SCHEMA="$TEMP_DIR/source_schema.sql"
TARGET_SCHEMA="$TEMP_DIR/target_schema.sql"
SOURCE_NORMALIZED="$TEMP_DIR/source_normalized.sql"
TARGET_NORMALIZED="$TEMP_DIR/target_normalized.sql"

DIFFERENCES_FOUND=0

# 1. Compare Database Schema
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  1. Comparing Database Schemas"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "Exporting source schema..."
# Get pooler host using environment name (more reliable)
SOURCE_POOLER=$(get_pooler_host_for_env "$SOURCE_ENV" 2>/dev/null || get_pooler_host "$SOURCE_REF")
if [ -z "$SOURCE_POOLER" ]; then
    SOURCE_POOLER="aws-1-us-east-2.pooler.supabase.com"
fi
SOURCE_DUMP_OUTPUT=$(mktemp)
set +e
# Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$SOURCE_POOLER" \
    -p 6543 \
    -U "postgres.${SOURCE_REF}" \
    -d postgres \
    --schema-only \
    --no-owner \
    --no-acl \
    -f "$SOURCE_SCHEMA" \
    2>&1 | tee "$SOURCE_DUMP_OUTPUT" | grep -v "WARNING" || true
SOURCE_DUMP_EXIT=${PIPESTATUS[0]}
set -e

if [ $SOURCE_DUMP_EXIT -ne 0 ] || grep -q "FATAL\|could not translate\|connection" "$SOURCE_DUMP_OUTPUT" 2>/dev/null; then
    if check_direct_connection_available "$SOURCE_REF"; then
        log_warning "Pooler connection failed for source, trying direct connection..."
        rm -f "$SOURCE_SCHEMA" "$SOURCE_DUMP_OUTPUT"
        set +e
        PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
            -h "db.${SOURCE_REF}.supabase.co" \
            -p 5432 \
            -U "postgres.${SOURCE_REF}" \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-acl \
            -f "$SOURCE_SCHEMA" \
            2>&1 | grep -v "WARNING" || {
            log_error "Failed to export source schema (both pooler and direct connection failed)"
            rm -f "$SOURCE_DUMP_OUTPUT"
            exit 1
        }
        set -e
    else
        log_error "Failed to export source schema: pooler failed and direct connection unavailable"
        rm -f "$SOURCE_DUMP_OUTPUT"
        exit 1
    fi
fi
rm -f "$SOURCE_DUMP_OUTPUT"

log_info "Exporting target schema..."
# Get pooler host using environment name (more reliable)
TARGET_POOLER=$(get_pooler_host_for_env "$TARGET_ENV" 2>/dev/null || get_pooler_host "$TARGET_REF")
if [ -z "$TARGET_POOLER" ]; then
    TARGET_POOLER="aws-1-us-east-2.pooler.supabase.com"
fi
TARGET_DUMP_OUTPUT=$(mktemp)
set +e
# Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
PGPASSWORD="$TARGET_PASSWORD" pg_dump \
    -h "$TARGET_POOLER" \
    -p 6543 \
    -U "postgres.${TARGET_REF}" \
    -d postgres \
    --schema-only \
    --no-owner \
    --no-acl \
    -f "$TARGET_SCHEMA" \
    2>&1 | tee "$TARGET_DUMP_OUTPUT" | grep -v "WARNING" || true
TARGET_DUMP_EXIT=${PIPESTATUS[0]}
set -e

if [ $TARGET_DUMP_EXIT -ne 0 ] || grep -q "FATAL\|could not translate\|connection" "$TARGET_DUMP_OUTPUT" 2>/dev/null; then
    if check_direct_connection_available "$TARGET_REF"; then
        log_warning "Pooler connection failed for target, trying direct connection..."
        rm -f "$TARGET_SCHEMA" "$TARGET_DUMP_OUTPUT"
        set +e
        PGPASSWORD="$TARGET_PASSWORD" pg_dump \
            -h "db.${TARGET_REF}.supabase.co" \
            -p 5432 \
            -U "postgres.${TARGET_REF}" \
            -d postgres \
            --schema-only \
            --no-owner \
            --no-acl \
            -f "$TARGET_SCHEMA" \
            2>&1 | grep -v "WARNING" || {
            log_error "Failed to export target schema (both pooler and direct connection failed)"
            rm -f "$TARGET_DUMP_OUTPUT"
            exit 1
        }
        set -e
    else
        log_error "Failed to export target schema: pooler failed and direct connection unavailable"
        rm -f "$TARGET_DUMP_OUTPUT"
        exit 1
    fi
fi
rm -f "$TARGET_DUMP_OUTPUT"

# Normalize schemas for comparison
log_info "Normalizing schemas for comparison..."
grep -v '^--' "$SOURCE_SCHEMA" | grep -v '^$' | sed 's/[[:space:]]\+/ /g' | sort > "$SOURCE_NORMALIZED"
grep -v '^--' "$TARGET_SCHEMA" | grep -v '^$' | sed 's/[[:space:]]\+/ /g' | sort > "$TARGET_NORMALIZED"

# Compare schemas
if diff -q "$SOURCE_NORMALIZED" "$TARGET_NORMALIZED" >/dev/null 2>&1; then
    log_success "✅ Database schemas are identical"
else
    DIFFERENCES_FOUND=1
    log_warning "⚠️  Database schemas differ"
    echo ""
    
    # Show summary
    log_info "Calculating differences..."
    diff_output_file="$TEMP_DIR/diff_output.txt"
    diff "$SOURCE_NORMALIZED" "$TARGET_NORMALIZED" > "$diff_output_file" 2>&1 || true
    diff_count=$(grep -E "^[<>]" "$diff_output_file" | wc -l | tr -d ' ')
    log_info "Found $diff_count lines of differences"
    echo ""
    
    # Show detailed diff (limit output)
    if [ $diff_count -gt 0 ]; then
        log_diff "Detailed schema differences (first 50 lines):"
        head -50 "$diff_output_file" || true
        echo ""
        
        if [ $diff_count -gt 50 ]; then
            log_info "... (showing first 50 lines, total: $diff_count)"
            echo ""
        fi
    fi
fi

echo ""

# 2. Compare Tables
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  2. Comparing Tables"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SOURCE_TABLES="$TEMP_DIR/source_tables.txt"
TARGET_TABLES="$TEMP_DIR/target_tables.txt"

set +e
PGPASSWORD="$SOURCE_PASSWORD" psql \
    -h "$SOURCE_POOLER" \
    -p 6543 \
    -U "postgres.${SOURCE_REF}" \
    -d postgres \
    -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" \
    | tr -d ' ' | grep -v '^$' > "$SOURCE_TABLES" 2>/dev/null || {
    PGPASSWORD="$SOURCE_PASSWORD" psql \
        -h db.${SOURCE_REF}.supabase.co \
        -p 5432 \
        -U "postgres.${SOURCE_REF}" \
        -d postgres \
        -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" \
        | tr -d ' ' | grep -v '^$' > "$SOURCE_TABLES" 2>/dev/null || true
}

PGPASSWORD="$TARGET_PASSWORD" psql \
    -h "$TARGET_POOLER" \
    -p 6543 \
    -U "postgres.${TARGET_REF}" \
    -d postgres \
    -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" \
    | tr -d ' ' | grep -v '^$' > "$TARGET_TABLES" 2>/dev/null || {
    PGPASSWORD="$TARGET_PASSWORD" psql \
        -h db.${TARGET_REF}.supabase.co \
        -p 5432 \
        -U "postgres.${TARGET_REF}" \
        -d postgres \
        -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" \
        | tr -d ' ' | grep -v '^$' > "$TARGET_TABLES" 2>/dev/null || true
}
set -e

if diff -q "$SOURCE_TABLES" "$TARGET_TABLES" >/dev/null 2>&1; then
    log_success "✅ Table lists are identical ($(wc -l < "$SOURCE_TABLES" | tr -d ' ') tables)"
else
    DIFFERENCES_FOUND=1
    log_warning "⚠️  Table lists differ"
    echo ""
    
    # Tables only in source
    only_in_source=$(comm -23 "$SOURCE_TABLES" "$TARGET_TABLES")
    if [ -n "$only_in_source" ]; then
        log_diff "Tables only in $SOURCE_ENV:"
        echo "$only_in_source" | sed 's/^/  - /'
        echo ""
    fi
    
    # Tables only in target
    only_in_target=$(comm -13 "$SOURCE_TABLES" "$TARGET_TABLES")
    if [ -n "$only_in_target" ]; then
        log_diff "Tables only in $TARGET_ENV:"
        echo "$only_in_target" | sed 's/^/  - /'
        echo ""
    fi
fi

echo ""

# Summary
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Comparison Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $DIFFERENCES_FOUND -eq 0 ]; then
    log_success "✅ No differences found - environments are identical"
    echo ""
    exit 0
else
    log_warning "⚠️  Differences found between environments"
    echo ""
    exit 1
fi
