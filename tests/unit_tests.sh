#!/bin/bash
# Unit Tests for Migration Tool
# Simple bash testing framework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Test framework variables
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test output functions
test_info() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

test_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$*")
}

test_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
}

# Assert functions
assert_true() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local condition=$1
    local message="${2:-Assertion failed}"
    
    if eval "$condition"; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (condition: $condition)"
        return 1
    fi
}

assert_false() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local condition=$1
    local message="${2:-Assertion failed}"
    
    if ! eval "$condition"; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (condition: $condition)"
        return 1
    fi
}

assert_equal() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    if [ "$expected" = "$actual" ]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (expected: '$expected', actual: '$actual')"
        return 1
    fi
}

assert_not_equal() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"
    
    if [ "$expected" != "$actual" ]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (both values were: '$expected')"
        return 1
    fi
}

assert_file_exists() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local file_path="$1"
    local message="${2:-File should exist}"
    
    if [ -f "$file_path" ]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (file: $file_path)"
        return 1
    fi
}

assert_file_not_exists() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local file_path="$1"
    local message="${2:-File should not exist}"
    
    if [ ! -f "$file_path" ]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (file: $file_path)"
        return 1
    fi
}

assert_exit_code() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local expected_code=$1
    local command="$2"
    local message="${3:-Command should exit with code $expected_code}"
    
    set +e
    eval "$command" >/dev/null 2>&1
    local actual_code=$?
    set -e
    
    if [ $actual_code -eq $expected_code ]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (expected: $expected_code, actual: $actual_code)"
        return 1
    fi
}

# Test runner
run_test_suite() {
    local suite_name="$1"
    shift
    local test_functions=("$@")
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running Test Suite: $suite_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    for test_func in "${test_functions[@]}"; do
        if [ -n "$(type -t "$test_func")" ] && [ "$(type -t "$test_func")" = "function" ]; then
            test_info "Running: $test_func"
            set +e
            $test_func
            local test_result=$?
            set -e
            if [ $test_result -ne 0 ]; then
                test_fail "Test function $test_func failed"
            fi
        else
            test_skip "Skipping: $test_func (not a function)"
        fi
    done
}

# Print test summary
print_test_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Tests Run:    $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    echo ""
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo "Failed Tests:"
        for failed_test in "${FAILED_TESTS[@]}"; do
            echo "  - $failed_test"
        done
        echo ""
        return 1
    else
        return 0
    fi
}

# Source libraries for testing
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/error_handler.sh"

# Test Logger Functions
test_logger_init() {
    local test_log_file="/tmp/test_logger_$$.log"
    init_logger "$test_log_file"
    assert_file_exists "$test_log_file" "Log file should be created"
    rm -f "$test_log_file"
}

test_logger_levels() {
    local test_log_file="/tmp/test_logger_levels_$$.log"
    init_logger "$test_log_file"
    
    LOG_LEVEL=$LOG_LEVEL_DEBUG
    log_debug "Debug message"
    log_info "Info message"
    log_warning "Warning message"
    log_error "Error message"
    log_success "Success message"
    
    # Check that messages were written
    local log_content=$(cat "$test_log_file" 2>/dev/null || echo "")
    assert_not_equal "" "$log_content" "Log file should contain messages"
    
    rm -f "$test_log_file"
}

test_log_to_file() {
    local test_log_file="/tmp/test_log_to_file_$$.log"
    log_to_file "$test_log_file" "Test message"
    assert_file_exists "$test_log_file" "Log file should be created"
    
    local content=$(cat "$test_log_file")
    assert_true '[[ "$content" =~ "Test message" ]]' "Log file should contain test message"
    
    rm -f "$test_log_file"
}

# Test Error Handler Functions
test_check_command() {
    # Test with existing command
    set +e
    check_command "echo" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_equal 0 $result "check_command should return 0 for existing command"
    
    # Test with non-existing command
    set +e
    check_command "nonexistent_command_xyz123" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_not_equal 0 $result "check_command should return non-zero for non-existing command"
}

test_validate_file() {
    local test_file="/tmp/test_validate_file_$$.txt"
    echo "test" > "$test_file"
    
    set +e
    validate_file "$test_file" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_equal 0 $result "validate_file should return 0 for existing file"
    
    rm -f "$test_file"
    
    set +e
    validate_file "/tmp/nonexistent_file_$$.txt" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_not_equal 0 $result "validate_file should return non-zero for non-existing file"
}

test_validate_directory() {
    local test_dir="/tmp/test_validate_dir_$$"
    mkdir -p "$test_dir"
    
    set +e
    validate_directory "$test_dir" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_equal 0 $result "validate_directory should return 0 for existing directory"
    
    rmdir "$test_dir"
    
    set +e
    validate_directory "/tmp/nonexistent_dir_$$" "" >/dev/null 2>&1
    local result=$?
    set -e
    assert_not_equal 0 $result "validate_directory should return non-zero for non-existing directory"
}

test_get_error_message() {
    local msg=$(get_error_message $EXIT_CONFIG_ERROR)
    assert_true '[[ "$msg" =~ "Configuration" ]]' "Error message should contain 'Configuration'"
    
    local msg2=$(get_error_message $EXIT_SUCCESS)
    assert_equal "Success" "$msg2" "Success exit code should return 'Success' message"
}

# Run all tests
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Unit Tests for Supabase Migration Tool"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Logger tests
    run_test_suite "Logger Tests" \
        test_logger_init \
        test_logger_levels \
        test_log_to_file
    
    # Error Handler tests
    run_test_suite "Error Handler Tests" \
        test_check_command \
        test_validate_file \
        test_validate_directory \
        test_get_error_message
    
    # Print summary
    print_test_summary
    local exit_code=$?
    
    exit $exit_code
}

# Run tests if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
