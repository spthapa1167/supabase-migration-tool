# Complete Supabase Project Migration Guide

This guide covers **ALL aspects** of migrating a Supabase project from one environment to another.

## 📋 Complete Migration Checklist

### ✅ Automated (via `duplicate_complete.sh`)

1. **Database Schema** - Tables, columns, data types, constraints
2. **Database Data** - All table records, sequences
3. **RLS Policies** - All row-level security policies
4. **Functions** - PostgreSQL functions
5. **Triggers** - Database triggers
6. **Enums/Custom Types** - Custom database types
7. **Extensions** - pgvector, pg_cron, etc.
8. **Indexes** - Performance indexes
9. **Storage Buckets Configuration** - Bucket definitions and policies
10. **Realtime Configuration** - Tables enabled for realtime
11. **Cron Jobs** - pg_cron scheduled jobs

### ⚠️ Manual Steps Required

1. **Edge Functions** - Deploy from codebase
2. **Secrets** - Set values manually (security)
3. **Storage Files** - Upload actual files to buckets
4. **Authentication Configuration** - Via Dashboard
5. **Project Settings** - Via Dashboard

## 🚀 Quick Start

### Complete Migration (All Components)

```bash
# Production → Test
./scripts/complete_prod_to_test.sh [--backup]

# Production → Develop
./scripts/complete_prod_to_dev.sh [--backup]

# Generic command
./scripts/duplicate_complete.sh <source> <target> [--backup]
```

### Database Only (Faster)

```bash
# Full duplication (schema + data)
./scripts/dup_prod_to_test.sh [--backup]

# Schema only (no data)
./scripts/schema_prod_to_test.sh [--backup]
```

## 📊 What Gets Migrated Automatically

### 1. Database Schema (Most Critical)

**Included:**
- ✅ Tables: Structure, columns, data types
- ✅ RLS Policies: All row-level security policies
- ✅ Functions: PostgreSQL functions (like `has_role`, `search_knowledge_base`)
- ✅ Triggers: Database triggers
- ✅ Enums/Custom Types: Like `app_role` enum
- ✅ Extensions: pgvector, pg_cron, etc.
- ✅ Indexes: Performance indexes
- ✅ Constraints: Foreign keys, unique constraints, check constraints

**How:** Uses `pg_dump` and `pg_restore` to copy complete database structure.

### 2. Database Data

**Included:**
- ✅ All table records
- ✅ Sequences and auto-increment values
- ✅ Auth users (in full duplication mode)

**How:** Full database dump includes all data.

### 3. Storage Buckets Configuration

**Included:**
- ✅ Bucket definitions (names, public/private settings)
- ✅ Bucket policies (RLS policies for storage)

**Not Included:**
- ❌ Actual file content (must be uploaded manually)

**How:** Exported as SQL and imported to target.

**Manual Step Required:**
```bash
# After migration, upload files to buckets:
# Go to: Dashboard → Storage → Buckets → Upload files
```

### 4. Edge Functions

**Included:**
- ✅ List of functions (names only)

**Not Included:**
- ❌ Function code (must be deployed from codebase)

**How:** List exported via API, deployment instructions provided.

**Manual Step Required:**
```bash
# Deploy functions from codebase:
supabase functions deploy <function-name> --project-ref <target-ref>

# Or deploy all:
cd supabase/functions
for func in */; do
    supabase functions deploy $(basename "$func") --project-ref <target-ref>
done
```

### 5. Secrets (Per-Project)

**Included:**
- ✅ List of secret names (for reference)

**Not Included:**
- ❌ Secret values (security - must be set manually)

**How:** List exported via API, values must be set manually.

**Manual Step Required:**

Via CLI:
```bash
supabase secrets set STRIPE_SECRET_KEY=your_value --project-ref <target-ref>
supabase secrets set FIRECRAWL_API_KEY=your_value --project-ref <target-ref>
supabase secrets set RESEND_API_KEY=your_value --project-ref <target-ref>
supabase secrets set LOVABLE_API_KEY=your_value --project-ref <target-ref>
supabase secrets set SENDGRID_API_KEY=your_value --project-ref <target-ref>
supabase secrets set APP_ENV=your_value --project-ref <target-ref>
```

Via Dashboard:
- Go to: Dashboard → Project Settings → Edge Functions → Manage Secrets
- Add each secret key-value pair

### 6. Authentication Configuration

**Not Included Automatically:**
- ❌ Auth Providers (Email, Google, GitHub, etc.)
- ❌ Email Templates (Confirmation, password reset)
- ❌ Auth Settings (Password requirements, JWT expiry, redirect URLs, site URL)
- ❌ User Data (migrated in full database dump, but auth config separate)

**Manual Step Required:**

Via Dashboard:
1. Go to: https://supabase.com/dashboard/project/<target-ref>/auth/providers
2. Configure each provider:
   - Email provider (default)
   - OAuth providers (Google, GitHub, etc.)
3. Configure email templates:
   - Confirmation email
   - Password reset email
   - Magic link email
4. Configure auth settings:
   - Password requirements (min length, complexity)
   - JWT expiry
   - Redirect URLs
   - Site URL

### 7. Realtime Configuration

**Included:**
- ✅ Tables enabled for realtime (`REPLICA IDENTITY FULL`)
- ✅ Publication settings

**How:** Exported as SQL and imported to target.

**Verify:**
```sql
-- Check realtime publications
SELECT * FROM pg_publication_tables WHERE pubname = 'supabase_realtime';

-- Check replica identity
SELECT schemaname, tablename, relreplident 
FROM pg_tables t
JOIN pg_class c ON c.relname = t.tablename
WHERE schemaname = 'public' AND relreplident != 'n';
```

### 8. Project Settings

**Not Included Automatically:**
- ❌ Project name
- ❌ Organization
- ❌ Custom domain
- ❌ API rate limiting
- ❌ CORS settings

**Manual Step Required:**

Via Dashboard:
1. Go to: https://supabase.com/dashboard/project/<target-ref>/settings/general
2. Configure:
   - Project name
   - Custom domain (if applicable)
   - API rate limiting
   - CORS settings

### 9. Cron Jobs (pg_cron)

**Included:**
- ✅ Scheduled jobs (if pg_cron extension enabled)

**How:** Exported as SQL and imported to target.

**Verify:**
```sql
-- Check cron jobs
SELECT * FROM cron.job;
```

## 📝 Step-by-Step Migration Process

### Step 1: Run Complete Migration Script

```bash
./scripts/complete_prod_to_test.sh --backup
```

This creates a migration directory with:
- Database dump
- Storage configuration SQL
- Realtime configuration SQL
- Cron jobs SQL
- Secrets list (names only)
- Edge functions list
- Migration summary and log

### Step 2: Review Migration Summary

Check the generated `MIGRATION_SUMMARY.md` file in the migration directory for:
- What was migrated automatically
- What needs manual attention
- Step-by-step instructions

### Step 3: Deploy Edge Functions

```bash
# List functions to deploy (check migration directory)
supabase functions deploy <function-name> --project-ref <target-ref>
```

### Step 4: Set Secrets

```bash
# Set each secret (check secrets_list.json for names)
supabase secrets set KEY_NAME=value --project-ref <target-ref>
```

### Step 5: Upload Storage Files

- Go to Dashboard → Storage → Buckets
- Upload files to each bucket

### Step 6: Configure Authentication

- Go to Dashboard → Authentication
- Configure providers, templates, and settings

### Step 7: Configure Project Settings

- Go to Dashboard → Project Settings
- Set project name, domain, rate limiting, CORS

### Step 8: Test Migration

- Test database queries
- Test edge functions
- Test authentication flows
- Test storage uploads/downloads
- Test realtime subscriptions

## 🔍 Verification Checklist

After migration, verify:

- [ ] Database schema matches (tables, columns, types)
- [ ] Database data matches (sample records)
- [ ] RLS policies work correctly
- [ ] Functions work correctly
- [ ] Storage buckets exist and have correct policies
- [ ] Storage files uploaded (if needed)
- [ ] Edge functions deployed and working
- [ ] Secrets set correctly
- [ ] Authentication providers configured
- [ ] Email templates configured
- [ ] Realtime subscriptions work
- [ ] Cron jobs scheduled correctly
- [ ] Project settings configured

## 📚 Related Documentation

- **[DUPLICATION_GUIDE.md](./DUPLICATION_GUIDE.md)** - Database duplication details
- **[MIGRATION_SYSTEM.md](./MIGRATION_SYSTEM.md)** - Migration management system
- **[scripts/README.md](./scripts/README.md)** - All available scripts

## ⚠️ Important Notes

1. **Secrets are never exported** - Values are secret and must be set manually
2. **Edge functions code** - Must be deployed from your codebase
3. **Storage files** - Configuration is migrated, but files must be uploaded
4. **Auth configuration** - Must be configured manually via Dashboard
5. **Project settings** - Must be configured manually via Dashboard
6. **Network restrictions** - Ensure both projects allow connections from your IP

## 🆘 Troubleshooting

### Database Migration Issues

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for database connection issues.

### Edge Functions Not Working

1. Check function code is deployed: `supabase functions list --project-ref <ref>`
2. Check secrets are set: `supabase secrets list --project-ref <ref>`
3. Check function logs: Dashboard → Edge Functions → Logs

### Storage Not Working

1. Verify buckets exist: Dashboard → Storage → Buckets
2. Check bucket policies: `SELECT * FROM storage.policies`
3. Verify files uploaded: Dashboard → Storage → Files

### Authentication Not Working

1. Check providers configured: Dashboard → Auth → Providers
2. Check redirect URLs: Dashboard → Auth → URL Configuration
3. Check email templates: Dashboard → Auth → Email Templates

