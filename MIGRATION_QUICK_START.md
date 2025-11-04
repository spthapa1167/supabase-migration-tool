# Migration System Quick Start

## Overview

This project uses an **organized migration folder structure** where each migration gets its own folder with all related files. This provides better organization, easier rollback, and comprehensive tracking.

## Migration Folder Structure

Each migration is organized like this:

```
supabase/migrations/
  YYYYMMDD_HHMMSS_migration_name/
    ├── migration.sql      # Forward migration SQL
    ├── rollback.sql       # Rollback SQL
    ├── diff_before.sql    # Schema before migration
    ├── diff_after.sql     # Schema after migration
    ├── metadata.json      # Migration metadata
    └── README.md          # Documentation
```

## Quick Commands

### Create New Migration

```bash
./scripts/migration_new.sh add_user_table "Add user management tables"
```

This creates a folder with all necessary files.

### List All Migrations

```bash
./scripts/migration_list.sh
```

### Apply Migration

```bash
./scripts/migration_apply.sh add_user_table prod
./scripts/migration_apply.sh add_user_table test
```

### Rollback Migration

```bash
./scripts/migration_rollback.sh add_user_table prod
```

### Generate Diff Files

```bash
# Capture schema before migration
./scripts/migration_diff.sh add_user_table prod --before

# Capture schema after migration
./scripts/migration_diff.sh add_user_table prod --after

# Capture both
./scripts/migration_diff.sh add_user_table prod --both
```

### Sync from Environment

```bash
# Pull schema from production and create migration
./scripts/migration_sync.sh prod "sync_from_production"
```

### Convert Old Migrations

If you have old flat migration files, convert them:

```bash
./scripts/migration_convert.sh --all
```

## Workflow Example

1. **Create migration:**
   ```bash
   ./scripts/migration_new.sh add_posts_table "Add posts table"
   ```

2. **Edit migration SQL:**
   ```bash
   vim supabase/migrations/YYYYMMDD_HHMMSS_add_posts_table/migration.sql
   ```

3. **Create rollback SQL:**
   ```bash
   vim supabase/migrations/YYYYMMDD_HHMMSS_add_posts_table/rollback.sql
   ```

4. **Test in test environment:**
   ```bash
   ./scripts/migration_apply.sh add_posts_table test
   ```

5. **Apply to production:**
   ```bash
   ./scripts/migration_apply.sh add_posts_table prod
   ```

## Supabase CLI Compatibility

The system automatically creates compatibility symlinks so Supabase CLI commands work normally:

- `supabase db push` - Works with organized migrations
- `supabase db pull` - Automatically converts new migrations to organized format
- `supabase migration list` - Works with organized migrations

## See Also

- **[MIGRATION_SYSTEM.md](./MIGRATION_SYSTEM.md)** - Complete documentation
- **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md)** - Migration-based workflow

