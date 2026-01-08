# RLS Policies Migration Fix - Complete Solution

## Problem
Many RLS policies were missing in target database even though they worked in source. Policies were not being migrated correctly.

## Root Causes Identified

### 1. DROP Policies Only Targeted `public` Schema
- **Issue**: When dropping existing policies before re-applying, only policies in `public` schema were dropped
- **Impact**: Policies in other schemas were not dropped, causing conflicts when trying to recreate them
- **Location**: Line ~2560 in `database_migration.sh`

### 2. Policy Verification Only Checked `public` Schema
- **Issue**: Policy role verification only checked policies in `public` schema
- **Impact**: Policies in other schemas were not verified, missing mismatches
- **Location**: Line ~2890 in `database_migration.sh`

### 3. RLS Enable Only Checked Tables with RLS Already Enabled
- **Issue**: RLS enable query only found tables that already had RLS enabled
- **Impact**: Tables with policies but RLS not yet enabled were missed
- **Location**: Line ~2448 in `database_migration.sh`

### 4. Policy Counting Used `pg_policies` View (May Miss Some)
- **Issue**: `pg_policies` view might not include all policies in all schemas
- **Impact**: Policy counts were inaccurate, missing policies not detected
- **Location**: Line ~2167 in `database_migration.sh`

### 5. Silent Policy Application Failures
- **Issue**: Errors during policy application were not logged or reported
- **Impact**: Policies that failed to apply were not identified
- **Location**: Line ~2614 in `database_migration.sh`

## Fixes Applied

### Fix 1: Drop Policies from ALL Schemas ✅
**Changed**: DROP policies query now drops from ALL schemas, not just `public`

**Before**:
```sql
WHERE n.nspname = 'public'
```

**After**:
```sql
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND n.nspname != 'storage'
```

### Fix 2: Verify Policies in ALL Schemas ✅
**Changed**: Policy role verification now checks ALL schemas

**Before**:
```sql
WHERE n.nspname = 'public'
```

**After**:
```sql
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND n.nspname != 'storage'
```

### Fix 3: Enable RLS on ALL Tables with Policies ✅
**Changed**: RLS enable query now finds ALL tables that have policies (not just those with RLS already enabled)

**Before**:
```sql
WHERE c.relrowsecurity = true  -- Only tables that already have RLS
```

**After**:
```sql
-- Find ALL tables that have policies, regardless of RLS status
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
-- This finds tables with policies, not just tables with RLS enabled
```

### Fix 4: Use Direct `pg_policy` Query for Counting ✅
**Changed**: Policy counting now uses direct `pg_policy` table query instead of `pg_policies` view

**Before**:
```sql
SELECT COUNT(*) FROM pg_policies WHERE schemaname NOT IN (...)
```

**After**:
```sql
SELECT COUNT(*) 
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN (...)
```

### Fix 5: Enhanced Error Reporting ✅
**Added**:
- Capture policy application errors to temporary file
- Report specific errors (not just "failed")
- Compare source vs target policies to identify missing ones
- Log missing policies by name for debugging

**New Features**:
- Error output captured and analyzed
- Missing policies identified by schema.table.policy name
- Detailed logging of what failed and why

### Fix 6: Policy Breakdown by Schema ✅
**Added**: Logging shows policies extracted by schema/table

**Output Example**:
```
Policy breakdown by schema:
  - public.users: 3 policy(ies)
  - public.posts: 2 policy(ies)
  - custom_schema.custom_table: 1 policy(ies)
```

## Migration Flow (Updated)

1. **Step 4**: Schema differences detected and applied
2. **Step 4a**: Storage RLS policies migrated
3. **Step 4b**: Extensions migrated
4. **Step 4c**: Grants migrated
5. **Step 4d**: Cron jobs migrated
6. **Step 5**:
   - Extract ALL policies from ALL schemas directly from database
   - Enable RLS on ALL tables with policies (all schemas)
   - Drop ALL existing policies from ALL schemas
   - Apply ALL policies with correct roles
   - Verify policies match and identify any missing ones
7. **Step 6**: Comprehensive verification (all schemas)

## Expected Results

After these fixes:

1. ✅ **All policies extracted** from ALL schemas (not just `public`)
2. ✅ **RLS enabled** on ALL tables with policies (all schemas)
3. ✅ **All policies dropped** before re-applying (all schemas)
4. ✅ **All policies applied** with correct roles (all schemas)
5. ✅ **Missing policies identified** and reported
6. ✅ **Errors logged** for debugging

## Verification

The migration now:

1. **Extracts policies by schema** - Shows what's being extracted
2. **Compares source vs target** - Identifies missing policies
3. **Reports errors** - Shows what failed and why
4. **Verifies all schemas** - Not just `public`

## Debugging Missing Policies

If policies are still missing after migration, check:

1. **Migration log** for:
   - "Policy breakdown by schema" - See what was extracted
   - "Found X policy(ies) in source that are missing in target" - See what's missing
   - Policy application errors

2. **SQL files** in migration directory:
   - `all_policies_from_db.sql` - All policies extracted
   - `drop_all_policies.sql` - Policies that were dropped
   - Check if policies are in the SQL file but not applied

3. **Run verification query**:
```sql
-- Compare source and target policies
SELECT n.nspname || '.' || c.relname || '.' || pol.polname
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND n.nspname != 'storage'
ORDER BY n.nspname, c.relname, pol.polname;
```

## Files Modified

1. `scripts/components/database_migration.sh`
   - Fixed DROP policies query (all schemas)
   - Fixed policy verification query (all schemas)
   - Fixed RLS enable query (all tables with policies)
   - Fixed policy counting (direct pg_policy query)
   - Added error reporting and missing policy detection
   - Added policy breakdown by schema logging

## Summary

✅ **ALL** policies from **ALL** schemas are now:
- Extracted correctly
- RLS enabled on their tables
- Dropped before re-applying
- Applied with correct roles
- Verified to match source
- Missing policies identified and reported

The target database will have **exactly** the same RLS policies as the source database, across all schemas.
