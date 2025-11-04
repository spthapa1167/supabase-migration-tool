# Migration System Documentation

## Overview

This project uses an **organized migration folder structure** where each migration gets its own folder containing all related files. This provides better organization, easier rollback, and comprehensive tracking of database changes.

## Migration Structure

Each migration is organized in its own folder with the following structure:

```
supabase/migrations/
  YYYYMMDD_HHMMSS_migration_name/
    ├── migration.sql      # Forward migration SQL
    ├── rollback.sql       # Rollback SQL to reverse changes
    ├── diff_before.sql    # Schema state before migration
    ├── diff_after.sql     # Schema state after migration
    ├── metadata.json      # Migration metadata (status, author, etc.)
    └── README.md          # Migration documentation
```

### Example

```
supabase/migrations/
  20250914_060248_initial/
    ├── migration.sql
    ├── rollback.sql
    ├── diff_before.sql
    ├── diff_after.sql
    ├── metadata.json
    └── README.md
```

## Migration Scripts

### 1. Create New Migration

```bash
./scripts/migration_new.sh <migration_name> [description] [--author <author>] [--env <environment>]
```

**Examples:**
```bash
# Basic migration
./scripts/migration_new.sh add_user_table "Add user management tables"

# With author and environment
./scripts/migration_new.sh update_schema "Update user schema" --author "John Doe" --env prod
```

This creates a new migration folder with all necessary files.

### 2. Apply Migration

```bash
./scripts/migration_apply.sh <migration_name> <environment> [--dry-run]
```

**Examples:**
```bash
# Apply to production
./scripts/migration_apply.sh add_user_table prod

# Dry run (test without applying)
./scripts/migration_apply.sh add_user_table test --dry-run
```

### 3. Rollback Migration

```bash
./scripts/migration_rollback.sh <migration_name> <environment> [--dry-run]
```

**Examples:**
```bash
# Rollback from production
./scripts/migration_rollback.sh add_user_table prod

# Dry run
./scripts/migration_rollback.sh add_user_table test --dry-run
```

**Note:** You must create the `rollback.sql` file in the migration folder before rolling back.

### 4. Generate Diff Files

```bash
./scripts/migration_diff.sh <migration_name> <environment> [--before|--after|--both]
```

**Examples:**
```bash
# Capture schema before migration
./scripts/migration_diff.sh add_user_table prod --before

# Capture schema after migration
./scripts/migration_diff.sh add_user_table prod --after

# Capture both
./scripts/migration_diff.sh add_user_table prod --both
```

### 5. List All Migrations

```bash
./scripts/migration_list.sh
```

Shows all migrations with their status, timestamps, and file counts.

### 6. Sync from Environment

```bash
./scripts/migration_sync.sh <source_env> [migration_name]
```

**Examples:**
```bash
# Sync from production (auto-named)
./scripts/migration_sync.sh prod

# Sync with custom name
./scripts/migration_sync.sh prod "sync_from_production"
```

This pulls the current schema from the source environment and creates a new migration.

### 7. Convert Old Migrations

```bash
./scripts/migration_convert.sh [--all|--file <file>] [--backup]
```

**Examples:**
```bash
# Convert all old migrations
./scripts/migration_convert.sh --all

# Convert specific file
./scripts/migration_convert.sh --file supabase/migrations/20250914060248_initial.sql

# Convert all with backup
./scripts/migration_convert.sh --all --backup
```

Converts flat migration files to the new organized folder structure.

## Migration Workflow

### Creating a New Migration

1. **Create migration structure:**
   ```bash
   ./scripts/migration_new.sh add_user_table "Add user management tables"
   ```

2. **Edit migration SQL:**
   ```bash
   # Edit the migration.sql file
   vim supabase/migrations/YYYYMMDD_HHMMSS_add_user_table/migration.sql
   ```

3. **Create rollback SQL:**
   ```bash
   # Edit the rollback.sql file
   vim supabase/migrations/YYYYMMDD_HHMMSS_add_user_table/rollback.sql
   ```

4. **Capture schema before (optional):**
   ```bash
   ./scripts/migration_diff.sh add_user_table prod --before
   ```

5. **Test migration:**
   ```bash
   ./scripts/migration_apply.sh add_user_table test --dry-run
   ./scripts/migration_apply.sh add_user_table test
   ```

6. **Capture schema after (optional):**
   ```bash
   ./scripts/migration_diff.sh add_user_table test --after
   ```

7. **Apply to production:**
   ```bash
   ./scripts/migration_apply.sh add_user_table prod
   ```

### Syncing from Environment

1. **Pull schema from source:**
   ```bash
   ./scripts/migration_sync.sh prod "sync_from_production"
   ```

2. **Review generated migration:**
   ```bash
   cat supabase/migrations/YYYYMMDD_HHMMSS_sync_from_production/migration.sql
   ```

3. **Apply to target environments:**
   ```bash
   ./scripts/migration_apply.sh sync_from_production test
   ./scripts/migration_apply.sh sync_from_production dev
   ```

### Rollback Workflow

1. **Check migration status:**
   ```bash
   ./scripts/migration_list.sh
   ```

2. **Ensure rollback.sql exists and is complete:**
   ```bash
   cat supabase/migrations/YYYYMMDD_HHMMSS_migration_name/rollback.sql
   ```

3. **Test rollback:**
   ```bash
   ./scripts/migration_rollback.sh migration_name test --dry-run
   ```

4. **Apply rollback:**
   ```bash
   ./scripts/migration_rollback.sh migration_name prod
   ```

## File Descriptions

### migration.sql
Contains the forward migration SQL statements. This is the main migration file that applies changes to the database.

### rollback.sql
Contains SQL statements to reverse the changes made in `migration.sql`. Should be created before applying migrations to production.

### diff_before.sql
Schema snapshot before the migration is applied. Useful for comparing changes and understanding what was modified.

### diff_after.sql
Schema snapshot after the migration is applied. Useful for comparing changes and verifying the migration worked correctly.

### metadata.json
Contains migration metadata:
- Name
- Timestamp
- Description
- Author
- Environment
- Status (pending, applied_prod, applied_test, rolled_back, etc.)

### README.md
Documentation for the migration including:
- Description
- Usage instructions
- Status tracking
- Notes

## Supabase CLI Compatibility

The migration system maintains compatibility with Supabase CLI by creating symlinks in `supabase/migrations/.supabase_compat/`. These symlinks point to the `migration.sql` files in each migration folder, allowing Supabase CLI commands to work normally.

## Best Practices

1. **Always create rollback.sql** before applying migrations to production
2. **Capture diff files** for important migrations to track schema changes
3. **Test migrations** in test/dev environments before production
4. **Use descriptive names** for migrations (e.g., `add_user_table` not `update_1`)
5. **Update metadata.json** with accurate descriptions and author information
6. **Commit migrations** to version control after testing
7. **Keep migration.sql focused** - one logical change per migration

## Troubleshooting

### Migration not found
- Use `./scripts/migration_list.sh` to see all migrations
- Use partial names: `./scripts/migration_apply.sh add_user` will match `add_user_table`

### Rollback file missing
- Create `rollback.sql` in the migration folder
- Edit it with SQL statements to reverse the migration

### Supabase CLI compatibility
- Symlinks are automatically created in `.supabase_compat/`
- If issues occur, run: `./scripts/migration_convert.sh --all` to regenerate

## Migration Status Tracking

Migration status is tracked in `metadata.json`:
- `pending` - Not yet applied
- `applied_prod` - Applied to production
- `applied_test` - Applied to test
- `applied_dev` - Applied to develop
- `rolled_back_prod` - Rolled back from production
- etc.

Use `./scripts/migration_list.sh` to see all migration statuses.

