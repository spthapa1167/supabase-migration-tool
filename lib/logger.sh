#!/bin/bash
# Logger Library
# Robust logging system with levels, timestamps, structured logging, and file management

# Log levels (only define if not already set)
if [ -z "${LOG_LEVEL_DEBUG:-}" ]; then
    readonly LOG_LEVEL_DEBUG=0
    readonly LOG_LEVEL_INFO=1
    readonly LOG_LEVEL_WARN=2
    readonly LOG_LEVEL_ERROR=3
    readonly LOG_LEVEL_SUCCESS=4
fi

# Default log level (can be overridden by environment variable)
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}
LOG_FILE="${LOG_FILE:-}"
LOG_DIR="${LOG_DIR:-logs}"

# Colors for terminal output (only define if not already set)
if [ -z "${RED:-}" ]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly MAGENTA='\033[0;35m'
    readonly GRAY='\033[0;90m'
    readonly NC='\033[0m' # No Color
    readonly BOLD='\033[1m'
    readonly COLOR_RESET='\033[0m'
fi

# Initialize logging
init_logger() {
    local log_file_path="${1:-}"
    
    if [ -n "$log_file_path" ]; then
        LOG_FILE="$log_file_path"
        # Create log directory if it doesn't exist
        local log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            mkdir -p "$log_dir"
        fi
        # Create empty log file if it doesn't exist
        touch "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Set log level from environment if provided
    case "${LOG_LEVEL_OVERRIDE:-}" in
        DEBUG|debug)
            LOG_LEVEL=$LOG_LEVEL_DEBUG
            ;;
        INFO|info)
            LOG_LEVEL=$LOG_LEVEL_INFO
            ;;
        WARN|warn)
            LOG_LEVEL=$LOG_LEVEL_WARN
            ;;
        ERROR|error)
            LOG_LEVEL=$LOG_LEVEL_ERROR
            ;;
    esac
}

# Get timestamp for logs
_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get log level name
_get_log_level_name() {
    local level=$1
    case $level in
        $LOG_LEVEL_DEBUG)
            echo "DEBUG"
            ;;
        $LOG_LEVEL_INFO)
            echo "INFO"
            ;;
        $LOG_LEVEL_WARN)
            echo "WARN"
            ;;
        $LOG_LEVEL_ERROR)
            echo "ERROR"
            ;;
        $LOG_LEVEL_SUCCESS)
            echo "SUCCESS"
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}

# Get color for log level
_get_log_color() {
    local level=$1
    case $level in
        $LOG_LEVEL_DEBUG)
            echo "$GRAY"
            ;;
        $LOG_LEVEL_INFO)
            echo "$BLUE"
            ;;
        $LOG_LEVEL_WARN)
            echo "$YELLOW"
            ;;
        $LOG_LEVEL_ERROR)
            echo "$RED"
            ;;
        $LOG_LEVEL_SUCCESS)
            echo "$GREEN"
            ;;
        *)
            echo "$NC"
            ;;
    esac
}

# Core logging function
_log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(_get_timestamp)
    local level_name=$(_get_log_level_name $level)
    local color=$(_get_log_color $level)
    
    # Check if we should log this level
    if [ $level -lt $LOG_LEVEL ] && [ $level -ne $LOG_LEVEL_SUCCESS ]; then
        return 0
    fi
    
    # Format log message
    local formatted_message="[${timestamp}] [${level_name}] ${message}"
    
    # Output to console with color (if terminal supports it)
    if [ -t 1 ] && [ -n "${color:-}" ]; then
        echo -e "${color}${formatted_message}${NC:-}" >&2
    else
        echo -e "${formatted_message}" >&2
    fi
    
    # Write to log file if configured (without ANSI codes)
    if [ -n "$LOG_FILE" ]; then
        echo "[${timestamp}] [${level_name}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Debug logging (only shown when LOG_LEVEL=DEBUG)
log_debug() {
    _log $LOG_LEVEL_DEBUG "$@"
}

# Info logging
log_info() {
    _log $LOG_LEVEL_INFO "$@"
}

# Warning logging
log_warning() {
    _log $LOG_LEVEL_WARN "$@"
}

# Error logging
log_error() {
    _log $LOG_LEVEL_ERROR "$@"
}

# Success logging
log_success() {
    _log $LOG_LEVEL_SUCCESS "$@"
}

# Log with context (function name, line number)
log_debug_with_context() {
    local func_name="${FUNCNAME[1]:-unknown}"
    local line_num="${BASH_LINENO[0]:-0}"
    log_debug "[${func_name}:${line_num}] $*"
}

# Log error with context and stack trace
log_error_with_context() {
    local func_name="${FUNCNAME[1]:-unknown}"
    local line_num="${BASH_LINENO[0]:-0}"
    local message="$*"
    
    log_error "[${func_name}:${line_num}] $message"
    
    # Log stack trace in debug mode
    if [ $LOG_LEVEL -le $LOG_LEVEL_DEBUG ]; then
        local i=1
        while [ $i -lt ${#FUNCNAME[@]} ]; do
            log_debug "  at ${FUNCNAME[$i]} (${BASH_SOURCE[$i]:-unknown}:${BASH_LINENO[$((i-1))]:-0})"
            i=$((i + 1))
        done
    fi
}

# Log a section header
log_section() {
    local title="$*"
    local separator="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "$separator"
    log_info "  $title"
    log_info "$separator"
}

# Log a step in a process
log_step() {
    local step_num=$1
    local total_steps=$2
    shift 2
    local message="$*"
    log_info "[Step ${step_num}/${total_steps}] $message"
}

# Log command execution
log_command() {
    local cmd="$*"
    log_debug "Executing: $cmd"
}

# Log function entry/exit (for debugging)
log_function_entry() {
    local func_name="${FUNCNAME[1]:-unknown}"
    log_debug "→ Entering function: $func_name"
}

log_function_exit() {
    local func_name="${FUNCNAME[1]:-unknown}"
    local exit_code=${1:-0}
    if [ $exit_code -eq 0 ]; then
        log_debug "← Exiting function: $func_name (success)"
    else
        log_debug "← Exiting function: $func_name (failed with code: $exit_code)"
    fi
}

# Log variable values (for debugging)
log_variable() {
    local var_name=$1
    local var_value="${!var_name:-<unset>}"
    log_debug "$var_name = $var_value"
}

# Set log file for a specific operation
set_log_file() {
    local log_file_path="$1"
    LOG_FILE="$log_file_path"
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
}

# Append to existing log file
log_to_file() {
    local log_file_path="$1"
    shift
    local message="$*"
    local timestamp=$(_get_timestamp)
    
    local log_dir=$(dirname "$log_file_path")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
    
    echo "[${timestamp}] ${message}" >> "$log_file_path" 2>/dev/null || true
}

# Rotate log file if it exceeds size limit
rotate_log_file() {
    local log_file="${1:-$LOG_FILE}"
    local max_size_mb=${2:-10}
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
    if [ ! -f "$log_file" ]; then
        return 0
    fi
    
    local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
    
    if [ "$file_size" -gt "$max_size_bytes" ]; then
        local backup_file="${log_file}.$(date +%Y%m%d_%H%M%S).old"
        mv "$log_file" "$backup_file" 2>/dev/null || true
        log_info "Rotated log file: $log_file (size: $file_size bytes)"
    fi
}

# Cleanup old log files
cleanup_old_logs() {
    local log_dir="${1:-$LOG_DIR}"
    local days_to_keep=${2:-7}
    
    if [ ! -d "$log_dir" ]; then
        return 0
    fi
    
    find "$log_dir" -name "*.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null || true
    log_debug "Cleaned up log files older than $days_to_keep days in $log_dir"
}

# Export functions for use in other scripts
export -f init_logger
export -f log_debug log_info log_warning log_error log_success
export -f log_debug_with_context log_error_with_context
export -f log_section log_step log_command
export -f log_function_entry log_function_exit log_variable
export -f set_log_file log_to_file rotate_log_file cleanup_old_logs
