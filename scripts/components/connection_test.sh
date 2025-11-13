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

# Test 2: Validate Supabase Management API access token by listing projects
log_info "Test 2: Validating Supabase Management API token..."
if command -v curl >/dev/null 2>&1; then
    MANAGED_API_TEST_CMD="curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$SUPABASE_ACCESS_TOKEN\" \"https://api.supabase.com/v1/projects\" | grep -q '200'"
    run_test "Management API token is valid (projects list succeeds)" "$MANAGED_API_TEST_CMD"
else
    echo "⚠️  SKIP: Management API token validation (curl not available)"
fi

# Adjust numbering for subsequent tests
test_counter=3

# Test 2: Check if project name is set
log_info "Test ${test_counter}: Checking Project Name..."
run_test "Project Name ($PROJECT_NAME_VAR) is set" "[ -n \"$PROJECT_NAME\" ]"
test_counter=$((test_counter + 1))

# Test 3: Check if project reference is set
log_info "Test ${test_counter}: Checking Project Reference..."
run_test "Project Reference ($PROJECT_REF_VAR) is set" "[ -n \"$PROJECT_REF\" ]"
test_counter=$((test_counter + 1))

# Test 4: Validate project reference format (20 lowercase alphanumeric characters)
log_info "Test ${test_counter}: Validating Project Reference Format..."
run_test "Project Reference format is valid (20 alphanumeric chars)" "[[ \"$PROJECT_REF\" =~ ^[a-z0-9]{20}$ ]]"
test_counter=$((test_counter + 1))

# Test 5: Check if database password is set
log_info "Test ${test_counter}: Checking Database Password..."
run_test "Database Password ($DB_PASSWORD_VAR) is set" "[ -n \"$DB_PASSWORD\" ]"
test_counter=$((test_counter + 1))

# Test 6: Check if URL is set
log_info "Test ${test_counter}: Checking Project URL..."
run_test "Project URL ($URL_VAR) is set" "[ -n \"$URL\" ]"
test_counter=$((test_counter + 1))

# Test 7: Validate URL format
log_info "Test ${test_counter}: Validating URL Format..."
run_test "URL format is valid (starts with https://)" "[[ \"$URL\" =~ ^https://.*\.supabase\.co$ ]]"
test_counter=$((test_counter + 1))

# Test 8: Check if Anon Key is set
log_info "Test ${test_counter}: Checking Anon Key..."
run_test "Anon Key ($ANON_KEY_VAR) is set" "[ -n \"$ANON_KEY\" ]"
test_counter=$((test_counter + 1))

# Test 9: Check if Service Role Key is set
log_info "Test ${test_counter}: Checking Service Role Key..."
run_test "Service Role Key ($SERVICE_ROLE_KEY_VAR) is set" "[ -n \"$SERVICE_ROLE_KEY\" ]"
test_counter=$((test_counter + 1))

# Test 10: Validate Anon Key format (JWT)
log_info "Test ${test_counter}: Validating Anon Key Format..."
run_test "Anon Key format is valid (JWT)" "[[ \"$ANON_KEY\" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]"
test_counter=$((test_counter + 1))

# Test 11: Validate Service Role Key format (JWT)
log_info "Test ${test_counter}: Validating Service Role Key Format..."
run_test "Service Role Key format is valid (JWT)" "[[ \"$SERVICE_ROLE_KEY\" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]"
test_counter=$((test_counter + 1))

# Test 12: Test API connectivity (check if project exists via API)
log_info "Test ${test_counter}: Testing API Connectivity..."
if command -v curl >/dev/null 2>&1; then
    API_TEST_CMD="curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$SUPABASE_ACCESS_TOKEN\" \"https://api.supabase.com/v1/projects/$PROJECT_REF\" | grep -q '200'"
    run_test "API connectivity (project exists)" "$API_TEST_CMD"
else
    echo "⚠️  SKIP: API connectivity test (curl not available)"
fi
test_counter=$((test_counter + 1))

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
            local db_user=$3

            local timeout_prefix=""
            if command -v timeout >/dev/null 2>&1; then
                timeout_prefix="timeout 10 "
            fi

            local cmd="PGPASSWORD=\"$DB_PASSWORD\" PGSSLMODE=require ${timeout_prefix}psql -h \"$host\" -p \"$port\" -U \"$db_user\" -d postgres -c \"SELECT 1;\" >/dev/null 2>&1"
            if eval "$cmd"; then
                return 0
            else
                return 1
            fi
        }

        pooler_region="${POOLER_REGION:-aws-1-us-east-2}"
        pooler_port="${POOLER_PORT:-6543}"

        if [ "$VERBOSE" = "true" ]; then
            log_info "  Pooler Region: $pooler_region"
            log_info "  Pooler Port: $pooler_port"
        fi

        TESTS_TOTAL=$((TESTS_TOTAL + 1))

        attempts=()
        while IFS='|' read -r host port user label; do
            [ -z "$host" ] && continue
            attempts+=("$host|$port|$user|$label")
        done < <(get_supabase_connection_endpoints "$PROJECT_REF" "$pooler_region" "$pooler_port")

        if [ ${#attempts[@]} -eq 0 ]; then
            echo "⚠️  SKIP: Database connectivity test (no connection endpoints available)"
            TESTS_TOTAL=$((TESTS_TOTAL - 1))
            continue
        fi

        success=false
        failure_messages=()

        for attempt in "${attempts[@]}"; do
            IFS='|' read -r host port db_user label <<< "$attempt"
            if run_db_connection_attempt "$host" "$port" "$db_user"; then
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

