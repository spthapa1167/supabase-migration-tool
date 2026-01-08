# Policy Roles and Storage Buckets Migration Fix

## Problems Identified

After migration, the target system was missing:

1. **Policy Roles**: CMS Upload Policy should include `cms, admin, super_admin` but only had `cms`
2. **Storage Buckets**: Only `cms-uploads` migrated, other buckets missing
3. **INSERT Policies**: Teacher table missing INSERT policy

## Root Causes

### 1. Policy Roles Not Preserved
- **Issue**: Policies were extracted from dump files which don't preserve role information correctly
- **Impact**: Policies migrated without their associated roles, causing access issues
- **Example**: Policy that should allow `cms, admin, super_admin` only allowed `cms`

### 2. Storage Buckets Skipped
- **Issue**: Storage migration script skips buckets that already exist in target (incremental mode)
- **Impact**: Only new buckets are migrated, existing buckets are skipped
- **Example**: If `cms-uploads` exists in target but other buckets don't, only new buckets are created

### 3. INSERT Policies Missing
- **Issue**: Policy extraction might miss some policy types or policies aren't being applied correctly
- **Impact**: Tables missing INSERT policies can't have data inserted via application

## Fixes Applied

### Fix 1: Direct Database Policy Extraction

**Location**: `scripts/components/database_migration.sh` - Step 5

**Changes**:
- **Extract policies directly from database** (not from dump files) using `pg_policy` system table
- This ensures all role information is preserved correctly
- Extracts policies with complete role information including multiple roles per policy

**Key Query**:
```sql
SELECT 
    'CREATE POLICY ' || quote_ident(pol.polname) || 
    ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) ||
    ' FOR ' || CASE pol.polcmd
        WHEN 'r' THEN 'SELECT'
        WHEN 'a' THEN 'INSERT'  -- This ensures INSERT policies are captured
        WHEN 'w' THEN 'UPDATE'
        WHEN 'd' THEN 'DELETE'
        WHEN '*' THEN 'ALL'
    END ||
    ' TO ' || string_agg(DISTINCT quote_ident(rol.rolname), ', ' ORDER BY rol.rolname) ||
    -- USING and WITH CHECK clauses...
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
WHERE n.nspname = 'public'
GROUP BY pol.polname, n.nspname, c.relname, pol.polcmd, ...
```

**Benefits**:
- ✅ All roles preserved (cms, admin, super_admin)
- ✅ All policy types captured (SELECT, INSERT, UPDATE, DELETE, ALL)
- ✅ Direct extraction ensures accuracy

### Fix 2: Drop Policies Before Re-application

**Location**: `scripts/components/database_migration.sh` - Step 5

**Changes**:
- Drop all existing policies on target before applying new ones
- This ensures policies are recreated with correct roles
- Prevents conflicts from policies with incorrect roles

**Implementation**:
```bash
# Drop all existing policies first
DROP_POLICIES_SQL="$MIGRATION_DIR/drop_all_policies.sql"
# Extract DROP statements for all policies
# Then apply new policies with correct roles
```

### Fix 3: Force All Storage Buckets Migration

**Location**: 
- `scripts/main/storage_buckets_migration.sh`
- `utils/storage-migration.js`

**Changes**:
- Added `--force-all`, `--force`, `--all-buckets`, `--migrate-all` flags
- When set, migrates ALL buckets even if they exist in target
- Useful for ensuring all bucket configurations match source

**Usage**:
```bash
./scripts/main/storage_buckets_migration.sh dev test --force-all
```

**Logic Change**:
```javascript
// Before: Skip if bucket exists and files not included
if (!INCLUDE_FILES) {
    continue;  // Skip bucket
}

// After: Skip only if bucket exists AND files not included AND force flag not set
if (!INCLUDE_FILES && !FORCE_ALL_BUCKETS) {
    continue;  // Skip bucket
}
// If FORCE_ALL_BUCKETS is true, process bucket for configuration sync
```

### Fix 4: Policy Role Verification

**Location**: `scripts/components/database_migration.sh` - Step 6

**Changes**:
- Added comprehensive policy role verification
- Compares policies with their roles between source and target
- Identifies policies with role mismatches
- Provides detailed logging of mismatches

**Verification Query**:
```sql
SELECT 
    n.nspname || '.' || c.relname || '|' || pol.polname || '|' || 
    CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' ... END || '|' ||
    COALESCE(string_agg(DISTINCT rol.rolname, ','), 'public') as policy_info
FROM pg_policy pol
-- ... joins ...
GROUP BY n.nspname, c.relname, pol.polname, pol.polcmd
```

**Output**:
- Lists all policies with role mismatches
- Shows source roles vs target roles
- Helps identify which policies need manual fix

### Fix 5: Policy Type Breakdown Logging

**Location**: `scripts/components/database_migration.sh` - Step 5

**Changes**:
- Added logging of policy counts by type (SELECT, INSERT, UPDATE, DELETE, ALL)
- Helps identify if specific policy types are missing
- Provides visibility into what's being migrated

**Example Output**:
```
Extracted 150 policies from DB: SELECT=45, INSERT=38, UPDATE=35, DELETE=20, ALL=12
```

## Migration Flow (Updated)

1. **Step 4a**: Migrate Storage RLS Policies (unconditional)
2. **Step 4b**: Migrate Extensions
3. **Step 4c**: Migrate Cron Jobs
4. **Step 5**: 
   - Extract ALL policies directly from database (with roles)
   - Drop existing policies on target
   - Apply policies with correct roles
   - Verify policy counts and types
5. **Step 6**: Comprehensive Verification
   - Verify storage policies
   - Verify extensions
   - Verify cron jobs
   - **Verify policy roles match** (NEW)

## Expected Results

After these fixes:

1. ✅ **All policy roles preserved**: Policies include all roles (cms, admin, super_admin)
2. ✅ **All storage buckets migrated**: Use `--force-all` to migrate all buckets
3. ✅ **All policy types migrated**: INSERT, UPDATE, DELETE, SELECT, ALL policies all captured
4. ✅ **Role mismatches detected**: Verification catches any role differences
5. ✅ **Policy type visibility**: Logging shows breakdown of policy types

## Usage

### To Fix Policy Roles Issue:
```bash
# Run database migration - policies will be extracted directly from database
./scripts/components/database_migration.sh dev test
```

### To Migrate All Storage Buckets:
```bash
# Migrate all buckets (even if they exist in target)
./scripts/main/storage_buckets_migration.sh dev test --force-all

# Or with files
./scripts/main/storage_buckets_migration.sh dev test --files --force-all
```

### To Verify Policy Roles:
After migration, check the log for:
- "Verifying policy roles match between source and target..."
- Any warnings about role mismatches
- Policy type breakdown (SELECT, INSERT, UPDATE, DELETE, ALL)

## Files Modified

1. `scripts/components/database_migration.sh`
   - Added direct database policy extraction (preserves roles)
   - Added policy drop before re-application
   - Added policy role verification
   - Added policy type breakdown logging

2. `scripts/main/storage_buckets_migration.sh`
   - Added `--force-all` flag support
   - Updated usage documentation

3. `utils/storage-migration.js`
   - Added `FORCE_ALL_BUCKETS` flag handling
   - Updated logic to migrate all buckets when flag is set

## Verification Queries

After migration, run these to verify:

**Check Policy Roles**:
```sql
SELECT 
    schemaname || '.' || tablename || '.' || policyname as policy,
    cmd,
    string_agg(rolname, ', ' ORDER BY rolname) as roles
FROM pg_policies p
LEFT JOIN pg_policy pol ON pol.polname = p.policyname
LEFT JOIN pg_roles rol ON rol.oid = ANY(pol.polroles)
WHERE schemaname = 'public'
GROUP BY schemaname, tablename, policyname, cmd
ORDER BY tablename, policyname;
```

**Check Storage Buckets**:
```sql
SELECT name, public, file_size_limit, allowed_mime_types 
FROM storage.buckets 
ORDER BY name;
```

**Check INSERT Policies**:
```sql
SELECT schemaname, tablename, policyname, cmd
FROM pg_policies
WHERE cmd = 'INSERT'
ORDER BY schemaname, tablename, policyname;
```

## Notes

- Direct database extraction ensures roles are preserved correctly
- Policy drop before re-application ensures clean migration
- `--force-all` flag ensures all storage buckets are migrated
- Policy role verification catches any remaining issues
- All fixes work together to ensure complete and accurate migration
