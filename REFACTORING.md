# Code Refactoring Documentation

## Overview

This document describes the refactoring work done to improve code robustness, maintainability, testability, and troubleshooting capabilities of the Supabase Migration Tool.

## Key Improvements

### 1. Centralized Logging System (`lib/logger.sh`)

**Features:**
- Log levels: DEBUG, INFO, WARN, ERROR, SUCCESS
- Timestamped log messages
- File and console logging support
- Structured logging with context
- Log rotation and cleanup utilities

**Usage:**
```bash
source lib/logger.sh

# Initialize logger with log file
init_logger "/path/to/logfile.log"

# Use logging functions
log_debug "Debug information"
log_info "General information"
log_warning "Warning message"
log_error "Error occurred"
log_success "Operation completed"

# Log with context
log_debug_with_context "Detailed debug info"
log_error_with_context "Error with stack trace"

# Log sections and steps
log_section "Migration Process"
log_step 1 5 "Backing up database"
```

**Configuration:**
- Set log level via `LOG_LEVEL_OVERRIDE` environment variable
- Log files can be rotated automatically
- Old logs are cleaned up automatically

### 2. Robust Error Handling (`lib/error_handler.sh`)

**Features:**
- Standardized exit codes
- Error recovery with retry mechanisms
- Command validation
- Resource cleanup on exit
- Context-aware error messages

**Exit Codes:**
- `0`: Success
- `1`: General error
- `10`: Configuration error
- `11`: Connection error
- `12`: Validation error
- `13`: Backup error
- `14`: Restore error
- `15`: Migration error
- `16`: User cancelled
- `17`: Dependency error

**Usage:**
```bash
source lib/error_handler.sh

# Validate dependencies
check_command "pg_dump" "PostgreSQL dump tool required"

# Retry commands with exponential backoff
retry_command 3 2 "pg_dump -h host -U user -d db"

# Validate inputs
validate_file "/path/to/file.sql" "SQL file required"
validate_directory "/path/to/dir" "Directory required"
validate_required_vars "VAR1" "VAR2"

# Register cleanup functions
cleanup_temp_files() {
    rm -f /tmp/temp_*.sql
}
register_cleanup cleanup_temp_files

# Safe exit with cleanup
safe_exit $EXIT_SUCCESS
```

### 3. Unit Testing Framework (`tests/unit_tests.sh`)

**Features:**
- Simple bash testing framework
- Assertion functions
- Test suites organization
- Detailed test reporting

**Usage:**
```bash
# Run all tests
./tests/unit_tests.sh

# Add new test
test_my_function() {
    assert_equal "expected" "$(my_function)" "Function should return expected value"
}

# Add to test suite
run_test_suite "My Tests" test_my_function
```

**Assertions:**
- `assert_true <condition> <message>`
- `assert_false <condition> <message>`
- `assert_equal <expected> <actual> <message>`
- `assert_not_equal <expected> <actual> <message>`
- `assert_file_exists <path> <message>`
- `assert_file_not_exists <path> <message>`
- `assert_exit_code <code> <command> <message>`

## Migration Guide

### For Existing Scripts

To migrate existing scripts to use the new logging and error handling:

1. **Replace logging functions:**
   ```bash
   # Old
   log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
   
   # New
   source lib/logger.sh
   # log_info is already available
   ```

2. **Add error handling:**
   ```bash
   # Old
   if [ ! -f "$file" ]; then
       log_error "File not found"
       exit 1
   fi
   
   # New
   source lib/error_handler.sh
   validate_file "$file" "File not found" || safe_exit $EXIT_CONFIG_ERROR
   ```

3. **Initialize logging:**
   ```bash
   # At the start of your script
   source lib/logger.sh
   init_logger "$LOG_FILE"
   ```

4. **Add cleanup:**
   ```bash
   # Register cleanup functions
   cleanup_on_exit() {
       supabase unlink --yes 2>/dev/null || true
       rm -f /tmp/temp_*.sql
   }
   register_cleanup cleanup_on_exit
   ```

### Best Practices

1. **Always initialize logger at script start:**
   ```bash
   source lib/logger.sh
   init_logger "$LOG_FILE"
   ```

2. **Use appropriate log levels:**
   - DEBUG: Detailed debugging information
   - INFO: General operational messages
   - WARN: Warning messages
   - ERROR: Error conditions
   - SUCCESS: Successful operations

3. **Validate inputs early:**
   ```bash
   validate_required_vars "SOURCE_ENV" "TARGET_ENV"
   validate_file "$CONFIG_FILE" "Config file required"
   ```

4. **Use retry for network operations:**
   ```bash
   retry_command 3 2 "pg_dump -h $HOST -U $USER -d $DB"
   ```

5. **Register cleanup functions:**
   ```bash
   register_cleanup cleanup_function
   ```

6. **Use safe_exit instead of exit:**
   ```bash
   safe_exit $EXIT_SUCCESS  # Executes cleanup functions
   ```

## Testing

Run unit tests:
```bash
./tests/unit_tests.sh
```

Test output includes:
- Tests run count
- Pass/fail status
- Failed test details

## Troubleshooting

### Enable Debug Logging

Set the log level to DEBUG:
```bash
export LOG_LEVEL_OVERRIDE=DEBUG
./your_script.sh
```

### View Log Files

Log files are created in the backup directories or specified locations:
```bash
tail -f backups/migration_*/migration.log
```

### Check Error Context

Errors now include context information:
- Function name
- Line number
- Stack trace (in DEBUG mode)

## File Structure

```
lib/
├── logger.sh           # Logging utilities
├── error_handler.sh    # Error handling utilities
├── supabase_utils.sh   # Supabase-specific utilities
├── migration_utils.sh  # Migration utilities
└── rollback_utils.sh   # Rollback utilities

tests/
└── unit_tests.sh       # Unit test framework and tests
```

## Benefits

1. **Maintainability:**
   - Centralized logging reduces code duplication
   - Consistent error handling across all scripts
   - Clear separation of concerns

2. **Testability:**
   - Unit tests verify core utilities
   - Easy to add new test cases
   - Automated test execution

3. **Troubleshooting:**
   - Detailed logging with timestamps
   - Error context and stack traces
   - Log file rotation prevents disk space issues

4. **Robustness:**
   - Standardized exit codes
   - Retry mechanisms for transient failures
   - Automatic cleanup on exit
   - Input validation

5. **User Experience:**
   - Better error messages
   - Progress indicators with log_step
   - Clear success/failure indicators

## Future Improvements

Potential enhancements:
1. Integration tests for full migration workflows
2. Performance benchmarking
3. Log aggregation and analysis
4. Enhanced error recovery strategies
5. Configuration file support
6. Dry-run mode improvements
