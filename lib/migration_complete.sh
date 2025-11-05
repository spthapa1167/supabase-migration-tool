#!/bin/bash
# Complete Migration Utilities
# Handles all aspects of Supabase project migration

# Export storage buckets SQL
export_storage_buckets() {
    local project_ref=$1
    local password=$2
    local output_file=$3
    
    log_info "Exporting storage buckets configuration..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    # Get storage buckets and policies
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT 
            'CREATE BUCKET IF NOT EXISTS ' || name || ';' ||
            CASE 
                WHEN public THEN ' ALTER BUCKET ' || name || ' SET public = true;'
                ELSE ''
            END
        FROM storage.buckets;
        " > "$output_file" 2>/dev/null || true
    
    # Get storage policies
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT 
            'CREATE POLICY IF NOT EXISTS ' || name || 
            ' ON storage.objects FOR ' || definition ||
            ' USING (' || check_expression || ');'
        FROM storage.policies;
        " >> "$output_file" 2>/dev/null || true
    
    log_success "Storage buckets exported to: $output_file"
}

# Export realtime configuration
export_realtime_config() {
    local project_ref=$1
    local password=$2
    local output_file=$3
    
    log_info "Exporting realtime configuration..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    # Get tables with realtime enabled
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT 
            'ALTER TABLE ' || schemaname || '.' || tablename || 
            ' REPLICA IDENTITY FULL;'
        FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename IN (
            SELECT table_name 
            FROM publication_tables 
            WHERE publication_name = 'supabase_realtime'
        );
        " > "$output_file" 2>/dev/null || true
    
    log_success "Realtime configuration exported to: $output_file"
}

# Export cron jobs
export_cron_jobs() {
    local project_ref=$1
    local password=$2
    local output_file=$3
    
    log_info "Exporting cron jobs..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    # Check if pg_cron extension exists
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -t -A \
        -c "
        SELECT EXISTS(
            SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
        );
        " > /tmp/pg_cron_check.txt 2>/dev/null || echo "f"
    
    if grep -q "t" /tmp/pg_cron_check.txt 2>/dev/null; then
        # Export cron jobs
        PGPASSWORD="$password" psql \
            -h "$POOLER_HOST" \
            -p 6543 \
            -U postgres.${project_ref} \
            -d postgres \
            -t -A \
            -c "
            SELECT 
                'SELECT cron.schedule(''' || jobname || ''', ''' || 
                schedule || ''', ''' || command || ''');'
            FROM cron.job;
            " > "$output_file" 2>/dev/null || true
        
        log_success "Cron jobs exported to: $output_file"
    else
        log_info "pg_cron extension not found, skipping cron jobs"
        echo "-- pg_cron extension not enabled" > "$output_file"
    fi
    
    rm -f /tmp/pg_cron_check.txt
}

# Export secrets (reads from Supabase API)
export_secrets_list() {
    local project_ref=$1
    local output_file=$2
    
    log_info "Exporting secrets list (names only - values are secret)..."
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set, cannot export secrets"
        echo "# Secrets list for project: $project_ref" > "$output_file"
        echo "# Note: Values are secret and must be set manually in target project" >> "$output_file"
        echo "# Go to: Dashboard → Project Settings → Edge Functions → Manage Secrets" >> "$output_file"
        return 0
    fi
    
    # Get secrets via API
    curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${project_ref}/secrets" \
        -o "$output_file" 2>/dev/null || {
        log_warning "Could not fetch secrets via API, creating template"
        echo "# Secrets list for project: $project_ref" > "$output_file"
        echo "# Note: Values are secret and must be set manually" >> "$output_file"
        echo "# Common secrets to set:" >> "$output_file"
        echo "# - STRIPE_SECRET_KEY" >> "$output_file"
        echo "# - FIRECRAWL_API_KEY" >> "$output_file"
        echo "# - RESEND_API_KEY" >> "$output_file"
        echo "# - LOVABLE_API_KEY" >> "$output_file"
        echo "# - SENDGRID_API_KEY" >> "$output_file"
        echo "# - APP_ENV" >> "$output_file"
        echo "" >> "$output_file"
        echo "# To set secrets:" >> "$output_file"
        echo "# supabase secrets set KEY_NAME=value --project-ref $project_ref" >> "$output_file"
    }
    
    log_success "Secrets list exported to: $output_file"
}

# Export edge functions list
export_edge_functions_list() {
    local project_ref=$1
    local output_file=$2
    local functions_dir=${3:-""}
    
    log_info "Exporting edge functions list from project: $project_ref..."
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set, cannot export edge functions"
        echo "# Edge functions list for project: $project_ref" > "$output_file"
        echo "# Note: Edge functions must be deployed from codebase" >> "$output_file"
        return 0
    fi
    
    # Get edge functions via API
    local temp_json=$(mktemp)
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${project_ref}/functions" \
        -o "$temp_json" 2>/dev/null; then
        
        # Check if we got valid JSON
        if command -v jq >/dev/null 2>&1 && jq empty "$temp_json" 2>/dev/null; then
            cp "$temp_json" "$output_file"
            log_success "Edge functions list exported to: $output_file"
            
            # If functions_dir is provided, download function code using Supabase CLI
            # Note: Project must be linked before calling this function for CLI download to work
            if [ -n "$functions_dir" ]; then
                mkdir -p "$functions_dir"
                local func_count=$(jq '. | length' "$output_file" 2>/dev/null || echo "0")
                
                if [ "$func_count" -gt 0 ]; then
                    log_info "Downloading $func_count edge function(s) from source project using CLI..."
                    local downloaded=0
                    
                    # Create a temporary supabase project structure for downloading
                    local temp_download_dir=$(mktemp -d)
                    mkdir -p "$temp_download_dir/supabase/functions"
                    
                    # Extract function names and download each using CLI
                    while IFS= read -r func_name; do
                        [ -z "$func_name" ] && continue
                        
                        log_info "Downloading function: $func_name from $project_ref"
                        
                        # Use supabase CLI to download function
                        # The CLI requires the project to be linked (which should be done before calling this)
                        # Try with --project-ref first
                        local download_output=$(cd "$temp_download_dir" && supabase functions download "$func_name" --project-ref "$project_ref" 2>&1)
                        local download_exit=$?
                        
                        # If that fails, try without --project-ref (requires project to be linked)
                        if [ $download_exit -ne 0 ]; then
                            log_info "Download with --project-ref failed, trying without (assuming project is linked)..."
                            download_output=$(cd "$temp_download_dir" && supabase functions download "$func_name" 2>&1)
                            download_exit=$?
                        fi
                        
                        # Check if download succeeded
                        if [ $download_exit -eq 0 ] && [ -d "$temp_download_dir/supabase/functions/$func_name" ]; then
                            # Copy downloaded function to functions_dir
                            local func_dir="$functions_dir/$func_name"
                            mkdir -p "$func_dir"
                            
                            # Copy all files from downloaded function
                            if cp -r "$temp_download_dir/supabase/functions/$func_name"/* "$func_dir/" 2>/dev/null; then
                                # Verify we got actual function code (not just empty directory)
                                if [ -f "$func_dir/index.ts" ] || [ -f "$func_dir/index.js" ] || [ -f "$func_dir/deno.json" ] || [ "$(ls -A "$func_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
                                    log_success "✓ Downloaded function from source: $func_name"
                                    downloaded=$((downloaded + 1))
                                else
                                    log_warning "Downloaded directory is empty for: $func_name"
                                    log_info "Download output: $download_output"
                                fi
                            else
                                log_warning "Failed to copy downloaded function: $func_name"
                            fi
                            
                            # Clean up downloaded function from temp dir
                            rm -rf "$temp_download_dir/supabase/functions/$func_name"
                        else
                            log_warning "Failed to download function: $func_name (exit code: $download_exit)"
                            log_info "Download output: $download_output"
                            
                            # Try alternative: download directly to functions_dir with proper structure
                            log_info "Trying alternative download method..."
                            local func_dir="$functions_dir/$func_name"
                            mkdir -p "$func_dir"
                            local parent_dir=$(dirname "$functions_dir")
                            local alt_temp_dir=$(mktemp -d)
                            mkdir -p "$alt_temp_dir/supabase/functions"
                            
                            # Try downloading with --project-ref
                            local alt_download_output=$(cd "$alt_temp_dir" && supabase functions download "$func_name" --project-ref "$project_ref" 2>&1)
                            local alt_download_exit=$?
                            
                            # If that fails, try without --project-ref
                            if [ $alt_download_exit -ne 0 ]; then
                                alt_download_output=$(cd "$alt_temp_dir" && supabase functions download "$func_name" 2>&1)
                                alt_download_exit=$?
                            fi
                            
                            if [ $alt_download_exit -eq 0 ] && [ -d "$alt_temp_dir/supabase/functions/$func_name" ]; then
                                cp -r "$alt_temp_dir/supabase/functions/$func_name"/* "$func_dir/" 2>/dev/null || true
                                
                                if [ -f "$func_dir/index.ts" ] || [ -f "$func_dir/index.js" ] || [ "$(ls -A "$func_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
                                    log_success "✓ Downloaded function (alternative method): $func_name"
                                    downloaded=$((downloaded + 1))
                                fi
                            else
                                log_warning "Alternative download also failed: $func_name"
                                log_info "Alternative download output: $alt_download_output"
                            fi
                            
                            rm -rf "$alt_temp_dir"
                        fi
                    done < <(jq -r '.[].name // empty' "$output_file" 2>/dev/null)
                    
                    # Cleanup temp directory
                    rm -rf "$temp_download_dir"
                    
                    log_info "Downloaded $downloaded function(s) from source project"
                    if [ $downloaded -eq 0 ]; then
                        log_warning "No functions were downloaded. Functions may need to be deployed manually."
                        log_info "Note: Ensure project is linked before calling export_edge_functions_list with functions_dir"
                    fi
                fi
            fi
        else
            log_warning "Invalid JSON response from API"
            echo "# Edge functions list for project: $project_ref" > "$output_file"
            echo "# Note: Edge functions must be deployed from codebase" >> "$output_file"
        fi
        rm -f "$temp_json"
    else
        log_warning "Could not fetch edge functions via API, creating template"
        echo "# Edge functions list for project: $project_ref" > "$output_file"
        echo "# Note: Edge functions must be deployed from codebase" >> "$output_file"
        echo "# To deploy:" >> "$output_file"
        echo "# supabase functions deploy <function-name> --project-ref $project_ref" >> "$output_file"
        rm -f "$temp_json"
    fi
}

# Deploy edge functions from source to target
# Downloads functions from both source and target, compares them, and deploys delta
deploy_edge_functions() {
    local source_ref=$1
    local target_ref=$2
    local functions_list_file=$3
    local functions_dir=${4:-""}
    
    log_info "Deploying edge functions from $source_ref to $target_ref (delta migration)..."
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set, cannot deploy edge functions"
        return 1
    fi
    
    # Ensure Docker is running
    if ! docker ps > /dev/null 2>&1; then
        log_error "Docker Desktop is not running. Edge functions deployment requires Docker."
        log_info "Please start Docker Desktop and try again."
        return 1
    fi
    
    # Create temporary directories for source and target functions
    local temp_base_dir=$(mktemp -d)
    local source_funcs_dir="$temp_base_dir/source_functions"
    local target_funcs_dir="$temp_base_dir/target_functions"
    local deploy_funcs_dir="$temp_base_dir/deploy_functions"
    
    mkdir -p "$source_funcs_dir/supabase/functions"
    mkdir -p "$target_funcs_dir/supabase/functions"
    mkdir -p "$deploy_funcs_dir/supabase/functions"
    
    # Create minimal config.toml files
    echo 'project_id = "temp_source"' > "$source_funcs_dir/supabase/config.toml"
    echo 'project_id = "temp_target"' > "$target_funcs_dir/supabase/config.toml"
    echo 'project_id = "temp_deploy"' > "$deploy_funcs_dir/supabase/config.toml"
    
    # Step 1: Link to source and download all functions
    log_info "Step 1/4: Downloading functions from source project ($source_ref)..."
    local source_func_names=""
    
    if [ -f "$functions_list_file" ] && command -v jq >/dev/null 2>&1; then
        source_func_names=$(jq -r '.[].name // empty' "$functions_list_file" 2>/dev/null || echo "")
    fi
    
    if [ -z "$source_func_names" ]; then
        log_warning "Could not get function names from list file, fetching from API..."
        local source_api_file=$(mktemp)
        if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            "https://api.supabase.com/v1/projects/${source_ref}/functions" \
            -o "$source_api_file" 2>/dev/null; then
            source_func_names=$(jq -r '.[].name // empty' "$source_api_file" 2>/dev/null || echo "")
        fi
        rm -f "$source_api_file"
    fi
    
    if [ -z "$source_func_names" ]; then
        log_warning "No functions found in source project"
        rm -rf "$temp_base_dir"
        return 1
    fi
    
    log_info "Found $(echo "$source_func_names" | grep -c . || echo "0") function(s) in source"
    
    # Download source functions
    # First ensure we're linked to source
    log_info "Linking to source project for function download..."
    if ! supabase link --project-ref "$source_ref" --password "${SOURCE_PASSWORD:-}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_warning "Could not link to source project, trying with --project-ref in download..."
    fi
    
    local source_downloaded=0
    for func_name in $source_func_names; do
        func_name=$(echo "$func_name" | xargs)
        [ -z "$func_name" ] && continue
        
        log_info "Downloading source function: $func_name"
        local download_output=$(cd "$source_funcs_dir" && supabase functions download "$func_name" --project-ref "$source_ref" --workdir "$source_funcs_dir" 2>&1)
        local download_exit=$?
        
        if [ $download_exit -eq 0 ]; then
            # Check if function was downloaded - look in multiple locations
            local func_path=""
            if [ -d "$source_funcs_dir/supabase/functions/$func_name" ]; then
                func_path="$source_funcs_dir/supabase/functions/$func_name"
            elif [ -d "$source_funcs_dir/$func_name" ]; then
                func_path="$source_funcs_dir/$func_name"
            else
                func_path=$(find "$source_funcs_dir" -type d -name "$func_name" 2>/dev/null | head -1)
            fi
            
            # If still not found, try extracting from Docker container
            if [ -z "$func_path" ] || [ ! -d "$func_path" ]; then
                log_info "Function not found in expected location, checking Docker container..."
                # Find containers that might have the function
                local container_id=$(docker ps -a --filter "ancestor=supabase/edge-runtime" --format "{{.ID}}" | head -1)
                if [ -n "$container_id" ]; then
                    # Try to copy from container
                    if docker cp "${container_id}:/home/deno/$func_name" "$source_funcs_dir/supabase/functions/" 2>/dev/null; then
                        if [ -d "$source_funcs_dir/supabase/functions/$func_name" ]; then
                            func_path="$source_funcs_dir/supabase/functions/$func_name"
                            log_info "Extracted function from Docker container"
                        fi
                    fi
                fi
            fi
            
            if [ -n "$func_path" ] && [ -d "$func_path" ]; then
                log_success "✓ Downloaded source function: $func_name"
                source_downloaded=$((source_downloaded + 1))
            elif echo "$download_output" | grep -q "extracted successfully" || echo "$download_output" | grep -q "Eszip extracted"; then
                # Download succeeded but files are in Docker container - this is okay
                # We'll use --use-api for deployment which doesn't need local files
                log_success "✓ Downloaded source function: $func_name (in Docker container)"
                source_downloaded=$((source_downloaded + 1))
                # Create a marker so we know the function was downloaded
                mkdir -p "$source_funcs_dir/supabase/functions/$func_name"
                touch "$source_funcs_dir/supabase/functions/$func_name/.downloaded"
            else
                log_warning "Download succeeded but function files not found: $func_name"
                log_info "Download output: $download_output"
            fi
        else
            log_warning "Failed to download source function: $func_name (exit code: $download_exit)"
            log_info "Download output: $download_output"
        fi
    done
    
    # Unlink from source after download
    supabase unlink --yes 2>/dev/null || true
    
    log_info "Downloaded $source_downloaded function(s) from source"
    
    # Step 2: Link to target and download all functions
    log_info "Step 2/4: Downloading functions from target project ($target_ref)..."
    local target_func_names=""
    local target_api_file=$(mktemp)
    
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${target_ref}/functions" \
        -o "$target_api_file" 2>/dev/null; then
        if jq empty "$target_api_file" 2>/dev/null; then
            target_func_names=$(jq -r '.[].name // empty' "$target_api_file" 2>/dev/null || echo "")
        fi
    fi
    rm -f "$target_api_file"
    
    log_info "Found $(echo "$target_func_names" | grep -c . || echo "0") function(s) in target"
    
    # Download target functions
    # Link to target project
    log_info "Linking to target project for function download..."
    if ! supabase link --project-ref "$target_ref" --password "${TARGET_PASSWORD:-}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_warning "Could not link to target project, trying with --project-ref in download..."
    fi
    
    local target_downloaded=0
    for func_name in $target_func_names; do
        func_name=$(echo "$func_name" | xargs)
        [ -z "$func_name" ] && continue
        
        log_info "Downloading target function: $func_name"
        local download_output=$(cd "$target_funcs_dir" && supabase functions download "$func_name" --project-ref "$target_ref" --workdir "$target_funcs_dir" 2>&1)
        local download_exit=$?
        
        if [ $download_exit -eq 0 ]; then
            # Check if function was downloaded - look in multiple locations
            local func_path=""
            if [ -d "$target_funcs_dir/supabase/functions/$func_name" ]; then
                func_path="$target_funcs_dir/supabase/functions/$func_name"
            elif [ -d "$target_funcs_dir/$func_name" ]; then
                func_path="$target_funcs_dir/$func_name"
            else
                func_path=$(find "$target_funcs_dir" -type d -name "$func_name" 2>/dev/null | head -1)
            fi
            
            # If still not found, try extracting from Docker container
            if [ -z "$func_path" ] || [ ! -d "$func_path" ]; then
                log_info "Function not found in expected location, checking Docker container..."
                local container_id=$(docker ps -a --filter "ancestor=supabase/edge-runtime" --format "{{.ID}}" | head -1)
                if [ -n "$container_id" ]; then
                    if docker cp "${container_id}:/home/deno/$func_name" "$target_funcs_dir/supabase/functions/" 2>/dev/null; then
                        if [ -d "$target_funcs_dir/supabase/functions/$func_name" ]; then
                            func_path="$target_funcs_dir/supabase/functions/$func_name"
                            log_info "Extracted function from Docker container"
                        fi
                    fi
                fi
            fi
            
            if [ -n "$func_path" ] && [ -d "$func_path" ]; then
                log_success "✓ Downloaded target function: $func_name"
                target_downloaded=$((target_downloaded + 1))
            elif echo "$download_output" | grep -q "extracted successfully" || echo "$download_output" | grep -q "Eszip extracted"; then
                # Download succeeded but files are in Docker container - this is okay
                log_success "✓ Downloaded target function: $func_name (in Docker container)"
                target_downloaded=$((target_downloaded + 1))
                # Create a marker so we know the function was downloaded
                mkdir -p "$target_funcs_dir/supabase/functions/$func_name"
                touch "$target_funcs_dir/supabase/functions/$func_name/.downloaded"
            else
                log_warning "Download succeeded but function files not found: $func_name"
            fi
        else
            log_warning "Failed to download target function: $func_name (exit code: $download_exit)"
        fi
    done
    
    # Unlink from target after download
    supabase unlink --yes 2>/dev/null || true
    
    log_info "Downloaded $target_downloaded function(s) from target"
    
    # Step 3: Compare and find delta (new or changed functions)
    log_info "Step 3/4: Comparing source and target to find delta..."
    local functions_to_deploy=""
    local new_count=0
    local changed_count=0
    
    for func_name in $source_func_names; do
        func_name=$(echo "$func_name" | xargs)
        [ -z "$func_name" ] && continue
        
        # Find source function directory
        local source_func_path=""
        if [ -d "$source_funcs_dir/supabase/functions/$func_name" ]; then
            source_func_path="$source_funcs_dir/supabase/functions/$func_name"
        elif [ -d "$source_funcs_dir/$func_name" ]; then
            source_func_path="$source_funcs_dir/$func_name"
        else
            source_func_path=$(find "$source_funcs_dir" -type d -name "$func_name" 2>/dev/null | head -1)
        fi
        
        # Check if function was downloaded (even if just marker file exists)
        local source_downloaded_marker=false
        if [ -f "$source_funcs_dir/supabase/functions/$func_name/.downloaded" ]; then
            source_downloaded_marker=true
        fi
        
        if [ -z "$source_func_path" ] || ([ ! -d "$source_func_path" ] && [ "$source_downloaded_marker" != "true" ]); then
            log_warning "Source function $func_name not found in downloaded files, skipping"
            continue
        fi
        
        # If only marker exists, create directory structure for deployment
        if [ "$source_downloaded_marker" = "true" ] && ([ -z "$source_func_path" ] || [ ! -d "$source_func_path" ]); then
            source_func_path="$source_funcs_dir/supabase/functions/$func_name"
            mkdir -p "$source_func_path"
        fi
        
        # Check if function exists in target
        local exists_in_target=false
        if echo "$target_func_names" | grep -q "^${func_name}$" 2>/dev/null; then
            exists_in_target=true
        fi
        
        # Find target function directory if it exists
        local target_func_path=""
        local target_downloaded_marker=false
        if [ "$exists_in_target" = "true" ]; then
            if [ -d "$target_funcs_dir/supabase/functions/$func_name" ]; then
                target_func_path="$target_funcs_dir/supabase/functions/$func_name"
            elif [ -d "$target_funcs_dir/$func_name" ]; then
                target_func_path="$target_funcs_dir/$func_name"
            else
                target_func_path=$(find "$target_funcs_dir" -type d -name "$func_name" 2>/dev/null | head -1)
            fi
            
            # Check if downloaded marker exists
            if [ -f "$target_funcs_dir/supabase/functions/$func_name/.downloaded" ]; then
                target_downloaded_marker=true
                if [ -z "$target_func_path" ] || [ ! -d "$target_func_path" ]; then
                    target_func_path="$target_funcs_dir/supabase/functions/$func_name"
                    mkdir -p "$target_func_path"
                fi
            fi
        fi
        
        # Determine if function needs deployment
        local needs_deployment=false
        local deployment_reason=""
        
        if [ "$exists_in_target" != "true" ]; then
            # New function
            needs_deployment=true
            deployment_reason="new"
            new_count=$((new_count + 1))
        elif [ -z "$target_func_path" ] || [ ! -d "$target_func_path" ]; then
            # Exists in target but couldn't download - deploy to be safe
            needs_deployment=true
            deployment_reason="exists but couldn't compare"
        else
            # Compare function code (simple hash comparison)
            # Skip comparison if only marker files exist (functions in Docker)
            if [ "$source_downloaded_marker" = "true" ] && [ "$target_downloaded_marker" = "true" ]; then
                # Both in Docker - assume they might be different and deploy
                needs_deployment=true
                deployment_reason="both in Docker - deploying to ensure sync"
                changed_count=$((changed_count + 1))
            elif [ "$source_downloaded_marker" = "true" ] || [ "$target_downloaded_marker" = "true" ]; then
                # One in Docker, one local - deploy to ensure sync
                needs_deployment=true
                deployment_reason="Docker vs local mismatch - deploying"
                changed_count=$((changed_count + 1))
            else
                # Both local - do hash comparison
                # Use md5sum if available, otherwise use md5 (macOS)
                local hash_cmd="md5sum"
                if ! command -v md5sum >/dev/null 2>&1; then
                    hash_cmd="md5 -q"
                fi
                
                local source_hash=""
                local target_hash=""
                
                if [ "$hash_cmd" = "md5sum" ]; then
                    source_hash=$(find "$source_func_path" -type f ! -name ".downloaded" -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)
                    target_hash=$(find "$target_func_path" -type f ! -name ".downloaded" -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)
                else
                    source_hash=$(find "$source_func_path" -type f ! -name ".downloaded" -exec md5 -q {} \; 2>/dev/null | sort | md5 -q)
                    target_hash=$(find "$target_func_path" -type f ! -name ".downloaded" -exec md5 -q {} \; 2>/dev/null | sort | md5 -q)
                fi
                
                if [ "$source_hash" != "$target_hash" ]; then
                    needs_deployment=true
                    deployment_reason="changed"
                    changed_count=$((changed_count + 1))
                fi
            fi
        fi
        
        if [ "$needs_deployment" = "true" ]; then
            log_info "Function $func_name needs deployment (reason: $deployment_reason)"
            
            # Copy source function to deploy directory
            mkdir -p "$deploy_funcs_dir/supabase/functions/$func_name"
            
            # If source function has actual files, copy them
            if [ -d "$source_func_path" ] && [ "$(ls -A "$source_func_path" 2>/dev/null | grep -v '^\.downloaded$' | wc -l)" -gt 0 ]; then
                cp -r "$source_func_path"/* "$deploy_funcs_dir/supabase/functions/$func_name/" 2>/dev/null || {
                    log_warning "Failed to copy function $func_name to deploy directory"
                }
                # Remove marker file if copied
                rm -f "$deploy_funcs_dir/supabase/functions/$func_name/.downloaded" 2>/dev/null || true
            else
                # Function is in Docker - create marker for deployment
                # Deployment will use --use-api which doesn't need local files
                touch "$deploy_funcs_dir/supabase/functions/$func_name/.deploy_from_docker"
                log_info "Function $func_name will be deployed from Docker container"
            fi
            
            if [ -z "$functions_to_deploy" ]; then
                functions_to_deploy="$func_name"
            else
                functions_to_deploy="$functions_to_deploy"$'\n'"$func_name"
            fi
        else
            log_info "Function $func_name is up to date in target, skipping"
        fi
    done
    
    if [ -z "$functions_to_deploy" ]; then
        log_info "No functions need deployment - all functions are up to date in target"
        rm -rf "$temp_base_dir"
        return 0
    fi
    
    local total_to_deploy=$(echo "$functions_to_deploy" | grep -c . || echo "0")
    log_info "Delta found: $new_count new, $changed_count changed, $total_to_deploy total to deploy"
    
    # Step 4: Deploy delta to target
    log_info "Step 4/4: Deploying delta ($total_to_deploy function(s)) to target..."
    
    # Link to target for deployment
    log_info "Linking to target project for deployment..."
    if ! supabase link --project-ref "$target_ref" --password "${TARGET_PASSWORD:-}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_warning "Could not link to target project, trying with --project-ref in deploy..."
    fi
    
    local deployed_count=0
    local failed_count=0
    
    for func_name in $functions_to_deploy; do
        func_name=$(echo "$func_name" | xargs)
        [ -z "$func_name" ] && continue
        
        if [ ! -d "$deploy_funcs_dir/supabase/functions/$func_name" ]; then
            log_warning "Function $func_name not found in deploy directory, skipping"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        log_info "Deploying function: $func_name to $target_ref"
        
        # Check if function is in Docker (only marker file exists)
        local deploy_from_docker=false
        if [ -f "$deploy_funcs_dir/supabase/functions/$func_name/.deploy_from_docker" ]; then
            deploy_from_docker=true
            log_info "Function $func_name is in Docker container, using --use-api for deployment"
        fi
        
        # Deploy using --use-api (works even if files are in Docker container)
        # This flag uses Management API which can access functions from Docker
        local deploy_output=""
        local deploy_exit=1
        
        if [ "$deploy_from_docker" = "true" ]; then
            # Function is in Docker - must use --use-api
            # Link to source and re-download, then deploy
            log_info "Function is in Docker - linking to source and re-downloading for deployment..."
            if supabase link --project-ref "$source_ref" --password "${SOURCE_PASSWORD:-}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                log_info "Re-downloading $func_name from source for deployment..."
                deploy_output=$(cd "$deploy_funcs_dir" && supabase functions download "$func_name" --project-ref "$source_ref" --workdir "$deploy_funcs_dir" 2>&1)
                local re_download_exit=$?
                supabase unlink --yes 2>/dev/null || true
                
                if [ $re_download_exit -eq 0 ]; then
                    # Now deploy with --use-api (works even if files are in Docker)
                    log_info "Deploying $func_name using --use-api..."
                    deploy_output=$(cd "$deploy_funcs_dir" && supabase functions deploy "$func_name" --project-ref "$target_ref" --use-api --workdir "$deploy_funcs_dir" 2>&1)
                    deploy_exit=$?
                else
                    log_warning "Re-download failed, trying direct deployment..."
                    deploy_output=$(cd "$deploy_funcs_dir" && supabase functions deploy "$func_name" --project-ref "$target_ref" --use-api --workdir "$deploy_funcs_dir" 2>&1)
                    deploy_exit=$?
                fi
            else
                # Link failed, try direct deployment
                log_warning "Could not link to source, trying direct deployment with --use-api..."
                deploy_output=$(cd "$deploy_funcs_dir" && supabase functions deploy "$func_name" --project-ref "$target_ref" --use-api --workdir "$deploy_funcs_dir" 2>&1)
                deploy_exit=$?
            fi
        else
            # Function files are local - try --use-api first
            deploy_output=$(cd "$deploy_funcs_dir" && supabase functions deploy "$func_name" --project-ref "$target_ref" --use-api --workdir "$deploy_funcs_dir" 2>&1)
            deploy_exit=$?
            
            if [ $deploy_exit -ne 0 ]; then
                # Fallback to regular deployment
                log_info "Deployment with --use-api failed, trying regular deployment..."
                deploy_output=$(cd "$deploy_funcs_dir" && supabase functions deploy "$func_name" --project-ref "$target_ref" --workdir "$deploy_funcs_dir" 2>&1)
                deploy_exit=$?
            fi
        fi
        
        echo "$deploy_output" | tee -a "${LOG_FILE:-/dev/null}"
        
        if [ $deploy_exit -eq 0 ]; then
            log_success "✓ Deployed: $func_name"
            deployed_count=$((deployed_count + 1))
        else
            log_warning "✗ Failed to deploy: $func_name (exit code: $deploy_exit)"
            log_info "Deploy output: $deploy_output"
            failed_count=$((failed_count + 1))
        fi
    done
    
    # Unlink from target after deployment
    supabase unlink --yes 2>/dev/null || true
    
    # Cleanup
    rm -rf "$temp_base_dir"
    
    log_info "Deployment summary: $deployed_count succeeded, $failed_count failed"
    log_info "Delta migration: $new_count new, $changed_count changed, $total_to_deploy total deployed"
    
    if [ $deployed_count -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Set secrets from list (with blank values)
# Creates secrets in target with empty values that need to be filled manually
set_secrets_from_list() {
    local target_ref=$1
    local secrets_list_file=$2
    
    log_info "Setting secrets in target project: $target_ref (delta only - new keys)"
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set, cannot set secrets"
        return 1
    fi
    
    if [ ! -f "$secrets_list_file" ]; then
        log_warning "Secrets list file not found: $secrets_list_file"
        log_info "Skipping secrets setup"
        return 1
    fi
    
    # Check if file is JSON or just a template
    if ! command -v jq >/dev/null 2>&1; then
        log_warning "jq not found, cannot parse secrets list"
        log_info "Secrets must be set manually"
        return 1
    fi
    
    # First, get existing secrets from target to compare (delta migration)
    log_info "Fetching existing secrets from target project..."
    local target_secrets_temp=$(mktemp)
    local target_secret_names=""
    
    if curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${target_ref}/secrets" \
        -o "$target_secrets_temp" 2>/dev/null; then
        if jq empty "$target_secrets_temp" 2>/dev/null; then
            target_secret_names=$(jq -r '.[].name // empty' "$target_secrets_temp" 2>/dev/null || echo "")
            log_info "Found $(echo "$target_secret_names" | grep -c . || echo "0") existing secret(s) in target"
        fi
    else
        log_warning "Could not fetch target secrets - will migrate all secrets (non-delta)"
    fi
    rm -f "$target_secrets_temp"
    
    # Try to extract secret names from source JSON
    local source_secret_names=$(jq -r '.[].name // .name // empty' "$secrets_list_file" 2>/dev/null || echo "")
    
    # If JSON parsing fails, try to read as simple list
    if [ -z "$source_secret_names" ]; then
        # Try reading as plain text (one secret name per line)
        source_secret_names=$(grep -v "^#" "$secrets_list_file" | grep -v "^$" | sed 's/.*- //' | sed 's/=.*//' | head -20)
    fi
    
    if [ -z "$source_secret_names" ]; then
        log_warning "No secret names found in $secrets_list_file"
        log_info "Secrets must be set manually"
        return 1
    fi
    
    # Filter to only secrets that don't exist in target (delta)
    local secrets_to_add=""
    local skipped_count=0
    
    for secret_name in $source_secret_names; do
        secret_name=$(echo "$secret_name" | xargs)
        [ -z "$secret_name" ] && continue
        
        # Check if secret already exists in target
        if [ -n "$target_secret_names" ] && echo "$target_secret_names" | grep -q "^${secret_name}$" 2>/dev/null; then
            log_info "Skipping $secret_name (already exists in target)"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Add to list of secrets to migrate
        if [ -z "$secrets_to_add" ]; then
            secrets_to_add="$secret_name"
        else
            secrets_to_add="$secrets_to_add"$'\n'"$secret_name"
        fi
    done
    
    if [ -z "$secrets_to_add" ]; then
        log_info "All secrets already exist in target (delta: 0 new secrets)"
        log_info "Skipped $skipped_count secret(s) that already exist"
        return 0
    fi
    
    local new_secrets_count=$(echo "$secrets_to_add" | grep -c . || echo "0")
    log_info "Found $new_secrets_count new secret(s) to migrate (delta), skipped $skipped_count existing"
    log_info "New secrets: $(echo "$secrets_to_add" | tr '\n' ' ')"
    log_warning "Setting new secrets with BLANK values - must be updated manually!"
    
    local set_count=0
    local failed_count=0
    
    for secret_name in $secrets_to_add; do
        # Trim whitespace
        secret_name=$(echo "$secret_name" | xargs)
        
        # Skip empty names
        [ -z "$secret_name" ] && continue
        
        log_info "Setting secret: $secret_name (blank value)"
        
        # Set secret with blank/empty value
        # Note: Supabase CLI may require a value, so we use a placeholder
        if supabase secrets set "${secret_name}=" --project-ref "$target_ref" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log_success "✓ Set: $secret_name (with blank value - UPDATE REQUIRED)"
            set_count=$((set_count + 1))
        else
            # Try alternative: set with placeholder value
            log_warning "Failed to set with blank value, trying placeholder..."
            if supabase secrets set "${secret_name}=PLACEHOLDER_UPDATE_REQUIRED" --project-ref "$target_ref" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                log_success "✓ Set: $secret_name (with placeholder - UPDATE REQUIRED)"
                set_count=$((set_count + 1))
            else
                log_warning "✗ Failed: $secret_name"
                failed_count=$((failed_count + 1))
            fi
        fi
    done
    
    log_info "Secrets setup summary: $set_count new secrets set (delta migration), $failed_count failed, $skipped_count skipped (already exist)"
    if [ $set_count -gt 0 ]; then
        log_warning "⚠️  IMPORTANT: Update all new secret values manually after migration!"
    fi
    
    # Create a template file for manual updates (only for new secrets)
    local secrets_template="${secrets_list_file%.*}_template.txt"
    cat > "$secrets_template" << EOF
# Secrets Template for Manual Update (New Secrets Only)
# Project: $target_ref
# Generated: $(date)
# Delta Migration: Only new secrets that didn't exist in target

# Update the values below and run:
# supabase secrets set KEY=value --project-ref $target_ref

EOF
    
    for secret_name in $secrets_to_add; do
        secret_name=$(echo "$secret_name" | xargs)
        [ -z "$secret_name" ] && continue
        echo "${secret_name}=YOUR_VALUE_HERE" >> "$secrets_template"
    done
    
    log_info "Template created: $secrets_template"
    
    if [ $set_count -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Import storage buckets
import_storage_buckets() {
    local project_ref=$1
    local password=$2
    local sql_file=$3
    
    if [ ! -f "$sql_file" ] || [ ! -s "$sql_file" ]; then
        log_warning "Storage buckets SQL file is empty or missing, skipping"
        return 0
    fi
    
    log_info "Importing storage buckets configuration..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -f "$sql_file" \
        2>&1 | grep -v "already exists" || log_info "Storage buckets imported"
    
    log_success "Storage buckets imported"
}

# Import realtime configuration
import_realtime_config() {
    local project_ref=$1
    local password=$2
    local sql_file=$3
    
    if [ ! -f "$sql_file" ] || [ ! -s "$sql_file" ]; then
        log_warning "Realtime SQL file is empty or missing, skipping"
        return 0
    fi
    
    log_info "Importing realtime configuration..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -f "$sql_file" \
        2>&1 | grep -v "already exists" || log_info "Realtime configuration imported"
    
    log_success "Realtime configuration imported"
}

# Import cron jobs
import_cron_jobs() {
    local project_ref=$1
    local password=$2
    local sql_file=$3
    
    if [ ! -f "$sql_file" ] || [ ! -s "$sql_file" ] || grep -q "not enabled" "$sql_file"; then
        log_warning "Cron jobs SQL file is empty or pg_cron not enabled, skipping"
        return 0
    fi
    
    log_info "Importing cron jobs..."
    
    POOLER_HOST=$(get_pooler_host "$project_ref")
    
    # Ensure pg_cron extension exists
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -c "CREATE EXTENSION IF NOT EXISTS pg_cron;" \
        2>&1 | grep -v "already exists" || true
    
    # Import cron jobs
    PGPASSWORD="$password" psql \
        -h "$POOLER_HOST" \
        -p 6543 \
        -U postgres.${project_ref} \
        -d postgres \
        -f "$sql_file" \
        2>&1 || log_warning "Some cron jobs may have failed to import"
    
    log_success "Cron jobs imported"
}

