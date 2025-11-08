#!/bin/bash
# Connection Test Script
# Tests connection and validates Supabase properties for a given environment
# Usage: connection_test.sh <env> [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Source utilities
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/supabase_utils.sh"

# Default configuration
VERBOSE=false
TEST_ENV=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 <env> [--verbose]

Tests connection and validates Supabase properties for a given environment.

Arguments:
  env         Environment to test (dev, test, prod, backup)
  --verbose   Show detailed output
  --help      Show this help message

Examples:
  $0 dev
  $0 test --verbose
  $0 prod

EOF
            exit 0
            ;;
        *)
            if [ -z "$TEST_ENV" ]; then
                TEST_ENV="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Check if environment is provided
if [ -z "$TEST_ENV" ]; then
    log_error "Environment is required"
    echo "Usage: $0 <env> [--verbose]"
    echo "Run '$0 --help' for more information"
    exit 1
fi

# Load environment
set +e
load_env
LOAD_ENV_EXIT_CODE=$?
set -e
if [ $LOAD_ENV_EXIT_CODE -ne 0 ]; then
    log_error "Failed to load environment variables"
    exit 1
fi

log_script_context "$(basename "$0")" "$TEST_ENV"

# Validate environment name (check if it's a valid environment)
# Note: validate_environments requires different source/target, so we validate manually
valid_envs="prod test dev backup production staging develop main bkp bkup"
env_check=$(printf '%s' "$TEST_ENV" | tr '[:upper:]' '[:lower:]')
if ! echo "$valid_envs" | grep -q "\b${env_check}\b"; then
    log_error "Invalid environment: $TEST_ENV"
    log_info "Valid environments: prod, test, dev, backup"
    exit 1
fi

# Get environment-specific variables
case $env_check in
    prod|production|main)
        ENV_PREFIX="PROD"
        ENV_NAME="Production"
        ;;
    test|staging)
        ENV_PREFIX="TEST"
        ENV_NAME="Test/Staging"
        ;;
    dev|develop)
        ENV_PREFIX="DEV"
        ENV_NAME="Development"
        ;;
    backup|bkup|bkp)
        ENV_PREFIX="BACKUP"
        ENV_NAME="Backup"
        ;;
    *)
        log_error "Unknown environment: $TEST_ENV"
        exit 1
        ;;
esac

PROJECT_NAME_VAR="SUPABASE_${ENV_PREFIX}_PROJECT_NAME"
PROJECT_REF_VAR="SUPABASE_${ENV_PREFIX}_PROJECT_REF"
DB_PASSWORD_VAR="SUPABASE_${ENV_PREFIX}_DB_PASSWORD"
POOLER_REGION_VAR="SUPABASE_${ENV_PREFIX}_POOLER_REGION"
POOLER_PORT_VAR="SUPABASE_${ENV_PREFIX}_POOLER_PORT"
URL_VAR="SUPABASE_${ENV_PREFIX}_URL"
ANON_KEY_VAR="SUPABASE_${ENV_PREFIX}_ANON_KEY"
SERVICE_ROLE_KEY_VAR="SUPABASE_${ENV_PREFIX}_SERVICE_ROLE_KEY"

PROJECT_NAME="${!PROJECT_NAME_VAR:-}"
PROJECT_REF="${!PROJECT_REF_VAR:-}"
DB_PASSWORD="${!DB_PASSWORD_VAR:-}"
POOLER_REGION="${!POOLER_REGION_VAR:-}"
POOLER_PORT="${!POOLER_PORT_VAR:-}"
URL="${!URL_VAR:-}"
ANON_KEY="${!ANON_KEY_VAR:-}"
SERVICE_ROLE_KEY="${!SERVICE_ROLE_KEY_VAR:-}"

# If URL is missing but project ref exists, generate default Supabase URL
URL_GENERATED=false
if [ -z "$URL" ] && [ -n "$PROJECT_REF" ]; then
    URL="https://${PROJECT_REF}.supabase.co"
    URL_GENERATED=true
fi

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="${3:-success}"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [ "$VERBOSE" = "true" ]; then
        log_info "Testing: $test_name"
    fi
    
TEST_OUTPUT=""
if TEST_OUTPUT=$(eval "$test_command" 2>&1); then
    if [ "$expected_result" = "success" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✅ PASS: $test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "❌ FAIL: $test_name (expected failure but got success)"
        if [ "$VERBOSE" = "true" ] && [ -n "$TEST_OUTPUT" ]; then
            echo "$TEST_OUTPUT" | head -5 | sed 's/^/   /'
        fi
        return 1
    fi
    else
        if [ "$expected_result" = "failure" ]; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo "✅ PASS: $test_name (expected failure)"
            return 0
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "❌ FAIL: $test_name"
        if [ "$VERBOSE" = "true" ]; then
            echo "   Command: $test_command"
            if [ -n "$TEST_OUTPUT" ]; then
                echo "$TEST_OUTPUT" | head -5 | sed 's/^/   /'
            fi
        fi
        return 1
        fi
    fi
}

# Start testing
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Connection Test for $ENV_NAME Environment"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 1: Check if SUPABASE_ACCESS_TOKEN is set
log_info "Test 1: Checking Supabase Access Token..."
run_test "Supabase Access Token is set" "[ -n \"\$SUPABASE_ACCESS_TOKEN\" ]"

# Test 2: Check if project name is set
log_info "Test 2: Checking Project Name..."
run_test "Project Name ($PROJECT_NAME_VAR) is set" "[ -n \"$PROJECT_NAME\" ]"

# Test 3: Check if project reference is set
log_info "Test 3: Checking Project Reference..."
run_test "Project Reference ($PROJECT_REF_VAR) is set" "[ -n \"$PROJECT_REF\" ]"

# Test 4: Validate project reference format (20 lowercase alphanumeric characters)
log_info "Test 4: Validating Project Reference Format..."
run_test "Project Reference format is valid (20 alphanumeric chars)" "[[ \"$PROJECT_REF\" =~ ^[a-z0-9]{20}$ ]]"

# Test 5: Check if database password is set
log_info "Test 5: Checking Database Password..."
run_test "Database Password ($DB_PASSWORD_VAR) is set" "[ -n \"$DB_PASSWORD\" ]"

# Test 6: Check if URL is set
log_info "Test 6: Checking Project URL..."
run_test "Project URL ($URL_VAR) is set" "[ -n \"$URL\" ]"

# Test 7: Validate URL format
log_info "Test 7: Validating URL Format..."
run_test "URL format is valid (starts with https://)" "[[ \"$URL\" =~ ^https://.*\.supabase\.co$ ]]"

# Test 8: Check if Anon Key is set
log_info "Test 8: Checking Anon Key..."
run_test "Anon Key ($ANON_KEY_VAR) is set" "[ -n \"$ANON_KEY\" ]"

# Test 9: Check if Service Role Key is set
log_info "Test 9: Checking Service Role Key..."
run_test "Service Role Key ($SERVICE_ROLE_KEY_VAR) is set" "[ -n \"$SERVICE_ROLE_KEY\" ]"

# Test 10: Validate Anon Key format (JWT)
log_info "Test 10: Validating Anon Key Format..."
run_test "Anon Key format is valid (JWT)" "[[ \"$ANON_KEY\" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]"

# Test 11: Validate Service Role Key format (JWT)
log_info "Test 11: Validating Service Role Key Format..."
run_test "Service Role Key format is valid (JWT)" "[[ \"$SERVICE_ROLE_KEY\" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]"

# Test 12: Test API connectivity (check if project exists via API)
log_info "Test 12: Testing API Connectivity..."
if command -v curl >/dev/null 2>&1; then
    API_TEST_CMD="curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$SUPABASE_ACCESS_TOKEN\" \"https://api.supabase.com/v1/projects/$PROJECT_REF\" | grep -q '200'"
    run_test "API connectivity (project exists)" "$API_TEST_CMD"
else
    echo "⚠️  SKIP: API connectivity test (curl not available)"
fi

# Test 13: Test database connectivity
log_info "Test 13: Testing Database Connectivity..."
if command -v psql >/dev/null 2>&1; then
    if [ -n "$PROJECT_REF" ]; then
        if [ "$VERBOSE" = "true" ]; then
            log_info "  Project Ref: $PROJECT_REF"
        fi

        run_db_connection_attempt() {
            local host=$1
            local port=$2

            local timeout_prefix=""
            if command -v timeout >/dev/null 2>&1; then
                timeout_prefix="timeout 10 "
            fi

            local db_user="postgres.${PROJECT_REF}"
            if [[ "$host" == db.*.supabase.co ]]; then
                db_user="postgres"
            fi

            local cmd="PGPASSWORD=\"$DB_PASSWORD\" PGSSLMODE=require ${timeout_prefix}psql -h \"$host\" -p \"$port\" -U \"$db_user\" -d postgres -c \"SELECT 1;\" >/dev/null 2>&1"
            if eval "$cmd"; then
                return 0
            else
                return 1
            fi
        }

        pooler_port="${POOLER_PORT:-6543}"
        shared_pooler_host="${POOLER_REGION:-aws-1-us-east-2}.pooler.supabase.com"

        if [ "$VERBOSE" = "true" ]; then
            log_info "  Shared Pooler Host: $shared_pooler_host"
            log_info "  Pooler Port: $pooler_port"
        fi

        TESTS_TOTAL=$((TESTS_TOTAL + 1))

        attempts=(
            "$shared_pooler_host|$pooler_port|shared pooler port ${pooler_port}"
            "$shared_pooler_host|5432|direct shared pooler port 5432"
            "db.${PROJECT_REF}.supabase.co|$pooler_port|dedicated pooler port ${pooler_port}"
            "db.${PROJECT_REF}.supabase.co|5432|dedicated direct port 5432"
        )

        success=false
        failure_messages=()

        for attempt in "${attempts[@]}"; do
            IFS='|' read -r host port label <<< "$attempt"
            if run_db_connection_attempt "$host" "$port"; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
                echo "✅ PASS: Database connectivity (${label})"
                success=true
                break
            else
                failure_messages+=("❌ FAIL: Database connectivity (${label})")
            fi
        done

        if ! $success; then
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf '%s\n' "${failure_messages[@]}"
        fi
        unset attempts failure_messages success
    else
        echo "⚠️  SKIP: Database connectivity test (project reference not configured)"
    fi
else
    echo "⚠️  SKIP: Database connectivity test (psql not available)"
fi

# Summary
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Test Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Total Tests: $TESTS_TOTAL"
echo "✅ Passed: $TESTS_PASSED"
echo "❌ Failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    log_success "All tests passed! Connection test successful."
    exit 0
else
    log_error "Some tests failed. Please check your configuration."
    exit 1
fi

