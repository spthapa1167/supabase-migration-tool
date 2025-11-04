# Getting Started Guide

This guide will help you set up the Supabase Project Duplication Tool for your own projects.

## Prerequisites

Before you begin, ensure you have:

1. **Supabase CLI** installed
   ```bash
   npm install -g supabase
   ```

2. **PostgreSQL Client Tools** (pg_dump, pg_restore, psql)
   - macOS: `brew install postgresql`
   - Ubuntu/Debian: `sudo apt-get install postgresql-client`
   - Windows: Download from [PostgreSQL website](https://www.postgresql.org/download/)

3. **Docker Desktop** (optional, for schema pulling)
   - Download from [Docker Desktop](https://www.docker.com/products/docker-desktop)

4. **Three Supabase Projects**
   - Production (main)
   - Test (staging)
   - Develop (development)

## Step-by-Step Setup

### Step 1: Clone or Download

```bash
git clone <repository-url>
cd xyntraweb_supabase
```

Or download the repository as a ZIP and extract it.

### Step 2: Create Environment Configuration

```bash
# Copy the example file
cp .env.example .env.local

# Edit with your project details
nano .env.local  # or use your preferred editor
```

### Step 3: Get Your Supabase Access Token

1. Go to [Supabase Dashboard](https://supabase.com/dashboard)
2. Click on your profile → Account Settings
3. Go to "Access Tokens" section
4. Click "Generate New Token"
5. Copy the token and add it to `.env.local`:
   ```
   SUPABASE_ACCESS_TOKEN=your_token_here
   ```

### Step 4: Get Your Project Reference IDs

For each of your three Supabase projects:

1. Go to your project in Supabase Dashboard
2. Navigate to: **Settings** → **General**
3. Find the **Reference ID** (20-character string like `abcdefghijklmnopqrst`)
4. Copy it to `.env.local`:
   ```
   SUPABASE_PROD_PROJECT_REF=your_prod_ref_here
   SUPABASE_TEST_PROJECT_REF=your_test_ref_here
   SUPABASE_DEV_PROJECT_REF=your_dev_ref_here
   ```

### Step 5: Get Your Database Passwords

For each project:

1. Go to: **Settings** → **Database**
2. Find the **Database Password** section
3. If you don't know it, click "Reset Database Password"
4. Copy the password to `.env.local`:
   ```
   SUPABASE_PROD_DB_PASSWORD=your_prod_password
   SUPABASE_TEST_DB_PASSWORD=your_test_password
   SUPABASE_DEV_DB_PASSWORD=your_dev_password
   ```

**Important**: These are the database passwords, NOT your Supabase account password.

### Step 6: Configure Network Restrictions (Important!)

For each project, ensure your IP can connect:

1. Go to: **Settings** → **Database** → **Network Restrictions**
2. Add your current IP address
3. Or temporarily allow all IPs (`0.0.0.0/0`) for testing

You can find your IP by running:
```bash
curl ifconfig.me
```

### Step 7: Validate Configuration

Run the setup script to validate everything:

```bash
./setup.sh
```

This will:
- Check if `.env.local` exists
- Validate all required variables
- Test Supabase authentication
- Verify project access
- Check required tools

If everything passes, you're ready to use the tool!

## First Use

### Test the Configuration

```bash
# Validate environment
./validate.sh
```

### Try a Simple Operation

```bash
# Duplicate production schema to test (no data)
./scripts/schema_prod_to_test.sh
```

### Full Duplication with Backup

```bash
# Full duplication with automatic backup
./scripts/dup_prod_to_test.sh --backup
```

## Understanding the Tool

### What Gets Copied?

**Full Duplication** (`dup_*.sh`):
- ✅ All tables with data
- ✅ All indexes and constraints
- ✅ All RLS policies
- ✅ All functions and stored procedures
- ✅ Database roles
- ⚠️ Auth users (included in dump but may need manual setup)
- ⚠️ Storage buckets (need manual copy via Dashboard)
- ⚠️ Edge functions (need separate deployment)

**Schema-Only Duplication** (`schema_*.sh`):
- ✅ Table structures (no data)
- ✅ All indexes and constraints
- ✅ All RLS policies
- ✅ All functions
- ❌ No data
- ❌ No auth users

### Available Scripts

**Full Duplication:**
- `dup_prod_to_test.sh` - Production → Test
- `dup_prod_to_dev.sh` - Production → Develop
- `dup_dev_to_test.sh` - Develop → Test
- `dup_test_to_prod.sh` - Test → Production ⚠️
- `dup_dev_to_prod.sh` - Develop → Production ⚠️
- `dup_test_to_dev.sh` - Test → Develop

**Schema-Only:**
- `schema_prod_to_test.sh` - Production → Test
- `schema_prod_to_dev.sh` - Production → Develop
- `schema_dev_to_test.sh` - Develop → Test
- `schema_test_to_prod.sh` - Test → Production ⚠️
- `schema_dev_to_prod.sh` - Develop → Production ⚠️
- `schema_test_to_dev.sh` - Test → Develop

⚠️ **Warning**: Scripts targeting production require explicit `YES` confirmation.

### Generic Commands

You can also use the generic commands directly:

```bash
# Full duplication
./scripts/duplicate_full.sh <source> <target> [--backup]

# Schema-only
./scripts/duplicate_schema.sh <source> <target> [--backup]

# Valid environments: prod, test, dev
```

## Common Workflows

### Sync Production to Test and Develop

```bash
# Full sync to test
./scripts/dup_prod_to_test.sh --backup

# Full sync to develop
./scripts/dup_prod_to_dev.sh --backup
```

### Update Test with Latest Production Schema (No Data)

```bash
./scripts/schema_prod_to_test.sh --backup
```

### Promote Test Changes to Production (After Testing)

```bash
# This requires confirmation
./scripts/dup_test_to_prod.sh --backup
```

## Troubleshooting

### "Connection refused" Error

**Solution**: Update network restrictions in Supabase Dashboard for all projects.

### "Permission denied" Errors During Restore

**Normal**: These errors are expected for `auth`, `storage`, and `realtime` schemas which are managed by Supabase. Your public schema tables and data are still copied successfully.

### "Docker is not running"

**Solution**: Start Docker Desktop. Required for `supabase db pull` command.

### "Environment variable not set"

**Solution**: Run `./setup.sh` to validate your `.env.local` configuration.

## Next Steps

- Read [DUPLICATION_GUIDE.md](./DUPLICATION_GUIDE.md) for detailed documentation
- Read [MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md) for migration workflows
- Check [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for common issues

## Support

If you encounter issues:
1. Run `./setup.sh` to validate configuration
2. Check logs in `backups/` directory
3. Review [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
4. Verify your Supabase project settings

---

**You're all set!** The tool is now configured for your Supabase projects. 🎉

