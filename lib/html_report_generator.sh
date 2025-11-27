#!/bin/bash
# HTML Report Generator for Migration Scripts
# Generates standardized HTML reports for all migration components

# Generate HTML report for a migration component
generate_migration_html_report() {
    local migration_dir=$1
    local component_name=$2  # e.g., "Database Migration", "Storage Migration", etc.
    local source_env=$3
    local target_env=$4
    local source_ref=$5
    local target_ref=$6
    local status=$7  # success, failed, partial
    local summary_data=$8  # JSON-like string or structured data
    
    local html_file="$migration_dir/result.html"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Parse summary data (expecting key=value pairs or JSON)
    # For now, we'll use a simple approach with predefined variables
    # Ensure all count variables are integers (remove any whitespace)
    local migrated_count=$(echo "${MIGRATED_COUNT:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
    local skipped_count=$(echo "${SKIPPED_COUNT:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
    local failed_count=$(echo "${FAILED_COUNT:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
    local removed_count=$(echo "${REMOVED_COUNT:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
    local details_section=${DETAILS_SECTION:-""}
    
    cat > "$html_file" << HTML_EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$component_name - $source_env to $target_env</title>
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
            max-width: 1200px;
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
        .status-badge {
            display: inline-block;
            padding: 8px 16px;
            border-radius: 20px;
            font-weight: 600;
            margin-top: 10px;
        }
        .status-success {
            background: #4caf50;
            color: white;
        }
        .status-failed {
            background: #f44336;
            color: white;
        }
        .status-partial {
            background: #ff9800;
            color: white;
        }
        .content {
            padding: 30px;
        }
        .section {
            margin-bottom: 30px;
        }
        .section h2 {
            color: #667eea;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .summary-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
        }
        .summary-card-value {
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .summary-card-label {
            font-size: 0.9em;
            opacity: 0.9;
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
        .details-item-label {
            font-weight: 600;
            color: #667eea;
            margin-bottom: 5px;
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
        .badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 500;
            margin-right: 5px;
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
        .timestamp {
            text-align: center;
            color: #666;
            font-size: 0.9em;
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>$component_name</h1>
            <div class="meta">
                <strong>$source_env</strong> ($source_ref) → <strong>$target_env</strong> ($target_ref)<br>
                Generated: $timestamp
            </div>
            <div class="status-badge status-${status}">
                $(if [ "$status" = "success" ]; then echo "✅ Success"; elif [ "$status" = "failed" ]; then echo "❌ Failed"; else echo "⚠️ Partial Success"; fi)
            </div>
        </header>
        <div class="content">
            <div class="section">
                <h2>📊 Migration Summary</h2>
                <div class="summary-grid">
                    <div class="summary-card">
                        <div class="summary-card-value">$migrated_count</div>
                        <div class="summary-card-label">Migrated</div>
                    </div>
                    <div class="summary-card">
                        <div class="summary-card-value">$skipped_count</div>
                        <div class="summary-card-label">Skipped</div>
                    </div>
                    <div class="summary-card">
                        <div class="summary-card-value">$failed_count</div>
                        <div class="summary-card-label">Failed</div>
                    </div>
                    $(if [ "${removed_count:-0}" -gt 0 ] 2>/dev/null; then
                        echo "<div class=\"summary-card\">
                        <div class=\"summary-card-value\">$removed_count</div>
                        <div class=\"summary-card-label\">Removed</div>
                    </div>"
                    fi)
                </div>
            </div>
            
            <div class="section">
                <h2>📝 Migration Details</h2>
                <div class="details">
                    $details_section
                </div>
            </div>
            
            <div class="timestamp">
                Report generated on $timestamp
            </div>
        </div>
    </div>
</body>
</html>
HTML_EOF
    
    echo "$html_file"
}

# Helper function to format details section from migration log
format_migration_details() {
    local log_file=$1
    local component_type=$2  # database, storage, edge_functions, secrets
    
    local details=""
    
    if [ ! -f "$log_file" ]; then
        echo "<div class=\"details-item\"><div class=\"details-item-label\">No log file available</div></div>"
        return
    fi
    
    # Extract relevant information from log based on component type
    case "$component_type" in
        database)
            # Extract table migration details
            if grep -q "Migrated\|migrated\|Tables" "$log_file" 2>/dev/null; then
                details="<div class=\"details-item\"><div class=\"details-item-label\">Database Migration</div>"
                details="${details}<div class=\"details-item-content\">"
                details="${details}$(grep -i "migrated\|tables\|schema" "$log_file" | tail -20 | sed 's/^/  /' | sed 's/$/<br>/')"
                details="${details}</div></div>"
            fi
            ;;
        storage)
            # Extract bucket and file details
            if grep -q "Bucket\|bucket\|File\|file" "$log_file" 2>/dev/null; then
                details="<div class=\"details-item\"><div class=\"details-item-label\">Storage Migration</div>"
                details="${details}<div class=\"details-item-content\">"
                details="${details}$(grep -i "bucket\|file\|migrated" "$log_file" | tail -30 | sed 's/^/  /' | sed 's/$/<br>/')"
                details="${details}</div></div>"
            fi
            ;;
        edge_functions)
            # Extract function deployment details
            if grep -q "Function\|function\|Deploy\|deploy" "$log_file" 2>/dev/null; then
                details="<div class=\"details-item\"><div class=\"details-item-label\">Edge Functions</div>"
                details="${details}<div class=\"details-item-content\">"
                details="${details}$(grep -i "function\|deploy\|migrated" "$log_file" | tail -20 | sed 's/^/  /' | sed 's/$/<br>/')"
                details="${details}</div></div>"
            fi
            ;;
        secrets)
            # Extract secret migration details
            if grep -q "Secret\|secret\|Migrated\|migrated" "$log_file" 2>/dev/null; then
                details="<div class=\"details-item\"><div class=\"details-item-label\">Secrets</div>"
                details="${details}<div class=\"details-item-content\">"
                details="${details}$(grep -i "secret\|migrated\|removed" "$log_file" | tail -20 | sed 's/^/  /' | sed 's/$/<br>/')"
                details="${details}</div></div>"
            fi
            ;;
    esac
    
    # If no specific details found, show general log excerpt
    if [ -z "$details" ]; then
        details="<div class=\"details-item\"><div class=\"details-item-label\">Migration Log</div>"
        details="${details}<div class=\"details-item-content\">"
        details="${details}$(tail -30 "$log_file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | sed 's/^/  /' | sed 's/$/<br>/')"
        details="${details}</div></div>"
    fi
    
    echo "$details"
}

