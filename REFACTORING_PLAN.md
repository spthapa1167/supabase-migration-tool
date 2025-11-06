# Refactoring Plan - Supabase Migration Tool

## Overview
This document outlines the refactoring plan to clean up the codebase and maintain only the 6 core parent scripts with best practices.

## Core Parent Scripts (KEEP)

1. **`scripts/supabase_migration.sh`** - Main orchestration script
2. **`scripts/migration_plan.sh`** - Migration plan generation
3. **`scripts/components/database_migration.sh`** - Database migration component
4. **`scripts/components/edge_functions_migration.sh`** - Edge functions migration component
5. **`scripts/components/secrets_migration.sh`** - Secrets migration component
6. **`scripts/components/storage_buckets_migration.sh`** - Storage migration component

## Essential Library Files (KEEP)

- `lib/supabase_utils.sh` - Core utilities (used by all scripts)
- `lib/logger.sh` - Logging utilities (used by components)
- `lib/html_report_generator.sh` - HTML report generation (used by components)
- `lib/html_generator.sh` - HTML generation for main script
- `lib/rollback_utils.sh` - Rollback utilities (used by database_migration.sh)

## Node.js Utilities (KEEP)

- `utils/storage-migration.js` - Storage migration (used by storage_buckets_migration.sh)
- `utils/edge-functions-migration.js` - Edge functions migration (used by edge_functions_migration.sh)

## Files to Remove (LEGACY/UNUSED)

### Scripts to Remove:
- `scripts/duplication/*` - All old duplication scripts (replaced by main migration)
- `scripts/migration/*` - Old migration management scripts (not used)
- `scripts/sync/*` - Sync scripts (not part of main flow)
- Root level: `sync_*.sh` - Old sync scripts

### Library Files to Remove:
- `lib/migration_complete.sh` - Legacy (only optional import, not actually used)
- `lib/storage_migration.sh` - Legacy (replaced by Node.js utility)
- `lib/migration_utils.sh` - Used only by old migration scripts
- `lib/count_objects.sh` - Optionally sourced but not actually used
- `lib/error_handler.sh` - Not used

### Utility Scripts to Review:
- `scripts/utils/checkdiff.sh` - Check if used
- `scripts/utils/deploy_functions.sh` - Check if used
- `scripts/utils/set_secrets.sh` - Check if used
- `scripts/utils/setup.sh` - Check if used
- `scripts/utils/validate.sh` - Check if used
- `scripts/utils/cleanup_backups.sh` - KEEP (used by components)

## Refactoring Tasks

### 1. Clean Up Unused Files
- [ ] Remove `scripts/duplication/*`
- [ ] Remove `scripts/migration/*`
- [ ] Remove `scripts/sync/*`
- [ ] Remove root level `sync_*.sh`
- [ ] Remove unused lib files
- [ ] Remove `lib/storage_migration.sh` and update `storage_buckets_migration.sh` to use Node.js utility directly

### 2. Update storage_buckets_migration.sh
- [ ] Remove dependency on `lib/storage_migration.sh`
- [ ] Ensure it uses Node.js utility (`utils/storage-migration.js`) directly
- [ ] Remove any bash-based storage migration logic

### 3. Remove Optional Legacy Imports
- [ ] Remove optional `migration_complete.sh` import from main script
- [ ] Remove optional `count_objects.sh` import
- [ ] Clean up any legacy code paths

### 4. Standardize Component Scripts
- [ ] Ensure all component scripts have consistent error handling
- [ ] Standardize logging format
- [ ] Standardize argument parsing
- [ ] Ensure consistent HTML report generation
- [ ] Add proper validation

### 5. Improve Error Handling
- [ ] Add comprehensive error handling to all scripts
- [ ] Add proper exit codes
- [ ] Add validation for required dependencies
- [ ] Add rollback mechanisms where appropriate

### 6. Documentation
- [ ] Update main README.md
- [ ] Update scripts/README.md
- [ ] Add inline documentation to all scripts
- [ ] Document all functions and their purposes

## Best Practices to Apply

1. **Error Handling**: Use `set -euo pipefail` consistently
2. **Logging**: Use standardized logging functions
3. **Validation**: Validate all inputs and dependencies
4. **Documentation**: Add comprehensive inline comments
5. **Modularity**: Keep functions focused and reusable
6. **Exit Codes**: Use proper exit codes for success/failure
7. **Testing**: Add validation checks for critical operations

