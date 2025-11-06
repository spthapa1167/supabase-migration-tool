#!/bin/bash
# Migration Plan Generator
# Generates a comprehensive HTML report comparing source and target environments
# Shows current status, differences, and migration recommendations

set -eo pipefail
# Note: Temporarily disabling 'u' flag for heredoc variable expansion
# Variables are initialized before use, but heredoc expansion can cause false positives

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/supabase_utils.sh"
source "$PROJECT_ROOT/lib/logger.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage
usage() {
    cat << EOF
Usage: $0 <source_env> <target_env> [output_dir]

Generates a comprehensive HTML migration plan comparing source and target environments.

Arguments:
  source_env   Source environment (prod, test, dev)
  target_env   Target environment (prod, test, dev)
  output_dir   Directory to save the HTML report (optional, defaults to ./migration_plans)

Examples:
  $0 dev test
  $0 prod test ./custom_output

The script will generate:
  - migration_plan_[source]_to_[target]_[timestamp].html

EOF
    exit 1
}

# Check arguments
SOURCE_ENV=${1:-}
TARGET_ENV=${2:-}
OUTPUT_DIR=${3:-"./migration_plans"}

if [ -z "$SOURCE_ENV" ] || [ -z "$TARGET_ENV" ]; then
    usage
fi

# Load environment
load_env
validate_environments "$SOURCE_ENV" "$TARGET_ENV"

# Get project references and passwords
SOURCE_REF=$(get_project_ref "$SOURCE_ENV")
TARGET_REF=$(get_project_ref "$TARGET_ENV")
SOURCE_PASSWORD=$(get_db_password "$SOURCE_ENV")
TARGET_PASSWORD=$(get_db_password "$TARGET_ENV")

# Create output directory
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HTML_FILE="$OUTPUT_DIR/migration_plan_${SOURCE_ENV}_to_${TARGET_ENV}_${TIMESTAMP}.html"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Migration Plan Generator"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Source: $SOURCE_ENV ($SOURCE_REF)"
log_info "Target: $TARGET_ENV ($TARGET_REF)"
log_info "Output: $HTML_FILE"
log_info ""

# Function to get database schema information
get_db_schema_info() {
    local env=$1
    local ref=$2
    local password=$3
    local output_file=$4
    
    log_info "Collecting database schema information from $env..."
    
    POOLER_HOST=$(get_pooler_host "$ref")
    
    # Get tables
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, tablename;" \
        > "$output_file.tables" 2>/dev/null || echo "" > "$output_file.tables"
    
    # Get views
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT schemaname||'.'||viewname FROM pg_views WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, viewname;" \
        > "$output_file.views" 2>/dev/null || echo "" > "$output_file.views"
    
    # Get database functions (stored in .db_functions to avoid conflict with edge functions)
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT n.nspname||'.'||p.proname||'('||pg_get_function_arguments(p.oid)||')' FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname IN ('public', 'storage', 'auth') ORDER BY n.nspname, p.proname;" \
        > "$output_file.db_functions" 2>/dev/null || echo "" > "$output_file.db_functions"
    
    # Get triggers
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT tgname FROM pg_trigger WHERE tgisinternal = false ORDER BY tgname;" \
        > "$output_file.triggers" 2>/dev/null || echo "" > "$output_file.triggers"
    
    # Get sequences
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT schemaname||'.'||sequencename FROM pg_sequences WHERE schemaname IN ('public', 'storage', 'auth') ORDER BY schemaname, sequencename;" \
        > "$output_file.sequences" 2>/dev/null || echo "" > "$output_file.sequences"
    
    # Get table row counts (using approximate statistics - faster than exact COUNT)
    # Note: n_live_tup is approximate but much faster than COUNT(*) for large tables
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT 
            schemaname||'.'||relname as table_name,
            COALESCE(n_live_tup::text, '0') as row_count
        FROM pg_stat_user_tables 
        WHERE schemaname IN ('public', 'storage', 'auth')
        ORDER BY schemaname, relname;
        " \
        > "$output_file.row_counts" 2>/dev/null || echo "" > "$output_file.row_counts"
    
    # Get RLS policies
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "SELECT schemaname||'.'||tablename||'.'||policyname FROM pg_policies WHERE schemaname IN ('public', 'storage') ORDER BY schemaname, tablename, policyname;" \
        > "$output_file.policies" 2>/dev/null || echo "" > "$output_file.policies"
    
    log_success "Database schema information collected from $env"
}

# Function to get storage buckets information
get_storage_buckets_info() {
    local env=$1
    local ref=$2
    local password=$3
    local output_file=$4
    
    log_info "Collecting storage buckets information from $env..."
    
    POOLER_HOST=$(get_pooler_host "$ref")
    
    # Get buckets with file counts
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT 
            b.name,
            b.public::text,
            COALESCE(b.file_size_limit::text, 'NULL'),
            COALESCE(array_to_string(b.allowed_mime_types, ','), 'NULL'),
            COALESCE((
                SELECT COUNT(*)::text 
                FROM storage.objects 
                WHERE bucket_id = b.id
            ), '0') as file_count
        FROM storage.buckets b
        ORDER BY b.name;
        " \
        > "$output_file.buckets" 2>/dev/null || echo "" > "$output_file.buckets"
    
    log_success "Storage buckets information collected from $env"
}

# Function to get edge functions information
get_edge_functions_info() {
    local env=$1
    local ref=$2
    local output_file=$3
    
    log_info "Collecting edge functions information from $env..."
    
    if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set - skipping edge functions"
        echo "" > "$output_file.functions"
        return
    fi
    
    # Get edge functions using Management API
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${ref}/functions" \
        -o "$output_file.functions_raw" 2>/dev/null; then
        
        # Extract function names
        if command -v jq >/dev/null 2>&1; then
            jq -r '.[].name' "$output_file.functions_raw" 2>/dev/null | sort > "$output_file.functions" || echo "" > "$output_file.functions"
        else
            log_warning "jq not found - cannot parse edge functions"
            echo "" > "$output_file.functions"
        fi
    else
        log_warning "Failed to fetch edge functions from $env"
        echo "" > "$output_file.functions"
    fi
    
    log_success "Edge functions information collected from $env"
}

# Function to get secrets information
get_secrets_info() {
    local env=$1
    local ref=$2
    local output_file=$3
    
    log_info "Collecting secrets information from $env..."
    
    if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set - skipping secrets"
        echo "" > "$output_file.secrets"
        return
    fi
    
    # Get secrets using Management API
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${ref}/secrets" \
        -o "$output_file.secrets_raw" 2>/dev/null; then
        
        # Extract secret names
        if command -v jq >/dev/null 2>&1; then
            jq -r '.[].name' "$output_file.secrets_raw" 2>/dev/null | sort > "$output_file.secrets" || echo "" > "$output_file.secrets"
        else
            log_warning "jq not found - cannot parse secrets"
            echo "" > "$output_file.secrets"
        fi
    else
        log_warning "Failed to fetch secrets from $env"
        echo "" > "$output_file.secrets"
    fi
    
    log_success "Secrets information collected from $env"
}

# Collect source information
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Source Environment Information"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

SOURCE_INFO="$TEMP_DIR/source"
get_db_schema_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_INFO"
get_storage_buckets_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_PASSWORD" "$SOURCE_INFO"
get_edge_functions_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_INFO"
get_secrets_info "$SOURCE_ENV" "$SOURCE_REF" "$SOURCE_INFO"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Collecting Target Environment Information"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

TARGET_INFO="$TEMP_DIR/target"
get_db_schema_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_INFO"
get_storage_buckets_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_PASSWORD" "$TARGET_INFO"
get_edge_functions_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_INFO"
get_secrets_info "$TARGET_ENV" "$TARGET_REF" "$TARGET_INFO"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Generating HTML Report"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

# Helper function to count lines in file (excluding empty lines)
count_items() {
    local file=$1
    if [ -f "$file" ]; then
        grep -v '^[[:space:]]*$' "$file" | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# Helper function to get file contents as array
get_file_contents() {
    local file=$1
    if [ -f "$file" ] && [ -s "$file" ]; then
        cat "$file"
    else
        echo ""
    fi
}

# Generate HTML report
cat > "$HTML_FILE" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Migration Plan: SOURCE_ENV to TARGET_ENV</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #f5f5f5;
            color: #333;
            line-height: 1.6;
            padding: 20px;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        header h1 {
            font-size: 2em;
            margin-bottom: 10px;
        }
        header .meta {
            opacity: 0.9;
            font-size: 0.9em;
        }
        .content {
            padding: 30px;
        }
        .section {
            margin-bottom: 40px;
        }
        .section h2 {
            color: #667eea;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        .section h3 {
            color: #764ba2;
            margin-top: 20px;
            margin-bottom: 15px;
        }
        .comparison-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 30px;
        }
        .comparison-card {
            border: 1px solid #ddd;
            border-radius: 6px;
            padding: 20px;
            background: #fafafa;
        }
        .comparison-card h4 {
            color: #667eea;
            margin-bottom: 15px;
            font-size: 1.1em;
        }
        .stat {
            display: flex;
            justify-content: space-between;
            padding: 8px 0;
            border-bottom: 1px solid #eee;
        }
        .stat:last-child {
            border-bottom: none;
        }
        .stat-label {
            font-weight: 500;
        }
        .stat-value {
            font-weight: bold;
            color: #667eea;
        }
        .diff-section {
            margin-top: 30px;
        }
        .diff-item {
            padding: 15px;
            margin: 10px 0;
            border-radius: 6px;
            border-left: 4px solid;
        }
        .diff-item.added {
            background: #e8f5e9;
            border-color: #4caf50;
        }
        .diff-item.removed {
            background: #ffebee;
            border-color: #f44336;
        }
        .diff-item.modified {
            background: #fff3e0;
            border-color: #ff9800;
        }
        .diff-item-header {
            font-weight: bold;
            margin-bottom: 8px;
        }
        .diff-item-content {
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            background: white;
            padding: 10px;
            border-radius: 4px;
            margin-top: 5px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background: #f5f5f5;
            font-weight: 600;
            color: #667eea;
        }
        tr:hover {
            background: #f9f9f9;
        }
        .badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 500;
        }
        .badge-success {
            background: #4caf50;
            color: white;
        }
        .badge-warning {
            background: #ff9800;
            color: white;
        }
        .badge-danger {
            background: #f44336;
            color: white;
        }
        .badge-info {
            background: #2196f3;
            color: white;
        }
        .summary-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .summary-stat {
            text-align: center;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border-radius: 8px;
        }
        .summary-stat-value {
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .summary-stat-label {
            font-size: 0.9em;
            opacity: 0.9;
        }
        .timestamp {
            text-align: center;
            color: #666;
            font-size: 0.9em;
            margin-top: 20px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
        }
        .details {
            background: #f9f9f9;
            border-left: 4px solid #667eea;
            padding: 20px;
            border-radius: 4px;
            margin-top: 20px;
        }
        .details-item {
            padding: 10px 0;
            border-bottom: 1px solid #eee;
        }
        .details-item:last-child {
            border-bottom: none;
        }
        .details-item-content {
            color: #666;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            background: white;
            padding: 10px;
            border-radius: 4px;
            margin-top: 5px;
        }
        .details-item-content ul {
            margin: 10px 0;
            padding-left: 20px;
        }
        .details-item-content li {
            margin: 5px 0;
            padding: 5px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🔄 Migration Plan Report</h1>
            <div class="meta">
                <strong>SOURCE_ENV</strong> → <strong>TARGET_ENV</strong><br>
                Generated: TIMESTAMP
            </div>
        </header>
        <div class="content">
HTML_EOF

# Replace placeholders in HTML
sed -i.bak "s/SOURCE_ENV/$SOURCE_ENV/g; s/TARGET_ENV/$TARGET_ENV/g; s/TIMESTAMP/$(date)/g" "$HTML_FILE"
rm -f "$HTML_FILE.bak"

# Add summary statistics
cat >> "$HTML_FILE" << HTML_INNER_EOF
            <div class="section">
                <h2>📊 Executive Summary</h2>
                <div class="summary-stats">
                    <div class="summary-stat">
                        <div class="summary-stat-value">$(count_items "$SOURCE_INFO.tables")</div>
                        <div class="summary-stat-label">Source Tables</div>
                    </div>
                    <div class="summary-stat">
                        <div class="summary-stat-value">$(count_items "$TARGET_INFO.tables")</div>
                        <div class="summary-stat-label">Target Tables</div>
                    </div>
                    <div class="summary-stat">
                        <div class="summary-stat-value">$(count_items "$SOURCE_INFO.buckets")</div>
                        <div class="summary-stat-label">Source Buckets</div>
                    </div>
                    <div class="summary-stat">
                        <div class="summary-stat-value">$(count_items "$TARGET_INFO.buckets")</div>
                        <div class="summary-stat-label">Target Buckets                        </div>
                    </div>
                </div>
            </div>

HTML_INNER_EOF

# Compare tables for differences section
SOURCE_TABLES=$(get_file_contents "$SOURCE_INFO.tables")
TARGET_TABLES=$(get_file_contents "$TARGET_INFO.tables")

ADDED_TABLES=""
REMOVED_TABLES=""
COMMON_TABLES=""

while IFS= read -r table; do
    [ -z "$table" ] && continue
    if echo "$TARGET_TABLES" | grep -q "^${table}$"; then
        COMMON_TABLES="${COMMON_TABLES}${table}\n"
    else
        ADDED_TABLES="${ADDED_TABLES}${table}\n"
    fi
done <<< "$SOURCE_TABLES"

while IFS= read -r table; do
    [ -z "$table" ] && continue
    if ! echo "$SOURCE_TABLES" | grep -q "^${table}$"; then
        REMOVED_TABLES="${REMOVED_TABLES}${table}\n"
    fi
done <<< "$TARGET_TABLES"

cat >> "$HTML_FILE" << HTML_DB_SCHEMA_EOF
            <div class="section">
                <h2>🗄️ Database Schema Comparison</h2>
                <div class="comparison-grid">
                    <div class="comparison-card">
                        <h4>Source ($SOURCE_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Tables</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.tables")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Views</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.views")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Functions</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.db_functions")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Triggers</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.triggers")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Sequences</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.sequences")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">RLS Policies</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.policies")</span>
                        </div>
                    </div>
                    <div class="comparison-card">
                        <h4>Target ($TARGET_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Tables</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.tables")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Views</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.views")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Functions</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.db_functions")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Triggers</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.triggers")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">Sequences</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.sequences")</span>
                        </div>
                        <div class="stat">
                            <span class="stat-label">RLS Policies</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.policies")</span>
                        </div>
                </div>
            </div>
HTML_DB_SCHEMA_EOF

# Compare tables
SOURCE_TABLES=$(get_file_contents "$SOURCE_INFO.tables")
TARGET_TABLES=$(get_file_contents "$TARGET_INFO.tables")

ADDED_TABLES=""
REMOVED_TABLES=""
COMMON_TABLES=""

while IFS= read -r table; do
    [ -z "$table" ] && continue
    if echo "$TARGET_TABLES" | grep -q "^${table}$"; then
        COMMON_TABLES="${COMMON_TABLES}${table}\n"
    else
        ADDED_TABLES="${ADDED_TABLES}${table}\n"
    fi
done <<< "$SOURCE_TABLES"

while IFS= read -r table; do
    [ -z "$table" ] && continue
    if ! echo "$SOURCE_TABLES" | grep -q "^${table}$"; then
        REMOVED_TABLES="${REMOVED_TABLES}${table}\n"
    fi
done <<< "$TARGET_TABLES"

cat >> "$HTML_FILE" << HTML_DIFF_EOF
                <div class="diff-section">
                    <h3>Tables Differences</h3>
HTML_DIFF_EOF

if [ -n "$ADDED_TABLES" ]; then
    echo "<div class='diff-item added'><div class='diff-item-header'>➕ Tables to Add ($(echo -e "$ADDED_TABLES" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$ADDED_TABLES" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
fi

if [ -n "$REMOVED_TABLES" ]; then
    echo "<div class='diff-item removed'><div class='diff-item-header'>➖ Tables in Target Not in Source ($(echo -e "$REMOVED_TABLES" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$REMOVED_TABLES" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
fi

if [ -z "$ADDED_TABLES" ] && [ -z "$REMOVED_TABLES" ]; then
    echo "<div class='diff-item added'><div class='diff-item-header'>✅ All tables match</div></div>" >> "$HTML_FILE"
fi

# Add table row counts comparison
cat >> "$HTML_FILE" << HTML_ROWS_EOF
                    <h3>Table Row Counts</h3>
                    <table>
                        <thead>
                            <tr>
                                <th>Table</th>
                                <th>Source Rows</th>
                                <th>Target Rows</th>
                                <th>Difference</th>
                            </tr>
                        </thead>
                        <tbody>
HTML_ROWS_EOF

# Process row counts (using grep instead of associative arrays for bash 3.x compatibility)
# Get all unique table names
ALL_TABLES=$(printf "%s\n%s\n" "$SOURCE_TABLES" "$TARGET_TABLES" | sort -u)

while IFS= read -r table; do
    [ -z "$table" ] && continue
    
    # Initialize variables with default values (required for set -u)
    source_count="0"
    target_count="0"
    diff=0
    diff_class="badge-success"
    diff_text="0"
    grep_result=""
    
    # Get source count using grep with proper error handling
    if [ -f "$SOURCE_INFO.row_counts" ]; then
        grep_result=$(grep "^${table}|" "$SOURCE_INFO.row_counts" 2>/dev/null | cut -d'|' -f2 | head -1 || echo "")
        if [ -n "$grep_result" ]; then
            source_count=$(echo "$grep_result" | tr -d '[:space:]')
            [ -z "$source_count" ] && source_count="0"
        fi
    fi
    
    # Reset grep_result for target
    grep_result=""
    
    # Get target count using grep with proper error handling
    if [ -f "$TARGET_INFO.row_counts" ]; then
        grep_result=$(grep "^${table}|" "$TARGET_INFO.row_counts" 2>/dev/null | cut -d'|' -f2 | head -1 || echo "")
        if [ -n "$grep_result" ]; then
            target_count=$(echo "$grep_result" | tr -d '[:space:]')
            [ -z "$target_count" ] && target_count="0"
        fi
    fi
    
    # Ensure variables are set (defensive programming)
    source_count="${source_count:-0}"
    target_count="${target_count:-0}"
    
    # Try to calculate difference, default to 0 if arithmetic fails
    if expr "${source_count}" + 0 >/dev/null 2>&1 && expr "${target_count}" + 0 >/dev/null 2>&1; then
        diff=$((source_count - target_count)) 2>/dev/null || diff=0
    else
        diff=0
    fi
    
    if [ "$diff" -gt 0 ]; then
        diff_class="badge-warning"
        diff_text="+$diff"
    elif [ "$diff" -lt 0 ]; then
        diff_class="badge-danger"
        diff_text="$diff"
    else
        diff_class="badge-success"
        diff_text="0"
    fi
    
    echo "<tr><td>$table</td><td>$source_count</td><td>$target_count</td><td><span class='badge $diff_class'>$diff_text</span></td></tr>" >> "$HTML_FILE"
done <<< "$ALL_TABLES"

cat >> "$HTML_FILE" << HTML_ROWS_END
                        </tbody>
                    </table>
                </div>
            </div>

HTML_ROWS_END

# RLS Policies Comparison
SOURCE_POLICIES=$(get_file_contents "$SOURCE_INFO.policies")
TARGET_POLICIES=$(get_file_contents "$TARGET_INFO.policies")

ADDED_POLICIES=""
REMOVED_POLICIES=""
COMMON_POLICIES=""

# Find added policies (in source but not in target)
while IFS= read -r policy; do
    [ -z "$policy" ] && continue
    if ! echo "$TARGET_POLICIES" | grep -q "^${policy}$"; then
        ADDED_POLICIES="${ADDED_POLICIES}${policy}\n"
    else
        COMMON_POLICIES="${COMMON_POLICIES}${policy}\n"
    fi
done <<< "$SOURCE_POLICIES"

# Find removed policies (in target but not in source)
while IFS= read -r policy; do
    [ -z "$policy" ] && continue
    if ! echo "$SOURCE_POLICIES" | grep -q "^${policy}$"; then
        REMOVED_POLICIES="${REMOVED_POLICIES}${policy}\n"
    fi
done <<< "$TARGET_POLICIES"

cat >> "$HTML_FILE" << HTML_POLICIES_EOF
            <div class="section">
                <h2>🔒 RLS Policies Comparison</h2>
                <div class="comparison-grid">
                    <div class="comparison-card">
                        <h4>Source ($SOURCE_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Total Policies</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.policies")</span>
                        </div>
                    </div>
                    <div class="comparison-card">
                        <h4>Target ($TARGET_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Total Policies</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.policies")</span>
                        </div>
                    </div>
                </div>
                <div class="diff-section">
                    <h3>RLS Policies Differences</h3>
HTML_POLICIES_EOF

if [ -n "$ADDED_POLICIES" ]; then
    echo "<div class='diff-item added'><div class='diff-item-header'>➕ Policies to Add ($(echo -e "$ADDED_POLICIES" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'><ul>$(echo -e "$ADDED_POLICIES" | grep -v '^$' | sed 's/^/<li>/; s/$/<\/li>/')</ul></div></div>" >> "$HTML_FILE"
fi

if [ -n "$REMOVED_POLICIES" ]; then
    echo "<div class='diff-item removed'><div class='diff-item-header'>➖ Policies in Target Not in Source ($(echo -e "$REMOVED_POLICIES" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'><ul>$(echo -e "$REMOVED_POLICIES" | grep -v '^$' | sed 's/^/<li>/; s/$/<\/li>/')</ul></div></div>" >> "$HTML_FILE"
fi

if [ -z "$ADDED_POLICIES" ] && [ -z "$REMOVED_POLICIES" ]; then
    echo "<div class='diff-item added'><div class='diff-item-header'>✅ All RLS policies match</div></div>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_POLICIES_LIST_EOF
                    <h3>Source RLS Policies List</h3>
                    <div class="details">
                        <div class="details-item">
                            <div class="details-item-content">
HTML_POLICIES_LIST_EOF

if [ -n "$SOURCE_POLICIES" ]; then
    echo "<ul>" >> "$HTML_FILE"
    while IFS= read -r policy; do
        [ -z "$policy" ] && continue
        echo "<li>$policy</li>" >> "$HTML_FILE"
    done <<< "$SOURCE_POLICIES"
    echo "</ul>" >> "$HTML_FILE"
else
    echo "<p>No RLS policies found in source</p>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_POLICIES_LIST_END
                            </div>
                        </div>
                    </div>
                    
                    <h3>Target RLS Policies List</h3>
                    <div class="details">
                        <div class="details-item">
                            <div class="details-item-content">
HTML_POLICIES_LIST_END

if [ -n "$TARGET_POLICIES" ]; then
    echo "<ul>" >> "$HTML_FILE"
    while IFS= read -r policy; do
        [ -z "$policy" ] && continue
        echo "<li>$policy</li>" >> "$HTML_FILE"
    done <<< "$TARGET_POLICIES"
    echo "</ul>" >> "$HTML_FILE"
else
    echo "<p>No RLS policies found in target</p>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_POLICIES_END
                            </div>
                        </div>
                    </div>
                </div>
            </div>

HTML_POLICIES_END

# Storage Buckets Comparison
cat >> "$HTML_FILE" << HTML_STORAGE_EOF
            <div class="section">
                <h2>📦 Storage Buckets Comparison</h2>
                <div class="comparison-grid">
                    <div class="comparison-card">
                        <h4>Source ($SOURCE_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Total Buckets</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.buckets")</span>
                        </div>
                    </div>
                    <div class="comparison-card">
                        <h4>Target ($TARGET_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Total Buckets</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.buckets")</span>
                        </div>
                    </div>
                </div>
                <h3>Bucket Details</h3>
                <table>
                    <thead>
                        <tr>
                            <th>Bucket Name</th>
                            <th>Source Files</th>
                            <th>Target Files</th>
                            <th>Public</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
HTML_STORAGE_EOF

# Process buckets (using grep instead of associative arrays for bash 3.x compatibility)
# Get all unique bucket names
ALL_BUCKETS=$(printf "%s\n%s\n" "$(get_file_contents "$SOURCE_INFO.buckets" | cut -d'|' -f1)" "$(get_file_contents "$TARGET_INFO.buckets" | cut -d'|' -f1)" | sort -u)

while IFS= read -r bucket_name; do
    [ -z "$bucket_name" ] && continue
    
    # Check if bucket exists in source
    source_bucket_line=$(grep "^${bucket_name}|" "$SOURCE_INFO.buckets" 2>/dev/null | head -1 || echo "")
    source_exists=false
    if [ -n "$source_bucket_line" ]; then
        source_exists=true
        source_files=$(echo "$source_bucket_line" | cut -d'|' -f5)
        source_public=$(echo "$source_bucket_line" | cut -d'|' -f2)
    else
        source_files="0"
        source_public=""
    fi
    
    # Check if bucket exists in target
    target_bucket_line=$(grep "^${bucket_name}|" "$TARGET_INFO.buckets" 2>/dev/null | head -1 || echo "")
    target_exists=false
    if [ -n "$target_bucket_line" ]; then
        target_exists=true
        target_files=$(echo "$target_bucket_line" | cut -d'|' -f5)
    else
        target_files="0"
    fi
    
    # Determine status
    if [ "$source_exists" = "true" ] && [ "$target_exists" = "true" ]; then
        status="<span class='badge badge-success'>Exists</span>"
        if [ "$source_files" != "$target_files" ]; then
            status="<span class='badge badge-warning'>File Count Diff</span>"
        fi
    elif [ "$source_exists" = "true" ]; then
        status="<span class='badge badge-info'>Needs Migration</span>"
    else
        status="<span class='badge badge-danger'>Not in Source</span>"
    fi
    
    # Determine public status
    public_status=""
    if [ "$source_exists" = "true" ]; then
        if [ "$source_public" = "true" ]; then
            public_status="<span class='badge badge-success'>Public</span>"
        else
            public_status="<span class='badge'>Private</span>"
        fi
    fi
    
    echo "<tr><td>$bucket_name</td><td>$source_files</td><td>$target_files</td><td>$public_status</td><td>$status</td></tr>" >> "$HTML_FILE"
done <<< "$ALL_BUCKETS"

cat >> "$HTML_FILE" << HTML_STORAGE_END
                    </tbody>
                </table>
                
                <h3>Source Buckets List</h3>
                <table>
                    <thead>
                        <tr>
                            <th>Bucket Name</th>
                            <th>Public</th>
                            <th>File Count</th>
                            <th>File Size Limit</th>
                            <th>Allowed MIME Types</th>
                        </tr>
                    </thead>
                    <tbody>
HTML_STORAGE_END

# List all source buckets
if [ -f "$SOURCE_INFO.buckets" ] && [ -s "$SOURCE_INFO.buckets" ]; then
    while IFS='|' read -r name public size_limit mime_types file_count; do
        [ -z "$name" ] && continue
        
        if [ "$public" = "true" ]; then
            public_badge="<span class='badge badge-success'>Public</span>"
        else
            public_badge="<span class='badge'>Private</span>"
        fi
        
        size_limit_display="$size_limit"
        [ "$size_limit" = "NULL" ] && size_limit_display="No limit"
        
        mime_display="$mime_types"
        [ "$mime_types" = "NULL" ] && mime_display="All types"
        
        echo "<tr><td>$name</td><td>$public_badge</td><td>$file_count</td><td>$size_limit_display</td><td>$mime_display</td></tr>" >> "$HTML_FILE"
    done < "$SOURCE_INFO.buckets"
else
    echo "<tr><td colspan='5'>No buckets found in source</td></tr>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_STORAGE_END2
                    </tbody>
                </table>
                
                <h3>Target Buckets List</h3>
                <table>
                    <thead>
                        <tr>
                            <th>Bucket Name</th>
                            <th>Public</th>
                            <th>File Count</th>
                            <th>File Size Limit</th>
                            <th>Allowed MIME Types</th>
                        </tr>
                    </thead>
                    <tbody>
HTML_STORAGE_END2

# List all target buckets
if [ -f "$TARGET_INFO.buckets" ] && [ -s "$TARGET_INFO.buckets" ]; then
    while IFS='|' read -r name public size_limit mime_types file_count; do
        [ -z "$name" ] && continue
        
        if [ "$public" = "true" ]; then
            public_badge="<span class='badge badge-success'>Public</span>"
        else
            public_badge="<span class='badge'>Private</span>"
        fi
        
        size_limit_display="$size_limit"
        [ "$size_limit" = "NULL" ] && size_limit_display="No limit"
        
        mime_display="$mime_types"
        [ "$mime_types" = "NULL" ] && mime_display="All types"
        
        echo "<tr><td>$name</td><td>$public_badge</td><td>$file_count</td><td>$size_limit_display</td><td>$mime_display</td></tr>" >> "$HTML_FILE"
    done < "$TARGET_INFO.buckets"
else
    echo "<tr><td colspan='5'>No buckets found in target</td></tr>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_STORAGE_END3
                    </tbody>
                </table>
            </div>

HTML_STORAGE_END3

# Edge Functions Comparison (edge functions are in .functions file)
SOURCE_EDGE_FUNCTIONS=$(get_file_contents "$SOURCE_INFO.functions")
TARGET_EDGE_FUNCTIONS=$(get_file_contents "$TARGET_INFO.functions")

if [ -n "$SOURCE_EDGE_FUNCTIONS" ] || [ -n "$TARGET_EDGE_FUNCTIONS" ]; then
    cat >> "$HTML_FILE" << HTML_FUNCTIONS_EOF
            <div class="section">
                <h2>⚡ Edge Functions Comparison</h2>
                <div class="comparison-grid">
                    <div class="comparison-card">
                        <h4>Source ($SOURCE_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Functions</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.functions")</span>
                        </div>
                    </div>
                    <div class="comparison-card">
                        <h4>Target ($TARGET_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Functions</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.functions")</span>
                        </div>
                    </div>
                </div>
HTML_FUNCTIONS_EOF

    ADDED_FUNCTIONS=""
    REMOVED_FUNCTIONS=""
    
    while IFS= read -r func; do
        [ -z "$func" ] && continue
        if ! echo "$TARGET_EDGE_FUNCTIONS" | grep -q "^${func}$"; then
            ADDED_FUNCTIONS="${ADDED_FUNCTIONS}${func}\n"
        fi
    done <<< "$SOURCE_EDGE_FUNCTIONS"
    
    while IFS= read -r func; do
        [ -z "$func" ] && continue
        if ! echo "$SOURCE_EDGE_FUNCTIONS" | grep -q "^${func}$"; then
            REMOVED_FUNCTIONS="${REMOVED_FUNCTIONS}${func}\n"
        fi
    done <<< "$TARGET_EDGE_FUNCTIONS"
    
    if [ -n "$ADDED_FUNCTIONS" ]; then
        echo "<div class='diff-item added'><div class='diff-item-header'>➕ Functions to Deploy ($(echo -e "$ADDED_FUNCTIONS" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$ADDED_FUNCTIONS" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
    fi
    
    if [ -n "$REMOVED_FUNCTIONS" ]; then
        echo "<div class='diff-item removed'><div class='diff-item-header'>➖ Functions in Target Not in Source ($(echo -e "$REMOVED_FUNCTIONS" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$REMOVED_FUNCTIONS" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
    fi
    
    if [ -z "$ADDED_FUNCTIONS" ] && [ -z "$REMOVED_FUNCTIONS" ]; then
        echo "<div class='diff-item added'><div class='diff-item-header'>✅ All functions match</div></div>" >> "$HTML_FILE"
    fi
    
    cat >> "$HTML_FILE" << HTML_FUNCTIONS_END
            </div>

HTML_FUNCTIONS_END
fi

# Secrets Comparison
SOURCE_SECRETS=$(get_file_contents "$SOURCE_INFO.secrets")
TARGET_SECRETS=$(get_file_contents "$TARGET_INFO.secrets")

if [ -n "$SOURCE_SECRETS" ] || [ -n "$TARGET_SECRETS" ]; then
    cat >> "$HTML_FILE" << HTML_SECRETS_EOF
            <div class="section">
                <h2>🔐 Secrets Comparison</h2>
                <div class="comparison-grid">
                    <div class="comparison-card">
                        <h4>Source ($SOURCE_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Secrets</span>
                            <span class="stat-value">$(count_items "$SOURCE_INFO.secrets")</span>
                        </div>
                    </div>
                    <div class="comparison-card">
                        <h4>Target ($TARGET_ENV)</h4>
                        <div class="stat">
                            <span class="stat-label">Secrets</span>
                            <span class="stat-value">$(count_items "$TARGET_INFO.secrets")</span>
                        </div>
                    </div>
                </div>
HTML_SECRETS_EOF

    ADDED_SECRETS=""
    REMOVED_SECRETS=""
    
    while IFS= read -r secret; do
        [ -z "$secret" ] && continue
        if ! echo "$TARGET_SECRETS" | grep -q "^${secret}$"; then
            ADDED_SECRETS="${ADDED_SECRETS}${secret}\n"
        fi
    done <<< "$SOURCE_SECRETS"
    
    while IFS= read -r secret; do
        [ -z "$secret" ] && continue
        if ! echo "$SOURCE_SECRETS" | grep -q "^${secret}$"; then
            REMOVED_SECRETS="${REMOVED_SECRETS}${secret}\n"
        fi
    done <<< "$TARGET_SECRETS"
    
    if [ -n "$ADDED_SECRETS" ]; then
        echo "<div class='diff-item added'><div class='diff-item-header'>➕ Secrets to Add ($(echo -e "$ADDED_SECRETS" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$ADDED_SECRETS" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
    fi
    
    if [ -n "$REMOVED_SECRETS" ]; then
        echo "<div class='diff-item removed'><div class='diff-item-header'>➖ Secrets in Target Not in Source ($(echo -e "$REMOVED_SECRETS" | grep -v '^$' | wc -l | tr -d ' '))</div><div class='diff-item-content'>$(echo -e "$REMOVED_SECRETS" | grep -v '^$' | sed 's/^/  /')</div></div>" >> "$HTML_FILE"
    fi
    
    if [ -z "$ADDED_SECRETS" ] && [ -z "$REMOVED_SECRETS" ]; then
        echo "<div class='diff-item added'><div class='diff-item-header'>✅ All secrets match</div></div>" >> "$HTML_FILE"
    fi
    
    # Add full lists of secrets
    cat >> "$HTML_FILE" << HTML_SECRETS_LIST_EOF
                <h3>Source Secrets List</h3>
                <div class="details">
                    <div class="details-item">
                        <div class="details-item-content">
HTML_SECRETS_LIST_EOF

    # List all source secrets
    if [ -n "$SOURCE_SECRETS" ]; then
        echo "<ul>" >> "$HTML_FILE"
        while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            echo "<li>$secret</li>" >> "$HTML_FILE"
        done <<< "$SOURCE_SECRETS"
        echo "</ul>" >> "$HTML_FILE"
    else
        echo "<p>No secrets found in source</p>" >> "$HTML_FILE"
    fi
    
    cat >> "$HTML_FILE" << HTML_SECRETS_LIST_END
                        </div>
                    </div>
                </div>
                
                <h3>Target Secrets List</h3>
                <div class="details">
                    <div class="details-item">
                        <div class="details-item-content">
HTML_SECRETS_LIST_END

    # List all target secrets
    if [ -n "$TARGET_SECRETS" ]; then
        echo "<ul>" >> "$HTML_FILE"
        while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            echo "<li>$secret</li>" >> "$HTML_FILE"
        done <<< "$TARGET_SECRETS"
        echo "</ul>" >> "$HTML_FILE"
    else
        echo "<p>No secrets found in target</p>" >> "$HTML_FILE"
    fi
    
    cat >> "$HTML_FILE" << HTML_SECRETS_END
                        </div>
                    </div>
                </div>
            </div>

HTML_SECRETS_END
fi

# Calculate differences for migration action plan (at the end, after all comparisons)
log_info "Calculating migration action plan..."

# Re-read source tables if not already set
if [ -z "${SOURCE_TABLES:-}" ]; then
    SOURCE_TABLES=$(get_file_contents "$SOURCE_INFO.tables")
fi
if [ -z "${TARGET_TABLES:-}" ]; then
    TARGET_TABLES=$(get_file_contents "$TARGET_INFO.tables")
fi

SOURCE_VIEWS=$(get_file_contents "$SOURCE_INFO.views")
TARGET_VIEWS=$(get_file_contents "$TARGET_INFO.views")
SOURCE_FUNCTIONS=$(get_file_contents "$SOURCE_INFO.db_functions")
TARGET_FUNCTIONS=$(get_file_contents "$TARGET_INFO.db_functions")
SOURCE_SECRETS=$(get_file_contents "$SOURCE_INFO.secrets")
TARGET_SECRETS=$(get_file_contents "$TARGET_INFO.secrets")

# Calculate what needs to be migrated
TABLES_TO_MIGRATE=""
TABLES_TO_REMOVE=""
VIEWS_TO_MIGRATE=""
FUNCTIONS_TO_MIGRATE=""
SECRETS_TO_MIGRATE=""
BUCKETS_TO_MIGRATE=""
BUCKETS_TO_REMOVE=""
EDGE_FUNCTIONS_TO_MIGRATE=""
EDGE_FUNCTIONS_TO_REMOVE=""

# Calculate database differences (with proper empty check)
if [ -n "$SOURCE_TABLES" ]; then
    while IFS= read -r table; do
        [ -z "$table" ] && continue
        if [ -z "$TARGET_TABLES" ] || ! echo "$TARGET_TABLES" | grep -q "^${table}$"; then
            TABLES_TO_MIGRATE="${TABLES_TO_MIGRATE}${table}\n"
        fi
    done <<< "$SOURCE_TABLES"
fi

if [ -n "$TARGET_TABLES" ]; then
    while IFS= read -r table; do
        [ -z "$table" ] && continue
        if [ -z "$SOURCE_TABLES" ] || ! echo "$SOURCE_TABLES" | grep -q "^${table}$"; then
            TABLES_TO_REMOVE="${TABLES_TO_REMOVE}${table}\n"
        fi
    done <<< "$TARGET_TABLES"
fi

if [ -n "$SOURCE_VIEWS" ]; then
    while IFS= read -r view; do
        [ -z "$view" ] && continue
        if [ -z "$TARGET_VIEWS" ] || ! echo "$TARGET_VIEWS" | grep -q "^${view}$"; then
            VIEWS_TO_MIGRATE="${VIEWS_TO_MIGRATE}${view}\n"
        fi
    done <<< "$SOURCE_VIEWS"
fi

if [ -n "$SOURCE_FUNCTIONS" ]; then
    while IFS= read -r func; do
        [ -z "$func" ] && continue
        if [ -z "$TARGET_FUNCTIONS" ] || ! echo "$TARGET_FUNCTIONS" | grep -q "^${func}$"; then
            FUNCTIONS_TO_MIGRATE="${FUNCTIONS_TO_MIGRATE}${func}\n"
        fi
    done <<< "$SOURCE_FUNCTIONS"
fi

# Calculate RLS policies differences
SOURCE_POLICIES=$(get_file_contents "$SOURCE_INFO.policies")
TARGET_POLICIES=$(get_file_contents "$TARGET_INFO.policies")

if [ -n "$SOURCE_POLICIES" ]; then
    while IFS= read -r policy; do
        [ -z "$policy" ] && continue
        if [ -z "$TARGET_POLICIES" ] || ! echo "$TARGET_POLICIES" | grep -q "^${policy}$"; then
            POLICIES_TO_MIGRATE="${POLICIES_TO_MIGRATE}${policy}\n"
        fi
    done <<< "$SOURCE_POLICIES"
fi

if [ -n "$TARGET_POLICIES" ]; then
    while IFS= read -r policy; do
        [ -z "$policy" ] && continue
        if [ -z "$SOURCE_POLICIES" ] || ! echo "$SOURCE_POLICIES" | grep -q "^${policy}$"; then
            POLICIES_TO_REMOVE="${POLICIES_TO_REMOVE}${policy}\n"
        fi
    done <<< "$TARGET_POLICIES"
fi

# Calculate secrets differences
if [ -n "$SOURCE_SECRETS" ]; then
    while IFS= read -r secret; do
        [ -z "$secret" ] && continue
        if [ -z "$TARGET_SECRETS" ] || ! echo "$TARGET_SECRETS" | grep -q "^${secret}$"; then
            SECRETS_TO_MIGRATE="${SECRETS_TO_MIGRATE}${secret}\n"
        fi
    done <<< "$SOURCE_SECRETS"
fi

# Calculate edge functions differences
SOURCE_EDGE_FUNCTIONS=$(get_file_contents "$SOURCE_INFO.functions")
TARGET_EDGE_FUNCTIONS=$(get_file_contents "$TARGET_INFO.functions")

if [ -n "$SOURCE_EDGE_FUNCTIONS" ]; then
    while IFS= read -r func; do
        [ -z "$func" ] && continue
        if [ -z "$TARGET_EDGE_FUNCTIONS" ] || ! echo "$TARGET_EDGE_FUNCTIONS" | grep -q "^${func}$"; then
            EDGE_FUNCTIONS_TO_MIGRATE="${EDGE_FUNCTIONS_TO_MIGRATE}${func}\n"
        fi
    done <<< "$SOURCE_EDGE_FUNCTIONS"
fi

if [ -n "$TARGET_EDGE_FUNCTIONS" ]; then
    while IFS= read -r func; do
        [ -z "$func" ] && continue
        if [ -z "$SOURCE_EDGE_FUNCTIONS" ] || ! echo "$SOURCE_EDGE_FUNCTIONS" | grep -q "^${func}$"; then
            EDGE_FUNCTIONS_TO_REMOVE="${EDGE_FUNCTIONS_TO_REMOVE}${func}\n"
        fi
    done <<< "$TARGET_EDGE_FUNCTIONS"
fi

# Calculate bucket differences
SOURCE_BUCKET_NAMES=$(get_file_contents "$SOURCE_INFO.buckets" | cut -d'|' -f1)
TARGET_BUCKET_NAMES=$(get_file_contents "$TARGET_INFO.buckets" | cut -d'|' -f1)

if [ -n "$SOURCE_BUCKET_NAMES" ]; then
    while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        if [ -z "$TARGET_BUCKET_NAMES" ] || ! echo "$TARGET_BUCKET_NAMES" | grep -q "^${bucket}$"; then
            BUCKETS_TO_MIGRATE="${BUCKETS_TO_MIGRATE}${bucket}\n"
        fi
    done <<< "$SOURCE_BUCKET_NAMES"
fi

if [ -n "$TARGET_BUCKET_NAMES" ]; then
    while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        if [ -z "$SOURCE_BUCKET_NAMES" ] || ! echo "$SOURCE_BUCKET_NAMES" | grep -q "^${bucket}$"; then
            BUCKETS_TO_REMOVE="${BUCKETS_TO_REMOVE}${bucket}\n"
        fi
    done <<< "$TARGET_BUCKET_NAMES"
fi

# Count items (with safe defaults)
TABLES_TO_MIGRATE_COUNT=0
if [ -n "$TABLES_TO_MIGRATE" ]; then
    TABLES_TO_MIGRATE_COUNT=$(echo -e "$TABLES_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
TABLES_TO_REMOVE_COUNT=0
if [ -n "$TABLES_TO_REMOVE" ]; then
    TABLES_TO_REMOVE_COUNT=$(echo -e "$TABLES_TO_REMOVE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
VIEWS_TO_MIGRATE_COUNT=0
if [ -n "$VIEWS_TO_MIGRATE" ]; then
    VIEWS_TO_MIGRATE_COUNT=$(echo -e "$VIEWS_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
FUNCTIONS_TO_MIGRATE_COUNT=0
if [ -n "$FUNCTIONS_TO_MIGRATE" ]; then
    FUNCTIONS_TO_MIGRATE_COUNT=$(echo -e "$FUNCTIONS_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
POLICIES_TO_MIGRATE_COUNT=0
if [ -n "$POLICIES_TO_MIGRATE" ]; then
    POLICIES_TO_MIGRATE_COUNT=$(echo -e "$POLICIES_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
POLICIES_TO_REMOVE_COUNT=0
if [ -n "$POLICIES_TO_REMOVE" ]; then
    POLICIES_TO_REMOVE_COUNT=$(echo -e "$POLICIES_TO_REMOVE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
SECRETS_TO_MIGRATE_COUNT=0
if [ -n "$SECRETS_TO_MIGRATE" ]; then
    SECRETS_TO_MIGRATE_COUNT=$(echo -e "$SECRETS_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
BUCKETS_TO_MIGRATE_COUNT=0
if [ -n "$BUCKETS_TO_MIGRATE" ]; then
    BUCKETS_TO_MIGRATE_COUNT=$(echo -e "$BUCKETS_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
BUCKETS_TO_REMOVE_COUNT=0
if [ -n "$BUCKETS_TO_REMOVE" ]; then
    BUCKETS_TO_REMOVE_COUNT=$(echo -e "$BUCKETS_TO_REMOVE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
EDGE_FUNCTIONS_TO_MIGRATE_COUNT=0
if [ -n "$EDGE_FUNCTIONS_TO_MIGRATE" ]; then
    EDGE_FUNCTIONS_TO_MIGRATE_COUNT=$(echo -e "$EDGE_FUNCTIONS_TO_MIGRATE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi
EDGE_FUNCTIONS_TO_REMOVE_COUNT=0
if [ -n "$EDGE_FUNCTIONS_TO_REMOVE" ]; then
    EDGE_FUNCTIONS_TO_REMOVE_COUNT=$(echo -e "$EDGE_FUNCTIONS_TO_REMOVE" | grep -v '^$' | wc -l | tr -d ' ' || echo "0")
fi

# Calculate total file count to migrate
TOTAL_FILES_TO_MIGRATE=0
if [ -n "$BUCKETS_TO_MIGRATE" ] && [ -f "$SOURCE_INFO.buckets" ]; then
    while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        file_count=$(grep "^${bucket}|" "$SOURCE_INFO.buckets" 2>/dev/null | cut -d'|' -f5 | head -1 || echo "0")
        if [ -n "$file_count" ] && expr "$file_count" + 0 >/dev/null 2>&1; then
            TOTAL_FILES_TO_MIGRATE=$((TOTAL_FILES_TO_MIGRATE + file_count))
        fi
    done <<< "$BUCKETS_TO_MIGRATE"
fi

log_info "Migration action plan calculation completed"

# Add Migration Action Plan section at the end
cat >> "$HTML_FILE" << HTML_ACTION_PLAN_EOF
            <div class="section">
                <h2>📋 Migration Action Plan</h2>
                <p style="margin-bottom: 20px; color: #666; font-size: 1.05em;">
                    This section summarizes what needs to be migrated from <strong>$SOURCE_ENV</strong> to <strong>$TARGET_ENV</strong> 
                    to make the target environment identical to the source.
                </p>
                
HTML_ACTION_PLAN_EOF

# Generate database migration section
cat >> "$HTML_FILE" << HTML_DB_ACTION_EOF
                <div class="details" style="margin-top: 20px;">
                    <h3 style="color: #667eea; margin-bottom: 15px;">🗄️ Database Migration Required</h3>
HTML_DB_ACTION_EOF

# Tables to migrate
if [ "$TABLES_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_TABLES_EOF
                    <div class="details-item">
                        <div class="details-item-label">Tables to Migrate:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $TABLES_TO_MIGRATE_COUNT table(s)<br><br>
                            <strong>Tables:</strong><br>
HTML_TABLES_EOF
    echo -e "$TABLES_TO_MIGRATE" | grep -v '^$' | while IFS= read -r table; do
        echo "                            • $table<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_TABLES_END
                        </div>
                    </div>
HTML_TABLES_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Tables:</div><div class='details-item-content'>✅ No tables need migration - all tables exist in target</div></div>" >> "$HTML_FILE"
fi

# Tables to remove
if [ "$TABLES_TO_REMOVE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_REMOVE_TABLES_EOF
                    <div class="details-item">
                        <div class="details-item-label">Tables to Remove from Target:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $TABLES_TO_REMOVE_COUNT table(s)<br><br>
                            <strong>Tables:</strong><br>
HTML_REMOVE_TABLES_EOF
    echo -e "$TABLES_TO_REMOVE" | grep -v '^$' | while IFS= read -r table; do
        echo "                            • $table<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_REMOVE_TABLES_END
                        </div>
                    </div>
HTML_REMOVE_TABLES_END
fi

# Views to migrate
if [ "$VIEWS_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_VIEWS_EOF
                    <div class="details-item">
                        <div class="details-item-label">Views to Migrate:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $VIEWS_TO_MIGRATE_COUNT view(s)<br><br>
                            <strong>Views:</strong><br>
HTML_VIEWS_EOF
    echo -e "$VIEWS_TO_MIGRATE" | grep -v '^$' | while IFS= read -r view; do
        echo "                            • $view<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_VIEWS_END
                        </div>
                    </div>
HTML_VIEWS_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Views:</div><div class='details-item-content'>✅ No views need migration - all views exist in target</div></div>" >> "$HTML_FILE"
fi

# Database functions to migrate
if [ "$FUNCTIONS_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_FUNCS_EOF
                    <div class="details-item">
                        <div class="details-item-label">Database Functions to Migrate:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $FUNCTIONS_TO_MIGRATE_COUNT function(s)<br><br>
                            <strong>Functions:</strong><br>
HTML_FUNCS_EOF
    echo -e "$FUNCTIONS_TO_MIGRATE" | grep -v '^$' | head -10 | while IFS= read -r func; do
        echo "                            • $func<br>" >> "$HTML_FILE"
    done
    if [ "$FUNCTIONS_TO_MIGRATE_COUNT" -gt 10 ]; then
        echo "                            ... and $((FUNCTIONS_TO_MIGRATE_COUNT - 10)) more<br>" >> "$HTML_FILE"
    fi
    cat >> "$HTML_FILE" << HTML_FUNCS_END
                        </div>
                    </div>
HTML_FUNCS_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Database Functions:</div><div class='details-item-content'>✅ No functions need migration - all functions exist in target</div></div>" >> "$HTML_FILE"
fi

# RLS Policies to migrate
if [ "$POLICIES_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_POLICIES_ACTION_EOF
                    <div class="details-item">
                        <div class="details-item-label">RLS Policies to Migrate:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $POLICIES_TO_MIGRATE_COUNT policy/policies<br><br>
                            <strong>Policies:</strong><br>
HTML_POLICIES_ACTION_EOF
    echo -e "$POLICIES_TO_MIGRATE" | grep -v '^$' | head -20 | while IFS= read -r policy; do
        echo "                            • $policy<br>" >> "$HTML_FILE"
    done
    if [ "$POLICIES_TO_MIGRATE_COUNT" -gt 20 ]; then
        echo "                            ... and $((POLICIES_TO_MIGRATE_COUNT - 20)) more policy/policies<br>" >> "$HTML_FILE"
    fi
    cat >> "$HTML_FILE" << HTML_POLICIES_ACTION_END
                        </div>
                    </div>
HTML_POLICIES_ACTION_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>RLS Policies:</div><div class='details-item-content'>✅ No RLS policies need migration - all policies exist in target</div></div>" >> "$HTML_FILE"
fi

# RLS Policies to remove
if [ "$POLICIES_TO_REMOVE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_REMOVE_POLICIES_EOF
                    <div class="details-item">
                        <div class="details-item-label">RLS Policies to Remove from Target:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $POLICIES_TO_REMOVE_COUNT policy/policies<br><br>
                            <strong>Policies:</strong><br>
HTML_REMOVE_POLICIES_EOF
    echo -e "$POLICIES_TO_REMOVE" | grep -v '^$' | head -20 | while IFS= read -r policy; do
        echo "                            • $policy<br>" >> "$HTML_FILE"
    done
    if [ "$POLICIES_TO_REMOVE_COUNT" -gt 20 ]; then
        echo "                            ... and $((POLICIES_TO_REMOVE_COUNT - 20)) more policy/policies<br>" >> "$HTML_FILE"
    fi
    cat >> "$HTML_FILE" << HTML_REMOVE_POLICIES_END
                        </div>
                    </div>
HTML_REMOVE_POLICIES_END
fi

cat >> "$HTML_FILE" << HTML_DB_ACTION_END
                </div>
                
HTML_DB_ACTION_END

# Generate storage migration section
cat >> "$HTML_FILE" << HTML_STORAGE_ACTION_EOF
                <div class="details" style="margin-top: 20px;">
                    <h3 style="color: #667eea; margin-bottom: 15px;">📦 Storage Migration Required</h3>
HTML_STORAGE_ACTION_EOF

# Buckets to migrate
if [ "$BUCKETS_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_BUCKETS_EOF
                    <div class="details-item">
                        <div class="details-item-label">Buckets to Migrate:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $BUCKETS_TO_MIGRATE_COUNT bucket(s)<br><br>
                            <strong>Buckets:</strong><br>
HTML_BUCKETS_EOF
    echo -e "$BUCKETS_TO_MIGRATE" | grep -v '^$' | while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        file_count=$(grep "^${bucket}|" "$SOURCE_INFO.buckets" 2>/dev/null | cut -d'|' -f5 | head -1 || echo "0")
        echo "                            • $bucket ($file_count files)<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_BUCKETS_END
                            <br><strong>Total Files to Migrate:</strong> $TOTAL_FILES_TO_MIGRATE file(s)
                        </div>
                    </div>
HTML_BUCKETS_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Buckets:</div><div class='details-item-content'>✅ No buckets need migration - all buckets exist in target</div></div>" >> "$HTML_FILE"
fi

# Buckets to remove
if [ "$BUCKETS_TO_REMOVE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_REMOVE_BUCKETS_EOF
                    <div class="details-item">
                        <div class="details-item-label">Buckets to Remove from Target:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $BUCKETS_TO_REMOVE_COUNT bucket(s)<br><br>
                            <strong>Buckets:</strong><br>
HTML_REMOVE_BUCKETS_EOF
    echo -e "$BUCKETS_TO_REMOVE" | grep -v '^$' | while IFS= read -r bucket; do
        echo "                            • $bucket<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_REMOVE_BUCKETS_END
                        </div>
                    </div>
HTML_REMOVE_BUCKETS_END
fi

cat >> "$HTML_FILE" << HTML_STORAGE_ACTION_END
                </div>
                
HTML_STORAGE_ACTION_END

# Generate edge functions migration section
cat >> "$HTML_FILE" << HTML_EDGE_ACTION_EOF
                <div class="details" style="margin-top: 20px;">
                    <h3 style="color: #667eea; margin-bottom: 15px;">⚡ Edge Functions Migration Required</h3>
HTML_EDGE_ACTION_EOF

# Edge functions to migrate
if [ "$EDGE_FUNCTIONS_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_EDGE_FUNCS_EOF
                    <div class="details-item">
                        <div class="details-item-label">Functions to Deploy:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $EDGE_FUNCTIONS_TO_MIGRATE_COUNT function(s)<br><br>
                            <strong>Functions:</strong><br>
HTML_EDGE_FUNCS_EOF
    echo -e "$EDGE_FUNCTIONS_TO_MIGRATE" | grep -v '^$' | while IFS= read -r func; do
        echo "                            • $func<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_EDGE_FUNCS_END
                        </div>
                    </div>
HTML_EDGE_FUNCS_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Edge Functions:</div><div class='details-item-content'>✅ No edge functions need deployment - all functions exist in target</div></div>" >> "$HTML_FILE"
fi

# Edge functions to remove
if [ "$EDGE_FUNCTIONS_TO_REMOVE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_REMOVE_EDGE_EOF
                    <div class="details-item">
                        <div class="details-item-label">Functions to Remove from Target:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $EDGE_FUNCTIONS_TO_REMOVE_COUNT function(s)<br><br>
                            <strong>Functions:</strong><br>
HTML_REMOVE_EDGE_EOF
    echo -e "$EDGE_FUNCTIONS_TO_REMOVE" | grep -v '^$' | while IFS= read -r func; do
        echo "                            • $func<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_REMOVE_EDGE_END
                        </div>
                    </div>
HTML_REMOVE_EDGE_END
fi

cat >> "$HTML_FILE" << HTML_EDGE_ACTION_END
                </div>
                
HTML_EDGE_ACTION_END

# Generate secrets migration section
cat >> "$HTML_FILE" << HTML_SECRETS_ACTION_EOF
                <div class="details" style="margin-top: 20px;">
                    <h3 style="color: #667eea; margin-bottom: 15px;">🔐 Secrets Migration Required</h3>
HTML_SECRETS_ACTION_EOF

# Secrets to migrate
if [ "$SECRETS_TO_MIGRATE_COUNT" -gt 0 ]; then
    cat >> "$HTML_FILE" << HTML_SECRETS_MIGRATE_EOF
                    <div class="details-item">
                        <div class="details-item-label">Secrets to Add:</div>
                        <div class="details-item-content">
                            <strong>Count:</strong> $SECRETS_TO_MIGRATE_COUNT secret(s)<br><br>
                            <strong>Secrets:</strong><br>
HTML_SECRETS_MIGRATE_EOF
    echo -e "$SECRETS_TO_MIGRATE" | grep -v '^$' | while IFS= read -r secret; do
        echo "                            • $secret<br>" >> "$HTML_FILE"
    done
    cat >> "$HTML_FILE" << HTML_SECRETS_MIGRATE_END
                            <br><strong>⚠️ Note:</strong> Secret values cannot be migrated automatically. You must set values manually after migration.
                        </div>
                    </div>
HTML_SECRETS_MIGRATE_END
else
    echo "                    <div class='details-item'><div class='details-item-label'>Secrets:</div><div class='details-item-content'>✅ No secrets need migration - all secrets exist in target</div></div>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_SECRETS_ACTION_END
                </div>
                
HTML_SECRETS_ACTION_END

# Generate final summary
cat >> "$HTML_FILE" << HTML_FINAL_SUMMARY_EOF
                <div class="details" style="margin-top: 20px; background: #e3f2fd; border-left-color: #2196f3;">
                    <h3 style="color: #1976d2; margin-bottom: 15px;">📝 Migration Summary</h3>
                    <div class="details-item">
                        <div class="details-item-content" style="font-size: 1em; font-family: inherit;">
                            <strong>Total Items to Migrate:</strong><br>
                            • Database Tables: $TABLES_TO_MIGRATE_COUNT<br>
                            • Database Views: $VIEWS_TO_MIGRATE_COUNT<br>
                            • Database Functions: $FUNCTIONS_TO_MIGRATE_COUNT<br>
                            • RLS Policies: $POLICIES_TO_MIGRATE_COUNT<br>
                            • Storage Buckets: $BUCKETS_TO_MIGRATE_COUNT<br>
                            • Storage Files: $TOTAL_FILES_TO_MIGRATE<br>
                            • Edge Functions: $EDGE_FUNCTIONS_TO_MIGRATE_COUNT<br>
                            • Secrets: $SECRETS_TO_MIGRATE_COUNT<br><br>
                            
                            <strong>Total Items to Remove from Target:</strong><br>
                            • Database Tables: $TABLES_TO_REMOVE_COUNT<br>
                            • RLS Policies: $POLICIES_TO_REMOVE_COUNT<br>
                            • Storage Buckets: $BUCKETS_TO_REMOVE_COUNT<br>
                            • Edge Functions: $EDGE_FUNCTIONS_TO_REMOVE_COUNT<br><br>
HTML_FINAL_SUMMARY_EOF

# Determine if migration is needed
if [ "$TABLES_TO_MIGRATE_COUNT" -eq 0 ] && [ "$VIEWS_TO_MIGRATE_COUNT" -eq 0 ] && \
   [ "$FUNCTIONS_TO_MIGRATE_COUNT" -eq 0 ] && [ "$POLICIES_TO_MIGRATE_COUNT" -eq 0 ] && \
   [ "$BUCKETS_TO_MIGRATE_COUNT" -eq 0 ] && [ "$EDGE_FUNCTIONS_TO_MIGRATE_COUNT" -eq 0 ] && \
   [ "$SECRETS_TO_MIGRATE_COUNT" -eq 0 ] && [ "$TABLES_TO_REMOVE_COUNT" -eq 0 ] && \
   [ "$POLICIES_TO_REMOVE_COUNT" -eq 0 ] && [ "$BUCKETS_TO_REMOVE_COUNT" -eq 0 ] && \
   [ "$EDGE_FUNCTIONS_TO_REMOVE_COUNT" -eq 0 ]; then
    echo "                            <strong style='color: #4caf50;'>✅ Target environment is already identical to source - no migration needed!</strong>" >> "$HTML_FILE"
else
    echo "                            <strong style='color: #ff9800;'>⚠️ Migration required to synchronize target with source</strong>" >> "$HTML_FILE"
fi

cat >> "$HTML_FILE" << HTML_FINAL_SUMMARY_END
                        </div>
                    </div>
                </div>
            </div>

HTML_FINAL_SUMMARY_END

# Close HTML
cat >> "$HTML_FILE" << HTML_END
            <div class="timestamp">
                Report generated on $(date)
            </div>
        </div>
    </div>
</body>
</html>
HTML_END

log_success "Migration plan generated successfully!"
log_info ""
log_info "📄 Report saved to: $HTML_FILE"
log_info ""
log_info "You can open it in your browser:"
log_info "  open $HTML_FILE"
log_info ""

exit 0

