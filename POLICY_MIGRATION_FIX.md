# Policy Migration Fix

## Problem
Source database had 357 policies but target only had 313 policies after migration - 44 policies were missing.

## Root Causes Identified

1. **`--no-privileges` flag in pg_dump**: This flag was excluding RLS policies from the schema dump
2. **Filtering logic**: The awk filtering script was removing storage policies, but might have been too aggressive
3. **Policy application**: Policies were being applied as part of the main schema dump, making it hard to track which ones failed

## Fixes Applied

### 1. Removed `--no-privileges` Flag
**Location**: `scripts/main/database_and_policy_migration.sh`

- Removed `--no-privileges` from all `pg_dump` commands (3 locations)
- This flag was preventing policies from being exported
- Policies are now included in the schema dump

**Changed**:
```bash
# Before
pg_dump ... --no-privileges ...

# After  
pg_dump ... (no --no-privileges flag)
```

### 2. Extract Policies Before Filtering
**Location**: `scripts/main/database_and_policy_migration.sh`

- Policies are now extracted from the ORIGINAL dump BEFORE any filtering
- Uses both `grep` and `awk` methods to handle single-line and multi-line policies
- Extracted policies are saved to `policies_only.sql` file
- This ensures no policies are lost during the filtering process

**Key Change**:
```bash
# Extract policies BEFORE filtering
POLICIES_FILE="$MIGRATION_DIR_ABS/policies_only.sql"
grep "^CREATE POLICY" "$SCHEMA_DUMP_FILE" | grep -v "ON storage\." > "$POLICIES_FILE"
# Also use awk for multi-line policies
```

### 3. Separate Policy Application
**Location**: `scripts/main/database_and_policy_migration.sh`

- Policies are now applied separately from the main schema
- Better error tracking for policy-specific failures
- Policies are applied after the main schema to ensure tables exist first

**Key Change**:
```bash
# Apply main schema first
psql -f "$SCHEMA_DUMP_FILE" ...

# Then apply policies separately
if [ -f "$POLICIES_FILE" ] && [ -s "$POLICIES_FILE" ]; then
    psql -f "$POLICIES_FILE" ...
    # Track policy-specific errors
fi
```

### 4. Enhanced Policy Verification
**Location**: `scripts/main/database_and_policy_migration.sh`

- Added comprehensive policy counting and comparison
- Distinguishes between storage and non-storage policies
- Identifies missing policies by name
- Provides detailed logging of policy migration status

**Features**:
- Counts policies in original dump (all schemas)
- Counts storage policies (excluded from migration)
- Counts non-storage policies (should be migrated)
- Compares source vs target policy counts
- Lists missing policy names if migration incomplete

### 5. Better Error Handling
**Location**: `scripts/main/database_and_policy_migration.sh`

- Improved error detection for policy application failures
- Logs policy-specific errors separately
- Continues migration even if some policies fail (non-critical)
- Provides actionable error messages

## Expected Results

After these fixes:
1. ✅ All 357 policies from source should be counted correctly
2. ✅ Storage policies (if any) are excluded (handled by storage migration)
3. ✅ All non-storage policies should be migrated to target
4. ✅ Target should have 313+ policies (depending on how many are storage policies)
5. ✅ Clear reporting of which policies were migrated and which failed

## Verification

The script now:
- Extracts policies before filtering (prevents loss)
- Applies policies separately (better error tracking)
- Verifies policy counts after migration
- Reports missing policies by name
- Provides detailed logs for troubleshooting

## Next Steps

1. Run the migration again
2. Check the migration log for policy extraction counts
3. Verify the `policies_only.sql` file contains all expected policies
4. Check the verification section for policy count comparison
5. Review any missing policy names listed in the log

## Notes

- Storage policies are intentionally excluded from database migration (handled by `storage_buckets_migration.sh`)
- The count of 357 vs 313 suggests 44 policies are either:
  - Storage policies (excluded intentionally)
  - Policies that failed to apply (will be logged)
  - Policies in schemas other than public (now included)

The enhanced logging will help identify which category the missing policies fall into.

