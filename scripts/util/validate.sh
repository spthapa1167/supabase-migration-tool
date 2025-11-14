#!/bin/bash
# Quick validation script for environment configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source lib/supabase_utils.sh

log_info "Validating environment configuration..."

load_env

# Validate all required variables
REQUIRED_VARS=(
    "SUPABASE_ACCESS_TOKEN"
    "SUPABASE_PROD_PROJECT_REF"
    "SUPABASE_PROD_DB_PASSWORD"
    "SUPABASE_TEST_PROJECT_REF"
    "SUPABASE_TEST_DB_PASSWORD"
    "SUPABASE_DEV_PROJECT_REF"
    "SUPABASE_DEV_DB_PASSWORD"
    "SUPABASE_BACKUP_PROJECT_REF"
    "SUPABASE_BACKUP_DB_PASSWORD"
)

ERRORS=0
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ] || [[ "${!var}" == *"your_"* ]] || [[ "${!var}" == *"here"* ]]; then
        log_error "$var is not set or contains placeholder value"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -eq 0 ]; then
    log_success "All environment variables are configured"
    exit 0
else
    log_error "Found $ERRORS configuration errors"
    log_info "Run ./setup.sh to fix configuration"
    exit 1
fi

