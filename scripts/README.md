# Duplication Scripts Quick Reference

## 🚀 Quick Commands

### Complete Migration (All Components)

```bash
# Production → Test (complete migration)
./scripts/complete_prod_to_test.sh [--backup]

# Production → Develop (complete migration)
./scripts/complete_prod_to_dev.sh [--backup]

# Generic command
./scripts/duplicate_complete.sh <source> <target> [--backup]
```

**Migrates:**
- ✅ Database (schema + data)
- ✅ Storage buckets configuration
- ✅ Realtime configuration
- ✅ Cron jobs
- ⚠️ Edge functions (list + deployment instructions)
- ⚠️ Secrets (list - values must be set manually)
- ⚠️ Auth configuration (manual via Dashboard)
- ⚠️ Project settings (manual via Dashboard)

### Full Duplication (Schema + Data)

```bash
# Production → Test
./scripts/dup_prod_to_test.sh [--backup]

# Production → Develop
./scripts/dup_prod_to_dev.sh [--backup]

# Develop → Test
./scripts/dup_dev_to_test.sh [--backup]

# Test → Develop
./scripts/dup_test_to_dev.sh [--backup]

# Test → Production (requires confirmation)
./scripts/dup_test_to_prod.sh [--backup]

# Develop → Production (requires confirmation)
./scripts/dup_dev_to_prod.sh [--backup]
```

### Schema-Only Duplication

```bash
# Production → Test
./scripts/schema_prod_to_test.sh [--backup]

# Production → Develop
./scripts/schema_prod_to_dev.sh [--backup]

# Develop → Test
./scripts/schema_dev_to_test.sh [--backup]

# Test → Develop
./scripts/schema_test_to_dev.sh [--backup]

# Test → Production (requires confirmation)
./scripts/schema_test_to_prod.sh [--backup]

# Develop → Production (requires confirmation)
./scripts/schema_dev_to_prod.sh [--backup]
```

### Generic Commands

```bash
# Full duplication
./scripts/duplicate_full.sh <source> <target> [--backup]

# Schema-only duplication
./scripts/duplicate_schema.sh <source> <target> [--backup]
```

**Environments**: `prod`, `test`, `dev`

## 📋 What Gets Copied

### Full Duplication ✅
- All tables with data
- All indexes and constraints
- All RLS policies
- All functions
- Database roles
- Sequences

### Schema-Only ✅
- Table structures (no data)
- All indexes and constraints
- All RLS policies
- All functions
- Sequences

### Manual Steps Required ⚠️
- Storage buckets (via Dashboard)
- Edge functions (via CLI)
- Realtime configurations
- Auth providers

## 🛡️ Safety

- Production operations require `YES` confirmation
- Use `--backup` to create backups before duplication
- All operations are logged to `backups/` directory

## 🔄 Migration Management Scripts

### Create New Migration

```bash
./scripts/migration_new.sh <migration_name> [description] [--author <author>] [--env <environment>]
```

Creates a new organized migration folder with all related files.

### Apply Migration

```bash
./scripts/migration_apply.sh <migration_name> <environment> [--dry-run]
```

Applies a migration to the specified environment (prod, test, dev, backup).

### Rollback Migration

```bash
./scripts/migration_rollback.sh <migration_name> <environment> [--dry-run]
```

Rolls back a migration from the specified environment.

### Generate Diff Files

```bash
./scripts/migration_diff.sh <migration_name> <environment> [--before|--after|--both]
```

Captures schema state before/after migration.

### List All Migrations

```bash
./scripts/migration_list.sh
```

Shows all migrations with their status.

### Sync from Environment

```bash
./scripts/migration_sync.sh <source_env> [migration_name]
```

Pulls schema from source environment and creates a new migration.

### Convert Old Migrations

```bash
./scripts/migration_convert.sh [--all|--file <file>] [--backup]
```

Converts flat migration files to organized folder structure.

## 📚 Documentation

- **[DUPLICATION_GUIDE.md](../DUPLICATION_GUIDE.md)** - Complete duplication documentation
- **[MIGRATION_SYSTEM.md](../MIGRATION_SYSTEM.md)** - Complete migration system documentation
- **[MIGRATION_QUICK_START.md](../MIGRATION_QUICK_START.md)** - Migration quick start guide

