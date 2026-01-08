# Storage RLS Policy Migration Fix

## Problem
After database migration, storage uploads were failing with:
```
StorageApiError: new row violates row-level security policy
```

This occurred because:
1. The `storage` schema is excluded from database migrations (it's in `PROTECTED_SCHEMAS`)
2. Storage RLS policies on `storage.objects` and `storage.buckets` were not being migrated
3. RLS was enabled on storage tables but policies were missing or incorrect

## Root Cause
The `storage` schema is intentionally excluded from database migrations because it's managed by Supabase's storage system. However, custom RLS policies on storage tables still need to be migrated.

## Solution Implemented

Added **Step 5a: Migrating Storage RLS Policies** to `database_migration.sh` that:

1. **Extracts storage policies from source** using a comprehensive query that:
   - Gets all policies on `storage.objects` and `storage.buckets`
   - Includes policy names, commands (SELECT, INSERT, UPDATE, DELETE, ALL)
   - Includes roles, USING clauses, and WITH CHECK clauses
   - Uses `pg_policy` and `pg_polroles` system tables for accuracy

2. **Enables RLS on storage tables** if not already enabled:
   ```sql
   ALTER TABLE IF EXISTS storage.objects ENABLE ROW LEVEL SECURITY;
   ALTER TABLE IF EXISTS storage.buckets ENABLE ROW LEVEL SECURITY;
   ```

3. **Drops existing policies** on target to avoid conflicts before applying new ones

4. **Applies all storage policies** from source to target

5. **Verifies migration** by counting policies and comparing source vs target

## Code Location

**File**: `scripts/components/database_migration.sh`  
**Location**: After Step 5 (Verifying Policies and Roles), before final verification  
**Step**: Step 5a: Migrating Storage RLS Policies

## How It Works

The extraction function uses this query:
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
    -- Roles, USING, WITH CHECK clauses...
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'storage'
  AND c.relname IN ('objects', 'buckets')
```

## Expected Results

After this fix:
- ✅ All storage RLS policies are migrated from source to target
- ✅ RLS is enabled on `storage.objects` and `storage.buckets`
- ✅ Storage uploads work without RLS violations
- ✅ Policy count matches between source and target

## Testing

To verify the fix worked:
1. Run a migration from source to target
2. Check the migration log for "Step 5a: Migrating Storage RLS Policies"
3. Verify storage policies in target:
   ```sql
   SELECT schemaname, tablename, policyname, cmd 
   FROM pg_policies 
   WHERE schemaname = 'storage'
   ORDER BY tablename, policyname;
   ```
4. Test file uploads to ensure no RLS violations

## Manual Fix (If Needed)

If the automatic migration didn't work, you can manually extract and apply policies:

**On Source:**
```sql
SELECT 
    'CREATE POLICY ' || quote_ident(pol.polname) || 
    ' ON storage.' || c.relname ||
    ' FOR ' || CASE pol.polcmd
        WHEN 'r' THEN 'SELECT'
        WHEN 'a' THEN 'INSERT'
        WHEN 'w' THEN 'UPDATE'
        WHEN 'd' THEN 'DELETE'
        WHEN '*' THEN 'ALL'
    END ||
    CASE 
        WHEN array_length(pol.polroles, 1) > 0 THEN
            ' TO ' || string_agg(quote_ident(rol.rolname), ', ')
        ELSE ''
    END ||
    CASE 
        WHEN pol.polqual IS NOT NULL THEN
            ' USING (' || pg_get_expr(pol.polqual, pol.polrelid) || ')'
        ELSE ''
    END ||
    CASE 
        WHEN pol.polwithcheck IS NOT NULL THEN
            ' WITH CHECK (' || pg_get_expr(pol.polwithcheck, pol.polrelid) || ')'
        ELSE ''
    END || ';' as policy_sql
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
WHERE n.nspname = 'storage'
  AND c.relname IN ('objects', 'buckets')
GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, pol.polqual, pol.polrelid, pol.polwithcheck
ORDER BY c.relname, pol.polname;
```

**On Target:**
1. Enable RLS:
   ```sql
   ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
   ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
   ```
2. Run the CREATE POLICY statements from source

## Related Files

- `scripts/components/database_migration.sh` - Main migration script with storage RLS fix
- `RLS_POLICY_FIX_SUMMARY.md` - Summary of all RLS policy fixes
