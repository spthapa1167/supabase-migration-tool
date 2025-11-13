#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const dotenv = require('dotenv');
const { createClient } = require('@supabase/supabase-js');

const PROJECT_ROOT = path.resolve(__dirname, '..');
dotenv.config({ path: path.join(PROJECT_ROOT, '.env.local') });

function exitWithError(message) {
  console.error(`[ERROR] ${message}`);
  process.exit(1);
}

function logInfo(message, logStream) {
  console.log(`[INFO] ${message}`);
  if (logStream) {
    logStream.write(`[${new Date().toISOString()}] INFO ${message}\n`);
  }
}

function logSuccess(message, logStream) {
  console.log(`[SUCCESS] ${message}`);
  if (logStream) {
    logStream.write(`[${new Date().toISOString()}] SUCCESS ${message}\n`);
  }
}

function logWarning(message, logStream) {
  console.warn(`[WARNING] ${message}`);
  if (logStream) {
    logStream.write(`[${new Date().toISOString()}] WARNING ${message}\n`);
  }
}

function normalizeEnvKey(env) {
  const lower = String(env || '').toLowerCase();
  if (['prod', 'production', 'main'].includes(lower)) return 'PROD';
  if (['test', 'staging'].includes(lower)) return 'TEST';
  if (['dev', 'develop'].includes(lower)) return 'DEV';
  if (['backup', 'bkup', 'bkp'].includes(lower)) return 'BACKUP';
  exitWithError(`Unsupported environment alias: ${env}`);
}

function loadEnvConfig(envAlias) {
  const key = normalizeEnvKey(envAlias);
  const projectRef = process.env[`SUPABASE_${key}_PROJECT_REF`];
  const dbPassword = process.env[`SUPABASE_${key}_DB_PASSWORD`];
  if (!projectRef) {
    exitWithError(`Missing SUPABASE_${key}_PROJECT_REF in environment variables`);
  }
  if (!dbPassword) {
    exitWithError(`Missing SUPABASE_${key}_DB_PASSWORD in environment variables`);
  }
  const poolerRegion = process.env[`SUPABASE_${key}_POOLER_REGION`] || 'aws-1-us-east-2';
  const poolerPort = parseInt(process.env[`SUPABASE_${key}_POOLER_PORT`] || '6543', 10);
  const serviceRole = process.env[`SUPABASE_${key}_SERVICE_ROLE_KEY`] || process.env.SUPABASE_SERVICE_ROLE_KEY;
  const projectUrl = process.env[`SUPABASE_${key}_URL`] || `https://${projectRef}.supabase.co`;

  return {
    alias: envAlias,
    key,
    projectRef,
    dbPassword,
    poolerRegion,
    poolerPort,
    serviceRole,
    projectUrl
  };
}

function getConnectionEndpoints(config) {
  const endpoints = [];
  const sharedHost = `${config.poolerRegion}.pooler.supabase.com`;
  const dedicatedHost = `db.${config.projectRef}.supabase.co`;
  const sharedUser = `postgres.${config.projectRef}`;
  const dedicatedUser = 'postgres';

  endpoints.push({ host: sharedHost, port: config.poolerPort, user: sharedUser, label: `shared_${config.poolerPort}` });
  endpoints.push({ host: sharedHost, port: 5432, user: sharedUser, label: 'shared_5432' });
  endpoints.push({ host: dedicatedHost, port: config.poolerPort, user: dedicatedUser, label: `dedicated_${config.poolerPort}` });
  endpoints.push({ host: dedicatedHost, port: 5432, user: dedicatedUser, label: 'dedicated_5432' });

  return endpoints;
}

function runPsql(commandDescription, endpoint, password, args, logStream) {
  const env = { ...process.env, PGPASSWORD: password, PGSSLMODE: 'require' };
  const fullArgs = ['-h', endpoint.host, '-p', String(endpoint.port), '-U', endpoint.user, '-d', 'postgres', ...args];
  const result = spawnSync('psql', fullArgs, { encoding: 'utf8', env });
  if (result.status !== 0) {
    const stderr = result.stderr || '';
    const stdout = result.stdout || '';
    const message = `${commandDescription} failed via ${endpoint.label}: ${stderr.trim() || stdout.trim()}`;
    throw new Error(message);
  }
  if (logStream) {
    logStream.write(`[${new Date().toISOString()}] EXEC psql ${fullArgs.join(' ')}\n`);
  }
  return result.stdout || '';
}

function attemptWithEndpoints(config, description, fn, logStream) {
  const endpoints = getConnectionEndpoints(config);
  let lastError;
  for (const endpoint of endpoints) {
    try {
      logInfo(`${description} via ${endpoint.label} (${endpoint.host}:${endpoint.port})`, logStream);
      return fn(endpoint);
    } catch (error) {
      lastError = error;
      logWarning(error.message, logStream);
    }
  }
  if (lastError) {
    throw lastError;
  }
  throw new Error(`No endpoints available for ${description}`);
}

function fetchColumnList(config, table, logStream) {
  const sql = `SELECT a.attname
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN information_schema.columns ic
  ON ic.table_schema = 'auth'
  AND ic.table_name = '${table}'
  AND ic.column_name = a.attname
WHERE n.nspname = 'auth'
  AND c.relname = '${table}'
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND a.attgenerated = ''
  AND a.attidentity = ''
  AND ic.is_updatable = 'YES'
ORDER BY a.attnum;`;
  return attemptWithEndpoints(
    config,
    `Fetching column list for auth.${table}`,
    (endpoint) => {
      const output = runPsql(`Fetch column list for auth.${table}`, endpoint, config.dbPassword, ['-t', '-A', '-F', ',', '-c', sql], logStream);
      return output
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => line.length > 0);
    },
    logStream
  );
}

function exportToCsv(config, query, filePath, logStream) {
  const escapedPath = filePath.replace(/'/g, "''");
  const sql = `\\copy (${query}) TO '${escapedPath}' WITH CSV HEADER`;
  return attemptWithEndpoints(
    config,
    `Exporting data to ${filePath}`,
    (endpoint) => {
      if (fs.existsSync(filePath)) {
        fs.unlinkSync(filePath);
      }
      runPsql(`Export ${filePath}`, endpoint, config.dbPassword, ['-v', 'ON_ERROR_STOP=1', '-c', sql], logStream);
    },
    logStream
  );
}

function getInstanceId(config, logStream) {
  const sql = "SELECT id FROM auth.instances ORDER BY created_at DESC LIMIT 1;";
  try {
    const result = attemptWithEndpoints(
      config,
      'Fetching instance_id',
      (endpoint) => {
        const output = runPsql('Fetch instance_id', endpoint, config.dbPassword, ['-t', '-A', '-c', sql], logStream);
        return output.trim();
      },
      logStream
    );
    return result || null;
  } catch (error) {
    logWarning(`Unable to fetch instance_id via SQL (${error.message})`, logStream);
    return null;
  }
}

function createTempDir(baseDir) {
  if (!fs.existsSync(baseDir)) {
    fs.mkdirSync(baseDir, { recursive: true });
  }
  return fs.mkdtempSync(path.join(baseDir, 'auth-users-'));
}

function formatTimestamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate())
  ].join('') + '_' + [pad(date.getHours()), pad(date.getMinutes()), pad(date.getSeconds())].join('');
}

function createMigrationDir(sourceEnv, targetEnv, providedDir) {
  if (providedDir) {
    const abs = path.isAbsolute(providedDir) ? providedDir : path.join(PROJECT_ROOT, providedDir);
    fs.mkdirSync(abs, { recursive: true });
    return abs;
  }
  const backupsDir = path.join(PROJECT_ROOT, 'backups');
  fs.mkdirSync(backupsDir, { recursive: true });
  const dirName = `auth_users_migration_${sourceEnv}_to_${targetEnv}_${formatTimestamp()}`;
  const fullPath = path.join(backupsDir, dirName);
  fs.mkdirSync(fullPath, { recursive: true });
  return fullPath;
}

function buildConflictClause(columns) {
  const updateCols = columns.filter((col) => col !== 'id');
  if (updateCols.length === 0) {
    return 'ON CONFLICT (id) DO NOTHING';
  }
  const expressions = updateCols.map((col) => `${col} = EXCLUDED.${col}`);
  return `ON CONFLICT (id) DO UPDATE SET ${expressions.join(', ')}`;
}

function generateImportSql(options) {
  const {
    usersColumns,
    identitiesColumns,
    usersCsv,
    identitiesCsv,
    conflictUsers,
    conflictIdentities,
    replace,
    instanceId
  } = options;

  const sqlParts = [];
  sqlParts.push('\\set ON_ERROR_STOP on');
  sqlParts.push('');
  sqlParts.push('BEGIN;');
  sqlParts.push('SET LOCAL session_replication_role = \"replica\";');
  sqlParts.push('');
  if (replace) {
    sqlParts.push('-- Replace target data');
    sqlParts.push('DELETE FROM auth.identities;');
    sqlParts.push('DELETE FROM auth.users;');
    sqlParts.push('');
  }

  const escapedUsersCsv = usersCsv.replace(/'/g, "''");
  const escapedIdentitiesCsv = identitiesCsv.replace(/'/g, "''");

  sqlParts.push('-- Upsert auth.users');
  sqlParts.push(`CREATE TEMP TABLE migration_auth_users_stage AS SELECT ${usersColumns.join(', ')} FROM auth.users WHERE FALSE;`);
  sqlParts.push(`\\copy migration_auth_users_stage (${usersColumns.join(', ')}) FROM '${escapedUsersCsv}' WITH CSV HEADER;`);
  if (instanceId && usersColumns.includes('instance_id')) {
    sqlParts.push("UPDATE migration_auth_users_stage SET instance_id = '" + instanceId.replace(/'/g, "''") + "';");
  }
  sqlParts.push(`INSERT INTO auth.users (${usersColumns.join(', ')})`);
  sqlParts.push(`SELECT ${usersColumns.join(', ')} FROM migration_auth_users_stage`);
  sqlParts.push(`${conflictUsers};`);
  sqlParts.push('');

  sqlParts.push('-- Upsert auth.identities');
  sqlParts.push(`CREATE TEMP TABLE migration_auth_identities_stage AS SELECT ${identitiesColumns.join(', ')} FROM auth.identities WHERE FALSE;`);
  sqlParts.push(`\\copy migration_auth_identities_stage (${identitiesColumns.join(', ')}) FROM '${escapedIdentitiesCsv}' WITH CSV HEADER;`);
  if (instanceId && identitiesColumns.includes('instance_id')) {
    sqlParts.push("UPDATE migration_auth_identities_stage SET instance_id = '" + instanceId.replace(/'/g, "''") + "';");
  }
  sqlParts.push(`INSERT INTO auth.identities (${identitiesColumns.join(', ')})`);
  sqlParts.push(`SELECT ${identitiesColumns.join(', ')} FROM migration_auth_identities_stage`);
  sqlParts.push(`${conflictIdentities};`);
  sqlParts.push('');

  sqlParts.push('COMMIT;');
  sqlParts.push('');

  return sqlParts.join('\n');
}

function parseArgs(argv) {
  const positionals = [];
  const options = { replace: false, increment: false };
  let migrationDir = null;

  for (const arg of argv) {
    if (arg === '--replace') {
      options.replace = true;
    } else if (arg === '--increment' || arg === '--incremental') {
      options.increment = true;
    } else if (arg.startsWith('--')) {
      exitWithError(`Unknown flag: ${arg}`);
    } else {
      positionals.push(arg);
    }
  }

  if (positionals.length < 2) {
    exitWithError('Usage: auth-users-migrate.js <source_env> <target_env> [migration_dir] [--replace]');
  }

  const sourceEnv = positionals[0];
  const targetEnv = positionals[1];
  if (positionals[2]) {
    migrationDir = positionals[2];
  }

  return { sourceEnv, targetEnv, migrationDir, replace: options.replace, increment: options.increment };
}

function ensureCommandExists(command) {
  const which = spawnSync('which', [command], { encoding: 'utf8' });
  if (which.status !== 0) {
    exitWithError(`${command} command not found. Please install PostgreSQL client utilities.`);
  }
}

function extractColumnsIntersection(sourceColumns, targetColumns) {
  const sourceSet = new Set(sourceColumns);
  return targetColumns.filter((column) => sourceSet.has(column));
}

async function verifyWithSupabase(targetConfig, expectedUserCount, logStream) {
  if (!targetConfig.serviceRole) {
    logWarning('Skipping Supabase Admin verification (service role key not available)', logStream);
    return;
  }
  try {
    const supabase = createClient(targetConfig.projectUrl, targetConfig.serviceRole);
    const { data, error } = await supabase.auth.admin.listUsers({ perPage: 1 });
    if (error) {
      logWarning(`Supabase Admin verification failed: ${error.message}`, logStream);
      return;
    }
    logInfo(`Supabase Admin API reachable. (Fetched ${data?.users?.length || 0} user(s) page size 1)`, logStream);
  } catch (error) {
    logWarning(`Supabase Admin verification error: ${error.message}`, logStream);
  }
}

async function main() {
  ensureCommandExists('psql');

  const { sourceEnv, targetEnv, migrationDir: providedDir, replace, increment } = parseArgs(process.argv.slice(2));
  const sourceConfig = loadEnvConfig(sourceEnv);
  const targetConfig = loadEnvConfig(targetEnv);

  const migrationDir = createMigrationDir(sourceEnv, targetEnv, providedDir);
  const logFile = path.join(migrationDir, 'migration.log');
  const logStream = fs.createWriteStream(logFile, { flags: 'a' });

  logInfo(`Auth Users Migration`, logStream);
  logInfo(`Source: ${sourceEnv} (${sourceConfig.projectRef})`, logStream);
  logInfo(`Target: ${targetEnv} (${targetConfig.projectRef})`, logStream);
  logInfo(`Migration directory: ${migrationDir}`, logStream);
  logInfo(`Mode: ${replace ? 'Replace (full refresh)' : 'Incremental (upsert)'}`, logStream);
  if (increment && !replace) {
    logInfo('Increment flag detected: running in incremental upsert mode.', logStream);
  }

  const tempDir = createTempDir(path.join(migrationDir, 'tmp'));
  const sourceUsersCsv = path.join(tempDir, 'source_users.csv');
  const sourceIdentitiesCsv = path.join(tempDir, 'source_identities.csv');

  const sourceUserColumns = fetchColumnList(sourceConfig, 'users', logStream);
  const targetUserColumns = fetchColumnList(targetConfig, 'users', logStream);
  const commonUserColumns = extractColumnsIntersection(sourceUserColumns, targetUserColumns);
  if (commonUserColumns.length === 0) {
    exitWithError('No overlapping columns between source and target auth.users tables.');
  }

  const sourceIdentityColumns = fetchColumnList(sourceConfig, 'identities', logStream);
  const targetIdentityColumns = fetchColumnList(targetConfig, 'identities', logStream);
  const commonIdentityColumns = extractColumnsIntersection(sourceIdentityColumns, targetIdentityColumns);
  if (commonIdentityColumns.length === 0) {
    exitWithError('No overlapping columns between source and target auth.identities tables.');
  }

  logInfo('Exporting auth.users from source ...', logStream);
  exportToCsv(sourceConfig, `SELECT ${commonUserColumns.join(', ')} FROM auth.users ORDER BY created_at`, sourceUsersCsv, logStream);
  logInfo('Exporting auth.identities from source ...', logStream);
  exportToCsv(sourceConfig, `SELECT ${commonIdentityColumns.join(', ')} FROM auth.identities ORDER BY created_at`, sourceIdentitiesCsv, logStream);

  const usersConflictClause = buildConflictClause(commonUserColumns);
  const identitiesConflictClause = buildConflictClause(commonIdentityColumns);

  const targetInstanceId = getInstanceId(targetConfig, logStream);
  if (targetInstanceId) {
    logInfo(`Resolved target instance_id: ${targetInstanceId}`, logStream);
  }

  const importSql = generateImportSql({
    usersColumns: commonUserColumns,
    identitiesColumns: commonIdentityColumns,
    usersCsv: sourceUsersCsv,
    identitiesCsv: sourceIdentitiesCsv,
    conflictUsers: usersConflictClause,
    conflictIdentities: identitiesConflictClause,
    replace,
    instanceId: targetInstanceId
  });

  const importSqlFile = path.join(tempDir, 'import.sql');
  fs.writeFileSync(importSqlFile, importSql, 'utf8');

  logInfo('Applying snapshot to target ...', logStream);
  attemptWithEndpoints(
    targetConfig,
    'Applying auth users snapshot',
    (endpoint) => {
      runPsql('Apply snapshot', endpoint, targetConfig.dbPassword, ['-v', 'ON_ERROR_STOP=1', '-f', importSqlFile], logStream);
    },
    logStream
  );
  logSuccess('Auth users import completed.', logStream);

  const countUsersSql = 'SELECT COUNT(*) FROM auth.users;';
  const countIdentitiesSql = 'SELECT COUNT(*) FROM auth.identities;';
  const targetUsersAfter = parseInt(
    attemptWithEndpoints(
      targetConfig,
      'Counting auth.users in target',
      (endpoint) => runPsql('Count target users', endpoint, targetConfig.dbPassword, ['-t', '-A', '-c', countUsersSql], logStream).trim(),
      logStream
    ) || '0',
    10
  );
  const targetIdentitiesAfter = parseInt(
    attemptWithEndpoints(
      targetConfig,
      'Counting auth.identities in target',
      (endpoint) => runPsql('Count target identities', endpoint, targetConfig.dbPassword, ['-t', '-A', '-c', countIdentitiesSql], logStream).trim(),
      logStream
    ) || '0',
    10
  );

  await verifyWithSupabase(targetConfig, targetUsersAfter, logStream);

  const summaryFile = path.join(migrationDir, 'auth_users_migration_summary.txt');
  const summary = [
    '# Auth Users Migration Summary',
    '',
    `**Source**: ${sourceEnv} (${sourceConfig.projectRef})`,
    `**Target**: ${targetEnv} (${targetConfig.projectRef})`,
    `**Date**: ${new Date().toString()}`,
    `**Mode**: ${replace ? 'Replace' : 'Incremental (upsert)'}`,
    '',
    '## Counts',
    '',
    `- Target auth.users rows: ${targetUsersAfter}`,
    `- Target auth.identities rows: ${targetIdentitiesAfter}`,
    '',
    '## Notes',
    '',
    '- Data exported and imported via PostgreSQL client (psql).',
    '- Column intersection ensured between source and target schemas.',
    '- Instance identifiers updated when present in both environments.',
    '- Supabase Admin API probed (service role) after import.'
  ].join('\n');
  fs.writeFileSync(summaryFile, summary, 'utf8');

  logInfo(`Summary file: ${summaryFile}`, logStream);
  logInfo(`Migration artifacts stored in: ${migrationDir}`, logStream);

  logStream.end();

  // Output migration directory path for shell wrapper compatibility
  process.stdout.write(`${migrationDir}\n`);
}

main().catch((error) => {
  console.error(`[ERROR] ${error.message}`);
  process.exit(1);
});
