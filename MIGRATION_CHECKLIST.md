# Complete Supabase Migration Checklist

Use this checklist to ensure you migrate everything when copying a Supabase project.

## ✅ Automated (via `duplicate_complete.sh`)

- [x] **Database Schema** - Tables, columns, data types, constraints
- [x] **Database Data** - All table records, sequences
- [x] **RLS Policies** - All row-level security policies
- [x] **Functions** - PostgreSQL functions
- [x] **Triggers** - Database triggers
- [x] **Enums/Custom Types** - Custom database types
- [x] **Extensions** - pgvector, pg_cron, etc.
- [x] **Indexes** - Performance indexes
- [x] **Storage Buckets Configuration** - Bucket definitions and policies
- [x] **Realtime Configuration** - Tables enabled for realtime
- [x] **Cron Jobs** - pg_cron scheduled jobs

## ⚠️ Manual Steps Required

### 1. Edge Functions
- [ ] List functions to deploy (check migration directory)
- [ ] Deploy each function: `supabase functions deploy <name> --project-ref <target-ref>`
- [ ] Test each function

### 2. Secrets
- [ ] Check `secrets_list.json` for list of secrets
- [ ] Set each secret via CLI or Dashboard:
  - [ ] `STRIPE_SECRET_KEY`
  - [ ] `FIRECRAWL_API_KEY`
  - [ ] `RESEND_API_KEY`
  - [ ] `LOVABLE_API_KEY`
  - [ ] `SENDGRID_API_KEY`
  - [ ] `APP_ENV`
  - [ ] Any other secrets

### 3. Storage Files
- [ ] Verify buckets exist: Dashboard → Storage → Buckets
- [ ] Upload files to each bucket (if needed)
- [ ] Verify bucket policies work

### 4. Authentication Configuration
- [ ] Configure auth providers: Dashboard → Auth → Providers
  - [ ] Email provider
  - [ ] OAuth providers (Google, GitHub, etc.)
- [ ] Configure email templates: Dashboard → Auth → Email Templates
  - [ ] Confirmation email
  - [ ] Password reset email
  - [ ] Magic link email
- [ ] Configure auth settings: Dashboard → Auth → Settings
  - [ ] Password requirements
  - [ ] JWT expiry
  - [ ] Redirect URLs
  - [ ] Site URL

### 5. Project Settings
- [ ] Configure project name: Dashboard → Settings → General
- [ ] Set custom domain (if applicable)
- [ ] Configure API rate limiting
- [ ] Configure CORS settings

## 🔍 Verification

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

## 📚 Quick Commands

```bash
# Complete migration (all automated components)
./scripts/complete_prod_to_test.sh --backup

# Database only (faster)
./scripts/dup_prod_to_test.sh --backup

# Schema only (no data)
./scripts/schema_prod_to_test.sh --backup
```

See [COMPLETE_MIGRATION_GUIDE.md](./COMPLETE_MIGRATION_GUIDE.md) for detailed instructions.
