# Migration: initial

**Created**: Tue Nov  4 14:08:16 CST 2025

## Description
Migrated from old format

## Files

- `migration.sql` - Forward migration script
- `rollback.sql` - Rollback script to reverse changes
- `diff_before.sql` - Schema state before migration
- `diff_after.sql` - Schema state after migration
- `metadata.json` - Migration metadata
- `README.md` - This file

## Usage

### Apply Migration
```bash
# Apply this migration
psql -f migration.sql
```

### Rollback Migration
```bash
# Rollback this migration
psql -f rollback.sql
```

## Status

- [ ] Not applied
- [ ] Applied to production
- [ ] Applied to test
- [ ] Applied to develop
