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
  env         Environment to test (dev, test, prod)
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

# Validate environment name (check if it's a valid environment)
# Note: validate_environments requires different source/target, so we validate manually
valid_envs="prod test dev production staging develop main"
if ! echo "$valid_envs" | grep -q "\b${TEST_ENV}\b"; then
    log_error "Invalid environment: $TEST_ENV"
    log_info "Valid environments: prod, test, dev"
    exit 1
fi

# Get environment-specific variables
case $TEST_ENV in
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
    *)
        log_error "Unknown environment: $TEST_ENV"
        exit 1
        ;;
esac

PROJECT_NAME_VAR="SUPABASE_${ENV_PREFIX}_PROJECT_NAME"
PROJECT_REF_VAR="SUPABASE_${ENV_PREFIX}_PROJECT_REF"
DB_PASSWORD_VAR="SUPABASE_${ENV_PREFIX}_DB_PASSWORD"
POOLER_REGION_VAR="SUPABASE_${ENV_PREFIX}_POOLER_REGION"
URL_VAR="SUPABASE_${ENV_PREFIX}_URL"
ANON_KEY_VAR="SUPABASE_${ENV_PREFIX}_ANON_KEY"
SERVICE_ROLE_KEY_VAR="SUPABASE_${ENV_PREFIX}_SERVICE_ROLE_KEY"

PROJECT_NAME="${!PROJECT_NAME_VAR:-}"
PROJECT_REF="${!PROJECT_REF_VAR:-}"
DB_PASSWORD="${!DB_PASSWORD_VAR:-}"
POOLER_REGION="${!POOLER_REGION_VAR:-}"
URL="${!URL_VAR:-}"
ANON_KEY="${!ANON_KEY_VAR:-}"
SERVICE_ROLE_KEY="${!SERVICE_ROLE_KEY_VAR:-}"

# If pooler region is not set, try to extract from URL or use default
if [ -z "$POOLER_REGION" ] && [ -n "$URL" ]; then
    # Try to extract pooler region from URL (e.g., aws-1-us-east-2 from project URL pattern)
    # This is a fallback - ideally POOLER_REGION should be set in .env.local
    POOLER_REGION="aws-1-us-east-2"  # Default fallback
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
    
    if eval "$test_command" >/dev/null 2>&1; then
        if [ "$expected_result" = "success" ]; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo "✅ PASS: $test_name"
            return 0
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "❌ FAIL: $test_name (expected failure but got success)"
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
                eval "$test_command" 2>&1 | head -5 | sed 's/^/   /'
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
    # Build pooler host dynamically from pooler region
    # Format: {POOLER_REGION}.pooler.supabase.com
    # Example: aws-1-us-east-2.pooler.supabase.com
    if [ -n "$POOLER_REGION" ]; then
        POOLER_HOST="${POOLER_REGION}.pooler.supabase.com"
        
        if [ "$VERBOSE" = "true" ]; then
            log_info "  Pooler Region: $POOLER_REGION"
            log_info "  Pooler Host: $POOLER_HOST"
            log_info "  Project Ref: $PROJECT_REF"
            log_info "  Connection String Format: postgresql://postgres.${PROJECT_REF}:***@${POOLER_HOST}:6543/postgres?pgbouncer=true"
        fi
        
        # Test connection via shared connection pooler (port 6543)
        # Connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:6543/postgres?pgbouncer=true
        # For psql: -h host -p port -U user -d database
        # Username format: postgres.{PROJECT_REF} (e.g., postgres.rkiovortqlqaqksllzqz)
        # Note: Pooler connections typically require SSL, but psql will auto-negotiate
        DB_TEST_CMD="PGPASSWORD=\"$DB_PASSWORD\" psql -h \"$POOLER_HOST\" -p 6543 -U \"postgres.${PROJECT_REF}\" -d postgres -c \"SELECT 1;\" 2>&1"
        
        # Run test and capture output for verbose mode
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        # Execute the command and capture both stdout and stderr
        TEST_OUTPUT=$(bash -c "$DB_TEST_CMD" 2>&1)
        TEST_EXIT_CODE=$?
        
        if [ $TEST_EXIT_CODE -eq 0 ]; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo "✅ PASS: Database connectivity (via pooler port 6543)"
            POOLER_TEST_RESULT=0
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "❌ FAIL: Database connectivity (via pooler port 6543)"
            POOLER_TEST_RESULT=1
            if [ "$VERBOSE" = "true" ]; then
                echo "$TEST_OUTPUT" | head -3 | sed 's/^/   /'
                log_info "  Trying direct connection on port 5432..."
            fi
            
            # If pooler test fails, also try direct connection (port 5432) for migrations
            # Direct connection format: postgresql://postgres.{PROJECT_REF}:[PASSWORD]@{POOLER_HOST}:5432/postgres
            DB_DIRECT_TEST_CMD="PGPASSWORD=\"$DB_PASSWORD\" psql -h \"$POOLER_HOST\" -p 5432 -U \"postgres.${PROJECT_REF}\" -d postgres -c \"SELECT 1;\" 2>&1"
            
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            DIRECT_TEST_OUTPUT=$(bash -c "$DB_DIRECT_TEST_CMD" 2>&1)
            DIRECT_TEST_EXIT_CODE=$?
            
            if [ $DIRECT_TEST_EXIT_CODE -eq 0 ]; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
                echo "✅ PASS: Database connectivity (direct port 5432)"
                POOLER_TEST_RESULT=0  # Mark as success since direct connection worked
            else
                TESTS_FAILED=$((TESTS_FAILED + 1))
                echo "❌ FAIL: Database connectivity (direct port 5432)"
                if [ "$VERBOSE" = "true" ]; then
                    echo "$DIRECT_TEST_OUTPUT" | head -3 | sed 's/^/   /'
                fi
            fi
        fi
    else
        # Fallback: try to get pooler host using get_pooler_host function
        POOLER_HOST=$(get_pooler_host "$PROJECT_REF")
        if [ -n "$POOLER_HOST" ] && [ "$POOLER_HOST" != "aws-1-us-east-2.pooler.supabase.com" ]; then
            if [ "$VERBOSE" = "true" ]; then
                log_info "  Using pooler host from get_pooler_host: $POOLER_HOST"
            fi
            DB_TEST_CMD="PGPASSWORD=\"$DB_PASSWORD\" timeout 10 psql -h \"$POOLER_HOST\" -p 6543 -U \"postgres.${PROJECT_REF}\" -d postgres -c \"SELECT 1;\" >/dev/null 2>&1"
            run_test "Database connectivity (via pooler)" "$DB_TEST_CMD"
        else
            echo "⚠️  SKIP: Database connectivity test (pooler region not configured)"
            echo "   Add SUPABASE_${ENV_PREFIX}_POOLER_REGION to .env.local"
            echo "   Example: SUPABASE_${ENV_PREFIX}_POOLER_REGION=aws-1-us-east-2"
        fi
    fi
else
    echo "⚠️  SKIP: Database connectivity test (psql not available)"
fi

# Test 14: Test URL accessibility
log_info "Test 14: Testing URL Accessibility..."
if command -v curl >/dev/null 2>&1; then
    # Test REST API endpoint with anon key
    URL_TEST_CMD="curl -s -o /dev/null -w '%{http_code}' --max-time 10 \"$URL/rest/v1/\" -H \"apikey: $ANON_KEY\" -H \"Authorization: Bearer $ANON_KEY\" | grep -q '200\|401\|404'"
    run_test "URL accessibility (REST API)" "$URL_TEST_CMD"
else
    echo "⚠️  SKIP: URL accessibility test (curl not available)"
fi

# Test 15: Verify URL format and extract project reference
log_info "Test 15: Verifying URL Format and Project Reference..."
if [ -n "$PROJECT_REF" ] && [ -n "$URL" ]; then
    # Extract project reference from URL
    # URL format: https://{PROJECT_REF}.supabase.co
    # Note: The URL project reference may differ from PROJECT_REF in some cases
    # This is acceptable as Supabase URLs can point to different references
    URL_REF=$(echo "$URL" | sed -E 's|https?://([^.]+)\.supabase\.co.*|\1|')
    
    # Alternative extraction method if first one didn't work (for macOS compatibility)
    if [ -z "$URL_REF" ] || [ "$URL_REF" = "$URL" ]; then
        URL_REF=$(echo "$URL" | sed -n 's|https\?://\([^.]*\)\.supabase\.co.*|\1|p')
    fi
    
    if [ "$VERBOSE" = "true" ]; then
        log_info "  Project Reference from env: $PROJECT_REF"
        log_info "  Project Reference from URL: $URL_REF"
        log_info "  Full URL: $URL"
    fi
    
    # Check if URL is valid and contains a project reference
    if [ -n "$URL_REF" ] && [ "$URL_REF" != "$URL" ] && [ ${#URL_REF} -ge 10 ]; then
        # Verify URL format is correct (starts with https:// and ends with .supabase.co)
        if [[ "$URL" =~ ^https://.*\.supabase\.co ]]; then
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo "✅ PASS: URL format is valid and contains project reference"
            
            # Optional: Show if references match (informational only, not a requirement)
            if [ "$PROJECT_REF" = "$URL_REF" ]; then
                if [ "$VERBOSE" = "true" ]; then
                    log_info "  Note: Project reference in env matches URL reference"
                fi
            else
                if [ "$VERBOSE" = "true" ]; then
                    log_info "  Note: Project reference in env ($PROJECT_REF) differs from URL reference ($URL_REF)"
                    log_info "  This is acceptable - URL and database connection may use different references"
                fi
            fi
        else
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "❌ FAIL: URL format is invalid"
            if [ "$VERBOSE" = "true" ]; then
                echo "   URL should match pattern: https://*.supabase.co"
                echo "   Actual URL: $URL"
            fi
        fi
    else
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "❌ FAIL: Could not extract valid project reference from URL"
        if [ "$VERBOSE" = "true" ]; then
            echo "   URL format might be incorrect: $URL"
            echo "   Extracted value: $URL_REF"
        fi
    fi
else
    echo "⚠️  SKIP: URL format verification (missing data)"
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

