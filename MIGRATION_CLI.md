# Migration CLI Guide

The Supabase migration tool runs **CLI-only**. All migration workflows are driven from the command line. No HTML reports are generated and no web server is required for migration.

## Running a migration

From the project root:

```bash
# Schema-only (default): database schema + RLS policies, storage buckets, edge functions, secrets structure
./scripts/main/supabase_migration.sh <source_env> <target_env>

# Full migration: schema + data, users, files, secrets
./scripts/main/supabase_migration.sh <source_env> <target_env> --full

# With options
./scripts/main/supabase_migration.sh prod test --mode schema --auto-confirm
./scripts/main/supabase_migration.sh dev test --data --no-secrets --skipEdge
```

Environments: `prod`, `test`, `dev`, `backup`.

## End-of-run summary

At the end of every run you get a **CLI summary** that includes:

- **Header**: Source → target, project refs, mode, status, timestamp  
- **Source vs target**: Counts (from comparison file when available)  
- **What was done**: Schema/policies, data, storage, edge functions, secrets  
- **Failures/warnings**: Failed artifact files (e.g. `failed_policies.sql`, `grants_failed.sql`)  
- **Paths**: Migration directory, log file, result file  

The same summary is appended to `migration.log`. No HTML or browser is involved.

## Parallel execution

After database schema (and optional data) migration finish, the tool runs these in **parallel**:

- Storage buckets migration  
- Edge functions migration  
- Secrets migration  

So total time is reduced when all three are enabled. Each step’s output is also written to a component log (e.g. `migration.log.storage`) and merged into the main `migration.log`.

## Edge function deploy state (per application and target environment)

The tool records the **last deployed timestamp** for each edge function **per application and per target environment**.

- **App name**: From `.env.local`: `SUPABASE_APP_NAME` or `SUPABSE_APP_NAME`. If unset, the app name is `default`.  
- **Target env**: Passed by the migration script (e.g. `test`, `prod`, `dev`, `backup`) so state is separate per target.  
- **State layout**: `edge_function_deploy_state/<APP_NAME>/<TARGET_ENV>.json`  
  - Example: `edge_function_deploy_state/KNC_Online_Platform/test.json`  
- **Format**: `{ "function_name": "2026-02-24T12:00:00.000Z", ... }` (ISO8601).  
- **When**: Updated after each successful deploy of an edge function.  
- **Skip logic**: When building the deploy list, functions whose source `updated_at` is not newer than the stored timestamp for that (app, target env) are skipped (already deployed and unchanged).

Use a distinct app name per project so multiple apps don't overwrite each other’s state. The directory `edge_function_deploy_state/` is gitignored.

## Result files

- **`result.md`**: Markdown report (counts, rollback notes, troubleshooting).  
- **`migration.log`**: Full log; CLI summary is appended at the end.  
- **Component logs**: `migration.log.storage`, `migration.log.edge_functions`, `migration.log.secrets` when parallel steps run.

No `result.html` is generated.

## Legacy UI (optional)

The repository may still include `server.js`, `ui.js`, `ui.html`, and `start-ui.sh` for a legacy web UI. Migration does **not** start or depend on this server. Use the CLI as above for all migration runs.

## Quick reference

| Goal              | Command |
|-------------------|--------|
| Schema-only       | `./scripts/main/supabase_migration.sh prod test` |
| Full (data + all)  | `./scripts/main/supabase_migration.sh prod test --full` |
| Policy-only (fix policy gap) | `./scripts/policy_migration_complete.sh dev test` |
| No secrets         | `./scripts/main/supabase_migration.sh prod test --no-secrets` |
| Skip edge functions | `./scripts/main/supabase_migration.sh prod test --skipEdge` |
| Non-interactive    | `./scripts/main/supabase_migration.sh prod test --auto-confirm` |

See `./scripts/main/supabase_migration.sh --help` for all options.

## Policy-only migration

To fix a **policy gap** after a schema migration (e.g. source has 498 policies, target has 455), use the standalone policy migration script. It copies all RLS policies from source to target without running the full schema migration:

```bash
./scripts/policy_migration_complete.sh <source_env> <target_env>
```

Example:

```bash
./scripts/policy_migration_complete.sh dev test
```

The script:

1. Extracts all `CREATE POLICY` statements from the source database  
2. Enables RLS on target tables, drops existing target policies, then applies policies in batches with retries  
3. Runs up to 3 delta passes (generating and applying missing-policies SQL)  
4. If a gap still remains, writes `apply_missing_policies_manual_<source>_to_<target>.sql` in the work directory and prints its path  

**If a gap remains:** run the printed SQL file in the **Supabase SQL Editor** for the **target** project to apply the remaining policies. The work directory is under `backups/policy_migration_<source>_to_<target>_<timestamp>/`; the log is `migration.log` there.
