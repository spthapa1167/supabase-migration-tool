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
    
    log_info "Exporting edge functions list..."
    
    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        log_warning "SUPABASE_ACCESS_TOKEN not set, cannot export edge functions"
        echo "# Edge functions list for project: $project_ref" > "$output_file"
        echo "# Note: Edge functions must be deployed from codebase" >> "$output_file"
        return 0
    fi
    
    # Get edge functions via API
    curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/${project_ref}/functions" \
        -o "$output_file" 2>/dev/null || {
        log_warning "Could not fetch edge functions via API, creating template"
        echo "# Edge functions list for project: $project_ref" > "$output_file"
        echo "# Note: Edge functions must be deployed from codebase" >> "$output_file"
        echo "# To deploy:" >> "$output_file"
        echo "# supabase functions deploy <function-name> --project-ref $project_ref" >> "$output_file"
    }
    
    log_success "Edge functions list exported to: $output_file"
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

