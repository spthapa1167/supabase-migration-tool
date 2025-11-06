# Supabase Project Duplication Tool

A comprehensive, reusable tool for duplicating and synchronizing Supabase projects between three environments (Production, Test, and Develop). Simply configure your project references in `.env.local` and start using it with any Supabase projects.

## 🌟 Features

- ✅ **Complete Migration**: Migrate ALL aspects (Database, Storage, Edge Functions, Secrets, Auth, Realtime, Cron)
- ✅ **Full Duplication**: Copy entire database (schema + all data) between environments
- ✅ **Schema-Only Duplication**: Copy structure without data
- ✅ **All Direction Combinations**: Support for prod ↔ test ↔ develop in any direction
- ✅ **Automatic Backups**: Create backups before duplication
- ✅ **Safety Confirmations**: Production operations require explicit confirmation
- ✅ **Comprehensive Logging**: All operations logged with timestamps
- ✅ **Error Handling**: Robust error handling and validation
- ✅ **Organized Migrations**: Date/time folder structure with all related files
- ✅ **Reusable**: Works with any Supabase projects - just configure `.env.local`

## 🚀 Quick Start

### 1. Clone and Setup

```bash
git clone <repository-url>
cd <project-directory>
cp .env.example .env.local
```

### 2. Configure Your Projects

Edit `.env.local` with your Supabase project details:

```bash
# Your Supabase access token
SUPABASE_ACCESS_TOKEN=your_access_token

# Production project
SUPABASE_PROD_PROJECT_REF=your_prod_project_ref
SUPABASE_PROD_DB_PASSWORD=your_prod_password

# Test project
SUPABASE_TEST_PROJECT_REF=your_test_project_ref
SUPABASE_TEST_DB_PASSWORD=your_test_password

# Develop project
SUPABASE_DEV_PROJECT_REF=your_dev_project_ref
SUPABASE_DEV_DB_PASSWORD=your_dev_password
```

### 3. Validate Configuration

```bash
./setup.sh
```

This will validate your configuration and ensure everything is ready.

### 4. Start Using

```bash
# Full duplication (schema + data)
./scripts/dup_prod_to_test.sh

# Schema-only duplication
./scripts/schema_prod_to_dev.sh

# See all available scripts
ls scripts/
```

## Prerequisites

1. **Supabase CLI**: `npm install -g supabase`
2. **PostgreSQL Tools**: pg_dump, pg_restore, psql
   - macOS: `brew install postgresql`
   - Ubuntu: `sudo apt-get install postgresql-client`
3. **Docker Desktop** (optional, for schema pulling)
4. **Three Supabase Projects** (Production, Test, Develop)

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd xyntraweb_supabase

# Copy and configure environment
cp .env.example .env.local
# Edit .env.local with your project details

# Run setup validation
./setup.sh
```

See [GETTING_STARTED.md](./GETTING_STARTED.md) for detailed setup instructions.

## Usage

### Duplication Scripts

The tool provides three types of duplication:

**1. Complete Migration** (All Components - Database, Storage, Edge Functions, Secrets, Realtime, Cron):
```bash
./scripts/complete_prod_to_test.sh      # Production → Test (complete)
./scripts/complete_prod_to_dev.sh       # Production → Develop (complete)
./scripts/duplicate_complete.sh prod test [--backup]  # Generic
```

**2. Full Duplication** (Schema + All Data):
```bash
./scripts/dup_prod_to_test.sh          # Production → Test
./scripts/dup_prod_to_dev.sh            # Production → Develop
./scripts/dup_dev_to_test.sh            # Develop → Test
# ... and more (see scripts/README.md)
```

**3. Schema-Only Duplication** (Structure Without Data):
```bash
./scripts/schema_prod_to_test.sh        # Production → Test
./scripts/schema_prod_to_dev.sh         # Production → Develop
./scripts/schema_dev_to_test.sh         # Develop → Test
# ... and more (see scripts/README.md)
```

**Generic Commands:**
```bash
./scripts/duplicate_complete.sh <source> <target> [--backup]  # All components
./scripts/duplicate_full.sh <source> <target> [--backup]       # Database only
./scripts/duplicate_schema.sh <source> <target> [--backup]    # Schema only
# Valid environments: prod, test, dev
```

### Migration-Based Sync (Alternative)

If you prefer migration-based workflow:

```bash
./sync_all.sh              # Full sync (pull from prod, push to test & dev)
./sync_production.sh        # Pull from production
./sync_test.sh             # Push to test
./sync_develop.sh          # Push to develop
```

See [MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md) for migration workflow details.

## Troubleshooting

If you encounter connection issues, see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for solutions.

Common issues:
- **Connection refused**: Network restrictions need to be updated in Supabase dashboard
- **Docker errors**: Docker Desktop must be running for schema pulling
- **Migration history mismatch**: See troubleshooting guide for repair commands

## Documentation

- **[GETTING_STARTED.md](./GETTING_STARTED.md)** - Step-by-step setup guide for new users
- **[TOOL_USAGE.md](./TOOL_USAGE.md)** - How to use this tool with your own projects
- **[COMPLETE_MIGRATION_GUIDE.md](./COMPLETE_MIGRATION_GUIDE.md)** - Complete migration guide (ALL components)
- **[MIGRATION_SYSTEM.md](./MIGRATION_SYSTEM.md)** - Migration system documentation
- **[DUPLICATION_GUIDE.md](./DUPLICATION_GUIDE.md)** - Database duplication documentation
- **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md)** - Migration-based workflow guide
- **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** - Common issues and solutions
- **[scripts/README.md](./scripts/README.md)** - Quick reference for all scripts

## Project Structure

```
.
├── .env.example              # Environment configuration template
├── .env.local                 # Your actual configuration (gitignored)
├── setup.sh                   # Setup and validation script
├── validate.sh                # Quick validation script
├── lib/
│   ├── supabase_utils.sh     # Utility functions library
│   └── migration_utils.sh    # Migration management utilities
├── scripts/
│   ├── duplicate_full.sh     # Main full duplication script
│   ├── duplicate_schema.sh   # Main schema-only script
│   ├── migration_new.sh      # Create new migration
│   ├── migration_apply.sh    # Apply migration to environment
│   ├── migration_rollback.sh # Rollback migration
│   ├── migration_diff.sh    # Generate diff files
│   ├── migration_list.sh    # List all migrations
│   ├── migration_convert.sh # Convert old migrations
│   ├── migration_sync.sh     # Sync from environment
│   ├── dup_*.sh              # Full duplication wrappers
│   └── schema_*.sh           # Schema-only wrappers
├── supabase/
│   └── migrations/
│       ├── YYYYMMDD_HHMMSS_migration_name/
│       │   ├── migration.sql
│       │   ├── rollback.sql
│       │   ├── diff_before.sql
│       │   ├── diff_after.sql
│       │   ├── metadata.json
│       │   └── README.md
│       └── .supabase_compat/ # Compatibility symlinks for Supabase CLI
├── sync_*.sh                  # Migration-based sync scripts
└── backups/                   # Backup directory (auto-created, gitignored)
```

## How It Works

1. **Configuration**: All project details are in `.env.local` (never committed)
2. **Validation**: Run `./setup.sh` to validate your configuration
3. **Execution**: Use wrapper scripts or generic commands
4. **Logging**: All operations are logged to `backups/` directory
5. **Safety**: Production operations require explicit confirmation

## Contributing

This is a reusable tool. To use it with your projects:
1. Clone this repository
2. Configure `.env.local` with your project details
3. Run `./setup.sh` to validate
4. Start using the duplication scripts

No code changes needed - just configuration!

## License

This tool is provided as-is for managing Supabase project duplication across environments.
