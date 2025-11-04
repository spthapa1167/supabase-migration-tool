# Supabase Database Branching Migration Guide

This guide explains how to set up and use Supabase database branching to keep your test database identical to production.

## Overview

- **Production**: Main branch (production Supabase project)
- **Test**: Test branch (test Supabase project)
- **Goal**: When merging main → test, the test database should be identical to production

## Prerequisites

1. Supabase CLI installed: `npm install -g supabase`
2. Authenticated with Supabase: `supabase login`
3. Production Supabase project reference ID
4. Test Supabase project reference ID (or create one)

## Initial Setup (One-time)

### Step 1: Link to Production Supabase Project (Main Branch)

On the **main branch**, link your local project to the production Supabase project:

```bash
# Make sure you're on main branch
git checkout main

# Link to production Supabase project
supabase link --project-ref <production-project-ref-id>
```

**Note**: You can find your project reference ID in your Supabase dashboard:
- Go to Project Settings → General
- Copy the "Reference ID"

### Step 2: Pull Current Schema from Production

Pull all migrations and schema from production:

```bash
# Pull all migrations from production
supabase db pull

# This creates migration files in supabase/migrations/ based on the current production schema
```

### Step 3: Verify Migrations

Check that migrations were created:

```bash
ls -la supabase/migrations/
```

You should see migration files like `YYYYMMDDHHMMSS_description.sql`

### Step 4: Commit Migrations to Main Branch

```bash
git add supabase/migrations/
git commit -m "Initial migration: Pull schema from production"
git push origin main
```

## Setting Up Test Branch

### Step 1: Create Test Branch

```bash
# Create and checkout test branch
git checkout -b test

# Or if test branch already exists
git checkout test
```

### Step 2: Link to Test Supabase Project

On the **test branch**, link to your test Supabase project:

```bash
# Unlink from production (if previously linked)
supabase unlink

# Link to test Supabase project
supabase link --project-ref <test-project-ref-id>
```

### Step 3: Apply Migrations to Test Database

Apply all migrations from main branch to test database:

```bash
# Push all migrations to test database
supabase db push

# This will apply all migration files in supabase/migrations/ to the test database
```

### Step 4: Verify Test Database

Verify that your test database matches production:

```bash
# Check migration status
supabase migration list

# Compare schemas (optional - you can use Supabase Studio)
supabase db diff
```

## Ongoing Workflow: Merging Main → Test

When you want to sync test database with production:

### Step 1: Update Main Branch with Production Changes

On **main branch**:

```bash
git checkout main

# Pull latest changes from production
supabase db pull

# This creates new migration files for any changes in production
# Review and commit the new migrations
git add supabase/migrations/
git commit -m "Update migrations from production"
git push origin main
```

### Step 2: Merge Main to Test Branch

```bash
# Switch to test branch
git checkout test

# Merge main into test
git merge main

# This brings all migration files from main to test
```

### Step 3: Apply Migrations to Test Database

```bash
# Make sure you're linked to test project
supabase link --project-ref <test-project-ref-id>

# Push migrations to test database
supabase db push

# This applies all new migrations, making test identical to production
```

### Step 4: Verify Sync

```bash
# Check migration status
supabase migration list

# Both production and test should show the same migration history
```

## Creating New Migrations

When creating new schema changes:

### On Main Branch (Production)

```bash
# Make schema changes via Supabase Studio or SQL editor
# Then pull the changes as a migration
supabase db pull

# Review the generated migration file
# Commit it
git add supabase/migrations/
git commit -m "Add new feature: description"
git push origin main
```

### On Test Branch

```bash
# Test your changes first on test branch
# Make changes and create migration
supabase migration new <description>
# Edit the generated migration file
supabase db push

# Once tested, merge to main
git checkout main
git merge test
supabase db push  # Apply to production
```

## Important Notes

1. **Always pull from production on main branch** - Production is the source of truth
2. **Always link to correct project** - Main branch → production, Test branch → test
3. **Never edit production migrations directly** - Always pull from production
4. **Test migrations before merging to main** - Use test branch for validation
5. **Migration files are version controlled** - They should be in git

## Troubleshooting

### Migration Conflicts

If you have conflicts when merging:

```bash
# Resolve conflicts in migration files
# Then verify with:
supabase db push --dry-run
```

### Schema Drift

If test database is out of sync:

```bash
# On test branch, reset and reapply all migrations
supabase db reset

# This will:
# 1. Drop all tables
# 2. Reapply all migrations in order
# 3. Run seed files (if any)
```

### Check Which Project You're Linked To

```bash
# Check current link
cat supabase/.temp/project-ref
```

### Unlink and Re-link

If you need to switch projects:

```bash
supabase unlink
supabase link --project-ref <new-project-ref-id>
```

## Quick Reference Commands

```bash
# Link to project
supabase link --project-ref <project-ref-id>

# Pull migrations from remote
supabase db pull

# Push migrations to remote
supabase db push

# List migrations
supabase migration list

# Create new migration
supabase migration new <description>

# Reset database (local only)
supabase db reset

# Check migration status
supabase db diff
```

## Branch Structure

```
main branch
├── supabase/
│   ├── migrations/          # Production migrations (source of truth)
│   ├── config.toml
│   └── .gitignore
└── README.md

test branch (branches from main)
├── supabase/
│   ├── migrations/          # Same migrations as main (synced on merge)
│   ├── config.toml
│   └── .gitignore
└── README.md
```

## Next Steps

1. Complete the initial setup steps above
2. Test the workflow by making a small change in production
3. Pull it on main, merge to test, and verify it syncs correctly


