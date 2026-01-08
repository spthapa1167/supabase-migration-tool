# Schema Difference Detection and Migration Fix

## Problem

New columns added to source database tables were not being migrated to the target. This happened because:

1. **pg_restore limitation**: `pg_restore` doesn't generate `ALTER TABLE ADD COLUMN` statements
2. **Only creates full table definitions**: When restoring, it tries to create complete tables, not modify existing ones
3. **Incremental mode issue**: When `--clean` is not used (incremental mode), existing tables are not dropped/recreated, so new columns are never added

## Root Cause

The migration script uses `pg_restore` which:
- Generates `CREATE TABLE` statements (full table definitions)
- Does NOT generate `ALTER TABLE ADD COLUMN` statements
- When a table already exists, the restore either fails or skips it
- New columns in source are never detected or applied to target

## Solution

Added **Step 4: Schema Difference Detection** that:
1. Extracts column information from both source and target databases
2. Compares schemas to find differences (new columns, modified columns, etc.)
3. Generates `ALTER TABLE` statements for all differences
4. Applies these statements to the target database
5. Verifies column counts match after migration

## Implementation

### Step 4: Schema Difference Detection

**Location**: `scripts/components/database_migration.sh` - After Step 3 (restore)

**Process**:
1. **Extract Column Information**: Queries `information_schema.columns` from both source and target
2. **Compare Schemas**: Uses Python script to compare column definitions
3. **Generate ALTER Statements**: Creates `ALTER TABLE ADD COLUMN`, `ALTER COLUMN TYPE`, etc.
4. **Apply Changes**: Executes ALTER statements on target database
5. **Verify**: Checks that column counts match

**Key Features**:
- Detects new columns (in source but not in target)
- Detects modified columns (type changes, nullable changes, default changes)
- Generates appropriate ALTER TABLE statements
- Handles NOT NULL constraints (warns if adding NOT NULL without default)
- Preserves existing data

### Column Information Extraction

The extraction query gets:
- Table schema and name
- Column name
- Data type (both `data_type` and `formatted_type`)
- Nullable status
- Default value
- Column position

### Schema Comparison Logic

The Python script:
1. Parses column information from both source and target
2. Groups columns by table (schema.table)
3. Finds differences:
   - **New columns**: In source but not in target → `ALTER TABLE ... ADD COLUMN`
   - **Type changes**: Different data types → `ALTER TABLE ... ALTER COLUMN TYPE`
   - **Nullable changes**: Different nullable status → `ALTER TABLE ... SET/DROP NOT NULL`
   - **Default changes**: Different defaults → `ALTER TABLE ... SET/DROP DEFAULT`

### Generated ALTER Statements

Examples:
```sql
-- New column
ALTER TABLE "public"."users" ADD COLUMN "new_field" text NOT NULL;

-- Type change
ALTER TABLE "public"."users" ALTER COLUMN "age" TYPE integer USING "age"::integer;

-- Nullable change
ALTER TABLE "public"."users" ALTER COLUMN "email" SET NOT NULL;

-- Default change
ALTER TABLE "public"."users" ALTER COLUMN "created_at" SET DEFAULT now();
```

## Verification

Added column count verification in Step 6 (Comprehensive Verification):
- Compares total column counts between source and target
- Warns if counts don't match
- Helps identify if schema differences were missed

## Migration Flow (Updated)

1. **Step 1-2**: Dump source database
2. **Step 3**: Restore to target (creates tables, but may miss new columns if tables exist)
3. **Step 4**: **NEW** - Detect and apply schema differences (adds missing columns, modifies existing ones)
4. **Step 4a**: Migrate Storage RLS Policies
5. **Step 4b**: Migrate Extensions
6. **Step 4c**: Migrate Cron Jobs
7. **Step 5**: Verify and retry policies/roles
8. **Step 6**: Comprehensive Verification (includes column count check)

## Expected Results

After this fix:

1. ✅ **New columns are detected and added** to target tables
2. ✅ **Column type changes are applied** (if any)
3. ✅ **Nullable constraints are updated** to match source
4. ✅ **Default values are synchronized** with source
5. ✅ **Column counts match** between source and target

## Usage

The fix is automatic - no changes needed to migration commands:

```bash
# Standard migration (now includes schema difference detection)
./scripts/components/database_migration.sh dev test

# With data
./scripts/components/database_migration.sh dev test --data
```

## Log Output

You'll see:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Step 4: Detecting and Applying Schema Differences
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Detecting schema differences (new columns, modified columns, etc.)...
Extracting column information from source...
Extracting column information from target...
Comparing schemas to find differences...
Found 5 schema difference(s) to apply
Schema changes to apply:
  - ALTER TABLE "public"."users" ADD COLUMN "new_field" text;
  - ALTER TABLE "public"."posts" ADD COLUMN "updated_at" timestamp;
  ...
Applying schema differences to target...
✓ Schema differences applied successfully
```

## Files Modified

1. `scripts/components/database_migration.sh`
   - Added Step 4: Schema Difference Detection
   - Added column count verification in Step 6
   - Extracts column information from both databases
   - Generates and applies ALTER TABLE statements

## Notes

- **Python Required**: The schema comparison uses Python. If Python is not available, the step is skipped with a warning.
- **Non-Destructive**: Only adds/modifies columns, never drops them (unless explicitly configured)
- **Handles NOT NULL**: Warns if adding NOT NULL columns without defaults (may require data backfill)
- **Works with Incremental Mode**: Especially important when `--clean` is not used
- **Runs After Restore**: Ensures it catches any columns that pg_restore might have missed

## Troubleshooting

If columns are still missing:

1. **Check the log** for "Step 4: Detecting and Applying Schema Differences"
2. **Review the SQL file**: `$MIGRATION_DIR/schema_differences.sql`
3. **Verify Python is available**: `python3 --version`
4. **Check column extraction**: Look for "Extracting column information" messages
5. **Manual verification**: Compare column counts in Step 6 verification

## Future Enhancements

Potential improvements:
- Detect and handle dropped columns (currently not implemented for safety)
- Detect and handle index changes
- Detect and handle constraint changes
- More detailed logging of what changed
- Dry-run mode to preview changes before applying
