#!/usr/bin/env node
/**
 * Supabase Edge Functions Migration Utility
 * Migrates edge functions from source to target project
 * Uses Supabase CLI for downloading and deploying functions
 *
 * CRITICAL: This script NEVER touches target project secrets. It does not run
 * "supabase secrets set". Deploy uses minimal env only (no .env.local). Any .env
 * files in the deploy directory are removed before deploy. Existing target secret
 * keys and values are never modified.
 *
 * Usage: node utils/edge-functions-migration.js <source_ref> <target_ref> <migration_dir> [options]
 *
 * Options:
 *   --functions=<name1,name2,...>  Migrate only specified functions
 *   --filter-file=<path>            Read function names from file (one per line)
 *   --allow-missing                 Allow missing functions in filter (for retry scripts)
 *   --incremental                   Incremental mode (skip identical functions)
 *   --replace                       Replace mode (delete all target functions first)
 *   --retryMissing                  Only deploy functions missing in target
 *   --compare-target                Download target copy and diff vs source before deploy (slower; default is direct deploy from source only)
 *   --prune-target                  After deploy, delete edge functions that exist on target but not in source (full mirror; skipped with --functions / --retryMissing)
 *
 * Edge deploy tuning (env):
 *   EDGE_DEPLOY_STRATEGY           Force one method: use-api | use-docker (skips probing; sticky is that method).
 *   EDGE_DEPLOY_TIMEOUT_USE_API_MS Per-strategy timeout for --use-api (default 90000).
 *   EDGE_DEPLOY_TIMEOUT_USE_DOCKER_MS Per-strategy timeout for --use-docker (default 180000).
 *   EDGE_DOCKER_NO_AUTO_START=true   Do not open Docker Desktop / systemctl start docker from this utility.
 *   EDGE_DOCKER_START_WAIT_SEC       Max seconds to poll after auto-start (default 120).
 */

const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');
const PROJECT_ROOT = path.resolve(__dirname, '..');
const {
    createDeployStrategyContext,
    deployWithProbeAndSticky,
    getDeployStrategyOrder
} = require('./lib/edgeFunctionDeploy');

// When stdout is a pipe (e.g. `node … | tee`), Node uses block buffering — logs appear stuck.
// setBlocking makes writes flush promptly on Unix/macOS.
(function lineBufferStdio() {
    try {
        for (const stream of [process.stdout, process.stderr]) {
            const h = stream && stream._handle;
            if (h && typeof h.setBlocking === 'function') {
                h.setBlocking(true);
            }
        }
    } catch (_) {
        /* ignore */
    }
})();

// ANSI color codes for console output
const colors = {
    reset: '\x1b[0m',
    bright: '\x1b[1m',
    dim: '\x1b[2m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    cyan: '\x1b[36m',
    magenta: '\x1b[35m'
};

// Logging functions
function logInfo(message) {
    console.log(`${colors.blue}[INFO]${colors.reset} ${message}`);
}

function logSuccess(message) {
    console.log(`${colors.green}[SUCCESS]${colors.reset} ${message}`);
}

function logWarning(message) {
    console.log(`${colors.yellow}[WARNING]${colors.reset} ${message}`);
}

function logError(message) {
    console.error(`${colors.red}[ERROR]${colors.reset} ${message}`);
}

function logStep(step, total, message) {
    console.log(`${colors.cyan}[STEP ${step}/${total}]${colors.reset} ${message}`);
}

function logSeparator() {
    console.log('━'.repeat(70));
}

function mergeDirectories(srcDir, destDir) {
    if (!fs.existsSync(srcDir)) {
        return;
    }
    fs.mkdirSync(destDir, { recursive: true });
    const entries = fs.readdirSync(srcDir, { withFileTypes: true });
    for (const entry of entries) {
        const srcPath = path.join(srcDir, entry.name);
        const destPath = path.join(destDir, entry.name);
        if (entry.isDirectory()) {
            mergeDirectories(srcPath, destPath);
        } else if (entry.isFile()) {
            fs.mkdirSync(path.dirname(destPath), { recursive: true });
            fs.copyFileSync(srcPath, destPath);
        }
    }
}

function normalizeFunctionLayout(functionDir, downloadRoot) {
    const sharedDest = path.join(downloadRoot, '_shared');
    try {
        const nestedFunctionsDir = path.join(functionDir, 'functions');
        if (fs.existsSync(nestedFunctionsDir) && fs.lstatSync(nestedFunctionsDir).isDirectory()) {
            const nestedEntries = fs.readdirSync(nestedFunctionsDir, { withFileTypes: true });
            for (const entry of nestedEntries) {
                const entryPath = path.join(nestedFunctionsDir, entry.name);
                if (entry.name === '_shared') {
                    mergeDirectories(entryPath, sharedDest);
                } else {
                    const destPath = path.join(functionDir, entry.name);
                    if (fs.existsSync(destPath)) {
                        fs.rmSync(destPath, { recursive: true, force: true });
                    }
                    fs.mkdirSync(path.dirname(destPath), { recursive: true });
                    fs.cpSync(entryPath, destPath, { recursive: true });
                }
            }
            fs.rmSync(nestedFunctionsDir, { recursive: true, force: true });
        }

        const localSharedDir = path.join(functionDir, '_shared');
        if (fs.existsSync(localSharedDir) && fs.lstatSync(localSharedDir).isDirectory()) {
            mergeDirectories(localSharedDir, sharedDest);
            fs.rmSync(localSharedDir, { recursive: true, force: true });
        }
    } catch (err) {
        logWarning(`    ⚠ Unable to normalize layout for ${path.basename(functionDir)}: ${err.message}`);
    }
}

// Collect shared files from all known locations into a single global directory
// Returns: { success: boolean, files: string[], locations: string[], globalDir: string }
function collectSharedFiles(functionsDir, functionDirs = []) {
    const globalSharedDir = path.join(functionsDir, '_shared');
    const collectedFiles = new Set();
    const foundLocations = [];
    
    // Ensure global shared directory exists
    if (!fs.existsSync(globalSharedDir)) {
        fs.mkdirSync(globalSharedDir, { recursive: true });
    }
    
    // Priority 1: Migration directory's global _shared (from previous downloads)
    const migrationSharedDir = path.join(functionsDir, '_shared');
    if (fs.existsSync(migrationSharedDir) && fs.lstatSync(migrationSharedDir).isDirectory()) {
        const files = fs.readdirSync(migrationSharedDir);
        if (files.length > 0) {
            foundLocations.push(migrationSharedDir);
            // Files already in global directory, just record them
            files.forEach(file => {
                const filePath = path.join(migrationSharedDir, file);
                try {
                    if (fs.statSync(filePath).isFile()) {
                        collectedFiles.add(file);
                    }
                } catch {
                    // Skip if can't stat
                }
            });
        }
    }
    
    // Priority 2: Project root shared files (local repository)
    const projectRootSharedDir = path.join(PROJECT_ROOT, 'supabase', 'functions', '_shared');
    if (fs.existsSync(projectRootSharedDir) && fs.lstatSync(projectRootSharedDir).isDirectory()) {
        const files = fs.readdirSync(projectRootSharedDir);
        if (files.length > 0) {
            foundLocations.push(projectRootSharedDir);
            mergeDirectories(projectRootSharedDir, globalSharedDir);
            files.forEach(file => {
                const filePath = path.join(projectRootSharedDir, file);
                try {
                    if (fs.statSync(filePath).isFile()) {
                        collectedFiles.add(file);
                    }
                } catch {
                    // Skip if can't stat
                }
            });
        }
    }
    
    // Priority 3: Each function's local _shared directory (merge into global)
    for (const functionDir of functionDirs) {
        if (!functionDir || !fs.existsSync(functionDir)) continue;
        
        // Check for local shared files in function directory
        const localSharedDir = path.join(functionDir, '_shared');
        if (fs.existsSync(localSharedDir) && fs.lstatSync(localSharedDir).isDirectory()) {
            const files = fs.readdirSync(localSharedDir);
            if (files.length > 0) {
                foundLocations.push(localSharedDir);
                mergeDirectories(localSharedDir, globalSharedDir);
                files.forEach(file => {
                    const filePath = path.join(localSharedDir, file);
                    try {
                        if (fs.statSync(filePath).isFile()) {
                            collectedFiles.add(file);
                        }
                    } catch {
                        // Skip if can't stat
                    }
                });
            }
        }
        
        // Check for nested shared files
        const nestedSharedDir = path.join(functionDir, 'functions', '_shared');
        if (fs.existsSync(nestedSharedDir) && fs.lstatSync(nestedSharedDir).isDirectory()) {
            const files = fs.readdirSync(nestedSharedDir);
            if (files.length > 0) {
                foundLocations.push(nestedSharedDir);
                mergeDirectories(nestedSharedDir, globalSharedDir);
                files.forEach(file => {
                    const filePath = path.join(nestedSharedDir, file);
                    try {
                        if (fs.statSync(filePath).isFile()) {
                            collectedFiles.add(file);
                        }
                    } catch {
                        // Skip if can't stat
                    }
                });
            }
        }
    }
    
    // Get final list of files in global directory
    const finalFiles = fs.existsSync(globalSharedDir) 
        ? fs.readdirSync(globalSharedDir).filter(f => {
            const filePath = path.join(globalSharedDir, f);
            try {
                return fs.statSync(filePath).isFile();
            } catch {
                return false;
            }
        })
        : [];
    
    return {
        success: finalFiles.length > 0,
        files: finalFiles,
        locations: foundLocations,
        globalDir: globalSharedDir
    };
}

// Explicitly download shared files by downloading a function that uses them
// This is a workaround when shared files aren't automatically downloaded
async function downloadSharedFilesExplicitly(projectRef, downloadDir, dbPassword, functionName, quiet = false) {
    if (!checkDocker()) {
        if (!quiet) {
            logWarning(`    Docker not running - cannot download shared files explicitly`);
        }
        return false;
    }
    
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), `shared-download-${functionName}-`));
    const originalCwd = process.cwd();
    
    try {
        const supabaseDir = path.join(tempDir, 'supabase');
        const functionsDir = path.join(supabaseDir, 'functions');
        fs.mkdirSync(functionsDir, { recursive: true });
        fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${projectRef}"\n`);
        
        process.chdir(tempDir);
        
        // Linking is optional - try to link, but continue if it fails
        if (!linkProject(projectRef, dbPassword)) {
            logWarning(`    ⚠ Could not link to project ${projectRef} - continuing anyway (project might already be linked)`);
        }
        
        // Try downloading the function again - sometimes shared files come with the second download
        // Use retry logic for rate limiting
        try {
            await retryWithBackoff(async () => {
                execSync(`supabase functions download ${functionName}`, {
                    stdio: 'pipe',
                    timeout: 60000
                });
            }, 3, 2000, true); // quiet mode for this retry
        } catch (e) {
            // Ignore errors - we're just trying to get shared files
        }
        
        // Check for shared files in temp directory
        const tempSharedDirs = [
            path.join(tempDir, 'supabase', 'functions', '_shared'),
            path.join(tempDir, 'supabase', 'functions', functionName, '_shared'),
            path.join(tempDir, 'functions', '_shared')
        ];
        
        const migrationSharedDir = path.join(downloadDir, '_shared');
        if (!fs.existsSync(migrationSharedDir)) {
            fs.mkdirSync(migrationSharedDir, { recursive: true });
        }
        
        let foundAny = false;
        for (const tempSharedDir of tempSharedDirs) {
            if (fs.existsSync(tempSharedDir) && fs.lstatSync(tempSharedDir).isDirectory()) {
                const files = fs.readdirSync(tempSharedDir);
                if (files.length > 0) {
                    const actualFiles = files.filter(f => {
                        const filePath = path.join(tempSharedDir, f);
                        try {
                            return fs.statSync(filePath).isFile();
                        } catch {
                            return false;
                        }
                    });
                    
                    if (actualFiles.length > 0) {
                        mergeDirectories(tempSharedDir, migrationSharedDir);
                        foundAny = true;
                        if (!quiet) {
                            logInfo(`    Found ${actualFiles.length} shared file(s) in explicit download: ${actualFiles.join(', ')}`);
                        }
                    }
                }
            }
        }
        
        return foundAny;
    } catch (error) {
        if (!quiet) {
            logWarning(`    Failed to download shared files explicitly: ${error.message}`);
        }
        return false;
    } finally {
        process.chdir(originalCwd);
        fs.rmSync(tempDir, { recursive: true, force: true });
    }
}

// Load environment variables from .env.local or .env file
function loadEnvFile() {
    const envFiles = ['.env.local', '.env'];
    let loaded = false;
    for (const envFile of envFiles) {
        if (fs.existsSync(envFile)) {
            const content = fs.readFileSync(envFile, 'utf8');
            const lines = content.split('\n');
            let loadedCount = 0;
            for (const line of lines) {
                const trimmed = line.trim();
                if (trimmed && !trimmed.startsWith('#')) {
                    const equalIndex = trimmed.indexOf('=');
                    if (equalIndex > 0) {
                        const cleanKey = trimmed.substring(0, equalIndex).trim();
                        let value = trimmed.substring(equalIndex + 1).trim();
                        
                        if ((value.startsWith('"') && value.endsWith('"')) || 
                            (value.startsWith("'") && value.endsWith("'"))) {
                            value = value.slice(1, -1);
                        }
                        
                        process.env[cleanKey] = value;
                        loadedCount++;
                    }
                }
            }
            logInfo(`Loaded ${loadedCount} environment variables from ${envFile}`);
            loaded = true;
        }
    }
    if (!loaded) {
        logWarning('No .env.local or .env in current directory — using existing process environment only.');
    }
    return loaded;
}

// Load environment variables
loadEnvFile();
logInfo(`[edge-functions-migration] cwd=${process.cwd()} | ${new Date().toISOString()}`);

// Application name for per-app state (SUPABASE_APP_NAME or SUPABSE_APP_NAME typo from .env.local)
function getAppName() {
    if (appNameOverride != null && String(appNameOverride).trim() !== '') {
        return String(appNameOverride).trim().replace(/[^a-zA-Z0-9_-]/g, '_');
    }
    const name = process.env.SUPABASE_APP_NAME || process.env.SUPABSE_APP_NAME || '';
    const sanitized = (typeof name === 'string' ? name : '').trim().replace(/[^a-zA-Z0-9_-]/g, '_') || 'default';
    return sanitized || 'default';
}

// Target environment for per-env state (test, prod, dev, backup). Used in state path.
function getTargetEnv() {
    if (targetEnvOverride != null && String(targetEnvOverride).trim() !== '') {
        return String(targetEnvOverride).trim().toLowerCase().replace(/[^a-zA-Z0-9_-]/g, '_') || 'default';
    }
    return 'default';
}

// Path to deploy state file: edge_function_deploy_state/<APP_NAME>/<TARGET_ENV>.json
function getDeployStatePath() {
    const appName = getAppName();
    const envName = getTargetEnv();
    return path.join(PROJECT_ROOT, 'edge_function_deploy_state', appName, `${envName}.json`);
}

// Load last-deployed state for (app, target env). Returns {} on missing/invalid.
function loadDeployState() {
    try {
        const stateFile = getDeployStatePath();
        if (!fs.existsSync(stateFile)) {
            return {};
        }
        const raw = fs.readFileSync(stateFile, 'utf8');
        const state = JSON.parse(raw);
        return typeof state === 'object' && state !== null ? state : {};
    } catch {
        return {};
    }
}

// Update last-deployed timestamp for a function (per application and target env).
// State path: edge_function_deploy_state/<APP_NAME>/<TARGET_ENV>.json
function updateLastDeployedTimestamp(functionName) {
    try {
        const stateFile = getDeployStatePath();
        const stateDir = path.dirname(stateFile);
        if (!fs.existsSync(stateDir)) {
            fs.mkdirSync(stateDir, { recursive: true });
        }
        const state = loadDeployState();
        state[functionName] = new Date().toISOString();
        const tmpFile = `${stateFile}.${process.pid}.${Date.now()}`;
        fs.writeFileSync(tmpFile, JSON.stringify(state, null, 2), 'utf8');
        fs.renameSync(tmpFile, stateFile);
    } catch (err) {
        logWarning(`Could not update last-deployed state for ${functionName}: ${err.message}`);
    }
}

// Configuration from arguments
const SOURCE_REF = process.argv[2];
const TARGET_REF = process.argv[3];
const MIGRATION_DIR_INPUT = process.argv[4];
const MIGRATION_DIR = MIGRATION_DIR_INPUT ? path.resolve(process.cwd(), MIGRATION_DIR_INPUT) : undefined;

const additionalArgs = process.argv.slice(5);
let filterList = [];
let filterFilePath = null;
let allowPartialFilter = false;
let incrementalMode = false;
let replaceMode = false;
let retryMissingMode = false;
/** When true: remove target-only functions after migration so target name set matches source. */
let pruneTargetMode = false;
/** When false (default): skip downloading target for byte compare — always deploy source to target (faster). */
let compareWithTarget = false;
let appNameOverride = null;
let targetEnvOverride = null;

for (const rawArg of additionalArgs) {
    if (!rawArg) continue;
    if (rawArg.startsWith('--functions=')) {
        const csv = rawArg.split('=')[1] || '';
        const names = csv.split(',').map((item) => item.trim()).filter(Boolean);
        filterList = filterList.concat(names);
    } else if (rawArg.startsWith('--filter-file=')) {
        filterFilePath = rawArg.split('=')[1] || '';
    } else if (rawArg.startsWith('--app-name=')) {
        appNameOverride = rawArg.split('=')[1] || '';
    } else if (rawArg.startsWith('--target-env=')) {
        targetEnvOverride = rawArg.split('=')[1] || '';
    } else if (rawArg === '--allow-missing') {
        allowPartialFilter = true;
    } else if (rawArg === '--incremental' || rawArg === '--increment') {
        incrementalMode = true;
    } else if (rawArg === '--replace') {
        replaceMode = true;
    } else if (rawArg === '--retryMissing' || rawArg === '--retry-missing') {
        retryMissingMode = true;
    } else if (rawArg === '--prune-target' || rawArg === '--prune-target-edge') {
        pruneTargetMode = true;
    } else if (rawArg === '--compare-target' || rawArg === '--compare-with-target') {
        compareWithTarget = true;
    } else if (rawArg.trim().length > 0) {
        logWarning(`Unknown argument ignored: ${rawArg}`);
    }
}

if (filterFilePath) {
    const resolvedPath = path.resolve(process.cwd(), filterFilePath);
    if (fs.existsSync(resolvedPath)) {
        const fileContents = fs.readFileSync(resolvedPath, 'utf8');
        const names = fileContents
            .split('\n')
            .map((line) => line.trim())
            .filter((line) => line.length > 0 && !line.startsWith('#'));
        filterList = filterList.concat(names);
    } else {
        logWarning(`Filter file not found: ${resolvedPath}. Continuing without it.`);
    }
}

let uniqueFilterSet = filterList.length > 0 ? new Set(filterList) : null;
let requestedFilterNames = uniqueFilterSet ? Array.from(uniqueFilterSet) : [];
const filterNamesFound = new Set();
const missingFilterFunctions = [];

const migratedFunctions = [];
const failedFunctions = [];
const skippedFunctions = [];
const skippedSharedFunctions = []; // Functions with shared files that are skipped
const incompatibleFunctions = []; // Functions with incompatible dependencies (e.g., native modules)
const identicalFunctions = [];

const normalizeTimestamp = (value) => {
    if (value === null || value === undefined) {
        return null;
    }
    if (typeof value === 'number' && Number.isFinite(value)) {
        return Math.floor(value);
    }
    if (typeof value === 'string') {
        const numeric = Number(value);
        if (!Number.isNaN(numeric) && Number.isFinite(numeric)) {
            return Math.floor(numeric);
        }
        const parsed = Date.parse(value);
        if (!Number.isNaN(parsed)) {
            return Math.floor(parsed);
        }
    }
    return null;
};

// Check if function code actually imports from shared files (not just mentions "_shared")
// Uses regex to match only actual import/require statements
function hasSharedFileImports(functionCode) {
    if (!functionCode || typeof functionCode !== 'string') {
        return false;
    }
    
    // Match actual import/require statements that reference _shared directory
    // Patterns: 
    // - import ... from '../_shared/...'
    // - import ... from './_shared/...'
    // - import ... from '_shared/...'
    // - require('../_shared/...')
    // - from '../_shared/...' (ES6 imports)
    const sharedImportPattern = /(?:import|require|from)\s+['"](?:\.\.?\/)?_shared\/[^'"]+['"]/i;
    return sharedImportPattern.test(functionCode);
}

// Get Supabase URLs, access token, and database password from environment
function getSupabaseConfig(projectRef) {
    let envName = '';
    const prodRef = process.env.SUPABASE_PROD_PROJECT_REF || '';
    const testRef = process.env.SUPABASE_TEST_PROJECT_REF || '';
    const devRef = process.env.SUPABASE_DEV_PROJECT_REF || '';
    const backupRef = process.env.SUPABASE_BACKUP_PROJECT_REF || '';
    
    if (prodRef === projectRef) {
        envName = 'PROD';
    } else if (testRef === projectRef) {
        envName = 'TEST';
    } else if (devRef === projectRef) {
        envName = 'DEV';
    } else if (backupRef === projectRef) {
        envName = 'BACKUP';
    }
    
    if (envName) {
        logSuccess(`✓ Detected environment: ${envName} for project ref: ${projectRef}`);
    } else {
        logWarning(`✗ Could not determine environment name for project ref: ${projectRef}`);
    }
    
    // Get environment-specific access token (required for Management API)
    let accessToken = '';
    if (envName) {
        const accessTokenKey = `SUPABASE_${envName}_ACCESS_TOKEN`;
        accessToken = process.env[accessTokenKey] || '';
        if (accessToken) {
            logInfo(`  Access Token: Found (${accessTokenKey}, length: ${accessToken.length})`);
        } else {
            logError(`✗ ${accessTokenKey} not found`);
        }
    } else {
        // Fallback: try to determine from project_ref matching
        if (projectRef === process.env.SUPABASE_PROD_PROJECT_REF) {
            accessToken = process.env.SUPABASE_PROD_ACCESS_TOKEN || '';
        } else if (projectRef === process.env.SUPABASE_TEST_PROJECT_REF) {
            accessToken = process.env.SUPABASE_TEST_ACCESS_TOKEN || '';
        } else if (projectRef === process.env.SUPABASE_DEV_PROJECT_REF) {
            accessToken = process.env.SUPABASE_DEV_ACCESS_TOKEN || '';
        } else if (projectRef === process.env.SUPABASE_BACKUP_PROJECT_REF) {
            accessToken = process.env.SUPABASE_BACKUP_ACCESS_TOKEN || '';
        }
        if (!accessToken) {
            logError(`✗ Could not determine access token for project ref: ${projectRef}`);
        }
    }
    
    // Get database password (required for supabase link command)
    let dbPassword = '';
    if (envName) {
        const dbPasswordKey = `SUPABASE_${envName}_DB_PASSWORD`;
        dbPassword = process.env[dbPasswordKey] || '';
        if (dbPassword) {
            logInfo(`  Database Password: Found (for linking)`);
        } else {
            logWarning(`  Database Password: Not found (${dbPasswordKey}) - linking may fail`);
        }
    }
    
    return { envName, accessToken, dbPassword, projectRef };
}

// Validate arguments
if (!SOURCE_REF || !TARGET_REF || !MIGRATION_DIR) {
    logError('Missing required arguments');
    console.error(`Usage: node utils/edge-functions-migration.js <source_ref> <target_ref> <migration_dir>`);
    console.error('');
    console.error('Environment variables required in .env.local:');
    console.error('  - SUPABASE_PROD_ACCESS_TOKEN, SUPABASE_TEST_ACCESS_TOKEN, SUPABASE_DEV_ACCESS_TOKEN, SUPABASE_BACKUP_ACCESS_TOKEN (required for Management API)');
    console.error('  - SUPABASE_PROD_PROJECT_REF, SUPABASE_TEST_PROJECT_REF, SUPABASE_DEV_PROJECT_REF, SUPABASE_BACKUP_PROJECT_REF');
    console.error('  - SUPABASE_PROD_DB_PASSWORD, SUPABASE_TEST_DB_PASSWORD, SUPABASE_DEV_DB_PASSWORD, SUPABASE_BACKUP_DB_PASSWORD (required for linking)');
    process.exit(1);
}

// Validate migration directory
if (!fs.existsSync(MIGRATION_DIR)) {
    fs.mkdirSync(MIGRATION_DIR, { recursive: true });
    logInfo(`Created migration directory: ${MIGRATION_DIR}`);
}

// Initialize configurations
const sourceConfig = getSupabaseConfig(SOURCE_REF);
const targetConfig = getSupabaseConfig(TARGET_REF);

// Validate access tokens
if (!sourceConfig.accessToken || !targetConfig.accessToken) {
    logError('Environment-specific access tokens not found in environment variables');
    logError(`Please ensure SUPABASE_${sourceConfig.envName || 'SOURCE'}_ACCESS_TOKEN and SUPABASE_${targetConfig.envName || 'TARGET'}_ACCESS_TOKEN are set in .env.local`);
    process.exit(1);
}

logInfo('[edge-functions-migration] Config validated — starting migration run…');

// Get edge functions from a project using Management API (with pagination to fetch ALL functions)
const EDGE_FUNCTIONS_PAGE_SIZE = 200;

function fetchFunctionsPage(projectRef, accessToken, offset = 0, limit = EDGE_FUNCTIONS_PAGE_SIZE) {
    const url = `https://api.supabase.com/v1/projects/${projectRef}/functions?limit=${limit}&offset=${offset}`;
    return new Promise((resolve, reject) => {
        const req = https.request(url, {
            method: 'GET',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': 'application/json'
            }
        }, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    try {
                        const json = JSON.parse(data);
                        // API may return array directly or { data: [...] }
                        const funcList = Array.isArray(json)
                            ? json
                            : (json && Array.isArray(json.data) ? json.data : []);
                        resolve(funcList);
                    } catch (e) {
                        reject(new Error(`Failed to parse functions response: ${e.message}`));
                    }
                } else {
                    reject(new Error(`HTTP ${res.statusCode}: ${data.substring(0, 200)}`));
                }
            });
        });
        req.on('error', reject);
        req.end();
    });
}

// Get edge functions from a project using Management API
async function getEdgeFunctions(projectRef, accessToken, projectName, dbPassword = null) {
    try {
        logInfo(`Fetching edge functions from ${projectName || 'project'}...`);
        
        // Show token info for debugging (first 8 and last 4 chars for security)
        if (accessToken) {
            const tokenPreview = accessToken.length > 12 
                ? `${accessToken.substring(0, 8)}...${accessToken.substring(accessToken.length - 4)}`
                : '***';
            logInfo(`  Using access token: ${tokenPreview} (length: ${accessToken.length})`);
        } else {
            logWarning(`  No access token provided`);
        }
        
        // Fetch all pages so we get every function (API may paginate at 100–200)
        const allFunctions = [];
        const seenIds = new Set();
        let offset = 0;
        let page;
        try {
            do {
                logInfo(
                    `  Management API: fetching functions page (offset ${offset}, limit ${EDGE_FUNCTIONS_PAGE_SIZE})…`
                );
                page = await fetchFunctionsPage(projectRef, accessToken, offset, EDGE_FUNCTIONS_PAGE_SIZE);
                for (const f of page) {
                    const key = f.id || f.name;
                    if (key && !seenIds.has(key)) {
                        seenIds.add(key);
                        allFunctions.push(f);
                    }
                }
                logInfo(`  … page done — ${allFunctions.length} unique function(s) so far`);
                offset += EDGE_FUNCTIONS_PAGE_SIZE;
            } while (page.length === EDGE_FUNCTIONS_PAGE_SIZE);
        } catch (apiError) {
            // If paginated request fails (e.g. API does not support limit/offset), try single request without params
            if (allFunctions.length === 0) {
                const url = `https://api.supabase.com/v1/projects/${projectRef}/functions`;
                const raw = await new Promise((resolve, reject) => {
                    const req = https.request(url, {
                        method: 'GET',
                        headers: {
                            'Authorization': `Bearer ${accessToken}`,
                            'Content-Type': 'application/json'
                        }
                    }, (res) => {
                        let data = '';
                        res.on('data', (chunk) => { data += chunk; });
                        res.on('end', () => resolve({ statusCode: res.statusCode, data }));
                    });
                    req.on('error', reject);
                    req.end();
                });
                if (raw.statusCode >= 200 && raw.statusCode < 300) {
                    const json = JSON.parse(raw.data);
                    const funcList = Array.isArray(json) ? json : (json && Array.isArray(json.data) ? json.data : []);
                    funcList.forEach(f => allFunctions.push(f));
                } else if (raw.statusCode === 403) {
                    let errorMsg = '';
                    try {
                        const errorJson = JSON.parse(raw.data);
                        errorMsg = errorJson.message || raw.data.substring(0, 200);
                    } catch {
                        errorMsg = raw.data.substring(0, 200);
                    }
                    logError(`  HTTP 403: ${errorMsg}`);
                    logWarning(`  ⚠ Permission denied: Access token does not have permission to access edge functions endpoint`);
                    logInfo(`  Attempting to use Supabase CLI as fallback...`);
                    try {
                        let passwordToUse = dbPassword;
                        if (!passwordToUse) {
                            try {
                                const config = getSupabaseConfig(projectRef);
                                passwordToUse = config.dbPassword;
                            } catch (e) { /* ignore */ }
                        }
                        let accessTokenToUse = accessToken;
                        if (!accessTokenToUse) {
                            try {
                                const config = getSupabaseConfig(projectRef);
                                accessTokenToUse = config.accessToken;
                            } catch (e) { /* ignore */ }
                        }
                        const cliFunctions = getEdgeFunctionsViaCLI(projectRef, projectName, passwordToUse, accessTokenToUse);
                        if (cliFunctions && cliFunctions.length > 0) {
                            logSuccess(`  ✓ Successfully retrieved ${cliFunctions.length} function(s) via Supabase CLI`);
                            return cliFunctions;
                        }
                    } catch (cliError) {
                        logWarning(`  Supabase CLI fallback failed: ${cliError.message}`);
                    }
                    logWarning(`  Edge functions migration will be skipped for this project`);
                    return [];
                } else {
                    throw new Error(`HTTP ${raw.statusCode}: ${raw.data.substring(0, 200)}`);
                }
            } else {
                throw apiError;
            }
        }

        const functions = allFunctions;
        
        // If we got nothing and API might have returned 403, run the 403 path (CLI fallback) via the original URL
        if (functions.length === 0) {
            const url = `https://api.supabase.com/v1/projects/${projectRef}/functions`;
            const response = await new Promise((resolve, reject) => {
                const req = https.request(url, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${accessToken}`,
                        'Content-Type': 'application/json'
                    }
                }, (res) => {
                    let data = '';
                    res.on('data', (chunk) => { data += chunk; });
                    res.on('end', () => resolve({ statusCode: res.statusCode, data }));
                });
                req.on('error', reject);
                req.end();
            });
            
            if (response.statusCode === 403) {
                let errorMsg = '';
                try {
                    const errorJson = JSON.parse(response.data);
                    errorMsg = errorJson.message || response.data.substring(0, 200);
                } catch {
                    errorMsg = response.data.substring(0, 200);
                }
                logError(`  HTTP 403: ${errorMsg}`);
                logWarning(`  ⚠ Permission denied: Access token does not have permission to access edge functions endpoint`);
                logInfo(`  Attempting to use Supabase CLI as fallback...`);
                
                try {
                    let passwordToUse = dbPassword;
                    if (!passwordToUse) {
                        try {
                            const config = getSupabaseConfig(projectRef);
                            passwordToUse = config.dbPassword;
                        } catch (e) { /* ignore */ }
                    }
                    let accessTokenToUse = accessToken;
                    if (!accessTokenToUse) {
                        try {
                            const config = getSupabaseConfig(projectRef);
                            accessTokenToUse = config.accessToken;
                        } catch (e) { /* ignore */ }
                    }
                    const cliFunctions = getEdgeFunctionsViaCLI(projectRef, projectName, passwordToUse, accessTokenToUse);
                    if (cliFunctions && cliFunctions.length > 0) {
                        logSuccess(`  ✓ Successfully retrieved ${cliFunctions.length} function(s) via Supabase CLI`);
                        return cliFunctions;
                    }
                    logWarning(`  Supabase CLI did not return any functions`);
                } catch (cliError) {
                    logWarning(`  Supabase CLI fallback failed: ${cliError.message}`);
                }
                logWarning(`  Edge functions migration will be skipped for this project`);
                logWarning(`  To fix: Ensure your access token has 'functions:read' permission or use a token with full project access`);
                return [];
            }
            if (response.statusCode >= 300) {
                throw new Error(`HTTP ${response.statusCode}: ${response.data.substring(0, 200)}`);
            }
        }
        
        logSuccess(`Found ${functions.length} edge function(s) in ${projectName || 'project'}`);
        if (functions.length > 0) {
            functions.forEach((func, index) => {
                logInfo(`  ${index + 1}. ${func.name} (id: ${func.id || 'N/A'})`);
            });
        }
        return functions;
    } catch (error) {
        // For 403 errors, we already handled them above and returned empty array
        // Only log and throw for other errors
        if (error.message && error.message.includes('403')) {
            // This shouldn't happen since we handle 403 above, but just in case
            logWarning(`Permission denied for edge functions in ${projectName || 'project'}`);
            logWarning(`Returning empty array to allow migration to continue`);
            return [];
        }
        
        logError(`Failed to get edge functions from ${projectName || 'project'}`);
        logError(`  Error: ${error.message || JSON.stringify(error)}`);
        
        if (error.message && (
            error.message.includes('401') ||
            error.message.includes('Unauthorized')
        )) {
            logError(`Authentication failed: Access token may be invalid or expired`);
            logError(`Please verify:`);
            logError(`  1. Environment-specific access tokens (SUPABASE_${sourceConfig.envName || 'SOURCE'}_ACCESS_TOKEN, SUPABASE_${targetConfig.envName || 'TARGET'}_ACCESS_TOKEN) are set correctly in .env.local`);
            logError(`  2. The access token has not expired`);
            logError(`  3. The access token has the necessary permissions`);
            throw error; // 401 errors should still fail
        }
        
        throw error;
    }
}

// Get edge functions using Supabase CLI (fallback when API returns 403)
function getEdgeFunctionsViaCLI(projectRef, projectName, dbPassword, accessToken = null) {
    try {
        logInfo(`  Attempting to list functions via Supabase CLI for ${projectName || 'project'}...`);
        
        // Prepare environment with access token if provided
        const env = { ...process.env };
        if (accessToken) {
            env.SUPABASE_ACCESS_TOKEN = accessToken;
        }
        
        // First, try to link to the project
        let linked = false;
        if (dbPassword) {
            try {
                // Unlink first to avoid conflicts
                try {
                    execSync('supabase unlink --yes', { 
                        stdio: 'pipe', 
                        timeout: 5000,
                        env: env
                    });
                } catch (e) {
                    // Ignore errors - project might not be linked
                }
                
                // Link to project
                execSync(`supabase link --project-ref ${projectRef} --password "${dbPassword}"`, {
                    stdio: 'pipe',
                    timeout: 30000,
                    env: env
                });
                linked = true;
            } catch (linkError) {
                logWarning(`  Failed to link project: ${linkError.message}`);
                // Try without password (might already be linked or use CLI auth)
                try {
                    execSync(`supabase link --project-ref ${projectRef}`, {
                        stdio: 'pipe',
                        timeout: 30000,
                        env: env
                    });
                    linked = true;
                } catch (e) {
                    logWarning(`  Could not link project via CLI`);
                }
            }
        } else {
            // Try to link without password
            try {
                execSync(`supabase link --project-ref ${projectRef}`, {
                    stdio: 'pipe',
                    timeout: 30000,
                    env: env
                });
                linked = true;
            } catch (e) {
                logWarning(`  Could not link project via CLI (no password provided)`);
            }
        }
        
        if (!linked) {
            logWarning(`  ⚠ Could not link to project via Supabase CLI - continuing anyway (project might already be linked)`);
            // Continue anyway - the project might already be linked or we can try without explicit linking
        }
        
        // List functions using Supabase CLI
        const output = execSync('supabase functions list', {
            stdio: 'pipe',
            timeout: 30000,
            encoding: 'utf8',
            env: env
        });
        
        // Parse the output - Supabase CLI outputs function names, one per line
        // Format is typically: function_name (or just function_name)
        const functionNames = output
            .split('\n')
            .map(line => line.trim())
            .filter(line => line.length > 0 && !line.startsWith('NAME') && !line.startsWith('-'))
            .map(line => {
                // Extract function name (might have extra info like "(deployed)" or timestamps)
                const match = line.match(/^(\S+)/);
                return match ? match[1] : line;
            })
            .filter(name => name && !name.includes('functions') && name.length > 0);
        
        // Convert to API-like format
        const functions = functionNames.map((name, index) => ({
            id: `cli-${index}`,
            name: name,
            slug: name,
            status: 'ACTIVE_HEALTHY',
            version: 1
        }));
        
        return functions;
    } catch (error) {
        logWarning(`  Supabase CLI method failed: ${error.message}`);
        throw error;
    }
}

// Check if Docker is running
function checkDocker() {
    try {
        execSync('docker ps', { stdio: 'pipe', timeout: 5000 });
        return true;
    } catch (e) {
        return false;
    }
}

// Ensure Docker is running before edge function download/deploy. Tries to start Docker on macOS/Linux unless EDGE_DOCKER_NO_AUTO_START=true.
async function ensureDockerRunning() {
    logInfo('Preflight: checking Docker (`docker ps`)…');
    if (checkDocker()) {
        logSuccess('Preflight: Docker is reachable.');
        return;
    }
    if (process.env.EDGE_DOCKER_NO_AUTO_START === 'true') {
        logError('Docker is not running and EDGE_DOCKER_NO_AUTO_START=true (auto-start disabled).');
        throw new Error('Docker is not running');
    }

    let waitSec = parseInt(process.env.EDGE_DOCKER_START_WAIT_SEC || '120', 10);
    if (!Number.isFinite(waitSec) || waitSec < 1) {
        waitSec = 120;
    }
    const maxWaitMs = waitSec * 1000;
    const pollIntervalMs = 3000;

    const waitForDockerDaemon = async () => {
        for (let waited = 0; waited < maxWaitMs; waited += pollIntervalMs) {
            logInfo(`Waiting for Docker to be ready... (${waited / 1000}s / ${maxWaitMs / 1000}s)`);
            try {
                execSync('docker ps', { stdio: 'pipe', timeout: 10000 });
                logSuccess('Docker is running.');
                return true;
            } catch (e) {
                /* keep polling */
            }
            await new Promise((r) => setTimeout(r, pollIntervalMs));
        }
        return false;
    };

    const isMac = process.platform === 'darwin';
    const isLinux = process.platform === 'linux';

    if (isMac) {
        logInfo('Docker is not running. Attempting to start Docker Desktop...');
        try {
            execSync('open -a Docker', { stdio: 'pipe', timeout: 5000 });
        } catch (e) {
            logWarning('Could not launch Docker Desktop (open -a Docker failed).');
        }
        if (await waitForDockerDaemon()) {
            return;
        }
    } else if (isLinux) {
        logInfo('Docker is not running. Attempting systemctl start docker...');
        try {
            execSync('systemctl start docker', { stdio: 'pipe', timeout: 15000 });
        } catch (e) {
            try {
                execSync('sudo -n systemctl start docker', { stdio: 'pipe', timeout: 15000 });
            } catch (e2) {
                logWarning('Could not start docker via systemctl (try: sudo systemctl start docker).');
            }
        }
        if (await waitForDockerDaemon()) {
            return;
        }
    }

    logError('Docker is not running - required for edge function download and deploy.');
    logInfo('Please start Docker and run this migration again.');
    if (isMac) {
        logInfo('  macOS: Open Docker from Applications, or run: open -a Docker');
    } else if (isLinux) {
        logInfo('  Linux: sudo systemctl start docker (or start your container runtime)');
    } else {
        logInfo('  Windows: Start Docker Desktop from the Start menu');
    }
    throw new Error('Docker is not running');
}

// Link project using Supabase CLI
function linkProject(projectRef, dbPassword, accessToken = null) {
    try {
        // Prepare environment with access token if provided
        const env = { ...process.env };
        if (accessToken) {
            env.SUPABASE_ACCESS_TOKEN = accessToken;
        }
        
        // Unlink first to avoid conflicts
        try {
            execSync('supabase unlink --yes', { 
                stdio: 'pipe', 
                timeout: 5000,
                env: env
            });
        } catch (e) {
            // Ignore errors - project might not be linked
        }
        
        // Link to project (password is required for link command)
        if (dbPassword) {
            execSync(`supabase link --project-ref ${projectRef} --password "${dbPassword}"`, {
                stdio: 'pipe',
                timeout: 30000,
                env: env
            });
        } else {
            // Try without password (may fail, but worth trying)
            logWarning(`    ⚠ No database password provided, trying to link without password...`);
            execSync(`supabase link --project-ref ${projectRef}`, {
                stdio: 'pipe',
                timeout: 30000,
                env: env
            });
        }
        
        return true;
    } catch (error) {
        logWarning(`    ⚠ Could not link to project ${projectRef}: ${error.message}`);
        return false;
    }
}

// Retry helper with exponential backoff for rate limiting
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function retryWithBackoff(fn, maxRetries = 3, initialDelay = 2000, quiet = false) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            return await fn();
        } catch (error) {
            lastError = error;
            const errorMessage = error.message || error.toString();
            const stderr = error.stderr ? error.stderr.toString() : '';
            const stdout = error.stdout ? error.stdout.toString() : '';
            // Also check error.code for spawn process errors
            const code = error.code || '';
            const combinedOutput = `${errorMessage}\n${stderr}\n${stdout}\n${code}`;
            
            // Check if it's a rate limit error (429) - check multiple patterns
            const isRateLimit = /429|Too Many Requests|ThrottlerException|status 429/i.test(combinedOutput);
            
            if (isRateLimit && attempt < maxRetries) {
                const delay = initialDelay * Math.pow(2, attempt); // Exponential backoff: 2s, 4s, 8s
                if (!quiet) {
                    logWarning(`    ⚠ Rate limit hit (429), retrying in ${delay/1000}s... (attempt ${attempt + 1}/${maxRetries + 1})`);
                }
                await sleep(delay);
                continue;
            }
            
            // If not rate limit or max retries reached, throw the error
            throw error;
        }
    }
    throw lastError;
}

// Download edge function code (Management API preferred, CLI fallback)
function findFunctionDirectory(rootDir, functionName) {
    if (!rootDir || !fs.existsSync(rootDir)) {
        return null;
    }

    const candidates = [
        path.join(rootDir, 'supabase', 'functions', functionName),
        path.join(rootDir, functionName),
        rootDir
    ];

    for (const candidate of candidates) {
        if (fs.existsSync(candidate) && fs.lstatSync(candidate).isDirectory()) {
            const contents = fs.readdirSync(candidate);
            if (contents.length > 0) {
                return candidate;
            }
        }
    }

    const queue = [rootDir];
    const visited = new Set();

    while (queue.length > 0) {
        const current = queue.shift();
        if (!current || visited.has(current)) continue;
        visited.add(current);

        let entries = [];
        try {
            entries = fs.readdirSync(current, { withFileTypes: true });
        } catch {
            continue;
        }

        const hasEntryPoint = entries.some((entry) => {
            if (!entry.isFile()) return false;
            const lower = entry.name.toLowerCase();
            return lower === 'index.ts' ||
                lower === 'index.js' ||
                lower === 'main.ts' ||
                lower === 'main.js' ||
                lower === 'deno.json';
        });

        if (hasEntryPoint) {
            return current;
        }

        for (const entry of entries) {
            if (entry.isDirectory()) {
                queue.push(path.join(current, entry.name));
            }
        }
    }

    return null;
}

async function downloadEdgeFunction(functionName, projectRef, downloadDir, dbPassword, quiet = false, accessToken = null) {
    let finalFunctionPath = path.join(downloadDir, functionName);
    try {
        if (!quiet) {
            logInfo(`    Downloading function code: ${functionName}...`);
        }

        // Prepare environment with access token if provided
        const env = { ...process.env };
        if (accessToken) {
            env.SUPABASE_ACCESS_TOKEN = accessToken;
        }

        if (!checkDocker()) {
            if (!quiet) {
                logError(`    ✗ Docker is not running - required for downloading functions via CLI`);
            }
            throw new Error('Docker is not running');
        }

        const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), `edge-cli-${functionName}-`));
        const originalCwd = process.cwd();
        try {
            const supabaseDir = path.join(tempDir, 'supabase');
            const functionsDir = path.join(supabaseDir, 'functions');
            fs.mkdirSync(functionsDir, { recursive: true });
            fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${projectRef}"\n`);

            process.chdir(tempDir);

            if (!quiet) {
                logInfo(`    Linking to source project for CLI download...`);
            }
            // Linking is optional - try to link, but continue if it fails (project might already be linked)
            if (!linkProject(projectRef, dbPassword, accessToken)) {
                logWarning(`    ⚠ Could not link to project ${projectRef} - continuing anyway (project might already be linked)`);
            }

            // Use retry logic with exponential backoff for rate limiting
            try {
                await retryWithBackoff(async () => {
                    execSync(`supabase functions download ${functionName}`, {
                        stdio: 'pipe',
                        timeout: 60000,
                        env: env
                    });
                }, 3, 2000, quiet);
            } catch (e) {
                const stderr = e.stderr ? e.stderr.toString() : '';
                const stdout = e.stdout ? e.stdout.toString() : '';
                const combinedOutput = `${e.message || ''}\n${stderr}\n${stdout}`;
                const needsLegacyBundle = /docker/i.test(combinedOutput) ||
                    /legacy[- ]bundle/i.test(combinedOutput) ||
                    /invalid eszip/i.test(combinedOutput) ||
                    /eszip v2/i.test(combinedOutput);

                if (needsLegacyBundle) {
                    if (!quiet) {
                        logInfo(`    Regular download failed, trying legacy bundle...`);
                    }
                    try {
                        await retryWithBackoff(async () => {
                            execSync(`supabase functions download --legacy-bundle ${functionName}`, {
                                stdio: 'pipe',
                                timeout: 60000,
                                env: env
                            });
                        }, 3, 2000, quiet);
                    } catch (legacyError) {
                        const legacyStderr = legacyError.stderr ? legacyError.stderr.toString() : '';
                        const legacyStdout = legacyError.stdout ? legacyError.stdout.toString() : '';
                        const legacyCombined = `${legacyError.message || ''}\n${legacyStderr}\n${legacyStdout}`;
                        throw new Error(`Regular and legacy download attempts failed.\nOriginal error:\n${combinedOutput}\nLegacy attempt error:\n${legacyCombined}`);
                    }
                } else {
                    throw new Error(combinedOutput.trim() || e.message);
                }
            }

            const downloadedFunctionPath = findFunctionDirectory(tempDir, functionName) ||
                path.join(tempDir, 'supabase', 'functions', functionName);

            if (!downloadedFunctionPath || !fs.existsSync(downloadedFunctionPath)) {
                throw new Error(`Downloaded function directory not found`);
            }

            fs.rmSync(finalFunctionPath, { recursive: true, force: true });
            fs.mkdirSync(path.dirname(finalFunctionPath), { recursive: true });
            fs.cpSync(downloadedFunctionPath, finalFunctionPath, { recursive: true });
            
            // IMPORTANT: Copy shared files from temp download directory to migration directory
            // Check multiple possible locations where shared files might be after download
            const migrationSharedDir = path.join(downloadDir, '_shared');
            if (!fs.existsSync(migrationSharedDir)) {
                fs.mkdirSync(migrationSharedDir, { recursive: true });
            }
            
            // Check multiple possible locations for shared files
            const tempSharedDirs = [
                path.join(tempDir, 'supabase', 'functions', '_shared'),
                path.join(tempDir, 'supabase', 'functions', functionName, '_shared'),
                path.join(tempDir, 'functions', '_shared'),
                path.join(tempDir, '_shared'),
                path.join(downloadedFunctionPath, '_shared'),
                path.join(downloadedFunctionPath, 'functions', '_shared')
            ];
            
            let totalSharedFiles = 0;
            const foundSharedLocations = [];
            
            for (const tempSharedDir of tempSharedDirs) {
                if (fs.existsSync(tempSharedDir) && fs.lstatSync(tempSharedDir).isDirectory()) {
                    const files = fs.readdirSync(tempSharedDir);
                    if (files.length > 0) {
                        // Count actual files (not directories)
                        const actualFiles = files.filter(f => {
                            const filePath = path.join(tempSharedDir, f);
                            try {
                                return fs.statSync(filePath).isFile();
                            } catch {
                                return false;
                            }
                        });
                        
                        if (actualFiles.length > 0) {
                            foundSharedLocations.push({ path: tempSharedDir, files: actualFiles });
                            mergeDirectories(tempSharedDir, migrationSharedDir);
                            totalSharedFiles += actualFiles.length;
                        }
                    }
                }
            }
            
            // Log what was copied
            if (totalSharedFiles > 0) {
                const finalSharedFiles = fs.readdirSync(migrationSharedDir).filter(f => {
                    const filePath = path.join(migrationSharedDir, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                });
                
                if (!quiet) {
                    logInfo(`    Found and copied ${finalSharedFiles.length} shared file(s) from ${foundSharedLocations.length} location(s): ${finalSharedFiles.join(', ')}`);
                }
            }
            
            normalizeFunctionLayout(finalFunctionPath, downloadDir);

            if (!quiet) {
                logSuccess(`    ✓ Downloaded function via CLI: ${functionName}`);
            }
            return true;
        } finally {
            process.chdir(originalCwd);
            fs.rmSync(tempDir, { recursive: true, force: true });
        }
    } catch (error) {
        const fallbackDir = path.join(PROJECT_ROOT, 'supabase', 'functions', functionName);
        if (fs.existsSync(fallbackDir)) {
            if (!quiet) {
                logWarning(`    Using local repository copy for ${functionName} (remote download failed)`);
            }
            fs.rmSync(finalFunctionPath, { recursive: true, force: true });
            fs.mkdirSync(path.dirname(finalFunctionPath), { recursive: true });
            fs.cpSync(fallbackDir, finalFunctionPath, { recursive: true });
            
            // Also copy shared files from local repository if they exist
            // Check multiple possible locations
            const migrationSharedDir = path.join(downloadDir, '_shared');
            if (!fs.existsSync(migrationSharedDir)) {
                fs.mkdirSync(migrationSharedDir, { recursive: true });
            }
            
            const localSharedDirs = [
                path.join(PROJECT_ROOT, 'supabase', 'functions', '_shared'),
                path.join(fallbackDir, '_shared'),
                path.join(fallbackDir, 'functions', '_shared')
            ];
            
            let totalSharedFiles = 0;
            const foundSharedLocations = [];
            
            for (const localSharedDir of localSharedDirs) {
                if (fs.existsSync(localSharedDir) && fs.lstatSync(localSharedDir).isDirectory()) {
                    const files = fs.readdirSync(localSharedDir);
                    if (files.length > 0) {
                        // Count actual files (not directories)
                        const actualFiles = files.filter(f => {
                            const filePath = path.join(localSharedDir, f);
                            try {
                                return fs.statSync(filePath).isFile();
                            } catch {
                                return false;
                            }
                        });
                        
                        if (actualFiles.length > 0) {
                            foundSharedLocations.push({ path: localSharedDir, files: actualFiles });
                            mergeDirectories(localSharedDir, migrationSharedDir);
                            totalSharedFiles += actualFiles.length;
                        }
                    }
                }
            }
            
            // Log what was copied
            if (totalSharedFiles > 0) {
                const finalSharedFiles = fs.readdirSync(migrationSharedDir).filter(f => {
                    const filePath = path.join(migrationSharedDir, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                });
                
                if (!quiet) {
                    logInfo(`    Found and copied ${finalSharedFiles.length} shared file(s) from ${foundSharedLocations.length} location(s): ${finalSharedFiles.join(', ')}`);
                }
            }
            
            normalizeFunctionLayout(finalFunctionPath, downloadDir);
            if (!quiet) {
                logSuccess(`    ✓ Copied local function source for ${functionName}`);
            }
            return true;
        }
        if (!quiet) {
            logError(`    ✗ Failed to download function ${functionName}: ${error.message}`);
        }
        return false;
    }
}

// Compare two function directories to check if they're identical (100% code comparison)
function compareFunctionDirectories(sourceDir, targetDir) {
    try {
        if (!fs.existsSync(sourceDir) || !fs.existsSync(targetDir)) {
            return false;
        }

        // Get all code files from both directories (including config files, but excluding build artifacts)
        const sourceFiles = getAllCodeFiles(sourceDir);
        const targetFiles = getAllCodeFiles(targetDir);

        // Sort for consistent comparison
        sourceFiles.sort();
        targetFiles.sort();

        // Check if file counts match
        if (sourceFiles.length !== targetFiles.length) {
            return false;
        }

        // Verify all files exist in both directories
        const sourceSet = new Set(sourceFiles);
        const targetSet = new Set(targetFiles);
        
        // Check if file lists are identical
        if (sourceFiles.length !== targetSet.size || targetFiles.length !== sourceSet.size) {
            return false;
        }
        
        for (const file of sourceFiles) {
            if (!targetSet.has(file)) {
                return false;
            }
        }

        // Compare each file byte-for-byte (100% accuracy)
        for (const file of sourceFiles) {
            const sourcePath = path.join(sourceDir, file);
            const targetPath = path.join(targetDir, file);

            if (!fs.existsSync(sourcePath) || !fs.existsSync(targetPath)) {
                return false;
            }

            const sourceStat = fs.statSync(sourcePath);
            const targetStat = fs.statSync(targetPath);

            // Compare file types (must both be files or both be directories)
            if (sourceStat.isDirectory() !== targetStat.isDirectory()) {
                return false;
            }

            // Skip directories (they're handled recursively)
            if (sourceStat.isDirectory()) {
                continue;
            }

            // Quick check: file sizes must match
            if (sourceStat.size !== targetStat.size) {
                return false;
            }

            // Byte-for-byte comparison of file contents (100% accuracy)
            const sourceContent = fs.readFileSync(sourcePath);
            const targetContent = fs.readFileSync(targetPath);
            
            // Use Buffer.compare for exact byte comparison
            if (sourceContent.compare(targetContent) !== 0) {
                return false;
            }
        }

        return true;
    } catch (error) {
        // If comparison fails, assume they're different (safer to redeploy)
        return false;
    }
}

// Get all code files recursively from a directory (including config files)
// Excludes only build artifacts and version control files
function getAllCodeFiles(dir, baseDir = dir, fileList = []) {
    try {
        const files = fs.readdirSync(dir);
        files.forEach(file => {
            const filePath = path.join(dir, file);
            const relativePath = path.relative(baseDir, filePath);
            const stat = fs.statSync(filePath);
            
            // Skip build artifacts and version control (but include .env, .deno, config files)
            if (file === 'node_modules' || 
                file === '.git' || 
                file === '.svn' ||
                file === 'dist' ||
                file === 'build' ||
                file === '.next' ||
                file === '.cache' ||
                (file.startsWith('.') && file !== '.env' && file !== '.deno' && !file.endsWith('.json') && !file.endsWith('.toml') && !file.endsWith('.yaml') && !file.endsWith('.yml'))) {
                return;
            }
            
            if (stat.isDirectory()) {
                getAllCodeFiles(filePath, baseDir, fileList);
            } else {
                // Include all code files: .ts, .js, .tsx, .jsx, .json, .toml, .yaml, .yml, .md, .txt, .env, etc.
                fileList.push(relativePath);
            }
        });
        return fileList;
    } catch (error) {
        // If we can't read the directory, return what we have
        return fileList;
    }
}

// Delete edge function using Supabase CLI
async function deleteEdgeFunction(functionName, targetRef, dbPassword, accessToken = null) {
    const originalCwd = process.cwd();
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), `edge-delete-${functionName}-`));
    
    try {
        // Prepare environment with access token if provided
        const env = { ...process.env };
        if (accessToken) {
            env.SUPABASE_ACCESS_TOKEN = accessToken;
        }
        
        const supabaseDir = path.join(tempDir, 'supabase');
        fs.mkdirSync(supabaseDir, { recursive: true });
        fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${targetRef}"\n`);
        
        process.chdir(tempDir);
        
        // Link to target project (optional - might already be linked)
        if (!linkProject(targetRef, dbPassword, accessToken)) {
            logWarning(`    ⚠ Could not link to target project ${targetRef} - continuing anyway (project might already be linked)`);
        }
        
        // Delete function (project is already linked) - with retry for rate limiting
        await retryWithBackoff(async () => {
            execSync(`supabase functions delete ${functionName}`, {
                stdio: 'pipe',
                timeout: 60000,
                env: env
            });
        }, 3, 2000, false);
        
        process.chdir(originalCwd);
        fs.rmSync(tempDir, { recursive: true, force: true });
        
        return true;
    } catch (error) {
        process.chdir(originalCwd);
        if (fs.existsSync(tempDir)) {
            fs.rmSync(tempDir, { recursive: true, force: true });
        }
        // If function doesn't exist, that's okay - it's already deleted
        if (error.message && error.message.includes('not found')) {
            return true;
        }
        throw error;
    }
}

// CRITICAL: Edge functions migration NEVER touches target secrets.
// We do not run "supabase secrets set". We pass minimal env to deploy so .env.local
// and other secrets are never sent to the CLI (which could otherwise push them to the project).

// Build minimal env for "supabase functions deploy" so no secrets from .env.local are passed.
// Only auth and safe system vars are included; target project secrets are never modified.
function getMinimalDeployEnv(accessToken) {
    const safe = {};
    const copy = ['PATH', 'HOME', 'USER', 'LANG', 'LC_ALL', 'TERM', 'SHELL', 'NODE_ENV', 'TMPDIR', 'TEMP', 'TMP'];
    copy.forEach(k => {
        if (process.env[k] !== undefined) safe[k] = process.env[k];
    });
    if (accessToken) safe.SUPABASE_ACCESS_TOKEN = accessToken;
    return safe;
}

// Remove any .env or .env.* files under dir so Supabase CLI never pushes them to target project.
function removeEnvFilesFromDeployDir(dir) {
    if (!fs.existsSync(dir)) return;
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const e of entries) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) {
            removeEnvFilesFromDeployDir(full);
        } else if (e.name === '.env' || (e.name.startsWith('.env.') && e.name.length > 4)) {
            try {
                fs.unlinkSync(full);
                logInfo(`    Removed ${path.relative(dir, full)} from deploy dir (to avoid touching target secrets)`);
            } catch (err) {
                logWarning(`    Could not remove ${full}: ${err.message}`);
            }
        }
    }
}

// Deploy edge function using Supabase CLI (--use-api / --use-docker with sticky strategy).
// Non-429 failures are not retried here; they go to the retry list.
async function deployEdgeFunction(
    functionName,
    functionDir,
    targetRef,
    dbPassword,
    sourceRef = null,
    sourceDbPassword = null,
    targetAccessToken = null,
    deployStrategyContext
) {
    try {
        if (!deployStrategyContext) {
            throw new Error('deployStrategyContext is required');
        }
        logInfo(`    Deploying function: ${functionName}...`);
        
        // Check if function directory exists
        if (!fs.existsSync(functionDir)) {
            throw new Error(`Function directory not found: ${functionDir}`);
        }
        
        normalizeFunctionLayout(functionDir, path.dirname(functionDir));

        // Check if function has index file
        const hasIndex = fs.existsSync(path.join(functionDir, 'index.ts')) ||
                        fs.existsSync(path.join(functionDir, 'index.js')) ||
                        fs.existsSync(path.join(functionDir, 'deno.json'));
        
        if (!hasIndex) {
            logWarning(`    ⚠ Function directory exists but no index file found, skipping...`);
            return false;
        }
        
        // Change to function directory parent (functions need to be in supabase/functions structure)
        const functionsParentDir = path.dirname(functionDir);
        const originalCwd = process.cwd();
        
        // Create supabase/functions structure if needed
        const supabaseDir = path.join(functionsParentDir, 'supabase', 'functions');
        if (!fs.existsSync(supabaseDir)) {
            fs.mkdirSync(supabaseDir, { recursive: true });
        }
        
        // Create config.toml for linking
        const supabaseConfigDir = path.join(functionsParentDir, 'supabase');
        const configTomlPath = path.join(supabaseConfigDir, 'config.toml');
        if (!fs.existsSync(configTomlPath)) {
            fs.writeFileSync(configTomlPath, `project_id = "${targetRef}"\n`);
        }
        
        // Copy function to supabase/functions structure
        const tempFunctionPath = path.join(supabaseDir, functionName);
        if (fs.existsSync(tempFunctionPath)) {
            fs.rmSync(tempFunctionPath, { recursive: true, force: true });
        }
        fs.cpSync(functionDir, tempFunctionPath, { recursive: true });

        // Copy shared files to deployment directory
        // CRITICAL: Shared files must be in supabase/functions/_shared/ for deployment to work
        const sharedDestDir = path.join(supabaseDir, '_shared');
        
        // Check if function code references _shared files
        const functionIndexPath = path.join(tempFunctionPath, 'index.ts');
        const functionIndexJsPath = path.join(tempFunctionPath, 'index.js');
        let functionCode = '';
        if (fs.existsSync(functionIndexPath)) {
            functionCode = fs.readFileSync(functionIndexPath, 'utf8');
        } else if (fs.existsSync(functionIndexJsPath)) {
            functionCode = fs.readFileSync(functionIndexJsPath, 'utf8');
        }
        const functionNeedsSharedFiles = hasSharedFileImports(functionCode);
        
        // Use collectSharedFiles to find all shared files
        let sharedFilesResult = collectSharedFiles(functionsParentDir, [functionDir]);
        
        if (sharedFilesResult.success && sharedFilesResult.files.length > 0) {
            // Copy shared files from global directory to deployment directory
            logInfo(`    Copying ${sharedFilesResult.files.length} shared file(s) to deployment directory...`);
            if (!fs.existsSync(sharedDestDir)) {
                fs.mkdirSync(sharedDestDir, { recursive: true });
            }
            
            // Use mergeDirectories to copy all files recursively
            mergeDirectories(sharedFilesResult.globalDir, sharedDestDir);
            
            // Verify files were copied
            const copiedFiles = fs.existsSync(sharedDestDir) 
                ? fs.readdirSync(sharedDestDir).filter(f => {
                    const filePath = path.join(sharedDestDir, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                })
                : [];
            
            if (copiedFiles.length > 0) {
                logInfo(`    ✓ Successfully copied ${copiedFiles.length} shared file(s): ${copiedFiles.join(', ')}`);
            } else {
                logError(`    ✗ Failed to copy shared files - destination directory is empty`);
                if (functionNeedsSharedFiles) {
                    throw new Error(`Function ${functionName} requires shared files but they could not be copied to deployment directory`);
                }
            }
        } else if (functionNeedsSharedFiles) {
            // Function needs shared files but none were found - try one more aggressive collection
            logWarning(`    ⚠ Function ${functionName} references _shared files but initial collection found none.`);
            logInfo(`    Attempting aggressive shared file collection...`);
            
            // Try collecting from ALL downloaded functions in the functions directory
            const aggressiveFunctionDirs = [functionDir];
            
            // Check ALL functions in the parent directory (all downloaded functions)
            if (fs.existsSync(functionsParentDir)) {
                const parentEntries = fs.readdirSync(functionsParentDir, { withFileTypes: true });
                for (const entry of parentEntries) {
                    if (entry.isDirectory() && entry.name !== functionName && entry.name !== '_shared' && !entry.name.startsWith('supabase')) {
                        const otherFunctionDir = path.join(functionsParentDir, entry.name);
                        // Verify it's actually a function directory (has index.ts or index.js)
                        if (fs.existsSync(path.join(otherFunctionDir, 'index.ts')) || 
                            fs.existsSync(path.join(otherFunctionDir, 'index.js'))) {
                            aggressiveFunctionDirs.push(otherFunctionDir);
                        }
                    }
                }
            }
            
            logInfo(`    Checking ${aggressiveFunctionDirs.length} function directory(ies) for shared files...`);
            const aggressiveSharedResult = collectSharedFiles(functionsParentDir, aggressiveFunctionDirs);
            
            if (aggressiveSharedResult.success && aggressiveSharedResult.files.length > 0) {
                logInfo(`    ✓ Found ${aggressiveSharedResult.files.length} shared file(s) on second attempt: ${aggressiveSharedResult.files.join(', ')}`);
                logInfo(`    Shared files location: ${aggressiveSharedResult.globalDir}`);
                
                // Retry the copy
                if (!fs.existsSync(sharedDestDir)) {
                    fs.mkdirSync(sharedDestDir, { recursive: true });
                }
                
                // Copy from the global shared directory
                mergeDirectories(aggressiveSharedResult.globalDir, sharedDestDir);
                
                // Also check if shared files are directly in functionsParentDir/_shared
                const directSharedDir = path.join(functionsParentDir, '_shared');
                if (fs.existsSync(directSharedDir) && fs.existsSync(aggressiveSharedResult.globalDir)) {
                    // They should be the same, but copy from direct location too just in case
                    mergeDirectories(directSharedDir, sharedDestDir);
                }
                
                // Verify again
                const retryCopiedFiles = fs.existsSync(sharedDestDir) 
                    ? fs.readdirSync(sharedDestDir).filter(f => {
                        const filePath = path.join(sharedDestDir, f);
                        try {
                            return fs.statSync(filePath).isFile();
                        } catch {
                            return false;
                        }
                    })
                    : [];
                
                if (retryCopiedFiles.length > 0) {
                    logInfo(`    ✓ Successfully copied ${retryCopiedFiles.length} shared file(s) on retry: ${retryCopiedFiles.join(', ')}`);
                    // Update sharedFilesResult for later use
                    sharedFilesResult.success = true;
                    sharedFilesResult.files = retryCopiedFiles;
                    sharedFilesResult.globalDir = aggressiveSharedResult.globalDir;
                } else {
                    // Still failed after retry - check if files exist in source
                    logError(`    ✗ CRITICAL: Shared files found but could not be copied to deployment directory!`);
                    logError(`    Source location: ${aggressiveSharedResult.globalDir}`);
                    logError(`    Destination location: ${sharedDestDir}`);
                    logError(`    Files found: ${aggressiveSharedResult.files.join(', ')}`);
                    
                    // Try one more direct copy
                    if (fs.existsSync(aggressiveSharedResult.globalDir)) {
                        const sourceFiles = fs.readdirSync(aggressiveSharedResult.globalDir);
                        logInfo(`    Attempting direct file copy...`);
                        for (const file of sourceFiles) {
                            const srcPath = path.join(aggressiveSharedResult.globalDir, file);
                            const destPath = path.join(sharedDestDir, file);
                            try {
                                if (fs.statSync(srcPath).isFile()) {
                                    fs.copyFileSync(srcPath, destPath);
                                    logInfo(`      ✓ Copied: ${file}`);
                                }
                            } catch (err) {
                                logError(`      ✗ Failed to copy ${file}: ${err.message}`);
                            }
                        }
                        
                        // Final check
                        const finalCheck = fs.existsSync(sharedDestDir) 
                            ? fs.readdirSync(sharedDestDir).filter(f => {
                                const filePath = path.join(sharedDestDir, f);
                                try {
                                    return fs.statSync(filePath).isFile();
                                } catch {
                                    return false;
                                }
                            })
                            : [];
                        
                        if (finalCheck.length > 0) {
                            logInfo(`    ✓ Final copy successful: ${finalCheck.length} file(s)`);
                            sharedFilesResult.success = true;
                            sharedFilesResult.files = finalCheck;
                        } else {
                            throw new Error(`Function ${functionName} requires shared files but they could not be copied`);
                        }
                    } else {
                        throw new Error(`Function ${functionName} requires shared files but none were found`);
                    }
                }
            } else {
                // Still no shared files found - try explicit download as last resort
                logWarning(`    ⚠ Shared files still not found after aggressive collection`);
                logInfo(`    Attempting explicit shared files download from source...`);
                
                // Try to get source project ref from the function context
                // We need to extract it from the calling context or pass it as parameter
                // For now, try to download shared files explicitly
                try {
                    // Get source ref from environment or context
                    // This is a workaround - we'll try to download shared files
                    logInfo(`    Re-downloading function ${functionName} to capture shared files...`);
                    
                    // Create a temp download to get shared files
                    const tempDownloadDir = fs.mkdtempSync(path.join(os.tmpdir(), `shared-emergency-${functionName}-`));
                    try {
                        // We need sourceRef and dbPassword - these should be available in the calling context
                        // For now, we'll try a different approach: check if we can find shared files
                        // by looking at what was actually downloaded
                        
                        // Check if shared files exist in the function's download location but weren't collected
                        const functionSharedDir = path.join(functionDir, '_shared');
                        if (fs.existsSync(functionSharedDir)) {
                            logInfo(`    Found shared files in function directory: ${functionSharedDir}`);
                            if (!fs.existsSync(sharedDestDir)) {
                                fs.mkdirSync(sharedDestDir, { recursive: true });
                            }
                            mergeDirectories(functionSharedDir, sharedDestDir);
                            
                            const emergencyFiles = fs.existsSync(sharedDestDir) 
                                ? fs.readdirSync(sharedDestDir).filter(f => {
                                    const filePath = path.join(sharedDestDir, f);
                                    try {
                                        return fs.statSync(filePath).isFile();
                                    } catch {
                                        return false;
                                    }
                                })
                                : [];
                            
                            if (emergencyFiles.length > 0) {
                                logInfo(`    ✓ Emergency copy successful: ${emergencyFiles.length} file(s): ${emergencyFiles.join(', ')}`);
                                sharedFilesResult.success = true;
                                sharedFilesResult.files = emergencyFiles;
                            }
                        }
                    } finally {
                        if (fs.existsSync(tempDownloadDir)) {
                            fs.rmSync(tempDownloadDir, { recursive: true, force: true });
                        }
                    }
                } catch (emergencyError) {
                    logWarning(`    Emergency download attempt failed: ${emergencyError.message}`);
                }
                
                // Final check - if still missing and we have sourceRef, try explicit download
                if ((!sharedFilesResult.success || sharedFilesResult.files.length === 0) && sourceRef && sourceDbPassword) {
                    logWarning(`    ⚠ Shared files still missing - attempting explicit download from source...`);
                    const explicitSuccess = await downloadSharedFilesExplicitly(
                        sourceRef,
                        functionsParentDir,
                        sourceDbPassword,
                        functionName,
                        false
                    );
                    
                    if (explicitSuccess) {
                        // Re-collect after explicit download
                        const finalSharedResult = collectSharedFiles(functionsParentDir, [functionDir]);
                        if (finalSharedResult.success && finalSharedResult.files.length > 0) {
                            logInfo(`    ✓ Found ${finalSharedResult.files.length} shared file(s) after explicit download: ${finalSharedResult.files.join(', ')}`);
                            sharedFilesResult = finalSharedResult;
                        }
                    }
                }
                
                // Final check after all attempts
                if (!sharedFilesResult.success || sharedFilesResult.files.length === 0) {
                    logError(`    ✗ CRITICAL: Function ${functionName} references _shared files but none were found!`);
                    logError(`    Deployment will fail. Please ensure shared files are available.`);
                    logError(`    Expected locations:`);
                    logError(`      1. ${path.join(functionsParentDir, '_shared')}`);
                    logError(`      2. ${path.join(PROJECT_ROOT, 'supabase', 'functions', '_shared')}`);
                    logError(`      3. ${path.join(functionDir, '_shared')}`);
                    logError(`    Workaround options:`);
                    logError(`      1. Download a function that uses shared files first (they will be collected automatically)`);
                    logError(`      2. Manually copy shared files from source project to: ${path.join(functionsParentDir, '_shared')}`);
                    logError(`      3. Use: supabase functions download <function-with-shared-files> --project-ref <source-ref>`);
                    throw new Error(`Function ${functionName} requires shared files but none were found`);
                }
            }
        } else {
            logInfo(`    ℹ No shared files needed for this function`);
        }
        
        // Change to supabase directory and link
        process.chdir(supabaseConfigDir);
        
        // CRITICAL: Remove any .env files so Supabase CLI never pushes them to target (never touch target secrets)
        removeEnvFilesFromDeployDir(supabaseConfigDir);
        
        try {
            // Link to target project (in supabase directory) - optional, might already be linked
            logInfo(`    Linking to target project...`);
            if (!linkProject(targetRef, dbPassword, targetAccessToken)) {
                logWarning(`    ⚠ Could not link to target project ${targetRef} - continuing anyway (project might already be linked)`);
            }
            
            // Final verification: shared files must be at functions/_shared/ relative to supabaseConfigDir
            const deploymentSharedPath = path.join(supabaseConfigDir, 'functions', '_shared');
            if (sharedFilesResult.success && sharedFilesResult.files.length > 0) {
                // Ensure shared files are at deployment path (they should already be there from copy above)
                if (!fs.existsSync(deploymentSharedPath)) {
                    fs.mkdirSync(deploymentSharedPath, { recursive: true });
                    mergeDirectories(sharedDestDir, deploymentSharedPath);
                }
                
                const deploymentFiles = fs.existsSync(deploymentSharedPath)
                    ? fs.readdirSync(deploymentSharedPath).filter(f => {
                        const filePath = path.join(deploymentSharedPath, f);
                        try {
                            return fs.statSync(filePath).isFile();
                        } catch {
                            return false;
                        }
                    })
                    : [];
                
                if (deploymentFiles.length > 0) {
                    logInfo(`    ✓ Deployment shared files verified: ${deploymentFiles.length} file(s) at functions/_shared/`);
                } else {
                    logError(`    ✗ CRITICAL: Shared files missing at deployment path: ${deploymentSharedPath}`);
                    throw new Error(`Shared files not found at deployment path`);
                }
            }
            
            // Deploy (project is now linked): API bundle first, then Docker; sticky after first success.
            let deployOutput = '';
            let deployStderr = '';
            try {
                const deployEnv = getMinimalDeployEnv(targetAccessToken);
                const order = deployStrategyContext.getOrder();

                if (!deployStrategyContext.getSticky() && order.length > 1 && !deployStrategyContext.probeBannerLogged) {
                    logInfo(`    Deploy strategy: probing (--use-api, then --use-docker)...`);
                    deployStrategyContext.probeBannerLogged = true;
                }

                const result = await deployWithProbeAndSticky({
                    cwd: supabaseConfigDir,
                    env: deployEnv,
                    functionName,
                    context: deployStrategyContext,
                    onRateLimit: (delay, attempt, max) => {
                        logWarning(
                            `    ⚠ Rate limit hit (429), retrying in ${delay / 1000}s... (attempt ${attempt}/${max})`
                        );
                    }
                });

                deployOutput = result.stdout || '';
                deployStderr = result.stderr || '';

                if (result.recoveredAfterStickyFailure) {
                    logWarning(
                        `    Sticky deploy (${result.previousSticky}) failed; recovered with --${result.strategyUsed}`
                    );
                }
                if (result.probed && !deployStrategyContext.lockBannerLogged && order.length > 1) {
                    logSuccess(`    Deploy strategy locked: ${result.strategyUsed}`);
                    deployStrategyContext.lockBannerLogged = true;
                }

                if (deployOutput) {
                    logInfo(`    Deployment output: ${deployOutput.trim().substring(0, 200)}`);
                }
                if (deployStderr && !deployStderr.toLowerCase().includes('warning')) {
                    logWarning(`    Deployment warnings: ${deployStderr.trim().substring(0, 200)}`);
                }
            } catch (deployErr) {
                // Capture error details
                let deployError = '';
                if (deployErr.stderr) {
                    deployStderr = deployErr.stderr.toString();
                    deployError = deployStderr;
                } else if (deployErr.stdout) {
                    deployOutput = deployErr.stdout.toString();
                    deployError = deployOutput;
                } else {
                    deployError = deployErr.message || String(deployErr);
                }
                
                // Also capture stderr separately if available
                if (deployErr.stderr) {
                    deployStderr = deployErr.stderr.toString();
                }
                if (deployErr.stdout) {
                    deployOutput = deployErr.stdout.toString();
                }
                
                // Check for common issues and provide guidance
                const fullError = (deployError + ' ' + (deployStderr || '')).toLowerCase();
                
                // Check for incompatible dependencies FIRST (before logging generic error)
                if (fullError.includes('canvas.node') || fullError.includes('canvas@') || 
                    (fullError.includes('module not found') && fullError.includes('.node'))) {
                    // Throw special error that will be caught and handled (don't log generic error for incompatible deps)
                    const incompatibleError = new Error('INCOMPATIBLE_DEPENDENCIES');
                    incompatibleError.incompatible = true;
                    incompatibleError.reason = 'incompatible_dependencies';
                    incompatibleError.details = {
                        detected: fullError.includes('canvas') ? 'canvas' : 'native_module',
                        message: 'Function uses native Node.js modules not supported in Deno'
                    };
                    throw incompatibleError;
                }
                
                // Log detailed error (only for actual failures, not incompatible dependencies)
                logError(`    Deployment failed for ${functionName}:`);
                if (deployError) {
                    logError(`    Error: ${deployError.substring(0, 500)}`);
                }
                if (deployStderr && deployStderr !== deployError) {
                    logError(`    Stderr: ${deployStderr.substring(0, 500)}`);
                }
                
                if (fullError.includes('timeout') || fullError.includes('etimedout')) {
                    logError(`    ⚠ Timeout during deployment - function may be too large or network issue`);
                    logError(`    Suggestion: Check network connection or reduce function size`);
                } else if (fullError.includes('enoent') || fullError.includes('not found')) {
                    logError(`    ⚠ File or directory not found - check function structure`);
                    logError(`    Suggestion: Verify function files exist in ${tempFunctionPath}`);
                } else if (fullError.includes('permission') || fullError.includes('unauthorized') || fullError.includes('401') || fullError.includes('403')) {
                    logError(`    ⚠ Permission issue - verify Supabase CLI authentication`);
                    logError(`    Suggestion: Run 'supabase login' and verify access token`);
                } else if (fullError.includes('shared') || fullError.includes('_shared')) {
                    logError(`    ⚠ Shared files issue - verify _shared directory structure`);
                    logError(`    Suggestion: Check that shared files are in functions/_shared/`);
                } else if (fullError.includes('docker') || fullError.includes('container')) {
                    logError(`    ⚠ Docker issue - verify Docker is running`);
                    logError(`    Suggestion: Start Docker Desktop or Docker daemon`);
                } else if (fullError.includes('syntax') || fullError.includes('parse')) {
                    logError(`    ⚠ Syntax error in function code`);
                    logError(`    Suggestion: Check function code for syntax errors`);
                }
                
                throw deployErr;
            }
            
            process.chdir(originalCwd);
            
            // Cleanup temp structure
            fs.rmSync(supabaseConfigDir, { recursive: true, force: true });
            
            logSuccess(`    ✓ Deployed function: ${functionName}`);
            return true;
        } catch (e) {
            process.chdir(originalCwd);
            // Only cleanup if we created it
            if (fs.existsSync(supabaseConfigDir)) {
                fs.rmSync(supabaseConfigDir, { recursive: true, force: true });
            }
            throw e;
        }
    } catch (error) {
        // Check if this is an incompatible dependency error
        if (error.incompatible === true || error.message === 'INCOMPATIBLE_DEPENDENCIES') {
            logWarning(`    ⚠ Incompatible dependency detected: This function uses native Node.js modules that aren't supported in Deno/Supabase Edge Functions`);
            logError(`    The function cannot be deployed due to dependencies requiring native bindings (e.g., canvas, sharp, etc.)`);
            logError(`    Common incompatible packages: canvas, sharp, bcrypt, node-gyp modules`);
            logError(`    Recommendation: Refactor the function to use Deno-compatible alternatives`);
            logWarning(`    This function will be skipped and added to the incompatible functions list`);
            return { success: false, incompatible: true, reason: 'incompatible_dependencies' };
        }
        
        // Check error message for canvas/native module issues (fallback detection)
        const errorMsg = (error.message || '').toLowerCase();
        const errorStderr = (error.stderr || '').toLowerCase();
        const fullErrorMsg = errorMsg + ' ' + errorStderr;
        if (fullErrorMsg.includes('canvas') || fullErrorMsg.includes('canvas.node') || 
            (fullErrorMsg.includes('module not found') && fullErrorMsg.includes('.node'))) {
            logWarning(`    ⚠ Incompatible dependency detected: This function uses native Node.js modules that aren't supported in Deno/Supabase Edge Functions`);
            logError(`    The function cannot be deployed due to dependencies requiring native bindings (e.g., canvas, sharp, etc.)`);
            logError(`    Common incompatible packages: canvas, sharp, bcrypt, node-gyp modules`);
            logError(`    Recommendation: Refactor the function to use Deno-compatible alternatives`);
            logWarning(`    This function will be skipped and added to the incompatible functions list`);
            return { success: false, incompatible: true, reason: 'incompatible_dependencies' };
        }
        
        // No retry - just return false and add to retry list
        logError(`    ✗ Failed to deploy function ${functionName}: ${error.message}`);
        logInfo(`    This function will be added to the retry list for manual retry`);
        return false;
    }
}

// Helper function to get environment name from project ref (for retry script command)
function getEnvNameFromRef(projectRef) {
    // Try to match project ref to known environments
    const envVars = ['SUPABASE_PROD_PROJECT_REF', 'SUPABASE_TEST_PROJECT_REF', 'SUPABASE_DEV_PROJECT_REF', 'SUPABASE_BACKUP_PROJECT_REF'];
    for (const envVar of envVars) {
        if (process.env[envVar] === projectRef) {
            if (envVar.includes('PROD')) return 'prod';
            if (envVar.includes('TEST')) return 'test';
            if (envVar.includes('DEV')) return 'dev';
            if (envVar.includes('BACKUP')) return 'backup';
        }
    }
    // Fallback: return the ref itself (user can correct it)
    return projectRef;
}

// Main migration function
async function migrateEdgeFunctions() {
    logSeparator();
    logInfo(`${colors.bright}Supabase Edge Functions Migration${colors.reset}`);
    logSeparator();
    logInfo(`Source: ${SOURCE_REF}`);
    logInfo(`Target: ${TARGET_REF}`);
    logInfo(`Migration Directory: ${MIGRATION_DIR}`);
    logSeparator();
    console.log('');

    // Ensure Docker is running (required for CLI download/deploy). On macOS, try to start Docker Desktop.
    logInfo('Step 0/4: Docker preflight (this can take up to ~90s if Docker is starting)…');
    await ensureDockerRunning();

    // Step 1: Get source edge functions
    logStep(1, 4, 'Fetching source edge functions...');
    let sourceFunctions = [];
    try {
        sourceFunctions = await getEdgeFunctions(SOURCE_REF, sourceConfig.accessToken, 'Source', sourceConfig.dbPassword);
        if (sourceFunctions.length === 0) {
            logWarning('No edge functions found in source project (or permission denied)');
            logInfo('Continuing migration without edge functions...');
        }
    } catch (error) {
        // Only fail for non-403 errors
        if (error.message && error.message.includes('403')) {
            logWarning('Permission denied for source edge functions - continuing migration without edge functions');
            sourceFunctions = [];
        } else {
            logError('Failed to fetch source edge functions - cannot continue migration');
            logError(`  Error: ${error.message || JSON.stringify(error)}`);
            throw error;
        }
    }

    if (uniqueFilterSet) {
        logInfo(`Function filter enabled (${requestedFilterNames.length} requested).`);
        sourceFunctions = sourceFunctions.filter((func) => {
            const name = func?.name;
            if (!name) return false;
            if (uniqueFilterSet.has(name)) {
                filterNamesFound.add(name);
                return true;
            }
            return false;
        });

        const missingNames = requestedFilterNames.filter((name) => !filterNamesFound.has(name));
        if (missingNames.length > 0) {
            missingFilterFunctions.push(...missingNames);
            logWarning(`Requested ${missingNames.length} function(s) not present in source: ${missingNames.join(', ')}`);
            if (!allowPartialFilter) {
                logWarning('To ignore missing functions, pass --allow-missing (used by retry script).');
            }
        }

        logInfo(`Filter result: ${sourceFunctions.length} function(s) available for migration.`);
        if (sourceFunctions.length === 0) {
            logWarning('No source functions remain after filtering; exiting early.');
        }
    }
    
    console.log('');
    
    // Step 2: Get target edge functions
    logStep(2, 4, 'Fetching target edge functions...');
    let targetFunctions = [];
    try {
        targetFunctions = await getEdgeFunctions(TARGET_REF, targetConfig.accessToken, 'Target', targetConfig.dbPassword);
        if (targetFunctions.length === 0) {
            logWarning('No edge functions found in target project (or permission denied)');
        }
    } catch (error) {
        // Only fail for non-403 errors
        if (error.message && error.message.includes('403')) {
            logWarning('Permission denied for target edge functions - continuing migration');
            targetFunctions = [];
        } else {
            logError('Failed to fetch target edge functions - cannot continue migration');
            logError(`  Error: ${error.message || JSON.stringify(error)}`);
            throw error;
        }
    }
    
    const targetFunctionMap = new Map(targetFunctions.map(f => [f.name, f]));
    
    // Step 2.5: If retryMissing mode, filter to only missing functions
    if (retryMissingMode) {
        logSeparator();
        logInfo(`${colors.bright}RETRY MISSING MODE: Finding functions missing in target${colors.reset}`);
        logSeparator();
        
        const targetFunctionNames = new Set(targetFunctions.map(f => f.name));
        const missingFunctions = sourceFunctions.filter(f => !targetFunctionNames.has(f.name));
        
        if (missingFunctions.length === 0) {
            logSuccess('All source functions are present in target. Nothing to migrate.');
            console.log('');
            return {
                success: true,
                attempted: [],
                migrated: [],
                failed: [],
                skipped: [],
                skippedShared: [],
                incompatible: [],
                identical: []
            };
        }
        
        logInfo(`Found ${missingFunctions.length} function(s) missing in target:`);
        missingFunctions.forEach((func, index) => {
            logInfo(`  ${index + 1}. ${func.name}`);
        });
        console.log('');
        
        // Set filter to only include missing functions
        const missingFunctionNames = missingFunctions.map(f => f.name);
        filterList = missingFunctionNames;
        uniqueFilterSet = new Set(missingFunctionNames);
        requestedFilterNames = Array.from(uniqueFilterSet);
        filterNamesFound.clear();
        missingFilterFunctions.length = 0;
        
        // Filter source functions to only missing ones
        sourceFunctions = missingFunctions;
        logInfo(`Filtered to ${sourceFunctions.length} missing function(s) for migration.`);
        console.log('');
    }
    
    // Step 2.5: If replace mode, delete all target functions first
    if (replaceMode && targetFunctions.length > 0) {
        logSeparator();
        logWarning(`${colors.bright}REPLACE MODE: Deleting all target edge functions${colors.reset}`);
        logSeparator();
        logWarning(`  This will delete ${targetFunctions.length} function(s) from target before redeploying from source.`);
        console.log('');
        
        const deletedFunctions = [];
        const deleteFailedFunctions = [];
        
        for (const targetFunction of targetFunctions) {
            const functionName = targetFunction.name;
            if (!functionName) continue;
            
            logInfo(`Deleting function: ${functionName}...`);
            try {
                if (await deleteEdgeFunction(functionName, TARGET_REF, targetConfig.dbPassword, targetConfig.accessToken)) {
                    logSuccess(`  ✓ Deleted function: ${functionName}`);
                    deletedFunctions.push(functionName);
                } else {
                    logWarning(`  ⚠ Failed to delete function: ${functionName}`);
                    deleteFailedFunctions.push(functionName);
                }
            } catch (error) {
                logWarning(`  ⚠ Error deleting function ${functionName}: ${error.message}`);
                deleteFailedFunctions.push(functionName);
            }
        }
        
        console.log('');
        if (deletedFunctions.length > 0) {
            logSuccess(`Deleted ${deletedFunctions.length} function(s) from target.`);
        }
        if (deleteFailedFunctions.length > 0) {
            logWarning(`${deleteFailedFunctions.length} function(s) could not be deleted (may not exist): ${deleteFailedFunctions.join(', ')}`);
        }
        console.log('');
        
        // Clear target function map since we're replacing everything
        targetFunctionMap.clear();
    }
    
    // Step 3: Smart migration - compare functions
    logSeparator();
    logInfo(`${colors.bright}Starting Edge Functions Migration${colors.reset}`);
    logSeparator();
    if (replaceMode) {
        logInfo(`${colors.yellow}Replace mode: All source functions will be deployed (target was cleared)${colors.reset}`);
    }
    console.log('');
    
    let migratedCount = 0;
    let skippedCount = 0;
    let failedCount = 0;
    let edgeDeployContext = null;

    // Create functions directory for downloads
    const functionsDir = path.join(MIGRATION_DIR, 'edge_functions');
    if (!fs.existsSync(functionsDir)) {
        fs.mkdirSync(functionsDir, { recursive: true });
    }
    
    // Step 4: Plan which functions to deploy from source → target
    logInfo(`Edge functions plan:`);
    logInfo(`  Source: ${sourceFunctions.length} function(s)`);
    logInfo(`  Target: ${targetFunctions.length} function(s)${replaceMode ? ' (cleared in replace mode)' : ''}`);
    const compareNote = compareWithTarget
        ? 'compare-with-target (download target + byte diff before deploy)'
        : 'direct deploy from source (no target code compare — faster)';
    logInfo(
        `  Mode: ${replaceMode ? 'REPLACE (all functions will be redeployed)' : incrementalMode ? 'incremental (skip identical API metadata)' : 'standard'} | ${compareNote}`
    );
    console.log('');
    
    // Determine which functions need migration
    const functionsToMigrate = [];
    const deployState = loadDeployState(); // last-deployed per (app, target env)
    const skippedByDeployState = [];

    for (const sourceFunction of sourceFunctions) {
        const functionName = sourceFunction.name;
        const existingFunction = replaceMode ? null : targetFunctionMap.get(functionName);
        
        if (!functionName) {
            failedFunctions.push('(unnamed)');
            continue;
        }

        // Skip if we already deployed this version for this (app, target env) and source hasn't changed.
        // Only when the function still exists on target — otherwise redeploy (target may have been wiped or drifted).
        const lastDeployedAt = deployState[functionName];
        if (lastDeployedAt != null && !replaceMode && existingFunction) {
            const stateTs = normalizeTimestamp(lastDeployedAt);
            const sourceUpdated = normalizeTimestamp(sourceFunction.updated_at ?? sourceFunction.updatedAt);
            if (sourceUpdated !== null && stateTs !== null && sourceUpdated <= stateTs) {
                skippedByDeployState.push(functionName);
                skippedFunctions.push(functionName);
                continue;
            }
        }
        
        if (existingFunction && !replaceMode) {
            const sourceVersion = typeof sourceFunction.version === 'number' ? sourceFunction.version : Number(sourceFunction.version);
            const targetVersion = typeof existingFunction.version === 'number' ? existingFunction.version : Number(existingFunction.version);
            const versionMatches = Number.isFinite(sourceVersion) && Number.isFinite(targetVersion) && sourceVersion === targetVersion;
            
            const sourceUpdated = normalizeTimestamp(sourceFunction.updated_at ?? sourceFunction.updatedAt);
            const targetUpdated = normalizeTimestamp(existingFunction.updated_at ?? existingFunction.updatedAt);
            const updatedMatches = sourceUpdated !== null && targetUpdated !== null && sourceUpdated === targetUpdated;
            
            const identical = versionMatches || updatedMatches;
            
            if (incrementalMode && identical) {
                identicalFunctions.push(functionName);
                skippedFunctions.push(functionName);
                continue;
            }
            
            functionsToMigrate.push({
                function: sourceFunction,
                isNew: false,
                existing: existingFunction,
                versionMatches,
                updatedMatches
            });
        } else {
            // New function (or replace mode - treat all as new)
            functionsToMigrate.push({ function: sourceFunction, isNew: true });
        }
    }
    
    if (incrementalMode && identicalFunctions.length > 0) {
        logSuccess(`Identical functions skipped (incremental mode): ${identicalFunctions.length}`);
        const previewCount = Math.min(identicalFunctions.length, 10);
        const previewList = identicalFunctions.slice(0, previewCount).join(', ');
        logInfo(`  Skipped: ${previewList}${identicalFunctions.length > previewCount ? ', …' : ''}`);
        console.log('');
    }
    if (skippedByDeployState.length > 0) {
        logSuccess(`Skipped (already deployed for this env, source unchanged): ${skippedByDeployState.length}`);
        const previewCount = Math.min(skippedByDeployState.length, 10);
        const previewList = skippedByDeployState.slice(0, previewCount).join(', ');
        logInfo(`  Skipped: ${previewList}${skippedByDeployState.length > previewCount ? ', …' : ''}`);
        console.log('');
    }

    // Check if all functions are already in target (or skipped due to identical versions)
    if (functionsToMigrate.length === 0) {
        if (sourceFunctions.length === 0) {
            logWarning('No edge functions found in source project.');
        } else {
            logSuccess(`✓ No edge function updates required for target.`);
            if (skippedFunctions.length === 0) {
                skippedFunctions.push(...sourceFunctions.map((fn) => fn?.name).filter(Boolean));
            }
        }
    } else {
        logInfo(`Functions to migrate: ${functionsToMigrate.length}`);
        logInfo(`  - New functions: ${functionsToMigrate.filter(f => f.isNew).length}`);
        logInfo(`  - Existing functions (will update): ${functionsToMigrate.filter(f => !f.isNew).length}`);
        console.log('');

        edgeDeployContext = createDeployStrategyContext();
        logInfo(
            `Edge function deploy strategy order: ${edgeDeployContext.getOrder().join(' → ')} (locks after first successful deploy)`
        );
        console.log('');
        
        // Pre-deployment: Collect all shared files from all functions before deploying
        // This ensures shared dependencies are available for all functions
        logInfo('Collecting shared files from all functions...');
        
        // Collect function directories
        const functionDirsToCheck = [];
        for (const { function: sourceFunction } of functionsToMigrate) {
            const functionName = sourceFunction.name;
            if (!functionName) continue;
            
            const functionDir = path.join(functionsDir, functionName);
            if (fs.existsSync(functionDir)) {
                functionDirsToCheck.push(functionDir);
            }
        }
        
        // Use the new collectSharedFiles helper
        const sharedFilesResult = collectSharedFiles(functionsDir, functionDirsToCheck);
        
        if (sharedFilesResult.success && sharedFilesResult.files.length > 0) {
            logInfo(`  ✓ Collected ${sharedFilesResult.files.length} shared file(s) from ${sharedFilesResult.locations.length} location(s): ${sharedFilesResult.files.join(', ')}`);
            if (sharedFilesResult.locations.length > 0) {
                logInfo(`  Sources: ${sharedFilesResult.locations.map(loc => path.relative(functionsDir, loc)).join(', ')}`);
            }
        } else {
            logInfo(`  ℹ No shared files found (functions may not have shared dependencies)`);
        }
        console.log('');
        
        // Process each function
        for (let i = 0; i < functionsToMigrate.length; i++) {
            const { function: sourceFunction, isNew, existing, versionMatches, updatedMatches } = functionsToMigrate[i];
            const functionName = sourceFunction.name;
            const indexLabel = `${i + 1}/${functionsToMigrate.length}`;
            
            if (!functionName) {
                logError(`Function ${indexLabel} has no name: ${JSON.stringify(sourceFunction)}`);
                failedFunctions.push('(unknown)');
                continue;
            }
            
            logInfo(`${colors.bright}Function ${indexLabel}: ${functionName}${colors.reset}`);
            
            if (isNew) {
                logInfo(`  Status: NEW - will create in target`);
            } else {
                logInfo(
                    `  Status: EXISTS - will ${compareWithTarget ? 'compare with target then deploy if different' : 'deploy from source (overwrite target)'}` 
                );
                logInfo(`  Source ID: ${sourceFunction.id || 'N/A'}`);
                logInfo(`  Target ID: ${existing?.id || 'N/A'}`);
            }
            
            // Download function from source (shared imports are bundled in deployEdgeFunction via _shared)
            const functionDir = path.join(functionsDir, functionName);
            logInfo(`  Downloading edge function from source...`);
            
            const downloadSuccess = await downloadEdgeFunction(
                functionName,
                SOURCE_REF,
                functionsDir,
                sourceConfig.dbPassword,
                false,
                sourceConfig.accessToken
            );
            
            if (!downloadSuccess) {
                logWarning(`  ⚠ Could not download function code - skipping deployment`);
                logWarning(`    Function may need to be deployed manually from codebase`);
                failedFunctions.push(functionName);
                console.log('');
                continue;
            }
            
            // Check if function directory was created
            if (!fs.existsSync(functionDir)) {
                logWarning(`  ⚠ Function directory not found after download - skipping`);
                failedFunctions.push(functionName);
                console.log('');
                continue;
            }
            
            // Ensure shared files are normalized to functionsDir/_shared after download
            // This is important for deployment to find shared files
            normalizeFunctionLayout(functionDir, functionsDir);
            
            // Re-collect shared files after each download to ensure they're captured
            // This is critical because shared files might be downloaded with any function
            const updatedFunctionDirs = [];
            for (let j = 0; j <= i; j++) {
                const { function: f } = functionsToMigrate[j];
                if (f?.name) {
                    const fd = path.join(functionsDir, f.name);
                    if (fs.existsSync(fd)) {
                        updatedFunctionDirs.push(fd);
                    }
                }
            }
            const updatedSharedResult = collectSharedFiles(functionsDir, updatedFunctionDirs);
            if (updatedSharedResult.success && updatedSharedResult.files.length > 0) {
                logInfo(`  ✓ Updated shared files collection: ${updatedSharedResult.files.length} file(s) available (${updatedSharedResult.files.join(', ')})`);
            }
            
            // Check if downloaded function actually needs shared files (verify from downloaded code)
            const downloadedIndexPath = path.join(functionDir, 'index.ts');
            const downloadedIndexJsPath = path.join(functionDir, 'index.js');
            let downloadedFunctionCode = '';
            if (fs.existsSync(downloadedIndexPath)) {
                downloadedFunctionCode = fs.readFileSync(downloadedIndexPath, 'utf8');
            } else if (fs.existsSync(downloadedIndexJsPath)) {
                downloadedFunctionCode = fs.readFileSync(downloadedIndexJsPath, 'utf8');
            }
            if (hasSharedFileImports(downloadedFunctionCode)) {
                logInfo(`  ✓ Confirmed: imports from _shared (will bundle during deploy)`);
            }
            
            logSuccess(`  ✓ Downloaded function: ${functionName}`);
            
            // Optional: download target and byte-compare (slow); default is deploy source → target without compare
            if (!isNew && !replaceMode && compareWithTarget) {
                logInfo(`  Comparing with target function...`);
                
                // Download target function for comparison (quiet mode to reduce noise)
                const targetCompareDir = fs.mkdtempSync(path.join(os.tmpdir(), `edge-compare-${functionName}-`));
                try {
                    const targetDownloadSuccess = await downloadEdgeFunction(
                        functionName,
                        TARGET_REF,
                        targetCompareDir,
                        targetConfig.dbPassword,
                        true,
                        targetConfig.accessToken
                    );
                    
                    if (targetDownloadSuccess) {
                        const targetFunctionDir = path.join(targetCompareDir, functionName);
                        if (fs.existsSync(targetFunctionDir)) {
                            // Get file counts for logging
                            const sourceFiles = getAllCodeFiles(functionDir);
                            logInfo(`  Comparing ${sourceFiles.length} code files (byte-for-byte)...`);
                            
                            const areIdentical = compareFunctionDirectories(functionDir, targetFunctionDir);
                            
                            if (areIdentical) {
                                logInfo(`  ✓ All ${sourceFiles.length} files are identical - skipping deployment.`);
                                skippedFunctions.push(functionName);
                                console.log('');
                                // Cleanup
                                fs.rmSync(targetCompareDir, { recursive: true, force: true });
                                continue;
                            } else {
                                logInfo(`  ✗ Code differences detected - redeploying...`);
                            }
                        } else {
                            logInfo(`  Target function directory not found - will deploy`);
                        }
                    } else {
                        logInfo(`  Could not download target function for comparison - will deploy`);
                    }
                } catch (compareError) {
                    logInfo(`  Comparison failed (${compareError.message}) - will deploy to be safe`);
                } finally {
                    // Cleanup target comparison directory
                    if (fs.existsSync(targetCompareDir)) {
                        fs.rmSync(targetCompareDir, { recursive: true, force: true });
                    }
                }
            }
            
            // Deploy function to target (failures go to retry list)
            const deployResult = await deployEdgeFunction(
                functionName,
                functionDir,
                TARGET_REF,
                targetConfig.dbPassword,
                SOURCE_REF,
                sourceConfig.dbPassword,
                targetConfig.accessToken,
                edgeDeployContext
            );
            
            // Handle different return types (boolean or object)
            const deploySuccess = typeof deployResult === 'object' ? deployResult.success : deployResult;
            const isIncompatible = typeof deployResult === 'object' && deployResult.incompatible === true;
            
            if (deploySuccess) {
                migratedFunctions.push(functionName);
                updateLastDeployedTimestamp(functionName);
                logSuccess(`  ✓ Function ${isNew ? 'created' : 'updated'} successfully`);
            } else if (isIncompatible) {
                incompatibleFunctions.push(functionName);
                logWarning(`  ⚠ Function skipped due to incompatible dependencies (native Node.js modules)`);
                logWarning(`  This function cannot be deployed to Supabase Edge Functions`);
                logInfo(`  Consider refactoring to use Deno-compatible alternatives`);
            } else {
                failedFunctions.push(functionName);
                logError(`  ✗ Function deployment failed`);
                logInfo(`  This function will be added to the retry list for manual retry via retry_edge_functions.sh`);
            }
            
            console.log('');
        }
    }

    let prunedTargetOnlyNames = [];
    let pruneDeleteFailed = [];
    const sourceNameSet = new Set(sourceFunctions.map((f) => f?.name).filter(Boolean));
    const allowPruneTarget =
        pruneTargetMode && !uniqueFilterSet && !retryMissingMode && sourceNameSet.size > 0;

    if (allowPruneTarget) {
        logSeparator();
        logInfo(`${colors.bright}Pruning target-only edge functions (not in source)${colors.reset}`);
        logSeparator();

        let currentTargetList = [];
        try {
            currentTargetList = await getEdgeFunctions(
                TARGET_REF,
                targetConfig.accessToken,
                'Target',
                targetConfig.dbPassword
            );
        } catch (pruneFetchErr) {
            logWarning(`Could not list target functions for prune: ${pruneFetchErr.message || pruneFetchErr}`);
        }

        const extras = currentTargetList.filter((f) => f?.name && !sourceNameSet.has(f.name));
        if (extras.length === 0) {
            logSuccess('Target has no extra edge functions vs source (nothing to prune).');
        } else {
            logInfo(
                `Removing ${extras.length} function(s) on target only: ${extras.map((f) => f.name).join(', ')}`
            );
            for (const tf of extras) {
                const name = tf.name;
                try {
                    if (await deleteEdgeFunction(name, TARGET_REF, targetConfig.dbPassword, targetConfig.accessToken)) {
                        logSuccess(`  ✓ Pruned: ${name}`);
                        prunedTargetOnlyNames.push(name);
                    } else {
                        logError(`  ✗ Could not prune: ${name}`);
                        pruneDeleteFailed.push(name);
                    }
                } catch (prErr) {
                    logError(`  ✗ Prune error for ${name}: ${prErr.message || prErr}`);
                    pruneDeleteFailed.push(name);
                }
            }
        }
        console.log('');
    }

    const dedupe = (arr) => Array.from(new Set(arr.filter(Boolean)));
    const attemptedFunctionNames = functionsToMigrate.map(({ function: func }) => func?.name).filter(Boolean);
    const uniqueMigratedFunctions = dedupe(migratedFunctions);
    const uniqueFailedFunctions = dedupe([...failedFunctions, ...missingFilterFunctions]);
    const uniqueSkippedFunctions = dedupe(skippedFunctions);
    const uniqueSkippedSharedFunctions = dedupe(skippedSharedFunctions);
    const uniqueIncompatibleFunctions = dedupe(incompatibleFunctions);
    const uniquePruneFailed = dedupe(pruneDeleteFailed);

    migratedCount = uniqueMigratedFunctions.length;
    failedCount = uniqueFailedFunctions.length;
    skippedCount = uniqueSkippedFunctions.length;

    const summary = {
        timestamp: new Date().toISOString(),
        sourceRef: SOURCE_REF,
        targetRef: TARGET_REF,
        requested: uniqueFilterSet ? requestedFilterNames : null,
        allowMissing: allowPartialFilter,
        attempted: attemptedFunctionNames,
        migrated: uniqueMigratedFunctions,
        failed: uniqueFailedFunctions,
        skipped: uniqueSkippedFunctions,
        skippedShared: uniqueSkippedSharedFunctions,
        incompatible: uniqueIncompatibleFunctions,
        identical: dedupe(identicalFunctions),
        incrementalMode,
        compareWithTarget,
        missingInSource: dedupe(missingFilterFunctions),
        deployStrategyOrder: getDeployStrategyOrder(),
        deployStrategyResolved: edgeDeployContext ? edgeDeployContext.getSticky() : null,
        deployStrategyChanges: edgeDeployContext ? edgeDeployContext.strategyChanges : [],
        pruneTarget: allowPruneTarget,
        prunedTargetOnly: dedupe(prunedTargetOnlyNames),
        pruneFailed: uniquePruneFailed
    };

    const failedFilePath = path.join(MIGRATION_DIR, 'edge_functions_failed.txt');
    const migratedFilePath = path.join(MIGRATION_DIR, 'edge_functions_migrated.txt');
    const skippedFilePath = path.join(MIGRATION_DIR, 'edge_functions_skipped.txt');
    const skippedSharedFilePath = path.join(MIGRATION_DIR, 'edge_functions_skipped_shared.txt');
    const incompatibleFilePath = path.join(MIGRATION_DIR, 'edge_functions_incompatible.txt');
    const summaryJsonPath = path.join(MIGRATION_DIR, 'edge_functions_summary.json');

    const writeListFile = (filePath, list) => {
        const content = list.length > 0 ? `${list.join('\n')}\n` : '';
        fs.writeFileSync(filePath, content, 'utf8');
    };

    writeListFile(failedFilePath, uniqueFailedFunctions);
    writeListFile(migratedFilePath, uniqueMigratedFunctions);
    writeListFile(skippedFilePath, uniqueSkippedFunctions);
    writeListFile(skippedSharedFilePath, uniqueSkippedSharedFunctions);
    writeListFile(incompatibleFilePath, uniqueIncompatibleFunctions);
    fs.writeFileSync(summaryJsonPath, JSON.stringify(summary, null, 2), 'utf8');

    if (uniqueFailedFunctions.length > 0) {
        logWarning(`Failed edge functions recorded in: ${failedFilePath}`);
    } else {
        logSuccess('No edge function failures recorded.');
    }

    if (uniquePruneFailed.length > 0) {
        logError(
            `Target prune failures (${uniquePruneFailed.length}): ${uniquePruneFailed.join(', ')} — re-run with network access or remove these functions in the dashboard.`
        );
    }
    
    if (uniqueSkippedSharedFunctions.length > 0) {
        logInfo(`Functions with shared files skipped (${uniqueSkippedSharedFunctions.length}): ${uniqueSkippedSharedFunctions.join(', ')}`);
        logInfo(`These functions are tracked in: ${skippedSharedFilePath}`);
        logInfo(`Use migrate_shared_edge_functions.sh to migrate them separately.`);
    }
    
    if (uniqueIncompatibleFunctions.length > 0) {
        logWarning(`Functions with incompatible dependencies skipped (${uniqueIncompatibleFunctions.length}): ${uniqueIncompatibleFunctions.join(', ')}`);
        logWarning(`These functions use native Node.js modules (e.g., canvas) that aren't supported in Deno/Supabase Edge Functions`);
        logInfo(`These functions are tracked in: ${incompatibleFilePath}`);
        logInfo(`Consider refactoring these functions to use Deno-compatible alternatives.`);
    }
    
    // Create README
    const readmePath = path.join(functionsDir, 'README.md');
    const readmeContent = `# Edge Functions Backup

This folder contains edge functions downloaded from source project for migration to target.

## Migration Summary
- Source: ${SOURCE_REF}
- Target: ${TARGET_REF}
- Functions migrated: ${migratedCount}
- Functions skipped: ${skippedCount}
- Functions failed: ${failedCount}
- Functions incompatible: ${uniqueIncompatibleFunctions.length}
- Date: ${new Date().toISOString()}

## Manual Deployment

If automatic deployment failed, you can deploy functions manually:

\`\`\`bash
# Navigate to function directory
cd edge_functions/<function-name>

# Deploy to target project
supabase functions deploy <function-name> --project-ref ${TARGET_REF}
\`\`\`

## Functions List

${sourceFunctions.map(f => `- ${f.name} (id: ${f.id || 'N/A'})`).join('\n')}
`;
    fs.writeFileSync(readmePath, readmeContent);
    logInfo(`Created README: ${readmePath}`);

    if (!uniqueFilterSet && !retryMissingMode && sourceNameSet.size > 0) {
        try {
            const verifyTargetList = await getEdgeFunctions(
                TARGET_REF,
                targetConfig.accessToken,
                'Target',
                targetConfig.dbPassword
            );
            const targetVerifySet = new Set(verifyTargetList.map((f) => f?.name).filter(Boolean));
            const namesMatch =
                targetVerifySet.size === sourceNameSet.size &&
                [...sourceNameSet].every((n) => targetVerifySet.has(n));
            if (namesMatch) {
                logSuccess(
                    `Edge function parity: source and target both have ${sourceNameSet.size} function(s) with the same names.`
                );
            } else {
                const missingOnTarget = [...sourceNameSet].filter((n) => !targetVerifySet.has(n)).sort();
                const extraOnTarget = [...targetVerifySet].filter((n) => !sourceNameSet.has(n)).sort();
                logWarning(
                    `Edge function parity: source has ${sourceNameSet.size} named function(s), target has ${targetVerifySet.size}.`
                );
                if (missingOnTarget.length > 0) {
                    logWarning(`  Missing on target (deploy failed, skipped, or incompatible): ${missingOnTarget.join(', ')}`);
                }
                if (extraOnTarget.length > 0) {
                    logWarning(
                        `  Extra on target only: ${extraOnTarget.join(', ')} — use ${colors.cyan}--prune-target${colors.reset} on the next run to remove them.`
                    );
                }
            }
        } catch (parityErr) {
            logWarning(`Could not verify edge function parity: ${parityErr.message || parityErr}`);
        }
        console.log('');
    }

    console.log('');
    logSeparator();
    logSuccess(`${colors.bright}Migration Complete!${colors.reset}`);
    logSeparator();
    logSuccess(`Functions migrated: ${migratedCount}`);
    logInfo(`Functions skipped: ${skippedCount}`);
    if (uniqueSkippedSharedFunctions.length > 0) {
        logInfo(`Functions with shared files skipped: ${uniqueSkippedSharedFunctions.length} (${uniqueSkippedSharedFunctions.join(', ')})`);
        logInfo(`  Use migrate_shared_edge_functions.sh to migrate these functions separately.`);
    }
    if (uniqueIncompatibleFunctions.length > 0) {
        logWarning(`Functions with incompatible dependencies: ${uniqueIncompatibleFunctions.length} (${uniqueIncompatibleFunctions.join(', ')})`);
        logWarning(`  These functions cannot be deployed due to native Node.js module dependencies`);
        logInfo(`  Consider refactoring to use Deno-compatible alternatives`);
    }
    if (failedCount > 0) {
        logError(`Functions failed: ${failedCount}`);
        console.log('');
        logSeparator();
        logWarning(`${colors.bright}Failed Edge Functions${colors.reset}`);
        logSeparator();
        logWarning(`The following ${failedCount} edge function(s) failed to deploy:`);
        console.log('');
        uniqueFailedFunctions.forEach((funcName, index) => {
            logError(`  ${index + 1}. ${funcName}`);
        });
        console.log('');
        logSeparator();
        logInfo(`${colors.bright}Next Steps${colors.reset}`);
        logSeparator();
        logInfo(`These functions have been added to the retry list: ${failedFilePath}`);
        logInfo(`You can retry them using one of the following methods:`);
        console.log('');
        logInfo(`${colors.cyan}Option 1: Use the retry script (recommended)${colors.reset}`);
        logInfo(`  ./scripts/components/retry_edge_functions.sh ${getEnvNameFromRef(SOURCE_REF)} ${getEnvNameFromRef(TARGET_REF)}`);
        console.log('');
        logInfo(`${colors.cyan}Option 2: Manual deployment${colors.reset}`);
        logInfo(`  For each failed function, navigate to its directory and deploy manually:`);
        uniqueFailedFunctions.forEach(funcName => {
            logInfo(`    cd ${path.relative(process.cwd(), path.join(functionsDir, funcName))}`);
            logInfo(`    supabase functions deploy ${funcName} --project-ref ${TARGET_REF}`);
        });
        console.log('');
        logWarning(`⚠ Note: Functions with shared dependencies may require shared files to be available.`);
        logWarning(`   The retry script will handle shared files automatically.`);
        logSeparator();
    } else if (uniquePruneFailed.length === 0) {
        logSuccess('No edge function failures - all functions deployed successfully!');
    }
    if (uniqueFailedFunctions.length === 0 && uniquePruneFailed.length > 0) {
        logError('All deploys succeeded but one or more target-only functions could not be pruned.');
    }
    console.log('');

    const success = uniqueFailedFunctions.length === 0 && uniquePruneFailed.length === 0;
    return { success, migrated: migratedCount, skipped: skippedCount, failed: failedCount };
}

// Run migration
logInfo('Starting edge functions migration process...');
console.log('');

migrateEdgeFunctions()
    .then(result => {
        if (result.success) {
            process.exit(0);
        } else {
            logError('Migration completed with errors');
            process.exit(1);
        }
    })
    .catch(error => {
        console.log('');
        logError('Migration failed with exception:');
        logError(`  ${error.message || error}`);
        if (error.stack) {
            console.error(error.stack);
        }
        process.exit(1);
    });

