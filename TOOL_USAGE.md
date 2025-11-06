# Using This Tool with Your Projects

This tool is designed to be **completely reusable** - no code changes needed! Just configure your project details in `.env.local` and start using it.

## Quick Setup for New Users

### 1. Clone the Repository

```bash
git clone <repository-url>
cd xyntraweb_supabase
```

### 2. Configure Your Projects

```bash
# Copy the example file
cp .env.example .env.local

# Edit with your project details
nano .env.local  # or use your preferred editor
```

### 3. Fill in Your Project Details

Edit `.env.local` with:
- Your Supabase access token
- Your three project reference IDs (Production, Test, Develop)
- Your three database passwords

**That's it!** No code changes needed.

### 4. Validate Setup

```bash
./setup.sh
```

This validates your configuration and ensures everything is ready.

### 5. Start Using

```bash
# Duplicate production to test
./scripts/dup_prod_to_test.sh

# Duplicate production to develop
./scripts/dup_prod_to_dev.sh
```

## Configuration Requirements

The tool expects **exactly 3 Supabase projects** configured as:
- **Production** (prod) - Your main/production environment
- **Test** (test) - Your staging/test environment  
- **Develop** (dev) - Your development environment

You can use any Supabase projects - just configure them in `.env.local`.

## How It Works

1. **All configuration is in `.env.local`** - Never commit this file
2. **Scripts read from environment variables** - No hardcoded values
3. **Works with any Supabase projects** - Just change the config
4. **Automatic connection detection** - Tries to detect pooler hostname from API

## Customization

### Override Pooler Hostname

If your projects are in a different region, you can override the pooler hostname:

```bash
# In .env.local
SUPABASE_POOLER_HOST=your-region.pooler.supabase.com
```

### Use Different Environment Names

The scripts support these environment name aliases:
- Production: `prod`, `production`, `main`
- Test: `test`, `staging`
- Develop: `dev`, `develop`

## Examples

### Example 1: Different Organization

```bash
# .env.local
SUPABASE_PROD_PROJECT_REF=abc123def456ghi789jkl
SUPABASE_TEST_PROJECT_REF=mno789pqr012stu345vwx
SUPABASE_DEV_PROJECT_REF=yzab12cdef34ghij56klmn
```

### Example 2: Different Region

If your projects are in a different region:

```bash
# .env.local
SUPABASE_POOLER_HOST=eu-west-1.pooler.supabase.com
```

The tool will automatically use this hostname for all connections.

## Migration from Existing Setup

If you're migrating from a hardcoded setup:

1. Copy your existing `.env.local` (if you have one)
2. Ensure all project references and passwords are correct
3. Run `./setup.sh` to validate
4. Start using the scripts - they'll work with your projects

## Support

- **Setup Issues**: Run `./setup.sh` to diagnose
- **Validation**: Run `./validate.sh` to check configuration
- **Documentation**: See [GETTING_STARTED.md](./GETTING_STARTED.md) for detailed setup

---

**The tool is now generic and reusable!** Just configure `.env.local` and use it with any Supabase projects.

