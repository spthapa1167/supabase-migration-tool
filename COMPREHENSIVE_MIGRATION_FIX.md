# Comprehensive Migration Fix - Complete Supabase Component Migration

## Overview
This document describes the comprehensive fixes applied to ensure the migration tool covers ALL Supabase components, making the target system behave exactly like the source system.

## Problems Identified

### 1. Storage RLS Policies Not Migrated
- **Issue**: Storage RLS policies were only migrated if `RESTORE_SUCCESS = true`
- **Impact**: Storage uploads failed with "new row violates row-level security policy" errors
- **Root Cause**: Storage schema is excluded from main migration (`PROTECTED_SCHEMAS`), and storage RLS migration was conditional

### 2. Missing Components
- **Database Extensions**: Not migrated
- **Cron Jobs (pg_cron)**: Not migrated
- **Storage RLS Policies**: Conditional migration only

### 3. Incomplete Verification
- No verification of storage RLS policies
- No verification of extensions
- No verification of cron jobs

## Fixes Applied

### Fix 1: Unconditional Storage RLS Migration

**Location**: `scripts/components/database_migration.sh`

**Changes**:
- Moved storage RLS migration (Step 4a) to run **unconditionally** before Step 5
- Runs independently of `RESTORE_SUCCESS` status
- Improved policy extraction query to handle all cases including `public` role

**Improved Query**:
```sql
SELECT 
    'CREATE POLICY ' || quote_ident(pol.polname) || 
    ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) ||
    ' FOR ' || CASE pol.polcmd
        WHEN 'r' THEN 'SELECT'
        WHEN 'a' THEN 'INSERT'
        WHEN 'w' THEN 'UPDATE'
        WHEN 'd' THEN 'DELETE'
        WHEN '*' THEN 'ALL'
    END ||
    CASE 
        WHEN array_length(pol.polroles, 1) > 0 AND (pol.polroles != ARRAY[0]::oid[]) THEN
            ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY rol.rolname)
        WHEN pol.polroles = ARRAY[0]::oid[] OR array_length(pol.polroles, 1) IS NULL THEN
            ' TO public'
        ELSE ''
    END ||
    -- USING and WITH CHECK clauses...
```

### Fix 2: Database Extensions Migration

**Location**: `scripts/components/database_migration.sh` - Step 4b

**Implementation**:
- Extracts all custom extensions from source (excluding default PostgreSQL extensions)
- Creates `CREATE EXTENSION IF NOT EXISTS` statements
- Applies extensions to target
- Handles superuser privilege requirements gracefully

**Excluded Extensions** (default PostgreSQL):
- `plpgsql`, `uuid-ossp`, `pgcrypto`, `pgjwt`, `pg_stat_statements`
- All `pg_*` and `pl*` extensions

### Fix 3: Cron Jobs Migration

**Location**: `scripts/components/database_migration.sh` - Step 4c

**Implementation**:
- Checks if `pg_cron` extension exists in source
- Extracts all cron jobs with their schedules and commands
- Installs `pg_cron` in target if needed
- Drops existing cron jobs in target before applying new ones
- Applies all cron jobs from source

**Query**:
```sql
SELECT 'SELECT cron.schedule(' || quote_literal(jobname) || ', ' || 
       quote_literal(schedule) || ', ' || quote_literal(command) || ');'
FROM cron.job
WHERE jobname IS NOT NULL
ORDER BY jobid;
```

### Fix 4: Comprehensive Verification

**Location**: `scripts/components/database_migration.sh` - Step 6

**Verification Checks**:
1. **Storage RLS Policies**: Compares policy counts between source and target
2. **Database Extensions**: Compares extension counts
3. **Cron Jobs**: Compares cron job counts (if pg_cron is installed)
4. **Storage RLS Enabled**: Verifies RLS is enabled on `storage.objects` and `storage.buckets`

**Always Runs**: Verification runs independently of `RESTORE_SUCCESS` status

## Migration Flow (Updated)

1. **Step 1-3**: Schema dump and restore (existing)
2. **Step 4a**: Migrate Storage RLS Policies (NEW - unconditional)
3. **Step 4b**: Migrate Database Extensions (NEW)
4. **Step 4c**: Migrate Cron Jobs (NEW)
5. **Step 5**: Verify and retry policies/roles (existing, but now includes storage)
6. **Step 6**: Comprehensive Verification (NEW - unconditional)

## Components Now Migrated

### ✅ Fully Migrated
- Database schema (tables, views, functions, indexes, constraints)
- Database data (with `--data` flag)
- RLS policies (public schema + storage schema)
- Database roles and grants
- Auth users (with `--users` flag)
- Storage bucket configurations
- Storage bucket files (with `--files` flag)
- Storage RLS policies (NEW - unconditional)
- Database extensions (NEW)
- Cron jobs (NEW)
- Edge functions
- Secrets (keys only, values need manual update)

### ⚠️ Partially Migrated
- Secrets: Keys migrated, values need manual update (security)

### ❌ Not Migrated (Platform-Managed)
- Realtime publications/subscriptions (managed by Supabase)
- Auth provider configurations (managed via Dashboard)
- Project settings (managed via Dashboard)
- Network restrictions (managed via Dashboard)

## Expected Results

After these fixes:

1. ✅ **Storage RLS policies are always migrated** (even if main restore fails)
2. ✅ **All database extensions are migrated** from source to target
3. ✅ **All cron jobs are migrated** (if pg_cron is installed)
4. ✅ **Comprehensive verification** catches any mismatches
5. ✅ **Target system behaves exactly like source** for all migrated components

## Testing

To verify the fixes:

1. **Check Storage RLS Policies**:
   ```sql
   SELECT schemaname, tablename, policyname, cmd 
   FROM pg_policies 
   WHERE schemaname = 'storage'
   ORDER BY tablename, policyname;
   ```

2. **Check Extensions**:
   ```sql
   SELECT extname, extversion 
   FROM pg_extension 
   WHERE extname NOT LIKE 'pg_%'
   ORDER BY extname;
   ```

3. **Check Cron Jobs**:
   ```sql
   SELECT jobname, schedule, command 
   FROM cron.job 
   ORDER BY jobid;
   ```

4. **Test Storage Uploads**: Should work without RLS violations

## Files Modified

1. `scripts/components/database_migration.sh`
   - Added Step 4a: Unconditional Storage RLS Migration
   - Added Step 4b: Database Extensions Migration
   - Added Step 4c: Cron Jobs Migration
   - Added Step 6: Comprehensive Verification
   - Improved storage policy extraction query

## Migration Order

The migration now follows this order to ensure dependencies are met:

1. Schema (tables, functions, etc.)
2. Storage RLS enable
3. Storage RLS policies
4. Extensions
5. Cron jobs
6. Public schema RLS policies
7. Data (if `--data` flag)
8. Auth users (if `--users` flag)
9. Comprehensive verification

This ensures:
- Tables exist before policies are created
- RLS is enabled before policies are applied
- Extensions are available before functions that use them
- All components are verified after migration

## Notes

- Storage RLS migration now runs **unconditionally** - it will always attempt to migrate storage policies
- Extensions migration handles privilege requirements gracefully
- Cron jobs migration automatically installs `pg_cron` if needed
- Comprehensive verification provides detailed feedback on what matches and what doesn't
- All fixes work together to ensure complete and accurate migration
