# RLS Policy Migration Fix Summary

## Problem
After migration, the target system was experiencing RLS policy violation issues while the source system had no issues. Similar policies should have been migrated, but they were either missing or not properly applied.

## Root Causes Identified

1. **`--no-privileges` flag in pg_dump**: This flag was excluding RLS policies from schema dumps in `policies_migration_new.sh`
2. **Incorrect order of operations**: Policies were being created before RLS was enabled on tables, causing policy violations
3. **Missing RLS enable verification**: No verification that RLS was enabled on all tables that should have policies
4. **Incomplete policy extraction**: Multi-line policy definitions might not have been properly extracted

## Fixes Applied

### 1. Removed `--no-privileges` Flag from `policies_migration_new.sh`

**Locations Fixed:**
- Line 314: Source schema dump
- Line 377: Target schema dump for comparison (verify-only mode)
- Line 487: Target schema dump after migration (verification)

**Impact:** Policies are now included in schema dumps, ensuring they can be migrated.

### 2. Proper Order of Operations for Policy Application

**File:** `scripts/main/policies_migration_new.sh`

**Changes:**
- Extract policies and RLS enable statements separately from schema dump
- Apply schema (tables, functions, etc.) first
- Enable RLS on tables that should have it
- Then apply policies

**Implementation:**
```bash
# Step 1: Apply schema without policies
# Step 2: Enable RLS on tables
# Step 3: Apply policies
```

This ensures that:
- Tables exist before policies are created
- RLS is enabled before policies are applied
- Policies can be created without errors

### 3. Improved Policy Extraction

**Files:** `scripts/main/policies_migration_new.sh`, `scripts/components/database_migration.sh`

**Changes:**
- Separate extraction of RLS enable statements from policy creation statements
- Better handling of multi-line policy definitions using both `grep` and `awk`
- Extract policies before any filtering that might remove them

### 4. RLS Enable Verification and Auto-Fix

**File:** `scripts/components/database_migration.sh`

**New Feature:**
- Added function to check if tables with policies have RLS enabled
- Automatically detects tables that have policies but RLS not enabled
- Attempts to enable RLS on these tables automatically
- Provides detailed logging of which tables need RLS enabled

**Query Used:**
```sql
SELECT DISTINCT schemaname || '.' || tablename
FROM pg_policies p
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p.schemaname
      AND c.relname = p.tablename
      AND c.relrowsecurity = true
)
```

### 5. Enhanced Error Handling

**Files:** Both migration scripts

**Improvements:**
- Better error messages that distinguish between expected errors (objects already exist) and actual failures
- Detailed logging of policy application attempts
- Retry logic with verification after each attempt
- Clear indication when manual intervention is required

## Expected Results

After these fixes:

1. ✅ All RLS policies from source are included in schema dumps
2. ✅ Policies are applied in the correct order (tables → RLS enable → policies)
3. ✅ RLS is automatically enabled on tables that have policies
4. ✅ Verification catches and fixes tables missing RLS
5. ✅ Better error reporting helps identify any remaining issues

## Migration Process Flow (Fixed)

1. **Export Source Schema** (with policies included)
   - Extract policies separately
   - Extract RLS enable statements separately
   - Create schema dump without policies

2. **Apply to Target** (in order):
   - Apply schema (tables, functions, etc.)
   - Enable RLS on tables
   - Apply policies

3. **Verification**:
   - Count policies in source vs target
   - Check that all tables with policies have RLS enabled
   - Auto-fix any missing RLS
   - Report any remaining issues

## Testing Recommendations

1. Run a test migration from a known-good source to a test target
2. Verify policy counts match between source and target
3. Check that all tables with policies have RLS enabled
4. Test application functionality to ensure no RLS violations occur
5. Review migration logs for any warnings or errors

## Additional Fix: Storage RLS Policies

### Problem
Storage schema is excluded from database migrations (`PROTECTED_SCHEMAS`), so RLS policies on `storage.objects` and `storage.buckets` were not being migrated. This caused "new row violates row-level security policy" errors when uploading files.

### Solution
Added Step 5a in `database_migration.sh` to specifically migrate storage RLS policies:

1. **Extract Storage Policies**: Queries source database for all policies on `storage.objects` and `storage.buckets`
2. **Enable RLS**: Ensures RLS is enabled on storage tables before applying policies
3. **Drop Existing Policies**: Removes existing policies on target to avoid conflicts
4. **Apply Policies**: Creates all storage policies from source on target
5. **Verify**: Confirms all policies were successfully migrated

**Implementation Details:**
- Uses `pg_policy` and `pg_polroles` system tables for accurate policy extraction
- Handles policy roles, USING clauses, and WITH CHECK clauses correctly
- Provides detailed logging and error handling

## Files Modified

1. `scripts/main/policies_migration_new.sh`
   - Removed `--no-privileges` flag (3 locations)
   - Added proper order of operations for policy application
   - Improved policy extraction

2. `scripts/components/database_migration.sh`
   - Improved policy extraction to separate RLS enable from policy creation
   - Added RLS enable step before policy application
   - Added verification and auto-fix for missing RLS on tables
   - **NEW**: Added Step 5a to migrate storage RLS policies

## Notes

- The `--no-privileges` flag was the primary cause of policies not being migrated
- The order of operations fix ensures policies can be created without errors
- The RLS verification and auto-fix addresses cases where RLS wasn't enabled on tables
- **Storage policies are now automatically migrated** even though storage schema is excluded from main migration
- These fixes work together to ensure complete and correct policy migration
