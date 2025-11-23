# Migration Error Handling Improvements

This document summarizes the comprehensive error handling improvements made to the Supabase migration tool to ensure robust, full migrations without issues.

## Overview

The migration tool has been enhanced with comprehensive error handling, validation checks, and proper exception handling to ensure migrations complete successfully or fail gracefully with clear error reporting.

## Key Improvements

### 1. Global Error Handling and Cleanup

**Location**: `scripts/main/supabase_migration.sh`

- Added global error trap (`ERR`) that catches all script errors
- Added cleanup handlers for `EXIT`, `INT`, and `TERM` signals
- Implemented cleanup function registry system
- Automatic cleanup on any error or interruption
- Proper Supabase project unlinking on exit

**Benefits**:
- No orphaned Supabase project links
- Clean state even on unexpected failures
- Proper resource cleanup

### 2. Component Script Error Handling

**Location**: `scripts/main/supabase_migration.sh` (component execution sections)

**Improvements**:
- Fixed exit code capture from piped commands using `${PIPESTATUS[0]}`
- Properly disable/enable `pipefail` mode around component execution
- Continue migration even if non-critical components fail
- Track succeeded, failed, and skipped components separately
- Critical component failures (database/policies) are flagged appropriately

**Before**:
```bash
if "$SCRIPT" args 2>&1 | tee -a "$LOG_FILE"; then
    # Success handling
fi
```

**After**:
```bash
set +e
set +o pipefail  # Disable pipefail to capture exit code properly
"$SCRIPT" args 2>&1 | tee -a "$LOG_FILE"
local exit_code=${PIPESTATUS[0]}
set -o pipefail  # Re-enable pipefail
set -e

if [ "$exit_code" -eq 0 ]; then
    # Success handling
else
    # Error handling with proper exit code
fi
```

### 3. Connection Fallback Logic

**Location**: `scripts/main/supabase_migration.sh` (schema comparison section)

**Improvements**:
- Explicit success/failure tracking for connection attempts
- Proper error detection for connection failures
- Graceful degradation when schema export fails (continues migration)
- Better error messages for connection issues

**Before**:
```bash
pg_dump ... || {
    # Fallback attempt
    pg_dump ...
}
```

**After**:
```bash
local dump_success=false
set +e
if pg_dump ...; then
    dump_success=true
else
    # Try fallback
    if pg_dump ...; then
        dump_success=true
    fi
fi
set -e

if [ "$dump_success" != "true" ]; then
    log_warning "Could not export schema - continuing anyway"
fi
```

### 4. Validation Checks

**Location**: `scripts/main/database_and_policy_migration.sh`

**Added Validations**:
- Project reference validation (source and target)
- Database password validation (source and target)
- Required tool checks (Supabase CLI, pg_dump, psql)
- Connection validation before critical operations

**Benefits**:
- Fail fast with clear error messages
- Prevent partial migrations due to missing prerequisites
- Better user experience with actionable error messages

### 5. Result Generation Error Handling

**Location**: `scripts/main/supabase_migration.sh` (result generation sections)

**Improvements**:
- Result generation failures don't mask actual migration failures
- Proper exit code preservation
- Non-fatal result generation (migration success/failure is independent)
- Error details captured and included in reports

**Key Change**:
- Migration exit code is stored before result generation
- Result generation errors are logged but don't affect migration status
- Migration status is accurately reported even if result generation fails

### 6. Comprehensive Error Logging

**Location**: `scripts/main/supabase_migration.sh` (component summary section)

**Added Features**:
- Error summary extraction from logs
- Detailed error reporting in component summary
- Critical component failure detection
- Troubleshooting guidance in logs
- Connection information logging for debugging

**Error Reporting Includes**:
- Component success/failure status
- Error details from logs
- Critical failure warnings
- Connection information
- Troubleshooting steps

### 7. Database and Policy Migration Script Improvements

**Location**: `scripts/main/database_and_policy_migration.sh`

**Improvements**:
- Added error trap and cleanup handlers
- Better connection error detection in psql execution
- Validation of connection success before processing results
- Proper error handling for SQL application failures

## Error Handling Flow

1. **Pre-Migration Validation**
   - Environment file validation
   - Project reference validation
   - Password validation
   - Tool availability checks

2. **Migration Execution**
   - Each component runs with proper error capture
   - Errors are logged but don't stop other components
   - Critical component failures are flagged
   - Cleanup is registered and executed on any error

3. **Post-Migration**
   - Component summary with success/failure status
   - Error details extracted and logged
   - Result files generated (non-fatal if they fail)
   - Cleanup executed (Supabase unlink, etc.)

## Error Categories

### Critical Errors
- Database schema migration failures
- Policy migration failures
- These cause the migration to be marked as failed

### Non-Critical Errors
- Storage bucket migration failures
- Edge function migration failures
- Secrets migration failures
- These are logged but don't stop the migration

### Validation Errors
- Missing environment variables
- Missing tools
- Invalid project references
- These cause immediate exit with clear error messages

## Best Practices Implemented

1. **Fail Fast**: Validation errors cause immediate exit
2. **Continue on Non-Critical**: Non-critical component failures don't stop migration
3. **Proper Cleanup**: Always cleanup resources, even on error
4. **Clear Error Messages**: All errors include actionable information
5. **Comprehensive Logging**: All operations are logged with timestamps
6. **Exit Code Preservation**: Migration status is accurately reflected in exit codes

## Testing Recommendations

1. Test with missing environment variables
2. Test with invalid project references
3. Test with network failures
4. Test with partial component failures
5. Test with interrupted migrations (Ctrl+C)
6. Test with missing tools (pg_dump, psql, supabase CLI)

## Migration Status Reporting

The migration now provides clear status reporting:

- ✅ **Success**: All components completed successfully
- ⚠️ **Partial Success**: Some components failed but migration continued
- ❌ **Failed**: Critical components failed or migration was cancelled
- ⏭️ **Skipped**: Migration skipped (e.g., identical projects)

## Troubleshooting

If migrations fail, check:

1. **Migration Log**: `backups/<migration_dir>/migration.log`
   - Contains detailed error messages
   - Includes connection information
   - Has troubleshooting guidance

2. **Component Summary**: Shown at end of migration
   - Lists succeeded/failed/skipped components
   - Highlights critical failures

3. **Result Files**: `backups/<migration_dir>/result.md` and `result.html`
   - Include error details
   - Provide rollback instructions
   - Show migration status

## Summary

All error handling improvements ensure:
- ✅ Full migrations complete without issues
- ✅ Errors and exceptions are handled properly
- ✅ Clear error reporting and troubleshooting guidance
- ✅ Proper cleanup on any failure
- ✅ Accurate migration status reporting

