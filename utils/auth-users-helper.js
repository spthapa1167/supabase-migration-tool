#!/usr/bin/env node

/**
 * Auth Users Helper
 *
 * Provides CLI utilities to introspect Supabase auth users using the Supabase client
 * (service role keys) and Management API. Supports listing user summaries and
 * comparing users across environments.
 */

const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');
const dotenv = require('dotenv');

const PROJECT_ROOT = path.resolve(__dirname, '..');
dotenv.config({ path: path.join(PROJECT_ROOT, '.env.local') });

const SUPABASE_ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN || '';
const fetchFn = typeof fetch === 'function' ? fetch.bind(global) : null;

const args = process.argv.slice(2);
if (args.length === 0) {
  printUsage();
  process.exit(1);
}

const command = args.shift();
const { positionalArgs, options } = parseArgs(args);

async function main() {
  try {
    switch (command) {
      case 'summary': {
        const env = positionalArgs[0];
        if (!env) {
          throw new Error('summary command requires <env>');
        }
        const summary = await buildSummary(env, options);
        printSummary(summary, options.format);
        if (options.output) {
          fs.writeFileSync(options.output, JSON.stringify(summary, null, 2));
          console.log(`[INFO] Summary written to ${options.output}`);
        }
        break;
      }
      case 'compare': {
        const sourceEnv = positionalArgs[0];
        const targetEnv = positionalArgs[1];
        if (!sourceEnv || !targetEnv) {
          throw new Error('compare command requires <source_env> <target_env>');
        }
        const comparison = await compareEnvironments(sourceEnv, targetEnv, options);
        printComparison(comparison, options.format);
        if (options.output) {
          fs.writeFileSync(options.output, JSON.stringify(comparison, null, 2));
          console.log(`[INFO] Comparison written to ${options.output}`);
        }
        if (comparison.missingInTarget.length > 0) {
          process.exitCode = 2;
        }
        break;
      }
      case 'instance-id': {
        const env = positionalArgs[0];
        if (!env) {
          throw new Error('instance-id command requires <env>');
        }
        const config = getEnvConfig(env);
        const instanceId = await fetchInstanceId(config.projectRef);
        if (!instanceId) {
          console.error('[WARN] Unable to retrieve instance_id via Management API');
          process.exitCode = 1;
        } else {
          process.stdout.write(`${instanceId}\n`);
        }
        break;
      }
      case 'import': {
        const targetEnv = positionalArgs[0];
        if (!targetEnv) {
          throw new Error('import command requires <target_env>');
        }
        const usersCsv = options['users-csv'] || options.users;
        const identitiesCsv = options['identities-csv'] || options.identities;
        if (!usersCsv || !identitiesCsv) {
          throw new Error('import command requires --users-csv and --identities-csv options');
        }
        const replace = Boolean(options.replace);
        const instanceIdOverride = options['instance-id'] || options.instance;
        const sourceEnv = options['source-env'] || options.source || '';

        const importResult = await importUsers(targetEnv, {
          usersCsv,
          identitiesCsv,
          replace,
          instanceIdOverride,
          sourceEnv
        });
        printImportResult(importResult, options.format);
        break;
      }
      default:
        throw new Error(`Unknown command: ${command}`);
    }
  } catch (error) {
    console.error(`[ERROR] ${error.message}`);
    process.exitCode = 1;
  }
}

main();

function printUsage() {
  console.log(`Usage:
  node utils/auth-users-helper.js summary <env> [--output=path] [--format=json|text]
  node utils/auth-users-helper.js compare <source_env> <target_env> [--output=path] [--format=json|text]
  node utils/auth-users-helper.js instance-id <env>
  node utils/auth-users-helper.js import <target_env> --users-csv=path --identities-csv=path [--instance-id=uuid] [--replace] [--format=json|text]

Options:
  --output=path   Write JSON output to the given file path.
  --format=text   Render human readable output (default: text).
`);
}

function parseArgs(inputArgs) {
  const positional = [];
  const opts = {};
  inputArgs.forEach((arg) => {
    if (arg.startsWith('--')) {
      const [key, value] = arg.slice(2).split('=');
      opts[key] = value !== undefined ? value : true;
    } else {
      positional.push(arg);
    }
  });
  return { positionalArgs: positional, options: opts };
}

function normalizeEnvKey(env = '') {
  const normalized = env.toLowerCase();
  switch (normalized) {
    case 'prod':
    case 'production':
    case 'main':
      return 'PROD';
    case 'test':
    case 'staging':
      return 'TEST';
    case 'dev':
    case 'develop':
      return 'DEV';
    case 'backup':
    case 'bkup':
    case 'bkp':
      return 'BACKUP';
    default:
      throw new Error(`Unsupported environment: ${env}`);
  }
}

function getEnvValue(primaryKey, fallbackKey) {
  return process.env[primaryKey] || process.env[fallbackKey] || '';
}

function getEnvConfig(env) {
  const envKey = normalizeEnvKey(env);
  const projectVar = `SUPABASE_${envKey}_PROJECT_REF`;
  const legacyProjectVar = `SUPABSE_${envKey}_PROJECT_REF`;
  const passwordVar = `SUPABASE_${envKey}_DB_PASSWORD`;
  const legacyPasswordVar = `SUPABSE_${envKey}_DB_PASSWORD`;
  const serviceRoleVar = `SUPABASE_${envKey}_SERVICE_ROLE_KEY`;
  const genericServiceRoleVar = 'SUPABASE_SERVICE_ROLE_KEY';

  const projectRef = getEnvValue(projectVar, legacyProjectVar);
  if (!projectRef) {
    throw new Error(`Missing project reference for ${envKey}. Set ${projectVar} in .env.local`);
  }

  const dbPassword = getEnvValue(passwordVar, legacyPasswordVar);
  if (!dbPassword) {
    throw new Error(`Missing database password for ${envKey}. Set ${passwordVar} in .env.local`);
  }

  let serviceRoleKey = process.env[serviceRoleVar] || '';
  let serviceRoleSource = serviceRoleVar;
  if (!serviceRoleKey && process.env[genericServiceRoleVar]) {
    serviceRoleKey = process.env[genericServiceRoleVar];
    serviceRoleSource = genericServiceRoleVar;
  }

  if (!serviceRoleKey) {
    throw new Error(`Missing service role key for ${envKey}. Set ${serviceRoleVar} or ${genericServiceRoleVar}`);
  }

  const supabaseUrl = `https://${projectRef}.supabase.co`;

  return {
    envKey,
    envLabel: env,
    projectRef,
    dbPassword,
    serviceRoleKey,
    serviceRoleSource,
    supabaseUrl
  };
}

async function listAuthUsers(config) {
  const supabase = createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });

  const users = [];
  const perPage = 1000;
  let page = 1;

  while (true) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage });
    if (error) {
      throw new Error(`Failed to list users for ${config.envLabel}: ${error.message}`);
    }
    if (!data || !Array.isArray(data.users) || data.users.length === 0) {
      break;
    }
    users.push(...data.users);
    if (data.users.length < perPage) {
      break;
    }
    page += 1;
  }

  return users;
}

async function fetchInstanceId(projectRef) {
  if (!SUPABASE_ACCESS_TOKEN || !fetchFn) {
    return null;
  }
  const response = await fetchFn(`https://api.supabase.com/v1/projects/${projectRef}`, {
    headers: {
      Authorization: `Bearer ${SUPABASE_ACCESS_TOKEN}`,
      'Content-Type': 'application/json'
    }
  });
  if (!response.ok) {
    return null;
  }
  const payload = await response.json();
  return payload?.id || null;
}

async function buildSummary(env, options = {}) {
  const config = getEnvConfig(env);
  const users = await listAuthUsers(config);
  const projectId = await fetchInstanceId(config.projectRef);

  const summary = {
    env: config.envLabel,
    projectRef: config.projectRef,
    projectId,
    userCount: users.length,
    users: users.map((user) => ({
      id: user.id,
      email: user.email,
      phone: user.phone,
      createdAt: user.created_at,
      lastSignInAt: user.last_sign_in_at,
      factorsCount: Array.isArray(user.factors) ? user.factors.length : 0,
      providers: Array.isArray(user.identities) ? user.identities.map((identity) => identity.provider) : []
    }))
  };

  if (options.limit && Number.isInteger(Number(options.limit))) {
    const limit = Number(options.limit);
    summary.users = summary.users.slice(0, limit);
  }

  return summary;
}

async function compareEnvironments(sourceEnv, targetEnv, options = {}) {
  const sourceSummary = await buildSummary(sourceEnv, options);
  const targetSummary = await buildSummary(targetEnv, options);

  const targetIds = new Set(targetSummary.users.map((user) => user.id));

  const missingInTarget = sourceSummary.users.filter((user) => !targetIds.has(user.id));

  return {
    source: sourceSummary,
    target: targetSummary,
    missingInTarget
  };
}

function printSummary(summary, format = 'text') {
  if (format === 'json') {
    console.log(JSON.stringify(summary, null, 2));
    return;
  }

  console.log(`[INFO] Auth users summary for ${summary.env} (${summary.projectRef})`);
  if (summary.projectId) {
    console.log(`[INFO] Management API project id: ${summary.projectId}`);
  }
  console.log(`[INFO] Total users: ${summary.userCount}`);
  summary.users.forEach((user) => {
    console.log(
      `  - id=${user.id} | email=${user.email || 'N/A'} | phone=${user.phone || 'N/A'} | providers=${user.providers.join(',')}`
    );
  });
}

function printComparison(comparison, format = 'text') {
  if (format === 'json') {
    console.log(JSON.stringify(comparison, null, 2));
    return;
  }

  console.log(`[INFO] Source ${comparison.source.env} users: ${comparison.source.userCount}`);
  console.log(`[INFO] Target ${comparison.target.env} users: ${comparison.target.userCount}`);
  if (comparison.missingInTarget.length === 0) {
    console.log('[SUCCESS] All source users are present in target.');
  } else {
    console.log(`[WARN] Missing ${comparison.missingInTarget.length} user(s) in target:`);
    comparison.missingInTarget.forEach((user) => {
      console.log(`  - id=${user.id} | email=${user.email || 'N/A'} | providers=${user.providers.join(',')}`);
    });
  }
}

async function importUsers(targetEnv, options = {}) {
  const config = getEnvConfig(targetEnv);
  const usersCsvPath = path.resolve(options.usersCsv);
  const identitiesCsvPath = path.resolve(options.identitiesCsv);

  if (!fs.existsSync(usersCsvPath)) {
    throw new Error(`Users CSV file not found: ${usersCsvPath}`);
  }
  if (!fs.existsSync(identitiesCsvPath)) {
    throw new Error(`Identities CSV file not found: ${identitiesCsvPath}`);
  }

  let instanceId = options.instanceIdOverride || null;
  if (!instanceId) {
    instanceId = await fetchInstanceId(config.projectRef);
  }
  if (!instanceId) {
    throw new Error('Unable to resolve target instance_id (provide --instance-id or set SUPABASE_ACCESS_TOKEN)');
  }

  const usersRaw = parseCsvFile(usersCsvPath);
  const identitiesRaw = parseCsvFile(identitiesCsvPath);

  if (!usersRaw.length) {
    throw new Error('Users CSV is empty - nothing to import');
  }

  const normalizedUsers = usersRaw.map((row) => normalizeUserRow(row, instanceId));
  const normalizedIdentities = identitiesRaw.map((row) => normalizeIdentityRow(row, instanceId));

  const supabase = createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });
  const authDb = supabase.schema('auth');

  if (options.replace) {
    await deleteAllRows(authDb, 'identities');
    await deleteAllRows(authDb, 'users');
  }

  await upsertRows(authDb, 'users', normalizedUsers, 'id');
  if (normalizedIdentities.length > 0) {
    await upsertRows(authDb, 'identities', normalizedIdentities, 'id');
  }

  const postSummary = await buildSummary(targetEnv, options);

  return {
    env: config.envLabel,
    projectRef: config.projectRef,
    instanceId,
    replace: Boolean(options.replace),
    usersProcessed: normalizedUsers.length,
    identitiesProcessed: normalizedIdentities.length,
    summary: postSummary,
    sourceEnv: options.sourceEnv || ''
  };
}

function printImportResult(result, format = 'text') {
  if (format === 'json') {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  console.log(`[INFO] Import completed for ${result.env} (${result.projectRef})`);
  console.log(`[INFO] Target instance_id: ${result.instanceId}`);
  if (result.replace) {
    console.log('[INFO] Target data was replaced prior to import.');
  }
  console.log(`[INFO] Users processed: ${result.usersProcessed}`);
  console.log(`[INFO] Identities processed: ${result.identitiesProcessed}`);
  if (result.summary) {
    console.log(`[INFO] Target now reports ${result.summary.userCount} user(s) via admin API.`);
  }
}

function parseCsvFile(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const rows = parseCsv(content);
  if (!rows.length) {
    return [];
  }
  const headers = rows.shift().map((header) => header.trim());
  const records = [];
  rows.forEach((row) => {
    if (row.length === 0) {
      return;
    }
    const record = {};
    headers.forEach((header, index) => {
      record[header] = row[index] !== undefined ? row[index] : '';
    });
    const hasValues = Object.values(record).some((value) => value !== '' && value !== null && value !== undefined);
    if (hasValues) {
      records.push(record);
    }
  });
  return records;
}

function parseCsv(content) {
  const rows = [];
  let currentRow = [];
  let currentField = '';
  let inQuotes = false;

  const pushField = () => {
    currentRow.push(currentField);
    currentField = '';
  };

  const pushRow = () => {
    // Skip entirely empty rows
    if (currentRow.length > 0) {
      rows.push(currentRow);
    }
    currentRow = [];
  };

  let i = 0;
  while (i < content.length) {
    let char = content[i];

    if (i === 0 && char === '\ufeff') {
      i += 1;
      continue;
    }

    if (inQuotes) {
      if (char === '"') {
        const nextChar = content[i + 1];
        if (nextChar === '"') {
          currentField += '"';
          i += 2;
          continue;
        }
        inQuotes = false;
        i += 1;
        continue;
      }
      currentField += char;
      i += 1;
      continue;
    }

    if (char === '"') {
      inQuotes = true;
      i += 1;
      continue;
    }

    if (char === ',') {
      pushField();
      i += 1;
      continue;
    }

    if (char === '\r') {
      pushField();
      if (content[i + 1] === '\n') {
        i += 2;
      } else {
        i += 1;
      }
      pushRow();
      continue;
    }

    if (char === '\n') {
      pushField();
      pushRow();
      i += 1;
      continue;
    }

    currentField += char;
    i += 1;
  }

  pushField();
  pushRow();

  return rows.filter((row) => row.some((field) => field !== ''));
}

function normalizeUserRow(row, instanceId) {
  const normalized = normalizeRow(row);
  normalized.instance_id = instanceId;
  return normalized;
}

function normalizeIdentityRow(row, instanceId) {
  const normalized = normalizeRow(row);
  normalized.instance_id = instanceId;
  return normalized;
}

function normalizeRow(row) {
  const normalized = {};
  Object.entries(row).forEach(([key, value]) => {
    normalized[key] = convertValue(key, value);
  });
  return normalized;
}

function convertValue(column, rawValue) {
  if (rawValue === undefined || rawValue === null) {
    return null;
  }

  if (typeof rawValue !== 'string') {
    return rawValue;
  }

  const trimmed = rawValue.trim();
  if (trimmed === '' || trimmed.toUpperCase() === 'NULL') {
    return null;
  }

  const lower = trimmed.toLowerCase();
  if (lower === 't' || lower === 'f') {
    return lower === 't';
  }
  if (lower === 'true' || lower === 'false') {
    return lower === 'true';
  }

  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try {
      return JSON.parse(trimmed);
    } catch (error) {
      return trimmed;
    }
  }

  return trimmed;
}

async function deleteAllRows(schemaClient, tableName, primaryKey = 'id') {
  const { error } = await schemaClient.from(tableName).delete().neq(primaryKey, '');
  if (error) {
    throw new Error(`Failed to delete rows from ${tableName}: ${error.message}`);
  }
}

async function upsertRows(schemaClient, tableName, rows, conflictKey) {
  const chunkSize = 50;
  for (let i = 0; i < rows.length; i += chunkSize) {
    const chunk = rows.slice(i, i + chunkSize);
    const { error } = await schemaClient.from(tableName).upsert(chunk, {
      onConflict: conflictKey,
      defaultToNull: false,
      returning: 'minimal'
    });
    if (error) {
      throw new Error(`Failed to upsert into ${tableName}: ${error.message}`);
    }
  }
}



