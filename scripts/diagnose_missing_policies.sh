#!/bin/bash
# Diagnostic script to identify missing policies between source and target environments
# This script queries both databases directly and compares policy lists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [output_dir]

Identifies missing policies between source and target environments by querying
databases directly using pg_policies view.

Arguments:
  source_env   Source environment (prod, test, dev, backup)
  target_env   Target environment (prod, test, dev, backup)
  output_dir   Directory to save policy lists (optional, defaults to ./policy_diagnosis)

Examples:
  $0 prod test
  $0 dev test ./my_output

EOF
    exit 0
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ $# -lt 2 ]; then
    usage
fi

SOURCE_ENV=$1
TARGET_ENV=$2
OUTPUT_DIR="${3:-./policy_diagnosis}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Policy Diagnosis: $SOURCE_ENV → $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Load environment variables
log_info "Loading environment configuration..."
if [ ! -f ".env.local" ]; then
    log_error "Error: .env.local file not found"
    exit 1
fi

source .env.local

# Get source environment variables
SOURCE_REF_VAR="SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF"
SOURCE_PASSWORD_VAR="SUPABASE_$(echo "$SOURCE_ENV" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
SOURCE_REF="${!SOURCE_REF_VAR:-}"
SOURCE_PASSWORD="${!SOURCE_PASSWORD_VAR:-}"

if [ -z "$SOURCE_REF" ] || [ -z "$SOURCE_PASSWORD" ]; then
    log_error "Error: Could not load source environment variables for $SOURCE_ENV"
    log_error "  Missing: $SOURCE_REF_VAR or $SOURCE_PASSWORD_VAR"
    exit 1
fi

# Get target environment variables
TARGET_REF_VAR="SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_PROJECT_REF"
TARGET_PASSWORD_VAR="SUPABASE_$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
TARGET_REF="${!TARGET_REF_VAR:-}"
TARGET_PASSWORD="${!TARGET_PASSWORD_VAR:-}"

if [ -z "$TARGET_REF" ] || [ -z "$TARGET_PASSWORD" ]; then
    log_error "Error: Could not load target environment variables for $TARGET_ENV"
    log_error "  Missing: $TARGET_REF_VAR or $TARGET_PASSWORD_VAR"
    exit 1
fi

log_info "Source: $SOURCE_ENV (ref: ${SOURCE_REF:0:8}...)"
log_info "Target: $TARGET_ENV (ref: ${TARGET_REF:0:8}...)"
echo ""

# Query to get all policies (excluding storage, system schemas)
POLICIES_QUERY="SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname NOT IN ('storage', 'pg_catalog', 'information_schema') ORDER BY schemaname, tablename, policyname;"

# Query source policies
log_info "Querying source database policies..."
source_policies_file="$OUTPUT_DIR/source_policies.txt"
endpoints=$(get_supabase_connection_endpoints "$SOURCE_REF" "" "")
source_success=false

while IFS='|' read -r host port user label; do
    [ -z "$host" ] && continue
    if PGPASSWORD="$SOURCE_PASSWORD" PGSSLMODE=require psql \
        -h "$host" \
        -p "$port" \
        -U "$user" \
        -d postgres \
        -t -A \
        -c "$POLICIES_QUERY" > "$source_policies_file" 2>/dev/null; then
        source_success=true
        log_success "  Source policies queried via $label"
        break
    fi
done <<< "$endpoints"

if [ "$source_success" = "false" ]; then
    log_error "Failed to query source policies from database"
    exit 1
fi

# Query target policies
log_info "Querying target database policies..."
target_policies_file="$OUTPUT_DIR/target_policies.txt"
endpoints=$(get_supabase_connection_endpoints "$TARGET_REF" "" "")
target_success=false

while IFS='|' read -r host port user label; do
    [ -z "$host" ] && continue
    if PGPASSWORD="$TARGET_PASSWORD" PGSSLMODE=require psql \
        -h "$host" \
        -p "$port" \
        -U "$user" \
        -d postgres \
        -t -A \
        -c "$POLICIES_QUERY" > "$target_policies_file" 2>/dev/null; then
        target_success=true
        log_success "  Target policies queried via $label"
        break
    fi
done <<< "$endpoints"

if [ "$target_success" = "false" ]; then
    log_error "Failed to query target policies from database"
    exit 1
fi

# Count policies
source_count=$(wc -l < "$source_policies_file" | tr -d '[:space:]' || echo "0")
target_count=$(wc -l < "$target_policies_file" | tr -d '[:space:]' || echo "0")

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Policy Count Comparison"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Source policies: $source_count"
log_info "  Target policies: $target_count"

if [ "$source_count" -gt "$target_count" ]; then
    missing_count=$((source_count - target_count))
    log_error "  ❌ Missing: $missing_count policy(ies)"
elif [ "$target_count" -gt "$source_count" ]; then
    extra_count=$((target_count - source_count))
    log_warning "  ⚠️  Extra: $extra_count policy(ies) in target (not in source)"
else
    log_success "  ✓ Policy counts match!"
fi
echo ""

# Find missing policies
missing_policies_file="$OUTPUT_DIR/missing_policies.txt"
comm -23 <(sort "$source_policies_file") <(sort "$target_policies_file") > "$missing_policies_file" 2>/dev/null || true

if [ -s "$missing_policies_file" ]; then
    missing_list=$(cat "$missing_policies_file")
    missing_count_actual=$(wc -l < "$missing_policies_file" | tr -d '[:space:]' || echo "0")
    
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error "  Missing Policies ($missing_count_actual total)"
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$missing_list" | while IFS= read -r policy_id; do
        [ -n "$policy_id" ] && log_error "  - $policy_id"
    done
    echo ""
    log_info "Full list saved to: $missing_policies_file"
fi

# Find extra policies (in target but not in source)
extra_policies_file="$OUTPUT_DIR/extra_policies.txt"
comm -13 <(sort "$source_policies_file") <(sort "$target_policies_file") > "$extra_policies_file" 2>/dev/null || true

if [ -s "$extra_policies_file" ]; then
    extra_list=$(cat "$extra_policies_file")
    extra_count_actual=$(wc -l < "$extra_policies_file" | tr -d '[:space:]' || echo "0")
    
    log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warning "  Extra Policies in Target ($extra_count_actual total)"
    log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$extra_list" | while IFS= read -r policy_id; do
        [ -n "$policy_id" ] && log_warning "  - $policy_id"
    done
    echo ""
    log_info "Full list saved to: $extra_policies_file"
fi

# Summary
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Output directory: $OUTPUT_DIR"
log_info "  Files created:"
log_info "    - source_policies.txt (all source policies)"
log_info "    - target_policies.txt (all target policies)"
[ -s "$missing_policies_file" ] && log_info "    - missing_policies.txt ($missing_count_actual missing policies)"
[ -s "$extra_policies_file" ] && log_info "    - extra_policies.txt ($extra_count_actual extra policies)"
echo ""

if [ "$source_count" -gt "$target_count" ]; then
    log_error "❌ Migration incomplete: $missing_count policy(ies) missing"
    exit 1
elif [ "$target_count" -ge "$source_count" ]; then
    log_success "✓ All policies migrated successfully"
    exit 0
else
    exit 0
fi

