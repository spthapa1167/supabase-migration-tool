# Troubleshooting Guide

## Connection Refused Errors

If you're getting `connection refused` errors when trying to link or push to Supabase projects, this is typically due to **Network Restrictions** configured in your Supabase projects.

### Solution: Update Network Restrictions

For each of your three environments (Production, Test, Develop), you need to whitelist your IP address:

1. **Production Environment**:
   - Go to: https://supabase.com/dashboard/project/YOUR_PROD_PROJECT_REF/settings/database
   - Navigate to **Network Restrictions** section
   - Add your current IP address or temporarily allow all IPs (`0.0.0.0/0`) for testing
   - Replace `YOUR_PROD_PROJECT_REF` with your actual production project reference ID

2. **Test Environment**:
   - Go to: https://supabase.com/dashboard/project/YOUR_TEST_PROJECT_REF/settings/database
   - Navigate to **Network Restrictions** section
   - Add your current IP address or temporarily allow all IPs (`0.0.0.0/0`) for testing
   - Replace `YOUR_TEST_PROJECT_REF` with your actual test project reference ID

3. **Develop Environment**:
   - Go to: https://supabase.com/dashboard/project/YOUR_DEV_PROJECT_REF/settings/database
   - Navigate to **Network Restrictions** section
   - Add your current IP address or temporarily allow all IPs (`0.0.0.0/0`) for testing
   - Replace `YOUR_DEV_PROJECT_REF` with your actual develop project reference ID

### Find Your Current IP Address

You can find your public IP address by running:
```bash
curl ifconfig.me
```

Or visit: https://whatismyipaddress.com/

### After Updating Network Restrictions

1. Wait 1-2 minutes for changes to propagate
2. Run the sync scripts again:
   ```bash
   ./sync_all.sh
   ```

## Docker Required for Schema Pulling

The `supabase db pull` command requires Docker Desktop to be running. If you get Docker errors:

1. **Install Docker Desktop** (if not installed):
   - macOS: https://docs.docker.com/desktop/install/mac-install/
   - Or use: `brew install --cask docker`

2. **Start Docker Desktop** before running sync scripts

3. **Verify Docker is running**:
   ```bash
   docker ps
   ```

## Migration History Mismatch

If you see errors about migration history not matching:

1. Check migration status:
   ```bash
   source .env.local
   export SUPABASE_ACCESS_TOKEN=$SUPABASE_ACCESS_TOKEN
   supabase migration list --password "$SUPABASE_PROD_DB_PASSWORD"
   ```

2. Repair migration history if needed:
   ```bash
   supabase migration repair --status applied <migration_timestamp> --password "$SUPABASE_PROD_DB_PASSWORD"
   ```

## Environment Variables Not Loading

If scripts can't find `.env.local`:

1. Verify the file exists:
   ```bash
   ls -la .env.local
   ```

2. Check file permissions:
   ```bash
   chmod 600 .env.local
   ```

3. Manually export variables:
   ```bash
   export SUPABASE_ACCESS_TOKEN=sbp_b4cb3d56bd9970bbb0cd706791a0916de5488200
   export SUPABASE_PROD_DB_PASSWORD=c9dPFIWNmXAVzeI1
   # etc.
   ```

