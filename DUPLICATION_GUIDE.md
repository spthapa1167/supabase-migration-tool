# Supabase Project Duplication Guide

Complete guide for duplicating Supabase projects between environments (Production, Test, Develop).

> **📋 For Complete Migration (All Components)**: See [COMPLETE_MIGRATION_GUIDE.md](./COMPLETE_MIGRATION_GUIDE.md)  
> This guide covers database-only duplication. For complete migration including Storage, Edge Functions, Secrets, Auth, Realtime, and Cron, use `./scripts/duplicate_complete.sh` or `./scripts/complete_prod_to_test.sh`.

## 📋 Overview

This toolkit provides comprehensive scripts for duplicating Supabase projects with full error handling, logging, and safety confirmations.

### Two Types of Duplication

1. **Full Duplication** (`duplicate_full.sh`): Schema + All Data
   - Copies all tables with data
   - Copies auth users
   - Copies roles and configurations
   - Copies storage bucket definitions
   - Includes all data

2. **Schema-Only Duplication** (`duplicate_schema.sh`): Structure Only
   - Copies table structures
   - Copies indexes and constraints
   - Copies RLS policies
   - Copies functions and views
   - **Excludes** actual user data

## 🚀 Quick Start

### Prerequisites

1. **Supabase CLI** installed: `npm install -g supabase`
2. **PostgreSQL tools** (pg_dump, pg_restore, psql)
3. **Docker Desktop** running (for some operations)
4. **Environment file** configured (`.env.local`)

### Basic Usage

**Full Duplication:**
```bash
# Production → Test (with backup)
./scripts/duplicate_full.sh prod test --backup

# Production → Develop
./scripts/duplicate_full.sh prod dev

# Develop → Test
./scripts/duplicate_full.sh dev test
```

**Schema-Only Duplication:**
```bash
# Production → Test (schema only)
./scripts/duplicate_schema.sh prod test --backup

# Production → Develop (schema only)
./scripts/duplicate_schema.sh prod dev
```

## 📚 Available Scripts

### Main Duplication Scripts

| Script | Description |
|--------|-------------|
| `duplicate_full.sh` | Full duplication (schema + data) |
| `duplicate_schema.sh` | Schema-only duplication |

### Full Duplication Wrappers

| Script | Direction | Description |
|--------|-----------|-------------|
| `dup_prod_to_test.sh` | Prod → Test | Copy production to test (full) |
| `dup_prod_to_dev.sh` | Prod → Dev | Copy production to develop (full) |
| `dup_dev_to_test.sh` | Dev → Test | Copy develop to test (full) |
| `dup_test_to_prod.sh` | Test → Prod | Copy test to production (full) ⚠️ |
| `dup_dev_to_prod.sh` | Dev → Prod | Copy develop to production (full) ⚠️ |
| `dup_test_to_dev.sh` | Test → Dev | Copy test to develop (full) |

### Schema-Only Wrappers

| Script | Direction | Description |
|--------|-----------|-------------|
| `schema_prod_to_test.sh` | Prod → Test | Copy production schema to test |
| `schema_prod_to_dev.sh` | Prod → Dev | Copy production schema to develop |
| `schema_dev_to_test.sh` | Dev → Test | Copy develop schema to test |
| `schema_test_to_prod.sh` | Test → Prod | Copy test schema to production ⚠️ |
| `schema_dev_to_prod.sh` | Dev → Prod | Copy develop schema to production ⚠️ |
| `schema_test_to_dev.sh` | Test → Dev | Copy test schema to develop |

⚠️ **Warning**: Scripts targeting production require explicit confirmation.

## 🔧 Detailed Usage

### Full Duplication

Copies everything from source to target:

```bash
./scripts/duplicate_full.sh <source> <target> [--backup]
```

**Arguments:**
- `source`: Source environment (`prod`, `test`, `dev`)
- `target`: Target environment (`prod`, `test`, `dev`)
- `--backup`: (Optional) Create backup of target before duplication

**Example:**
```bash
# Copy production to test with backup
./scripts/duplicate_full.sh prod test --backup
```

**What it copies:**
- ✅ All tables with data
- ✅ All indexes and constraints
- ✅ All RLS policies
- ✅ All functions and stored procedures
- ✅ All sequences
- ✅ Database roles and permissions
- ⚠️ Storage buckets (needs manual copy via Dashboard)
- ⚠️ Edge functions (needs separate deployment)
- ⚠️ Auth users (included in full dump)

### Schema-Only Duplication

Copies structure without data:

```bash
./scripts/duplicate_schema.sh <source> <target> [--backup]
```

**Arguments:**
- `source`: Source environment (`prod`, `test`, `dev`)
- `target`: Target environment (`prod`, `test`, `dev`)
- `--backup`: (Optional) Create backup of target before duplication

**Example:**
```bash
# Copy production schema to test with backup
./scripts/duplicate_schema.sh prod test --backup
```

**What it copies:**
- ✅ Table structures (no data)
- ✅ All indexes
- ✅ All constraints (foreign keys, unique, check, etc.)
- ✅ All RLS policies
- ✅ All functions and stored procedures
- ✅ All sequences
- ✅ Views and materialized views
- ❌ **No data** (tables are empty)
- ❌ **No auth users**
- ⚠️ Storage buckets (needs manual copy)
- ⚠️ Edge functions (needs separate deployment)

## 📁 Directory Structure

```
xyntraweb_supabase/
├── lib/
│   └── supabase_utils.sh      # Utility functions
├── scripts/
│   ├── duplicate_full.sh      # Main full duplication script
│   ├── duplicate_schema.sh    # Main schema-only script
│   ├── dup_*.sh               # Full duplication wrappers
│   └── schema_*.sh            # Schema-only wrappers
├── backups/                   # Backup directory (auto-created)
│   └── YYYYMMDD_HHMMSS/
│       ├── duplication.log
│       ├── source_full.dump
│       └── target_backup.dump
└── .env.local                 # Environment configuration
```

## 🛡️ Safety Features

### Production Protection

All scripts that target production require explicit confirmation:

```
⚠️  WARNING: You are about to modify PRODUCTION environment!
Operation: FULL DUPLICATION (Schema + Data)

Are you absolutely sure? Type 'YES' to confirm:
```

### Automatic Backups

Use `--backup` flag to create backups before duplication:

```bash
./scripts/duplicate_full.sh prod test --backup
```

This creates a backup in `backups/YYYYMMDD_HHMMSS/target_backup.dump`

### Logging

All operations are logged to:
- `backups/YYYYMMDD_HHMMSS/duplication.log` (full duplication)
- `backups/YYYYMMDD_HHMMSS/schema_duplication.log` (schema-only)

## 🔄 Common Workflows

### Sync Production to Test and Develop

```bash
# Step 1: Full sync to test
./scripts/dup_prod_to_test.sh --backup

# Step 2: Full sync to develop
./scripts/dup_prod_to_dev.sh --backup
```

### Update Test with Latest Production Schema (No Data)

```bash
./scripts/schema_prod_to_test.sh --backup
```

### Promote Test to Production (After Testing)

```bash
# This requires confirmation
./scripts/dup_test_to_prod.sh --backup
```

### Copy Develop Changes to Test

```bash
./scripts/dup_dev_to_test.sh
```

## 📝 Environment Variables

All scripts use `.env.local` for configuration:

```bash
# Production
SUPABASE_PROD_PROJECT_REF=your_production_project_ref
SUPABASE_PROD_DB_PASSWORD=your_production_password

# Test
SUPABASE_TEST_PROJECT_REF=your_test_project_ref
SUPABASE_TEST_DB_PASSWORD=your_test_password

# Develop
SUPABASE_DEV_PROJECT_REF=your_develop_project_ref
SUPABASE_DEV_DB_PASSWORD=your_develop_password

# Access Token
SUPABASE_ACCESS_TOKEN=your_access_token
```

## ⚠️ Important Notes

### What Gets Copied

✅ **Automatically Copied:**
- Database schema (tables, indexes, constraints)
- RLS policies
- Functions and stored procedures
- Sequences
- Database roles
- Data (in full duplication mode)

⚠️ **Needs Manual Attention:**
- **Storage Buckets**: Must be copied via Supabase Dashboard
  - Go to: Dashboard → Storage → Buckets
  - Export from source, import to target
  
- **Edge Functions**: Must be deployed separately
  ```bash
  supabase functions deploy <function-name>
  ```

- **Realtime Configurations**: May need manual setup
  - Check: Dashboard → Database → Realtime

- **Auth Providers**: OAuth providers need to be configured
  - Dashboard → Authentication → Providers

### Network Requirements

- Network restrictions must allow connections from your IP
- All three projects should have network restrictions configured
- Check: Dashboard → Settings → Database → Network Restrictions

### Large Datasets

For large databases:
- Full duplication may take significant time
- Monitor disk space (dumps can be large)
- Consider schema-only for faster operations
- Use `--backup` to ensure you can restore if needed

## 🐛 Troubleshooting

### Connection Refused

**Error**: `connection refused`

**Solution**: 
1. Check network restrictions in Supabase Dashboard
2. Verify IP is whitelisted
3. Check firewall settings

### Docker Not Running

**Error**: `Cannot connect to Docker daemon`

**Solution**:
```bash
# Start Docker Desktop
open -a Docker

# Verify Docker is running
docker ps
```

### Permission Denied

**Error**: `Permission denied`

**Solution**:
```bash
# Make scripts executable
chmod +x scripts/*.sh lib/*.sh
```

### Migration History Mismatch

**Error**: `migration history does not match`

**Solution**: This is expected when duplicating. The scripts handle this automatically by dropping existing objects.

### Large Dump Files

If dump files are very large:
- Monitor disk space
- Consider using `--schema-only` for testing
- Use compression if needed (pg_dump supports `-Fc` format with compression)

## 📊 Backup Management

Backups are stored in `backups/` directory:

```
backups/
├── 20241104_120000/
│   ├── duplication.log
│   ├── source_full.dump
│   └── target_backup.dump
├── 20241104_130000/
│   └── ...
```

**Recommendation**: 
- Keep backups for at least 7 days
- Archive old backups before deletion
- Test restore procedures periodically

## 🔐 Security Best Practices

1. **Never commit `.env.local`** - Already in `.gitignore`
2. **Use strong passwords** for database access
3. **Rotate access tokens** regularly
4. **Limit network restrictions** to trusted IPs
5. **Review logs** for sensitive information before sharing
6. **Use backups** before major operations

## 📞 Support

For issues or questions:
1. Check logs in `backups/` directory
2. Review [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
3. Verify environment variables in `.env.local`
4. Check Supabase Dashboard for project status

## 🎯 Quick Reference

```bash
# Full duplication
./scripts/duplicate_full.sh <source> <target> [--backup]

# Schema-only
./scripts/duplicate_schema.sh <source> <target> [--backup]

# Common shortcuts
./scripts/dup_prod_to_test.sh          # Prod → Test (full)
./scripts/schema_prod_to_test.sh       # Prod → Test (schema)
./scripts/dup_prod_to_dev.sh           # Prod → Dev (full)
./scripts/schema_prod_to_dev.sh        # Prod → Dev (schema)
```

---

**Last Updated**: 2024-11-04

