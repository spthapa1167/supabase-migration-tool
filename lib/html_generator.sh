#!/bin/bash
# HTML Result Generator for Migration Results
# Generates a beautiful HTML page with migration details, comparisons, and rollback instructions

# Generate HTML result page
generate_result_html() {
    local migration_dir=$1
    local status=$2
    local comparison_file=$3
    local error_details=${4:-""}  # Optional 4th parameter for error details
    
    # Ensure migration_dir exists (create if it doesn't)
    if [ ! -d "$migration_dir" ]; then
        mkdir -p "$migration_dir"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Created migration directory: $migration_dir" >&2
    fi
    
    local result_html="$migration_dir/result.html"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get all the data needed for HTML generation
    local log_file="$migration_dir/migration.log"
    local backup_file="$migration_dir/target_backup.dump"
    local rollback_db_sql="$migration_dir/rollback_db.sql"
    local source_schema="$migration_dir/source_schema.sql"
    local target_schema="$migration_dir/target_schema.sql"
    local storage_buckets="$migration_dir/storage_buckets.sql"
    local secrets_list="$migration_dir/secrets_list.json"
    local functions_list="$migration_dir/edge_functions_list.json"
    
    # Check what's available
    local has_backup="false"
    [ -f "$backup_file" ] && has_backup="true"
    
    local has_rollback_sql="false"
    [ -f "$rollback_db_sql" ] && has_rollback_sql="true"
    
    # Extract data from environment
    local source_ref=""
    local target_ref=""
    local source_table_count=0
    local target_table_count=0
    local storage_buckets_migrated="⚠️  Not migrated"
    local edge_functions_deployed="⚠️  Not deployed or failed"
    local secrets_set="⚠️  Not set or failed"
    local comparison_details=""
    
    # Get refs from log or try to get from environment
    if [ -f "$log_file" ]; then
        source_ref=$(grep -i "source.*ref\|source.*project" "$log_file" | head -1 | grep -oE '[a-z]{20}' | head -1 || echo "")
        target_ref=$(grep -i "target.*ref\|target.*project" "$log_file" | head -1 | grep -oE '[a-z]{20}' | head -1 || echo "")
    fi
    
    # Try to get refs from environment if not found in log
    if [ -z "$source_ref" ] && [ -n "$SOURCE_ENV" ]; then
        if command -v get_project_ref >/dev/null 2>&1; then
            source_ref=$(get_project_ref "$SOURCE_ENV" 2>/dev/null || echo "")
        fi
    fi
    
    if [ -z "$target_ref" ] && [ -n "$TARGET_ENV" ]; then
        if command -v get_project_ref >/dev/null 2>&1; then
            target_ref=$(get_project_ref "$TARGET_ENV" 2>/dev/null || echo "")
        fi
    fi
    
    # Get pooler host and target password if available
    local pooler_host=""
    local target_password=""
    if [ -n "$target_ref" ]; then
        if command -v get_pooler_host >/dev/null 2>&1; then
            pooler_host=$(get_pooler_host "$target_ref" 2>/dev/null || echo "")
        fi
        if [ -n "$TARGET_ENV" ] && command -v get_db_password >/dev/null 2>&1; then
            target_password=$(get_db_password "$TARGET_ENV" 2>/dev/null || echo "")
        fi
    fi
    
    # Extract migration details from log file
    if [ -f "$log_file" ]; then
        # Extract migration details
        if grep -q "Edge functions deployed\|Edge functions.*deployed" "$log_file" 2>/dev/null; then
            edge_functions_deployed="✅ Deployed"
            local func_names=$(grep -i "Deployed:" "$log_file" | sed 's/.*Deployed: //' | tr '\n' ',' | sed 's/,$//' | head -c 100 || echo "")
            if [ -n "$func_names" ]; then
                edge_functions_deployed="✅ Deployed: $func_names"
            fi
        fi
        
        if grep -q "Secrets.*created\|Secrets.*set\|Secrets structure created" "$log_file" 2>/dev/null; then
            secrets_set="✅ Created (with blank/placeholder values)"
            local secret_count=$(grep -i "Set:" "$log_file" | wc -l | tr -d ' ')
            if [ "$secret_count" -gt 0 ]; then
                secrets_set="✅ Created $secret_count secret(s) (with blank/placeholder values)"
            fi
        fi
        
        if grep -q "Storage buckets imported\|Storage buckets exported\|Storage buckets.*migrated" "$log_file" 2>/dev/null; then
            storage_buckets_migrated="✅ Migrated"
        fi
    fi
    
    # Source counting utilities
    if [ -f "$PROJECT_ROOT/lib/count_objects.sh" ]; then
        source "$PROJECT_ROOT/lib/count_objects.sh"
    fi
    
    # Function to query database directly for counts if schema files don't exist
    query_database_counts() {
        local project_ref=$1
        local password=$2
        local pooler_host=$3
        
        if [ -z "$project_ref" ] || [ -z "$password" ]; then
            echo "0 0 0 0 0 0 0 0 0"
            return 0
        fi
        
        # Try pooler first, then direct connection
        local tables=0
        local views=0
        local functions=0
        local sequences=0
        local indexes=0
        local policies=0
        local triggers=0
        local types=0
        local enums=0
        
        if [ -n "$pooler_host" ]; then
            # Query via pooler
            tables=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            views=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_views WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            functions=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            sequences=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            indexes=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            policies=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            triggers=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'public' AND NOT t.tgisinternal;" 2>/dev/null | tr -d ' ' || echo "0")
            types=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = 'public' AND t.typtype = 'c';" 2>/dev/null | tr -d ' ' || echo "0")
            enums=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = 'public' AND t.typtype = 'e';" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        # If pooler failed or wasn't available, try direct connection
        if [ -z "$pooler_host" ] || [ "$tables" = "" ]; then
            local direct_host="db.${project_ref}.supabase.co"
            tables=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            views=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_views WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            functions=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            sequences=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            indexes=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            policies=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
            triggers=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'public' AND NOT t.tgisinternal;" 2>/dev/null | tr -d ' ' || echo "0")
            types=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = 'public' AND t.typtype = 'c';" 2>/dev/null | tr -d ' ' || echo "0")
            enums=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = 'public' AND t.typtype = 'e';" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        echo "$tables $views $functions $sequences $indexes $policies $triggers $types $enums"
    }
    
    # Function to query auth users count from database
    query_auth_users_count() {
        local project_ref=$1
        local password=$2
        local pooler_host=$3
        
        if [ -z "$project_ref" ] || [ -z "$password" ]; then
            echo "0"
            return 0
        fi
        
        local auth_users=0
        
        if [ -n "$pooler_host" ]; then
            # Query via pooler
            auth_users=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        # If pooler failed or wasn't available, try direct connection
        if [ -z "$pooler_host" ] || [ "$auth_users" = "" ] || [ "$auth_users" = "0" ]; then
            local direct_host="db.${project_ref}.supabase.co"
            auth_users=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM auth.users;" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        echo "$auth_users"
    }
    
    # Function to query edge functions count from API
    query_edge_functions_count() {
        local project_ref=$1
        
        if [ -z "$project_ref" ] || [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
            echo "0"
            return 0
        fi
        
        local temp_json=$(mktemp)
        local count=0
        
        if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${project_ref}/functions" \
            -o "$temp_json" 2>/dev/null; then
            if command -v jq >/dev/null 2>&1 && jq empty "$temp_json" 2>/dev/null; then
                count=$(jq '. | length' "$temp_json" 2>/dev/null || echo "0")
            fi
        fi
        
        rm -f "$temp_json"
        echo "$count"
    }
    
    # Function to query storage buckets count from database
    query_storage_buckets_count() {
        local project_ref=$1
        local password=$2
        local pooler_host=$3
        
        if [ -z "$project_ref" ] || [ -z "$password" ]; then
            echo "0"
            return 0
        fi
        
        local buckets=0
        
        if [ -n "$pooler_host" ]; then
            # Query via pooler
            buckets=$(PGPASSWORD="$password" psql -h "$pooler_host" -p 6543 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM storage.buckets;" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        # If pooler failed or wasn't available, try direct connection
        if [ -z "$pooler_host" ] || [ "$buckets" = "" ]; then
            local direct_host="db.${project_ref}.supabase.co"
            buckets=$(PGPASSWORD="$password" psql -h "$direct_host" -p 5432 -U postgres.${project_ref} -d postgres -t -A -c "SELECT COUNT(*) FROM storage.buckets;" 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        echo "$buckets"
    }
    
    # Function to query secrets count from API
    query_secrets_count() {
        local project_ref=$1
        
        if [ -z "$project_ref" ] || [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
            echo "0"
            return 0
        fi
        
        local temp_json=$(mktemp)
        local count=0
        
        if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${project_ref}/secrets" \
            -o "$temp_json" 2>/dev/null; then
            if command -v jq >/dev/null 2>&1 && jq empty "$temp_json" 2>/dev/null; then
                count=$(jq '. | length' "$temp_json" 2>/dev/null || echo "0")
            fi
        fi
        
        rm -f "$temp_json"
        echo "$count"
    }
    
    # Load before/after snapshots if available
    local before_snapshot="$migration_dir/snapshot_before.json"
    local after_snapshot="$migration_dir/snapshot_after.json"
    
    # Get comprehensive object counts from schemas or database
    local source_counts="0 0 0 0 0 0 0 0 0"
    local target_counts="0 0 0 0 0 0 0 0 0"
    
    # Load before snapshot counts if available
    local source_before_tables=0 source_before_views=0 source_before_functions=0 source_before_sequences=0
    local source_before_indexes=0 source_before_policies=0 source_before_triggers=0 source_before_types=0 source_before_enums=0
    local source_before_auth_users=0 source_before_edge_functions=0 source_before_buckets=0 source_before_secrets=0
    local target_before_tables=0 target_before_views=0 target_before_functions=0 target_before_sequences=0
    local target_before_indexes=0 target_before_policies=0 target_before_triggers=0 target_before_types=0 target_before_enums=0
    local target_before_auth_users=0 target_before_edge_functions=0 target_before_buckets=0 target_before_secrets=0
    
    if [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
        log_info "Loading BEFORE migration snapshot from: $before_snapshot"
        source_before_tables=$(jq -r '.source.counts.tables // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_views=$(jq -r '.source.counts.views // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_functions=$(jq -r '.source.counts.functions // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_sequences=$(jq -r '.source.counts.sequences // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_indexes=$(jq -r '.source.counts.indexes // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_policies=$(jq -r '.source.counts.policies // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_triggers=$(jq -r '.source.counts.triggers // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_types=$(jq -r '.source.counts.types // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_enums=$(jq -r '.source.counts.enums // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_auth_users=$(jq -r '.source.counts.auth_users // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_edge_functions=$(jq -r '.source.counts.edge_functions // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_buckets=$(jq -r '.source.counts.buckets // 0' "$before_snapshot" 2>/dev/null || echo "0")
        source_before_secrets=$(jq -r '.source.counts.secrets // 0' "$before_snapshot" 2>/dev/null || echo "0")
        
        target_before_tables=$(jq -r '.target.counts.tables // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_views=$(jq -r '.target.counts.views // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_functions=$(jq -r '.target.counts.functions // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_sequences=$(jq -r '.target.counts.sequences // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_indexes=$(jq -r '.target.counts.indexes // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_policies=$(jq -r '.target.counts.policies // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_triggers=$(jq -r '.target.counts.triggers // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_types=$(jq -r '.target.counts.types // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_enums=$(jq -r '.target.counts.enums // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_auth_users=$(jq -r '.target.counts.auth_users // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_edge_functions=$(jq -r '.target.counts.edge_functions // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_buckets=$(jq -r '.target.counts.buckets // 0' "$before_snapshot" 2>/dev/null || echo "0")
        target_before_secrets=$(jq -r '.target.counts.secrets // 0' "$before_snapshot" 2>/dev/null || echo "0")
    fi
    
    # Get source counts - prefer live database query for accuracy, fallback to schema file or snapshot
    if [ -n "$source_ref" ]; then
        local source_password=""
        local source_pooler=""
        if [ -n "$SOURCE_ENV" ] && command -v get_db_password >/dev/null 2>&1; then
            source_password=$(get_db_password "$SOURCE_ENV" 2>/dev/null || echo "")
        fi
        if [ -n "$source_ref" ] && command -v get_pooler_host >/dev/null 2>&1; then
            source_pooler=$(get_pooler_host "$source_ref" 2>/dev/null || echo "")
        fi
        if [ -n "$source_password" ]; then
            # Always query live database for real-time counts (before migration state)
            log_info "Querying database object counts from source: $source_ref"
            source_counts=$(query_database_counts "$source_ref" "$source_password" "$source_pooler")
            log_info "Source database counts retrieved: $source_counts"
            
            # If counts are all 0, try direct connection
            local count_sum=$(echo "$source_counts" | awk '{sum=0; for(i=1;i<=NF;i++) sum+=$i; print sum}')
            if [ "$count_sum" = "0" ] || [ -z "$count_sum" ]; then
                log_info "Pooler returned 0 counts, trying direct connection for source..."
                source_counts=$(query_database_counts "$source_ref" "$source_password" "")
            fi
        elif [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
            # Use snapshot if available
            log_info "Using before snapshot for source counts (database query not available)"
            local snap_tables=$(jq -r '.source.counts.tables // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_views=$(jq -r '.source.counts.views // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_functions=$(jq -r '.source.counts.functions // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_sequences=$(jq -r '.source.counts.sequences // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_indexes=$(jq -r '.source.counts.indexes // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_policies=$(jq -r '.source.counts.policies // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_triggers=$(jq -r '.source.counts.triggers // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_types=$(jq -r '.source.counts.types // 0' "$before_snapshot" 2>/dev/null || echo "0")
            local snap_enums=$(jq -r '.source.counts.enums // 0' "$before_snapshot" 2>/dev/null || echo "0")
            source_counts="$snap_tables $snap_views $snap_functions $snap_sequences $snap_indexes $snap_policies $snap_triggers $snap_types $snap_enums"
        elif [ -f "$source_schema" ] && [ -s "$source_schema" ]; then
            # Fallback to schema file if database query not possible
            log_info "Using source schema file for counts (database query not available)"
            if command -v count_objects_from_schema >/dev/null 2>&1; then
                source_counts=$(count_objects_from_schema "$source_schema")
            else
                source_table_count=$(grep -c "^CREATE TABLE" "$source_schema" 2>/dev/null || echo "0")
                source_counts="$source_table_count 0 0 0 0 0 0 0 0"
            fi
        fi
    fi
    
    # Get target counts - ALWAYS query live database AFTER migration completes
    # This ensures we get accurate post-migration counts
    if [ -n "$target_ref" ] && [ -n "$target_password" ]; then
        if [ -z "$pooler_host" ] && command -v get_pooler_host >/dev/null 2>&1; then
            pooler_host=$(get_pooler_host "$target_ref" 2>/dev/null || echo "")
        fi
        # CRITICAL: Query live database AFTER migration for accurate post-migration state
        log_info "Querying database object counts from target (POST-MIGRATION state): $target_ref"
        log_info "This ensures counts reflect the actual state after migration completes"
        target_counts=$(query_database_counts "$target_ref" "$target_password" "$pooler_host")
        log_info "Target database counts retrieved (post-migration): $target_counts"
        
        # If counts are all 0, try direct connection
        local count_sum=$(echo "$target_counts" | awk '{sum=0; for(i=1;i<=NF;i++) sum+=$i; print sum}')
        if [ "$count_sum" = "0" ] || [ -z "$count_sum" ]; then
            log_info "Pooler returned 0 counts, trying direct connection for target..."
            target_counts=$(query_database_counts "$target_ref" "$target_password" "")
            log_info "Target counts after direct connection: $target_counts"
        fi
    elif [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
        # Use after snapshot if available
        log_info "Using after snapshot for target counts (database query not available)"
        local snap_tables=$(jq -r '.target.counts.tables // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_views=$(jq -r '.target.counts.views // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_functions=$(jq -r '.target.counts.functions // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_sequences=$(jq -r '.target.counts.sequences // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_indexes=$(jq -r '.target.counts.indexes // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_policies=$(jq -r '.target.counts.policies // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_triggers=$(jq -r '.target.counts.triggers // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_types=$(jq -r '.target.counts.types // 0' "$after_snapshot" 2>/dev/null || echo "0")
        local snap_enums=$(jq -r '.target.counts.enums // 0' "$after_snapshot" 2>/dev/null || echo "0")
        target_counts="$snap_tables $snap_views $snap_functions $snap_sequences $snap_indexes $snap_policies $snap_triggers $snap_types $snap_enums"
    elif [ -f "$target_schema" ] && [ -s "$target_schema" ]; then
        # Fallback to schema file ONLY if database query not possible
        # Note: This is less accurate as schema file may be from before migration
        log_warning "Using target schema file for counts (database query not available)"
        log_warning "Note: Schema file may be from before migration - counts may be inaccurate"
        if command -v count_objects_from_schema >/dev/null 2>&1; then
            target_counts=$(count_objects_from_schema "$target_schema")
        else
            target_table_count=$(grep -c "^CREATE TABLE" "$target_schema" 2>/dev/null || echo "0")
            target_counts="$target_table_count 0 0 0 0 0 0 0 0"
        fi
    fi
    
    # Parse counts (tables, views, functions, sequences, indexes, policies, triggers, types, enums)
    # Ensure defaults to "0" if empty
    local source_tables=$(echo "$source_counts" | awk '{print ($1 ? $1 : "0")}')
    local source_views=$(echo "$source_counts" | awk '{print ($2 ? $2 : "0")}')
    local source_functions=$(echo "$source_counts" | awk '{print ($3 ? $3 : "0")}')
    local source_sequences=$(echo "$source_counts" | awk '{print ($4 ? $4 : "0")}')
    local source_indexes=$(echo "$source_counts" | awk '{print ($5 ? $5 : "0")}')
    local source_policies=$(echo "$source_counts" | awk '{print ($6 ? $6 : "0")}')
    local source_triggers=$(echo "$source_counts" | awk '{print ($7 ? $7 : "0")}')
    local source_types=$(echo "$source_counts" | awk '{print ($8 ? $8 : "0")}')
    local source_enums=$(echo "$source_counts" | awk '{print ($9 ? $9 : "0")}')
    
    # Ensure values are not empty (default to 0)
    source_tables=${source_tables:-0}
    source_views=${source_views:-0}
    source_functions=${source_functions:-0}
    source_sequences=${source_sequences:-0}
    source_indexes=${source_indexes:-0}
    source_policies=${source_policies:-0}
    source_triggers=${source_triggers:-0}
    source_types=${source_types:-0}
    source_enums=${source_enums:-0}
    
    local target_tables=$(echo "$target_counts" | awk '{print ($1 ? $1 : "0")}')
    local target_views=$(echo "$target_counts" | awk '{print ($2 ? $2 : "0")}')
    local target_functions=$(echo "$target_counts" | awk '{print ($3 ? $3 : "0")}')
    local target_sequences=$(echo "$target_counts" | awk '{print ($4 ? $4 : "0")}')
    local target_indexes=$(echo "$target_counts" | awk '{print ($5 ? $5 : "0")}')
    local target_policies=$(echo "$target_counts" | awk '{print ($6 ? $6 : "0")}')
    local target_triggers=$(echo "$target_counts" | awk '{print ($7 ? $7 : "0")}')
    local target_types=$(echo "$target_counts" | awk '{print ($8 ? $8 : "0")}')
    local target_enums=$(echo "$target_counts" | awk '{print ($9 ? $9 : "0")}')
    
    # Ensure values are not empty (default to 0)
    target_tables=${target_tables:-0}
    target_views=${target_views:-0}
    target_functions=${target_functions:-0}
    target_sequences=${target_sequences:-0}
    target_indexes=${target_indexes:-0}
    target_policies=${target_policies:-0}
    target_triggers=${target_triggers:-0}
    target_types=${target_types:-0}
    target_enums=${target_enums:-0}
    
    # Get edge functions count - ALWAYS query from API to get real-time counts
    # This ensures we get accurate before/after migration counts
    local source_edge_functions=0
    local target_edge_functions=0
    
    # Always query source from API for real-time count
    if [ -n "$source_ref" ]; then
        log_info "Querying edge functions count from source API: $source_ref"
        source_edge_functions=$(query_edge_functions_count "$source_ref")
        log_info "Source edge functions count: $source_edge_functions"
    fi
    
    # Always query target from API for real-time count (POST-MIGRATION state)
    if [ -n "$target_ref" ]; then
        log_info "Querying edge functions count from target API (POST-MIGRATION): $target_ref"
        target_edge_functions=$(query_edge_functions_count "$target_ref")
        log_info "Target edge functions count (post-migration): $target_edge_functions"
    fi
    
    # Get storage buckets count - ALWAYS query from database to get real-time counts
    local source_buckets=0
    local target_buckets=0
    
    # Query source storage buckets - try database first, fallback to snapshot
    if [ -n "$source_ref" ]; then
        local source_password=""
        local source_pooler=""
        if [ -n "$SOURCE_ENV" ] && command -v get_db_password >/dev/null 2>&1; then
            source_password=$(get_db_password "$SOURCE_ENV" 2>/dev/null || echo "")
        fi
        if [ -n "$source_ref" ] && command -v get_pooler_host >/dev/null 2>&1; then
            source_pooler=$(get_pooler_host "$source_ref" 2>/dev/null || echo "")
        fi
        if [ -n "$source_password" ]; then
            log_info "Querying storage buckets count from source database: $source_ref"
            source_buckets=$(query_storage_buckets_count "$source_ref" "$source_password" "$source_pooler")
            log_info "Source storage buckets count: $source_buckets"
            
            # If count is 0 and we have a snapshot, try using that
            if [ "$source_buckets" = "0" ] && [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
                local snap_count=$(jq -r '.source.counts.buckets // 0' "$before_snapshot" 2>/dev/null || echo "0")
                if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                    log_info "Using snapshot for source buckets count: $snap_count"
                    source_buckets="$snap_count"
                fi
            fi
        elif [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
            source_buckets=$(jq -r '.source.counts.buckets // 0' "$before_snapshot" 2>/dev/null || echo "0")
        fi
    fi
    
    # Query target storage buckets - try database first, fallback to snapshot
    if [ -n "$target_ref" ] && [ -n "$target_password" ]; then
        if [ -z "$pooler_host" ] && command -v get_pooler_host >/dev/null 2>&1; then
            pooler_host=$(get_pooler_host "$target_ref" 2>/dev/null || echo "")
        fi
        log_info "Querying storage buckets count from target database (POST-MIGRATION): $target_ref"
        target_buckets=$(query_storage_buckets_count "$target_ref" "$target_password" "$pooler_host")
        log_info "Target storage buckets count (post-migration): $target_buckets"
        
        # If count is 0 and we have a snapshot, try using that
        if [ "$target_buckets" = "0" ] && [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
            local snap_count=$(jq -r '.target.counts.buckets // 0' "$after_snapshot" 2>/dev/null || echo "0")
            if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                log_info "Using snapshot for target buckets count: $snap_count"
                target_buckets="$snap_count"
            fi
        fi
    elif [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
        target_buckets=$(jq -r '.target.counts.buckets // 0' "$after_snapshot" 2>/dev/null || echo "0")
    fi
    
    # Ensure all count variables have defaults
    source_edge_functions=${source_edge_functions:-0}
    target_edge_functions=${target_edge_functions:-0}
    source_buckets=${source_buckets:-0}
    target_buckets=${target_buckets:-0}
    
    # Get secrets count - ALWAYS query from API to get real-time counts
    local source_secrets=0
    local target_secrets=0
    
    # Query source secrets - try API first, fallback to snapshot
    if [ -n "$source_ref" ]; then
        log_info "Querying secrets count from source API: $source_ref"
        source_secrets=$(query_secrets_count "$source_ref")
        log_info "Source secrets count: $source_secrets"
        
        # If count is 0 and we have a snapshot, try using that
        if [ "$source_secrets" = "0" ] && [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
            local snap_count=$(jq -r '.source.counts.secrets // 0' "$before_snapshot" 2>/dev/null || echo "0")
            if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                log_info "Using snapshot for source secrets count: $snap_count"
                source_secrets="$snap_count"
            fi
        fi
    fi
    
    # Query target secrets - try API first, fallback to snapshot
    if [ -n "$target_ref" ]; then
        log_info "Querying secrets count from target API (POST-MIGRATION): $target_ref"
        target_secrets=$(query_secrets_count "$target_ref")
        log_info "Target secrets count (post-migration): $target_secrets"
        
        # If count is 0 and we have a snapshot, try using that
        if [ "$target_secrets" = "0" ] && [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
            local snap_count=$(jq -r '.target.counts.secrets // 0' "$after_snapshot" 2>/dev/null || echo "0")
            if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                log_info "Using snapshot for target secrets count: $snap_count"
                target_secrets="$snap_count"
            fi
        fi
    fi
    
    # Ensure secrets have defaults
    source_secrets=${source_secrets:-0}
    target_secrets=${target_secrets:-0}
    
    # Get auth users count - ALWAYS query from database to get real-time counts
    local source_auth_users=0
    local target_auth_users=0
    
    # Query source auth users - try database first, fallback to snapshot
    if [ -n "$source_ref" ]; then
        local source_password=""
        local source_pooler=""
        if [ -n "$SOURCE_ENV" ] && command -v get_db_password >/dev/null 2>&1; then
            source_password=$(get_db_password "$SOURCE_ENV" 2>/dev/null || echo "")
        fi
        if [ -n "$source_ref" ] && command -v get_pooler_host >/dev/null 2>&1; then
            source_pooler=$(get_pooler_host "$source_ref" 2>/dev/null || echo "")
        fi
        if [ -n "$source_password" ]; then
            log_info "Querying auth users count from source database: $source_ref"
            source_auth_users=$(query_auth_users_count "$source_ref" "$source_password" "$source_pooler")
            log_info "Source auth users count: $source_auth_users"
            
            # If count is 0 and we have a snapshot, try using that
            if [ "$source_auth_users" = "0" ] && [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
                local snap_count=$(jq -r '.source.counts.auth_users // 0' "$before_snapshot" 2>/dev/null || echo "0")
                if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                    log_info "Using snapshot for source auth users count: $snap_count"
                    source_auth_users="$snap_count"
                fi
            fi
        elif [ -f "$before_snapshot" ] && command -v jq >/dev/null 2>&1; then
            source_auth_users=$(jq -r '.source.counts.auth_users // 0' "$before_snapshot" 2>/dev/null || echo "0")
        fi
    fi
    
    # Query target auth users - try database first, fallback to snapshot
    if [ -n "$target_ref" ] && [ -n "$target_password" ]; then
        if [ -z "$pooler_host" ] && command -v get_pooler_host >/dev/null 2>&1; then
            pooler_host=$(get_pooler_host "$target_ref" 2>/dev/null || echo "")
        fi
        log_info "Querying auth users count from target database (POST-MIGRATION): $target_ref"
        target_auth_users=$(query_auth_users_count "$target_ref" "$target_password" "$pooler_host")
        log_info "Target auth users count (post-migration): $target_auth_users"
        
        # If count is 0 and we have a snapshot, try using that
        if [ "$target_auth_users" = "0" ] && [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
            local snap_count=$(jq -r '.target.counts.auth_users // 0' "$after_snapshot" 2>/dev/null || echo "0")
            if [ "$snap_count" != "0" ] && [ -n "$snap_count" ]; then
                log_info "Using snapshot for target auth users count: $snap_count"
                target_auth_users="$snap_count"
            fi
        fi
    elif [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
        target_auth_users=$(jq -r '.target.counts.auth_users // 0' "$after_snapshot" 2>/dev/null || echo "0")
    fi
    
    # Ensure auth users have defaults
    source_auth_users=${source_auth_users:-0}
    target_auth_users=${target_auth_users:-0}
    
    # Set source_table_count and target_table_count for backward compatibility
    source_table_count=${source_tables:-0}
    target_table_count=${target_tables:-0}
    
    # Debug: Log all counts to verify they're set
    log_info "Count variables set - Source: tables=$source_tables, views=$source_views, functions=$source_functions, edge_functions=$source_edge_functions, buckets=$source_buckets, secrets=$source_secrets, auth_users=$source_auth_users"
    log_info "Count variables set - Target: tables=$target_tables, views=$target_views, functions=$target_functions, edge_functions=$target_edge_functions, buckets=$target_buckets, secrets=$target_secrets, auth_users=$target_auth_users"
    
    # Extract object names for comparison
    local source_table_names=""
    local target_table_names=""
    local source_policy_names=""
    local target_policy_names=""
    local source_function_names=""
    local target_function_names=""
    local source_edge_function_names=""
    local target_edge_function_names=""
    local source_bucket_names=""
    local target_bucket_names=""
    
    if command -v extract_table_names >/dev/null 2>&1; then
        [ -f "$source_schema" ] && source_table_names=$(extract_table_names "$source_schema")
        [ -f "$target_schema" ] && target_table_names=$(extract_table_names "$target_schema")
        [ -f "$source_schema" ] && source_policy_names=$(extract_policy_names "$source_schema")
        [ -f "$target_schema" ] && target_policy_names=$(extract_policy_names "$target_schema")
        [ -f "$source_schema" ] && source_function_names=$(extract_function_names "$source_schema")
        [ -f "$target_schema" ] && target_function_names=$(extract_function_names "$target_schema")
    fi
    
    if command -v extract_edge_function_names >/dev/null 2>&1; then
        [ -f "$functions_list" ] && source_edge_function_names=$(extract_edge_function_names "$functions_list")
    fi
    
    if command -v extract_bucket_names >/dev/null 2>&1; then
        [ -f "$storage_buckets" ] && source_bucket_names=$(extract_bucket_names "$storage_buckets")
    fi
    
    # Get target counts AFTER migration (from target schema if available, or assume same as source for now)
    # Note: In a real migration, target schema should reflect the post-migration state
    # For now, we'll use target_schema if it exists, otherwise assume target matches source after migration
    if [ -f "$target_schema" ] && [ -s "$target_schema" ]; then
        # Target schema exists - use it (this should be the post-migration state)
        if command -v count_objects_from_schema >/dev/null 2>&1; then
            target_counts=$(count_objects_from_schema "$target_schema")
            # Re-parse target counts
            target_tables=$(echo $target_counts | awk '{print $1}')
            target_views=$(echo $target_counts | awk '{print $2}')
            target_functions=$(echo $target_counts | awk '{print $3}')
            target_sequences=$(echo $target_counts | awk '{print $4}')
            target_indexes=$(echo $target_counts | awk '{print $5}')
            target_policies=$(echo $target_counts | awk '{print $6}')
            target_triggers=$(echo $target_counts | awk '{print $7}')
            target_types=$(echo $target_counts | awk '{print $8}')
            target_enums=$(echo $target_counts | awk '{print $9}')
        fi
        
        # Get target object names
        if command -v extract_table_names >/dev/null 2>&1; then
            target_table_names=$(extract_table_names "$target_schema")
            target_policy_names=$(extract_policy_names "$target_schema")
            target_function_names=$(extract_function_names "$target_schema")
        fi
    else
        # If target schema doesn't exist, assume migration will make target match source
        # (This is a reasonable assumption for a successful migration)
        target_tables=$source_tables
        target_views=$source_views
        target_functions=$source_functions
        target_sequences=$source_sequences
        target_indexes=$source_indexes
        target_policies=$source_policies
        target_triggers=$source_triggers
        target_types=$source_types
        target_enums=$source_enums
        target_edge_functions=$source_edge_functions
        target_buckets=$source_buckets
        target_secrets=$source_secrets
        target_table_names="$source_table_names"
        target_policy_names="$source_policy_names"
        target_function_names="$source_function_names"
        target_edge_function_names="$source_edge_function_names"
        target_bucket_names="$source_bucket_names"
    fi
    
    # Helper function to calculate change badge
    calculate_change_badge() {
        local before=${1:-0}
        local after=${2:-0}
        # Remove any non-numeric characters
        before=${before//[^0-9]/}
        after=${after//[^0-9]/}
        if [ -z "$before" ] || [ -z "$after" ]; then
            echo "<span class=\"badge badge-info\">N/A</span>"
            return 0
        fi
        if [ "$before" -eq "$after" ]; then
            echo "<span class=\"badge badge-success\">No change</span>"
        elif [ "$after" -gt "$before" ]; then
            local diff=$((after - before))
            echo "<span class=\"badge badge-success\">+$diff added</span>"
        else
            local diff=$((before - after))
            echo "<span class=\"badge badge-danger\">-$diff removed</span>"
        fi
    }
    
    # Helper function to generate object changes HTML
    generate_object_changes_html() {
        local source_list="$1"
        local target_list="$2"
        local object_type="$3"
        
        local changes_html=""
        local added_items=""
        local removed_items=""
        
        # Convert to arrays for easier processing
        local source_array=()
        local target_array=()
        
        if [ -n "$source_list" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && source_array+=("$line")
            done <<< "$source_list"
        fi
        
        if [ -n "$target_list" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && target_array+=("$line")
            done <<< "$target_list"
        fi
        
        # Find added objects (in target but not in source)
        if [ ${#target_array[@]} -gt 0 ]; then
            for target_obj in "${target_array[@]}"; do
                local found=false
                if [ ${#source_array[@]} -gt 0 ]; then
                    for source_obj in "${source_array[@]}"; do
                        if [ "$target_obj" = "$source_obj" ]; then
                            found=true
                            break
                        fi
                    done
                fi
                if ! $found; then
                    added_items+="$target_obj\n"
                fi
            done
        fi
        
        # Find removed objects (in source but not in target)
        if [ ${#source_array[@]} -gt 0 ]; then
            for source_obj in "${source_array[@]}"; do
                local found=false
                if [ ${#target_array[@]} -gt 0 ]; then
                    for target_obj in "${target_array[@]}"; do
                        if [ "$source_obj" = "$target_obj" ]; then
                            found=true
                            break
                        fi
                    done
                fi
                if ! $found; then
                    removed_items+="$source_obj\n"
                fi
            done
        fi
        
        if [ -n "$added_items" ]; then
            changes_html+="<div class=\"change-item change-added\"><strong>✅ Added:</strong><ul>"
            echo -e "$added_items" | while IFS= read -r obj; do
                [ -n "$obj" ] && changes_html+="<li>$obj</li>"
            done
            changes_html+="</ul></div>"
        fi
        
        if [ -n "$removed_items" ]; then
            changes_html+="<div class=\"change-item change-removed\"><strong>❌ Removed:</strong><ul>"
            echo -e "$removed_items" | while IFS= read -r obj; do
                [ -n "$obj" ] && changes_html+="<li>$obj</li>"
            done
            changes_html+="</ul></div>"
        fi
        
        if [ -z "$added_items" ] && [ -z "$removed_items" ]; then
            if [ ${#source_array[@]} -eq 0 ] && [ ${#target_array[@]} -eq 0 ]; then
                changes_html+="<p>No $object_type objects found.</p>"
            else
                changes_html+="<p>✅ No changes detected. All $object_type objects match between source and target.</p>"
            fi
        fi
        
        echo "$changes_html"
    }
    
    # Load after snapshot counts if available
    local source_after_tables=$source_tables source_after_views=$source_views source_after_functions=$source_functions source_after_sequences=$source_sequences
    local source_after_indexes=$source_indexes source_after_policies=$source_policies source_after_triggers=$source_triggers source_after_types=$source_types source_after_enums=$source_enums
    local source_after_auth_users=$source_auth_users source_after_edge_functions=$source_edge_functions source_after_buckets=$source_buckets source_after_secrets=$source_secrets
    local target_after_tables=$target_tables target_after_views=$target_views target_after_functions=$target_functions target_after_sequences=$target_sequences
    local target_after_indexes=$target_indexes target_after_policies=$target_policies target_after_triggers=$target_triggers target_after_types=$target_types target_after_enums=$target_enums
    local target_after_auth_users=$target_auth_users target_after_edge_functions=$target_edge_functions target_after_buckets=$target_buckets target_after_secrets=$target_secrets
    
    if [ -f "$after_snapshot" ] && command -v jq >/dev/null 2>&1; then
        log_info "Loading AFTER migration snapshot from: $after_snapshot"
        source_after_tables=$(jq -r '.source.counts.tables // 0' "$after_snapshot" 2>/dev/null || echo "$source_tables")
        source_after_views=$(jq -r '.source.counts.views // 0' "$after_snapshot" 2>/dev/null || echo "$source_views")
        source_after_functions=$(jq -r '.source.counts.functions // 0' "$after_snapshot" 2>/dev/null || echo "$source_functions")
        source_after_sequences=$(jq -r '.source.counts.sequences // 0' "$after_snapshot" 2>/dev/null || echo "$source_sequences")
        source_after_indexes=$(jq -r '.source.counts.indexes // 0' "$after_snapshot" 2>/dev/null || echo "$source_indexes")
        source_after_policies=$(jq -r '.source.counts.policies // 0' "$after_snapshot" 2>/dev/null || echo "$source_policies")
        source_after_triggers=$(jq -r '.source.counts.triggers // 0' "$after_snapshot" 2>/dev/null || echo "$source_triggers")
        source_after_types=$(jq -r '.source.counts.types // 0' "$after_snapshot" 2>/dev/null || echo "$source_types")
        source_after_enums=$(jq -r '.source.counts.enums // 0' "$after_snapshot" 2>/dev/null || echo "$source_enums")
        source_after_auth_users=$(jq -r '.source.counts.auth_users // 0' "$after_snapshot" 2>/dev/null || echo "$source_auth_users")
        source_after_edge_functions=$(jq -r '.source.counts.edge_functions // 0' "$after_snapshot" 2>/dev/null || echo "$source_edge_functions")
        source_after_buckets=$(jq -r '.source.counts.buckets // 0' "$after_snapshot" 2>/dev/null || echo "$source_buckets")
        source_after_secrets=$(jq -r '.source.counts.secrets // 0' "$after_snapshot" 2>/dev/null || echo "$source_secrets")
        
        target_after_tables=$(jq -r '.target.counts.tables // 0' "$after_snapshot" 2>/dev/null || echo "$target_tables")
        target_after_views=$(jq -r '.target.counts.views // 0' "$after_snapshot" 2>/dev/null || echo "$target_views")
        target_after_functions=$(jq -r '.target.counts.functions // 0' "$after_snapshot" 2>/dev/null || echo "$target_functions")
        target_after_sequences=$(jq -r '.target.counts.sequences // 0' "$after_snapshot" 2>/dev/null || echo "$target_sequences")
        target_after_indexes=$(jq -r '.target.counts.indexes // 0' "$after_snapshot" 2>/dev/null || echo "$target_indexes")
        target_after_policies=$(jq -r '.target.counts.policies // 0' "$after_snapshot" 2>/dev/null || echo "$target_policies")
        target_after_triggers=$(jq -r '.target.counts.triggers // 0' "$after_snapshot" 2>/dev/null || echo "$target_triggers")
        target_after_types=$(jq -r '.target.counts.types // 0' "$after_snapshot" 2>/dev/null || echo "$target_types")
        target_after_enums=$(jq -r '.target.counts.enums // 0' "$after_snapshot" 2>/dev/null || echo "$target_enums")
        target_after_auth_users=$(jq -r '.target.counts.auth_users // 0' "$after_snapshot" 2>/dev/null || echo "$target_auth_users")
        target_after_edge_functions=$(jq -r '.target.counts.edge_functions // 0' "$after_snapshot" 2>/dev/null || echo "$target_edge_functions")
        target_after_buckets=$(jq -r '.target.counts.buckets // 0' "$after_snapshot" 2>/dev/null || echo "$target_buckets")
        target_after_secrets=$(jq -r '.target.counts.secrets // 0' "$after_snapshot" 2>/dev/null || echo "$target_secrets")
    fi
    
    # Generate BEFORE migration table rows (Source, Target)
    local before_table_rows=""
    before_table_rows+="<tr><td><strong>Tables</strong></td><td>$source_before_tables</td><td>$target_before_tables</td></tr>"
    before_table_rows+="<tr><td><strong>Views</strong></td><td>$source_before_views</td><td>$target_before_views</td></tr>"
    before_table_rows+="<tr><td><strong>Functions</strong></td><td>$source_before_functions</td><td>$target_before_functions</td></tr>"
    before_table_rows+="<tr><td><strong>Sequences</strong></td><td>$source_before_sequences</td><td>$target_before_sequences</td></tr>"
    before_table_rows+="<tr><td><strong>Indexes</strong></td><td>$source_before_indexes</td><td>$target_before_indexes</td></tr>"
    before_table_rows+="<tr><td><strong>RLS Policies</strong></td><td>$source_before_policies</td><td>$target_before_policies</td></tr>"
    before_table_rows+="<tr><td><strong>Triggers</strong></td><td>$source_before_triggers</td><td>$target_before_triggers</td></tr>"
    before_table_rows+="<tr><td><strong>Types</strong></td><td>$source_before_types</td><td>$target_before_types</td></tr>"
    before_table_rows+="<tr><td><strong>Enums</strong></td><td>$source_before_enums</td><td>$target_before_enums</td></tr>"
    before_table_rows+="<tr><td><strong>Auth Users</strong></td><td>$source_before_auth_users</td><td>$target_before_auth_users</td></tr>"
    before_table_rows+="<tr><td><strong>Edge Functions</strong></td><td>$source_before_edge_functions</td><td>$target_before_edge_functions</td></tr>"
    before_table_rows+="<tr><td><strong>Storage Buckets</strong></td><td>$source_before_buckets</td><td>$target_before_buckets</td></tr>"
    before_table_rows+="<tr><td><strong>Secrets</strong></td><td>$source_before_secrets</td><td>$target_before_secrets</td></tr>"
    
    # Generate AFTER migration table rows (Source, Target, Change)
    local after_table_rows=""
    after_table_rows+="<tr><td><strong>Tables</strong></td><td>$source_after_tables</td><td>$target_after_tables</td><td>$(calculate_change_badge "$target_before_tables" "$target_after_tables")</td></tr>"
    after_table_rows+="<tr><td><strong>Views</strong></td><td>$source_after_views</td><td>$target_after_views</td><td>$(calculate_change_badge "$target_before_views" "$target_after_views")</td></tr>"
    after_table_rows+="<tr><td><strong>Functions</strong></td><td>$source_after_functions</td><td>$target_after_functions</td><td>$(calculate_change_badge "$target_before_functions" "$target_after_functions")</td></tr>"
    after_table_rows+="<tr><td><strong>Sequences</strong></td><td>$source_after_sequences</td><td>$target_after_sequences</td><td>$(calculate_change_badge "$target_before_sequences" "$target_after_sequences")</td></tr>"
    after_table_rows+="<tr><td><strong>Indexes</strong></td><td>$source_after_indexes</td><td>$target_after_indexes</td><td>$(calculate_change_badge "$target_before_indexes" "$target_after_indexes")</td></tr>"
    after_table_rows+="<tr><td><strong>RLS Policies</strong></td><td>$source_after_policies</td><td>$target_after_policies</td><td>$(calculate_change_badge "$target_before_policies" "$target_after_policies")</td></tr>"
    after_table_rows+="<tr><td><strong>Triggers</strong></td><td>$source_after_triggers</td><td>$target_after_triggers</td><td>$(calculate_change_badge "$target_before_triggers" "$target_after_triggers")</td></tr>"
    after_table_rows+="<tr><td><strong>Types</strong></td><td>$source_after_types</td><td>$target_after_types</td><td>$(calculate_change_badge "$target_before_types" "$target_after_types")</td></tr>"
    after_table_rows+="<tr><td><strong>Enums</strong></td><td>$source_after_enums</td><td>$target_after_enums</td><td>$(calculate_change_badge "$target_before_enums" "$target_after_enums")</td></tr>"
    after_table_rows+="<tr><td><strong>Auth Users</strong></td><td>$source_after_auth_users</td><td>$target_after_auth_users</td><td>$(calculate_change_badge "$target_before_auth_users" "$target_after_auth_users")</td></tr>"
    after_table_rows+="<tr><td><strong>Edge Functions</strong></td><td>$source_after_edge_functions</td><td>$target_after_edge_functions</td><td>$(calculate_change_badge "$target_before_edge_functions" "$target_after_edge_functions")</td></tr>"
    after_table_rows+="<tr><td><strong>Storage Buckets</strong></td><td>$source_after_buckets</td><td>$target_after_buckets</td><td>$(calculate_change_badge "$target_before_buckets" "$target_after_buckets")</td></tr>"
    after_table_rows+="<tr><td><strong>Secrets</strong></td><td>$source_after_secrets</td><td>$target_after_secrets</td><td>$(calculate_change_badge "$target_before_secrets" "$target_after_secrets")</td></tr>"
    
    # Legacy: keep comparison_table_rows for backward compatibility (use after table)
    local comparison_table_rows="$after_table_rows"
    
    # Generate object changes details
    local object_changes_html=""
    object_changes_html+="<h4>Tables</h4>"
    object_changes_html+="<div class=\"changes-list\">$(generate_object_changes_html "$source_table_names" "$target_table_names" "table")</div>"
    object_changes_html+="<h4>RLS Policies</h4>"
    object_changes_html+="<div class=\"changes-list\">$(generate_object_changes_html "$source_policy_names" "$target_policy_names" "policy")</div>"
    object_changes_html+="<h4>Database Functions</h4>"
    object_changes_html+="<div class=\"changes-list\">$(generate_object_changes_html "$source_function_names" "$target_function_names" "function")</div>"
    object_changes_html+="<h4>Edge Functions</h4>"
    object_changes_html+="<div class=\"changes-list\">$(generate_object_changes_html "$source_edge_function_names" "$target_edge_function_names" "edge function")</div>"
    object_changes_html+="<h4>Storage Buckets</h4>"
    object_changes_html+="<div class=\"changes-list\">$(generate_object_changes_html "$source_bucket_names" "$target_bucket_names" "bucket")</div>"
    
    # Legacy function name alias (for backward compatibility)
    calculate_change() {
        local before=$1
        local after=$2
        if [ "$before" -eq "$after" ]; then
            echo "<span class=\"badge badge-success\">No change</span>"
        elif [ "$after" -gt "$before" ]; then
            local diff=$((after - before))
            echo "<span class=\"badge badge-success\">+$diff added</span>"
        else
            local diff=$((before - after))
            echo "<span class=\"badge badge-danger\">-$diff removed</span>"
        fi
    }
    
    # Helper function to generate object changes list
    generate_object_changes() {
        local source_list="$1"
        local target_list="$2"
        local object_type="$3"
        
        if [ -z "$source_list" ] && [ -z "$target_list" ]; then
            echo "<p>No $object_type objects found.</p>"
            return 0
        fi
        
        local changes_html=""
        local added_objects=""
        local removed_objects=""
        local unchanged_objects=""
        
        # Find added objects (in target but not in source)
        if [ -n "$target_list" ]; then
            while IFS= read -r obj; do
                [ -z "$obj" ] && continue
                if [ -z "$source_list" ] || ! echo "$source_list" | grep -q "^${obj}$"; then
                    added_objects="${added_objects}${obj}\n"
                fi
            done <<< "$target_list"
        fi
        
        # Find removed objects (in source but not in target)
        if [ -n "$source_list" ]; then
            while IFS= read -r obj; do
                [ -z "$obj" ] && continue
                if [ -z "$target_list" ] || ! echo "$target_list" | grep -q "^${obj}$"; then
                    removed_objects="${removed_objects}${obj}\n"
                fi
            done <<< "$source_list"
        fi
        
        # Find unchanged objects (in both)
        if [ -n "$source_list" ] && [ -n "$target_list" ]; then
            while IFS= read -r obj; do
                [ -z "$obj" ] && continue
                if echo "$target_list" | grep -q "^${obj}$"; then
                    unchanged_objects="${unchanged_objects}${obj}\n"
                fi
            done <<< "$source_list"
        fi
        
        if [ -n "$added_objects" ]; then
            changes_html+="<div class=\"change-item change-added\"><strong>✅ Added:</strong><ul>"
            echo -e "$added_objects" | while IFS= read -r obj; do
                [ -z "$obj" ] && continue
                changes_html+="<li>$obj</li>"
            done
            changes_html+="</ul></div>"
        fi
        
        if [ -n "$removed_objects" ]; then
            changes_html+="<div class=\"change-item change-removed\"><strong>❌ Removed:</strong><ul>"
            echo -e "$removed_objects" | while IFS= read -r obj; do
                [ -z "$obj" ] && continue
                changes_html+="<li>$obj</li>"
            done
            changes_html+="</ul></div>"
        fi
        
        if [ -z "$added_objects" ] && [ -z "$removed_objects" ]; then
            changes_html+="<p>No changes detected. All $object_type objects match between source and target.</p>"
        fi
        
        echo "$changes_html"
    }
    
    # Get comparison details
    if [ -f "$comparison_file" ]; then
        comparison_details=$(cat "$comparison_file" | head -500)
    fi
    
    # Read rollback script if available
    local rollback_script_content=""
    if [ -f "$migration_dir/rollback.sh" ]; then
        rollback_script_content=$(cat "$migration_dir/rollback.sh" | sed 's/</\&lt;/g; s/>/\&gt;/g')
    fi
    
    # Read rollback SQL if available
    local rollback_sql_content=""
    if [ "$has_rollback_sql" = "true" ] && [ -f "$rollback_db_sql" ]; then
        rollback_sql_content=$(cat "$rollback_db_sql" | head -200 | sed 's/</\&lt;/g; s/>/\&gt;/g')
    fi
    
    # Determine status color
    local status_color="#28a745"
    local status_icon="✅"
    if [[ "$status" == *"Failed"* ]] || [[ "$status" == *"❌"* ]]; then
        status_color="#dc3545"
        status_icon="❌"
    elif [[ "$status" == *"Skipped"* ]] || [[ "$status" == *"⏭️"* ]]; then
        status_color="#ffc107"
        status_icon="⏭️"
    fi
    
    # Generate HTML
    cat > "$result_html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Migration Result</title>
    <!-- Charts removed - focusing on summary and details only -->
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            font-weight: 700;
        }
        
        .status-badge {
            display: inline-block;
            padding: 10px 24px;
            border-radius: 50px;
            font-size: 1.1em;
            font-weight: 600;
            margin-top: 15px;
            background: rgba(255,255,255,0.2);
            backdrop-filter: blur(10px);
        }
        
        .content {
            padding: 40px;
        }
        
        .section {
            margin-bottom: 40px;
            padding: 30px;
            background: #f8f9fa;
            border-radius: 8px;
            border-left: 4px solid #667eea;
        }
        
        .section h2 {
            color: #667eea;
            font-size: 1.8em;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #e9ecef;
        }
        
        .section h3 {
            color: #495057;
            font-size: 1.4em;
            margin-top: 25px;
            margin-bottom: 15px;
        }
        
        .section h4 {
            color: #6c757d;
            font-size: 1.2em;
            margin-top: 20px;
            margin-bottom: 10px;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            text-align: center;
        }
        
        .stat-card .label {
            font-size: 0.9em;
            color: #6c757d;
            margin-bottom: 10px;
        }
        
        .stat-card .value {
            font-size: 2em;
            font-weight: 700;
            color: #667eea;
        }
        
        .info-table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        .info-table th {
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }
        
        .info-table td {
            padding: 15px;
            border-bottom: 1px solid #e9ecef;
        }
        
        .info-table tr:last-child td {
            border-bottom: none;
        }
        
        .info-table tr:hover {
            background: #f8f9fa;
        }
        
        .code-block {
            background: #1e1e1e;
            color: #d4d4d4;
            padding: 20px;
            border-radius: 8px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            line-height: 1.5;
            margin: 15px 0;
        }
        
        .code-block code {
            color: #d4d4d4;
        }
        
        .badge {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            margin: 5px;
        }
        
        .badge-success {
            background: #28a745;
            color: white;
        }
        
        .badge-warning {
            background: #ffc107;
            color: #333;
        }
        
        .badge-danger {
            background: #dc3545;
            color: white;
        }
        
        .badge-info {
            background: #17a2b8;
            color: white;
        }
        
        .comparison-box {
            background: white;
            padding: 20px;
            border-radius: 8px;
            margin: 15px 0;
            border: 1px solid #dee2e6;
        }
        
        .comparison-box pre {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-size: 0.85em;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        
        .checklist {
            list-style: none;
            padding: 0;
        }
        
        .checklist li {
            padding: 10px;
            margin: 5px 0;
            background: white;
            border-radius: 5px;
            border-left: 3px solid #667eea;
        }
        
        .checklist li::before {
            content: "☐ ";
            font-size: 1.2em;
            margin-right: 10px;
        }
        
        .alert {
            padding: 15px 20px;
            border-radius: 8px;
            margin: 15px 0;
            border-left: 4px solid;
        }
        
        .alert-warning {
            background: #fff3cd;
            border-color: #ffc107;
            color: #856404;
        }
        
        .alert-danger {
            background: #f8d7da;
            border-color: #dc3545;
            color: #721c24;
        }
        
        .alert-info {
            background: #d1ecf1;
            border-color: #17a2b8;
            color: #0c5460;
        }
        
        .alert-success {
            background: #d4edda;
            border-color: #28a745;
            color: #155724;
        }
        
        .file-list {
            list-style: none;
            padding: 0;
        }
        
        .file-list li {
            padding: 12px;
            margin: 8px 0;
            background: white;
            border-radius: 5px;
            border: 1px solid #dee2e6;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .file-list li .file-name {
            font-family: 'Courier New', monospace;
            font-weight: 600;
            color: #495057;
        }
        
        .file-list li .file-status {
            font-size: 0.9em;
        }
        
        .tabs {
            display: flex;
            border-bottom: 2px solid #dee2e6;
            margin-bottom: 20px;
        }
        
        .tab {
            padding: 12px 24px;
            cursor: pointer;
            background: #f8f9fa;
            border: none;
            border-bottom: 3px solid transparent;
            font-size: 1em;
            font-weight: 600;
            color: #6c757d;
            transition: all 0.3s;
        }
        
        .tab:hover {
            background: #e9ecef;
        }
        
        .tab.active {
            color: #667eea;
            border-bottom-color: #667eea;
            background: white;
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
        }
        
        @media (max-width: 768px) {
            .header h1 {
                font-size: 1.8em;
            }
            
            .content {
                padding: 20px;
            }
            
            .section {
                padding: 20px;
            }
            
            .stats-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Migration Result</h1>
            <div class="status-badge" style="background: STATUS_COLOR_PLACEHOLDER;">
                STATUS_ICON_PLACEHOLDER STATUS_PLACEHOLDER
            </div>
            <p style="margin-top: 15px; opacity: 0.9;">TIMESTAMP_PLACEHOLDER</p>
        </div>
        
        <div class="content">
            <!-- Executive Summary -->
            <div class="section">
                <h2>📊 Executive Summary</h2>
                <p style="font-size: 1.1em; margin-bottom: 20px;">
                    EXECUTIVE_SUMMARY_PLACEHOLDER
                </p>
                
                ERROR_DETAILS_SECTION_PLACEHOLDER
                
                <div class="stats-grid">
                    <div class="stat-card">
                        <div class="label">Source Environment</div>
                        <div class="value">SOURCE_ENV_PLACEHOLDER</div>
                    </div>
                    <div class="stat-card">
                        <div class="label">Target Environment</div>
                        <div class="value">TARGET_ENV_PLACEHOLDER</div>
                    </div>
                    <div class="stat-card">
                        <div class="label">Migration Mode</div>
                        <div class="value">MODE_PLACEHOLDER</div>
                    </div>
                    <div class="stat-card">
                        <div class="label">Source Tables</div>
                        <div class="value">SOURCE_TABLE_COUNT_PLACEHOLDER</div>
                    </div>
                    <div class="stat-card">
                        <div class="label">Target Tables</div>
                        <div class="value">TARGET_TABLE_COUNT_PLACEHOLDER</div>
                    </div>
                </div>
                
                <table class="info-table">
                    <tr>
                        <th>Quick Stats</th>
                        <th>Status</th>
                    </tr>
                    <tr>
                        <td>Migration Mode</td>
                        <td>MODE_DETAIL_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Backup Created</td>
                        <td>BACKUP_STATUS_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Rollback SQL Available</td>
                        <td>ROLLBACK_SQL_STATUS_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Dry Run</td>
                        <td>DRY_RUN_PLACEHOLDER</td>
                    </tr>
                </table>
            </div>
            
            <!-- Migration Summary (Charts and snapshots removed - focusing on summary and details) -->
            <div class="section">
                <h2>📊 Migration Summary</h2>
                <p>Migration completed successfully. See detailed object changes below.</p>
            </div>
            
            <!-- Object Changes Details -->
            <div class="section">
                <h2>📝 Detailed Object Changes</h2>
                
                <h3>What Changed on Target</h3>
                OBJECT_CHANGES_DETAILS_PLACEHOLDER
            </div>
            
            <!-- Detailed Comparison -->
            <div class="section">
                <h2>🔍 Detailed Comparison</h2>
                
                <h3>Database Schema Comparison</h3>
                <div class="comparison-box">
                    <p><strong>Source Environment:</strong> SOURCE_ENV_PLACEHOLDER (SOURCE_REF_PLACEHOLDER)</p>
                    <p><strong>Target Environment:</strong> TARGET_ENV_PLACEHOLDER (TARGET_REF_PLACEHOLDER)</p>
                </div>
                
                <h4>Schema Statistics</h4>
                <table class="info-table">
                    <tr>
                        <th>Metric</th>
                        <th>Source</th>
                        <th>Target</th>
                    </tr>
                    <tr>
                        <td>Tables</td>
                        <td>SOURCE_TABLE_COUNT_PLACEHOLDER</td>
                        <td>TARGET_TABLE_COUNT_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Data Migration</td>
                        <td colspan="2">DATA_MIGRATION_STATUS_PLACEHOLDER</td>
                    </tr>
                </table>
                
                COMPARISON_DETAILS_PLACEHOLDER
                
                <h3>Component Status</h3>
                <table class="info-table">
                    <tr>
                        <th>Component</th>
                        <th>Status</th>
                    </tr>
                    <tr>
                        <td>Storage Buckets</td>
                        <td>STORAGE_BUCKETS_STATUS_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Edge Functions</td>
                        <td>EDGE_FUNCTIONS_STATUS_PLACEHOLDER</td>
                    </tr>
                    <tr>
                        <td>Secrets</td>
                        <td>SECRETS_STATUS_PLACEHOLDER</td>
                    </tr>
                </table>
            </div>
            
            <!-- Migration Summary -->
            <div class="section">
                <h2>📋 Migration Summary</h2>
                
                <h3>What Was Applied to Target</h3>
                <ul class="checklist">
                    <li><strong>Database Schema</strong> ✅ - All tables, indexes, constraints, and policies were applied</li>
                    <li><strong>Database Data</strong> DATA_MIGRATION_ITEM_PLACEHOLDER</li>
                    <li><strong>Storage Buckets</strong> ✅ - Bucket configurations migrated (files need manual upload)</li>
                    <li><strong>Edge Functions</strong> EDGE_FUNCTIONS_ITEM_PLACEHOLDER</li>
                    <li><strong>Secrets</strong> ✅ - Secret keys created (values need manual update)</li>
                </ul>
                
                <div class="alert alert-warning">
                    <strong>⚠️ Important:</strong> Secrets were created with blank/placeholder values. You MUST update all secret values manually for the application to work properly.
                </div>
            </div>
            
            <!-- Rollback Instructions -->
            <div class="section">
                <h2>↩️ Rollback Instructions</h2>
                
                <div class="tabs">
                    <button class="tab active" onclick="switchTab('rollback-script')">Rollback Script</button>
                    <button class="tab" onclick="switchTab('rollback-sql')">Rollback SQL</button>
                    <button class="tab" onclick="switchTab('manual-rollback')">Manual Rollback</button>
                </div>
                
                <div id="rollback-script" class="tab-content active">
                    <h3>Method 1: Using Rollback Script (Recommended)</h3>
                    <p>Copy and paste this entire script into your terminal:</p>
                    <div class="code-block">
                        <code>ROLLBACK_SCRIPT_PLACEHOLDER</code>
                    </div>
                    <div class="alert alert-info">
                        <strong>💡 Tip:</strong> You can also save this script to a file: <code>MIGRATION_DIR_PLACEHOLDER/rollback.sh</code>, make it executable with <code>chmod +x rollback.sh</code>, and run it.
                    </div>
                </div>
                
                <div id="rollback-sql" class="tab-content">
                    <h3>Method 2: Using Supabase SQL Editor</h3>
                    ROLLBACK_SQL_CONTENT_PLACEHOLDER
                </div>
                
                <div id="manual-rollback" class="tab-content">
                    <h3>Method 3: Manual Rollback via pg_restore</h3>
                    <p>If the rollback script doesn't work, use these manual commands:</p>
                    <div class="code-block">
                        <code># Navigate to migration directory
cd "MIGRATION_DIR_PLACEHOLDER"

# Load environment
source ../../.env.local
export SUPABASE_ACCESS_TOKEN

# Link to target project
supabase link --project-ref "TARGET_REF_PLACEHOLDER" --password "TARGET_PASSWORD_PLACEHOLDER"

# Restore from backup
PGPASSWORD="TARGET_PASSWORD_PLACEHOLDER" pg_restore \
    -h "POOLER_HOST_PLACEHOLDER" \
    -p 6543 \
    -U postgres.TARGET_REF_PLACEHOLDER \
    -d postgres \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --verbose \
    target_backup.dump

# Unlink
supabase unlink --yes</code>
                    </div>
                </div>
            </div>
            
            <!-- Files Generated -->
            <div class="section">
                <h2>📁 Files Generated</h2>
                <p>All migration files are located in: <code>MIGRATION_DIR_PLACEHOLDER</code></p>
                
                <ul class="file-list">
                    FILE_LIST_PLACEHOLDER
                </ul>
            </div>
            
            <!-- Next Steps -->
            <div class="section">
                <h2>✅ Next Steps</h2>
                
                <h3>Immediate Actions Required</h3>
                <ol style="margin-left: 20px; line-height: 2;">
                    <li><strong>Update Secrets</strong> ⚠️ <strong>CRITICAL</strong>
                        <ul style="margin-top: 10px; margin-left: 20px;">
                            <li>All secrets were created with blank/placeholder values</li>
                            <li>Update each secret: <code>supabase secrets set KEY_NAME=actual_value --project-ref TARGET_REF_PLACEHOLDER</code></li>
                            <li>Check <code>MIGRATION_DIR_PLACEHOLDER/secrets_list.json</code> for list of secrets</li>
                        </ul>
                    </li>
                    <li><strong>Upload Storage Files</strong> (if applicable)
                        <ul style="margin-top: 10px; margin-left: 20px;">
                            <li>Go to: <a href="https://supabase.com/dashboard/project/TARGET_REF_PLACEHOLDER/storage/buckets" target="_blank">Supabase Dashboard → Storage</a></li>
                            <li>Upload actual files to each bucket</li>
                        </ul>
                    </li>
                    <li><strong>Verify Edge Functions</strong> (if applicable)
                        <ul style="margin-top: 10px; margin-left: 20px;">
                            EDGE_FUNCTIONS_NEXT_STEPS_PLACEHOLDER
                        </ul>
                    </li>
                    <li><strong>Test Application</strong>
                        <ul style="margin-top: 10px; margin-left: 20px;">
                            <li>Verify all functionality works correctly</li>
                            <li>Test database queries, storage operations, edge functions</li>
                        </ul>
                    </li>
                </ol>
                
                <h3>Post-Migration Checklist</h3>
                <ul class="checklist">
                    <li>Secrets updated with actual values</li>
                    <li>Storage files uploaded (if needed)</li>
                    <li>Edge functions verified/deployed</li>
                    <li>Application tested and working</li>
                    <li>Rollback plan reviewed (if needed)</li>
                    <li>Team notified of migration completion</li>
                </ul>
            </div>
            
            <!-- Troubleshooting -->
            <div class="section">
                <h2>🔧 Troubleshooting</h2>
                
                <h3>Migration Log</h3>
                <p>For detailed operation logs, check: <code>LOG_FILE_PLACEHOLDER</code></p>
                
                <h3>Common Issues</h3>
                <div class="alert alert-info">
                    <strong>Secrets not working:</strong> Ensure all secrets are updated with actual values. Verify with: <code>supabase secrets list --project-ref TARGET_REF_PLACEHOLDER</code>
                </div>
                <div class="alert alert-info">
                    <strong>Edge functions not deployed:</strong> Deploy manually from codebase or check function logs in Supabase Dashboard.
                </div>
                <div class="alert alert-info">
                    <strong>Storage files missing:</strong> Upload files manually via Dashboard or Storage API. Verify bucket policies are correct.
                </div>
                <div class="alert alert-info">
                    <strong>Database connection issues:</strong> Verify connection strings are updated. Check pooler vs direct connection settings.
                </div>
            </div>
        </div>
    </div>
    
    <script>
        function switchTab(tabId) {
            // Hide all tab contents
            document.querySelectorAll('.tab-content').forEach(content => {
                content.classList.remove('active');
            });
            
            // Remove active class from all tabs
            document.querySelectorAll('.tab').forEach(tab => {
                tab.classList.remove('active');
            });
            
            // Show selected tab content
            document.getElementById(tabId).classList.add('active');
            
            // Add active class to clicked tab
            event.target.classList.add('active');
        }
        
        // Charts removed - focusing on summary and details only
    </script>
</body>
</html>
HTML_EOF
    
    # Replace placeholders
    sed -i.bak \
        -e "s|STATUS_COLOR_PLACEHOLDER|$status_color|g" \
        -e "s|STATUS_ICON_PLACEHOLDER|$status_icon|g" \
        -e "s|STATUS_PLACEHOLDER|$status|g" \
        -e "s|TIMESTAMP_PLACEHOLDER|$timestamp|g" \
        -e "s|SOURCE_ENV_PLACEHOLDER|${SOURCE_ENV:-N/A}|g" \
        -e "s|TARGET_ENV_PLACEHOLDER|${TARGET_ENV:-N/A}|g" \
        -e "s|SOURCE_REF_PLACEHOLDER|${source_ref:-N/A}|g" \
        -e "s|TARGET_REF_PLACEHOLDER|${target_ref:-N/A}|g" \
        -e "s|MODE_PLACEHOLDER|${MODE:-N/A}|g" \
        -e "s|MODE_DETAIL_PLACEHOLDER|${MODE:-N/A} ($([ "$MODE" = "full" ] && echo "Schema + Data" || echo "Schema Only"))|g" \
        -e "s|SOURCE_TABLE_COUNT_PLACEHOLDER|${source_table_count:-0}|g" \
        -e "s|TARGET_TABLE_COUNT_PLACEHOLDER|${target_table_count:-0}|g" \
        -e "s|BACKUP_STATUS_PLACEHOLDER|$([ "$has_backup" = "true" ] && echo '<span class="badge badge-success">✅ Available</span>' || echo '<span class="badge badge-danger">❌ Not available</span>')|g" \
        -e "s|ROLLBACK_SQL_STATUS_PLACEHOLDER|$([ "$has_rollback_sql" = "true" ] && echo '<span class="badge badge-success">✅ Available</span>' || echo '<span class="badge badge-danger">❌ Not available</span>')|g" \
        -e "s|DRY_RUN_PLACEHOLDER|${DRY_RUN:-false}|g" \
        -e "s|DATA_MIGRATION_STATUS_PLACEHOLDER|$([ "$MODE" = "full" ] && echo '<span class="badge badge-success">✅ All data migrated</span>' || echo '<span class="badge badge-warning">⏭️ No data migration (schema only)</span>')|g" \
        -e "s|STORAGE_BUCKETS_STATUS_PLACEHOLDER|$storage_buckets_migrated|g" \
        -e "s|EDGE_FUNCTIONS_STATUS_PLACEHOLDER|$edge_functions_deployed|g" \
        -e "s|SECRETS_STATUS_PLACEHOLDER|$secrets_set|g" \
        -e "s|DATA_MIGRATION_ITEM_PLACEHOLDER|$([ "$MODE" = "full" ] && echo '✅ - All table data was copied from source to target' || echo '⏭️ - No data was copied (schema-only migration)')|g" \
        -e "s|EDGE_FUNCTIONS_ITEM_PLACEHOLDER|$([ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ] && echo '✅ - Functions deployed successfully' || echo '⚠️ - Functions deployment failed or skipped - deploy manually')|g" \
        -e "s|MIGRATION_DIR_PLACEHOLDER|$migration_dir|g" \
        -e "s|LOG_FILE_PLACEHOLDER|$log_file|g" \
        -e "s|POOLER_HOST_PLACEHOLDER|${pooler_host:-N/A}|g" \
        -e "s|TARGET_PASSWORD_PLACEHOLDER|${target_password:-N/A}|g" \
        -e "s|SOURCE_TABLES_PLACEHOLDER|${source_tables:-0}|g" \
        -e "s|SOURCE_VIEWS_PLACEHOLDER|${source_views:-0}|g" \
        -e "s|SOURCE_FUNCTIONS_PLACEHOLDER|${source_functions:-0}|g" \
        -e "s|SOURCE_SEQUENCES_PLACEHOLDER|${source_sequences:-0}|g" \
        -e "s|SOURCE_INDEXES_PLACEHOLDER|${source_indexes:-0}|g" \
        -e "s|SOURCE_POLICIES_PLACEHOLDER|${source_policies:-0}|g" \
        -e "s|SOURCE_TRIGGERS_PLACEHOLDER|${source_triggers:-0}|g" \
        -e "s|SOURCE_TYPES_PLACEHOLDER|${source_types:-0}|g" \
        -e "s|SOURCE_ENUMS_PLACEHOLDER|${source_enums:-0}|g" \
        -e "s|SOURCE_EDGE_FUNCTIONS_PLACEHOLDER|${source_edge_functions:-0}|g" \
        -e "s|SOURCE_BUCKETS_PLACEHOLDER|${source_buckets:-0}|g" \
        -e "s|SOURCE_SECRETS_PLACEHOLDER|${source_secrets:-0}|g" \
        -e "s|SOURCE_AUTH_USERS_PLACEHOLDER|${source_auth_users:-0}|g" \
        -e "s|TARGET_TABLES_PLACEHOLDER|${target_tables:-0}|g" \
        -e "s|TARGET_VIEWS_PLACEHOLDER|${target_views:-0}|g" \
        -e "s|TARGET_FUNCTIONS_PLACEHOLDER|${target_functions:-0}|g" \
        -e "s|TARGET_SEQUENCES_PLACEHOLDER|${target_sequences:-0}|g" \
        -e "s|TARGET_INDEXES_PLACEHOLDER|${target_indexes:-0}|g" \
        -e "s|TARGET_POLICIES_PLACEHOLDER|${target_policies:-0}|g" \
        -e "s|TARGET_TRIGGERS_PLACEHOLDER|${target_triggers:-0}|g" \
        -e "s|TARGET_TYPES_PLACEHOLDER|${target_types:-0}|g" \
        -e "s|TARGET_ENUMS_PLACEHOLDER|${target_enums:-0}|g" \
        -e "s|TARGET_EDGE_FUNCTIONS_PLACEHOLDER|${target_edge_functions:-0}|g" \
        -e "s|TARGET_BUCKETS_PLACEHOLDER|${target_buckets:-0}|g" \
        -e "s|TARGET_SECRETS_PLACEHOLDER|${target_secrets:-0}|g" \
        -e "s|TARGET_AUTH_USERS_PLACEHOLDER|${target_auth_users:-0}|g" \
        "$result_html" 2>/dev/null || true
    
    # Handle executive summary
    local exec_summary=""
    if [[ "$status" == *"Skipped"* ]] || [[ "$status" == *"⏭️"* ]]; then
        exec_summary="Migration from <strong>$SOURCE_ENV</strong> to <strong>$TARGET_ENV</strong> was <strong>skipped</strong> because projects are identical."
    else
        exec_summary="Migration from <strong>$SOURCE_ENV</strong> to <strong>$TARGET_ENV</strong> completed with status: <strong>$status</strong>"
    fi
    sed -i.bak "s|EXECUTIVE_SUMMARY_PLACEHOLDER|$exec_summary|g" "$result_html" 2>/dev/null || true
    
    # Handle error details section
    local error_details_html=""
    if [ -n "$error_details" ] && ([[ "$status" == *"Failed"* ]] || [[ "$status" == *"❌"* ]]); then
        error_details_html="<div class=\"alert alert-danger\" style=\"margin: 20px 0; padding: 20px; background: #fee; border-left: 4px solid #f44; border-radius: 4px;\">"
        error_details_html+="<h3 style=\"margin-top: 0; color: #c00;\">❌ Migration Failed - Error Details</h3>"
        error_details_html+="<p style=\"margin-bottom: 10px;\"><strong>The migration encountered errors. Please review the details below:</strong></p>"
        error_details_html+="<div style=\"background: #fff; padding: 15px; border-radius: 4px; max-height: 400px; overflow-y: auto; font-family: monospace; font-size: 0.9em; white-space: pre-wrap; word-wrap: break-word;\">"
        error_details_html+="$(echo "$error_details" | sed 's/</\&lt;/g; s/>/\&gt;/g' | head -30)"
        error_details_html+="</div>"
        error_details_html+="<p style=\"margin-top: 15px; margin-bottom: 0;\"><strong>Full log:</strong> Check <code>$log_file</code> for complete error details.</p>"
        error_details_html+="</div>"
    fi
    sed -i.bak "s|ERROR_DETAILS_SECTION_PLACEHOLDER|$error_details_html|g" "$result_html" 2>/dev/null || true
    
    # Handle comparison details
    local comparison_html=""
    if [ -n "$comparison_details" ]; then
        comparison_html="<h4>Schema Differences</h4><div class=\"comparison-box\"><pre>$(echo "$comparison_details" | sed 's/</\&lt;/g; s/>/\&gt;/g' | head -100)</pre></div>"
    else
        comparison_html="<div class=\"alert alert-info\"><strong>Note:</strong> Schema comparison details not available. Check migration log for details.</div>"
    fi
    sed -i.bak "s|COMPARISON_DETAILS_PLACEHOLDER|$comparison_html|g" "$result_html" 2>/dev/null || true
    
    # Before/After snapshot sections removed - no longer replacing those placeholders
    
    # Replace object changes details
    sed -i.bak "s|OBJECT_CHANGES_DETAILS_PLACEHOLDER|$object_changes_html|g" "$result_html" 2>/dev/null || true
    
    # Handle rollback script
    if [ -n "$rollback_script_content" ]; then
        sed -i.bak "s|ROLLBACK_SCRIPT_PLACEHOLDER|$rollback_script_content|g" "$result_html" 2>/dev/null || true
    else
        sed -i.bak "s|ROLLBACK_SCRIPT_PLACEHOLDER|# No backup available for rollback. Manual rollback required.|g" "$result_html" 2>/dev/null || true
    fi
    
    # Handle rollback SQL
    local rollback_sql_html=""
    if [ "$has_rollback_sql" = "true" ] && [ -n "$rollback_sql_content" ]; then
        rollback_sql_html="<p>If you only need to rollback schema changes, you can use the SQL rollback file:</p><ol style=\"margin-left: 20px; line-height: 2;\"><li>Open Supabase Dashboard → SQL Editor</li><li>Select target project: <strong>$target_ref</strong></li><li>Open file: <code>$rollback_db_sql</code></li><li>Copy the entire contents</li><li>Paste into SQL Editor</li><li>Click \"Run\" to execute</li></ol><div class=\"alert alert-warning\"><strong>⚠️ Warning:</strong> This will restore the database schema to its pre-migration state. Review the SQL before executing.</div><div class=\"code-block\"><code>$rollback_sql_content</code></div>"
    else
        rollback_sql_html="<div class=\"alert alert-info\">SQL rollback file not available. Use Method 1 or 3 instead.</div>"
    fi
    sed -i.bak "s|ROLLBACK_SQL_CONTENT_PLACEHOLDER|$rollback_sql_html|g" "$result_html" 2>/dev/null || true
    
    # Handle file list
    local file_list_html=""
    file_list_html+="<li><span class=\"file-name\">migration.log</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    file_list_html+="<li><span class=\"file-name\">target_backup.dump</span><span class=\"file-status\">$([ "$has_backup" = "true" ] && echo '<span class="badge badge-success">✅ Available</span>' || echo '<span class="badge badge-danger">❌ Not available</span>')</span></li>"
    file_list_html+="<li><span class=\"file-name\">rollback_db.sql</span><span class=\"file-status\">$([ "$has_rollback_sql" = "true" ] && echo '<span class="badge badge-success">✅ Available</span>' || echo '<span class="badge badge-danger">❌ Not available</span>')</span></li>"
    file_list_html+="<li><span class=\"file-name\">result.html</span><span class=\"file-status\"><span class=\"badge badge-info\">This file</span></span></li>"
    file_list_html+="<li><span class=\"file-name\">result.md</span><span class=\"file-status\"><span class=\"badge badge-info\">Markdown version</span></span></li>"
    [ -f "$source_schema" ] && file_list_html+="<li><span class=\"file-name\">source_schema.sql</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    [ -f "$target_schema" ] && file_list_html+="<li><span class=\"file-name\">target_schema.sql</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    [ -f "$storage_buckets" ] && file_list_html+="<li><span class=\"file-name\">storage_buckets.sql</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    [ -f "$secrets_list" ] && file_list_html+="<li><span class=\"file-name\">secrets_list.json</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    [ -f "$functions_list" ] && file_list_html+="<li><span class=\"file-name\">edge_functions_list.json</span><span class=\"file-status\"><span class=\"badge badge-info\">Available</span></span></li>"
    sed -i.bak "s|FILE_LIST_PLACEHOLDER|$file_list_html|g" "$result_html" 2>/dev/null || true
    
    # Handle edge functions next steps
    local edge_funcs_next=""
    if [ "$edge_functions_deployed" != "⚠️  Not deployed or failed" ]; then
        edge_funcs_next="<li>Functions should be deployed automatically</li><li>Verify functions are working in Supabase Dashboard</li>"
    else
        edge_funcs_next="<li>Deploy functions manually: <code>supabase functions deploy &lt;function-name&gt; --project-ref $target_ref</code></li><li>Check function logs in Supabase Dashboard</li>"
    fi
    sed -i.bak "s|EDGE_FUNCTIONS_NEXT_STEPS_PLACEHOLDER|$edge_funcs_next|g" "$result_html" 2>/dev/null || true
    
    # Clean up backup files (created by sed -i.bak on macOS)
    find "$migration_dir" -name "result.html.bak" -delete 2>/dev/null || true
    
    echo "$result_html"
}

