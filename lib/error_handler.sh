#!/bin/bash
# Error Handler Library
# Robust error handling with exit codes, recovery mechanisms, and context

# Exit codes (following Unix conventions)
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_MISUSE_OF_SHELL=2
readonly EXIT_CANNOT_EXECUTE=126
readonly EXIT_COMMAND_NOT_FOUND=127
readonly EXIT_INVALID_EXIT_ARG=128

# Custom exit codes for our application
readonly EXIT_CONFIG_ERROR=10
readonly EXIT_CONNECTION_ERROR=11
readonly EXIT_VALIDATION_ERROR=12
readonly EXIT_BACKUP_ERROR=13
readonly EXIT_RESTORE_ERROR=14
readonly EXIT_MIGRATION_ERROR=15
readonly EXIT_USER_CANCELLED=16
readonly EXIT_DEPENDENCY_ERROR=17

# Error recovery mechanisms
ERROR_RECOVERY_ENABLED=${ERROR_RECOVERY_ENABLED:-false}
ERROR_RETRY_COUNT=${ERROR_RETRY_COUNT:-3}
ERROR_RETRY_DELAY=${ERROR_RETRY_DELAY:-2}

# Source logger if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/logger.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

# Get error message for exit code
get_error_message() {
    local exit_code=$1
    case $exit_code in
        $EXIT_SUCCESS)
            echo "Success"
            ;;
        $EXIT_CONFIG_ERROR)
            echo "Configuration error"
            ;;
        $EXIT_CONNECTION_ERROR)
            echo "Connection error"
            ;;
        $EXIT_VALIDATION_ERROR)
            echo "Validation error"
            ;;
        $EXIT_BACKUP_ERROR)
            echo "Backup operation failed"
            ;;
        $EXIT_RESTORE_ERROR)
            echo "Restore operation failed"
            ;;
        $EXIT_MIGRATION_ERROR)
            echo "Migration operation failed"
            ;;
        $EXIT_USER_CANCELLED)
            echo "Operation cancelled by user"
            ;;
        $EXIT_DEPENDENCY_ERROR)
            echo "Missing dependency or external command failed"
            ;;
        *)
            echo "Unknown error (exit code: $exit_code)"
            ;;
    esac
}

# Handle error with context
handle_error() {
    local exit_code=${1:-$EXIT_GENERAL_ERROR}
    local error_message="${2:-}"
    local error_context="${3:-}"
    
    if [ -n "$error_message" ]; then
        if [ -n "$(type -t log_error_with_context)" ] && [ "$(type -t log_error_with_context)" = "function" ]; then
            log_error_with_context "$error_message"
        elif [ -n "$(type -t log_error)" ] && [ "$(type -t log_error)" = "function" ]; then
            log_error "$error_message"
        else
            echo "[ERROR] $error_message" >&2
        fi
    fi
    
    if [ -n "$error_context" ]; then
        if [ -n "$(type -t log_debug)" ] && [ "$(type -t log_debug)" = "function" ]; then
            log_debug "Error context: $error_context"
        fi
    fi
    
    return $exit_code
}

# Check if command exists and handle error
check_command() {
    local cmd=$1
    local error_msg="${2:-Command not found: $cmd}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        handle_error $EXIT_DEPENDENCY_ERROR "$error_msg" "Command: $cmd"
        return $EXIT_DEPENDENCY_ERROR
    fi
    return 0
}

# Retry a command with exponential backoff
retry_command() {
    local max_attempts=${1:-$ERROR_RETRY_COUNT}
    local delay=${2:-$ERROR_RETRY_DELAY}
    shift 2
    local cmd="$*"
    
    local attempt=1
    local exit_code=0
    
    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            if [ -n "$(type -t log_warning)" ] && [ "$(type -t log_warning)" = "function" ]; then
                log_warning "Retrying command (attempt $attempt/$max_attempts): $cmd"
            fi
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        # Execute command
        eval "$cmd"
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            if [ $attempt -gt 1 ] && [ -n "$(type -t log_success)" ] && [ "$(type -t log_success)" = "function" ]; then
                log_success "Command succeeded on attempt $attempt"
            fi
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ -n "$(type -t log_error)" ] && [ "$(type -t log_error)" = "function" ]; then
        log_error "Command failed after $max_attempts attempts: $cmd"
    fi
    
    return $exit_code
}

# Execute command with timeout
execute_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd="$*"
    
    # Use timeout command if available
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" bash -c "$cmd"
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            handle_error $EXIT_GENERAL_ERROR "Command timed out after ${timeout_seconds}s: $cmd"
            return $exit_code
        fi
        return $exit_code
    else
        # Fallback: execute without timeout
        eval "$cmd"
        return $?
    fi
}

# Validate required environment variables
validate_required_vars() {
    local missing_vars=()
    
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        handle_error $EXIT_CONFIG_ERROR \
            "Missing required environment variables: ${missing_vars[*]}" \
            "Variables checked: $*"
        return $EXIT_CONFIG_ERROR
    fi
    
    return 0
}

# Validate file exists
validate_file() {
    local file_path=$1
    local error_msg="${2:-File not found: $file_path}"
    
    if [ ! -f "$file_path" ]; then
        handle_error $EXIT_CONFIG_ERROR "$error_msg" "Path: $file_path"
        return $EXIT_CONFIG_ERROR
    fi
    
    return 0
}

# Validate directory exists
validate_directory() {
    local dir_path=$1
    local error_msg="${2:-Directory not found: $dir_path}"
    
    if [ ! -d "$dir_path" ]; then
        handle_error $EXIT_CONFIG_ERROR "$error_msg" "Path: $dir_path"
        return $EXIT_CONFIG_ERROR
    fi
    
    return 0
}

# Cleanup function registration
CLEANUP_FUNCTIONS=()

# Register cleanup function
register_cleanup() {
    local cleanup_func=$1
    CLEANUP_FUNCTIONS+=("$cleanup_func")
    
    # Set trap if not already set
    if ! trap -p EXIT | grep -q "execute_cleanup"; then
        trap 'execute_cleanup' EXIT INT TERM
    fi
}

# Execute all registered cleanup functions
execute_cleanup() {
    local exit_code=$?
    
    if [ ${#CLEANUP_FUNCTIONS[@]} -eq 0 ]; then
        exit $exit_code
    fi
    
    if [ -n "$(type -t log_debug)" ] && [ "$(type -t log_debug)" = "function" ]; then
        log_debug "Executing cleanup functions (exit code: $exit_code)"
    fi
    
    # Execute cleanup functions in reverse order
    for ((idx=${#CLEANUP_FUNCTIONS[@]}-1; idx>=0; idx--)); do
        local cleanup_func="${CLEANUP_FUNCTIONS[$idx]}"
        if [ -n "$(type -t "$cleanup_func")" ] && [ "$(type -t "$cleanup_func")" = "function" ]; then
            $cleanup_func || true
        fi
    done
    
    exit $exit_code
}

# Safe exit with cleanup
safe_exit() {
    local exit_code=${1:-$EXIT_SUCCESS}
    execute_cleanup
    exit $exit_code
}

# Export functions
export -f handle_error check_command retry_command execute_with_timeout
export -f validate_required_vars validate_file validate_directory
export -f register_cleanup execute_cleanup safe_exit
export -f get_error_message
