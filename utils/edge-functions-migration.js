#!/usr/bin/env node
/**
 * Supabase Edge Functions Migration Utility
 * Migrates edge functions from source to target project
 * Uses Supabase CLI for downloading and deploying functions
 * 
 * Usage: node utils/edge-functions-migration.js <source_ref> <target_ref> <migration_dir>
 */

const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');
const PROJECT_ROOT = path.resolve(__dirname, '..');

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
    return loaded;
}

// Load environment variables
loadEnvFile();

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

for (const rawArg of additionalArgs) {
    if (!rawArg) continue;
    if (rawArg.startsWith('--functions=')) {
        const csv = rawArg.split('=')[1] || '';
        const names = csv.split(',').map((item) => item.trim()).filter(Boolean);
        filterList = filterList.concat(names);
    } else if (rawArg.startsWith('--filter-file=')) {
        filterFilePath = rawArg.split('=')[1] || '';
    } else if (rawArg === '--allow-missing') {
        allowPartialFilter = true;
    } else if (rawArg === '--incremental' || rawArg === '--increment') {
        incrementalMode = true;
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

const uniqueFilterSet = filterList.length > 0 ? new Set(filterList) : null;
const requestedFilterNames = uniqueFilterSet ? Array.from(uniqueFilterSet) : [];
const filterNamesFound = new Set();
const missingFilterFunctions = [];

const migratedFunctions = [];
const failedFunctions = [];
const skippedFunctions = [];
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
    
    // Get access token (required for Management API)
    const accessToken = process.env.SUPABASE_ACCESS_TOKEN || '';
    
    if (!accessToken) {
        logError(`✗ SUPABASE_ACCESS_TOKEN not found`);
    } else {
        logInfo(`  Access Token: Found (length: ${accessToken.length})`);
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
    console.error('  - SUPABASE_ACCESS_TOKEN (required for Management API)');
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

// Validate access token
if (!sourceConfig.accessToken || !targetConfig.accessToken) {
    logError('SUPABASE_ACCESS_TOKEN not found in environment variables');
    logError('Please ensure SUPABASE_ACCESS_TOKEN is set in .env.local');
    process.exit(1);
}

// Get edge functions from a project using Management API
async function getEdgeFunctions(projectRef, accessToken, projectName) {
    try {
        logInfo(`Fetching edge functions from ${projectName || 'project'}...`);
        
        const url = `https://api.supabase.com/v1/projects/${projectRef}/functions`;
        
        const functions = await new Promise((resolve, reject) => {
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
                            const funcList = Array.isArray(json) ? json : [];
                            resolve(funcList);
                        } catch (e) {
                            logError(`  Failed to parse response: ${e.message}`);
                            reject(new Error(`Failed to parse functions response: ${e.message}`));
                        }
                    } else {
                        logError(`  HTTP ${res.statusCode}: ${data.substring(0, 200)}`);
                        reject(new Error(`HTTP ${res.statusCode}: ${data.substring(0, 200)}`));
                    }
                });
            });
            req.on('error', (error) => {
                logError(`  Request error: ${error.message}`);
                reject(error);
            });
            req.end();
        });
        
        logSuccess(`Found ${functions.length} edge function(s) in ${projectName || 'project'}`);
        if (functions.length > 0) {
            functions.forEach((func, index) => {
                logInfo(`  ${index + 1}. ${func.name} (id: ${func.id || 'N/A'})`);
            });
        }
        return functions;
    } catch (error) {
        logError(`Failed to get edge functions from ${projectName || 'project'}`);
        logError(`  Error: ${error.message || JSON.stringify(error)}`);
        
        if (error.message && (
            error.message.includes('401') ||
            error.message.includes('403') ||
            error.message.includes('Unauthorized')
        )) {
            logError(`Authentication failed: Access token may be invalid or expired`);
            logError(`Please verify:`);
            logError(`  1. SUPABASE_ACCESS_TOKEN is set correctly in .env.local`);
            logError(`  2. The access token has not expired`);
            logError(`  3. The access token has the necessary permissions`);
        }
        
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

// Link project using Supabase CLI
function linkProject(projectRef, dbPassword) {
    try {
        // Unlink first to avoid conflicts
        try {
            execSync('supabase unlink --yes', { stdio: 'pipe', timeout: 5000 });
        } catch (e) {
            // Ignore errors - project might not be linked
        }
        
        // Link to project (password is required for link command)
        if (dbPassword) {
            execSync(`supabase link --project-ref ${projectRef} --password "${dbPassword}"`, {
                stdio: 'pipe',
                timeout: 30000
            });
        } else {
            // Try without password (may fail, but worth trying)
            logWarning(`    ⚠ No database password provided, trying to link without password...`);
            execSync(`supabase link --project-ref ${projectRef}`, {
                stdio: 'pipe',
                timeout: 30000
            });
        }
        
        return true;
    } catch (error) {
        logWarning(`    ⚠ Could not link to project ${projectRef}: ${error.message}`);
        return false;
    }
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

async function downloadEdgeFunction(functionName, projectRef, downloadDir, dbPassword, quiet = false) {
    let finalFunctionPath = path.join(downloadDir, functionName);
    try {
        if (!quiet) {
            logInfo(`    Downloading function code: ${functionName}...`);
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
            if (!linkProject(projectRef, dbPassword)) {
                throw new Error('Failed to link to project');
            }

            try {
                execSync(`supabase functions download ${functionName}`, {
                    stdio: 'pipe',
                    timeout: 60000
                });
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
                        execSync(`supabase functions download --legacy-bundle ${functionName}`, {
                            stdio: 'pipe',
                            timeout: 60000
                        });
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

// Deploy edge function using Supabase CLI
function deployEdgeFunction(functionName, functionDir, targetRef, dbPassword) {
    try {
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

        const globalSharedDir = path.join(functionsParentDir, '_shared');
        const localSharedDir = path.join(functionDir, '_shared');
        const sharedDestDir = path.join(supabaseDir, '_shared');
        if (fs.existsSync(sharedDestDir)) {
            fs.rmSync(sharedDestDir, { recursive: true, force: true });
        }
        if (fs.existsSync(globalSharedDir)) {
            mergeDirectories(globalSharedDir, sharedDestDir);
        }
        if (fs.existsSync(localSharedDir)) {
            mergeDirectories(localSharedDir, sharedDestDir);
        }
        
        // Change to supabase directory and link
        process.chdir(supabaseConfigDir);
        
        try {
            // Link to target project (in supabase directory)
            logInfo(`    Linking to target project...`);
            if (!linkProject(targetRef, dbPassword)) {
                throw new Error('Failed to link to target project');
            }
            
            // Deploy (project is now linked)
            execSync(`supabase functions deploy ${functionName}`, {
                stdio: 'pipe',
                timeout: 120000
            });
            
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
        logError(`    ✗ Failed to deploy function ${functionName}: ${error.message}`);
        return false;
    }
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
    
    // Step 1: Get source edge functions
    logStep(1, 4, 'Fetching source edge functions...');
    let sourceFunctions = [];
    try {
        sourceFunctions = await getEdgeFunctions(SOURCE_REF, sourceConfig.accessToken, 'Source');
        if (sourceFunctions.length === 0) {
            logWarning('No edge functions found in source project');
        }
    } catch (error) {
        logError('Failed to fetch source edge functions - cannot continue migration');
        throw error;
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
        targetFunctions = await getEdgeFunctions(TARGET_REF, targetConfig.accessToken, 'Target');
    } catch (error) {
        logError('Failed to fetch target edge functions - cannot continue migration');
        throw error;
    }
    
    const targetFunctionMap = new Map(targetFunctions.map(f => [f.name, f]));
    console.log('');
    
    // Step 3: Smart migration - compare functions
    logSeparator();
    logInfo(`${colors.bright}Starting Edge Functions Migration${colors.reset}`);
    logSeparator();
    console.log('');
    
    let migratedCount = 0;
    let skippedCount = 0;
    let failedCount = 0;
    
    // Create functions directory for downloads
    const functionsDir = path.join(MIGRATION_DIR, 'edge_functions');
    if (!fs.existsSync(functionsDir)) {
        fs.mkdirSync(functionsDir, { recursive: true });
    }
    
    // Step 4: Smart migration - compare functions and deploy only what's needed
    logInfo(`Function comparison:`);
    logInfo(`  Source: ${sourceFunctions.length} function(s)`);
    logInfo(`  Target: ${targetFunctions.length} function(s)`);
    logInfo(`  Incremental mode: ${incrementalMode ? 'enabled' : 'disabled (will redeploy existing functions)'}`);
    console.log('');
    
    // Determine which functions need migration
    const functionsToMigrate = [];
    
    for (const sourceFunction of sourceFunctions) {
        const functionName = sourceFunction.name;
        const existingFunction = targetFunctionMap.get(functionName);
        
        if (!functionName) {
            failedFunctions.push('(unnamed)');
            continue;
        }
        
        if (existingFunction) {
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
            // New function - needs deployment
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
                logInfo(`  Status: EXISTS - checking for updates`);
                logInfo(`  Source ID: ${sourceFunction.id || 'N/A'}`);
                logInfo(`  Target ID: ${existing?.id || 'N/A'}`);
            }
            
            // Download function from source
            const functionDir = path.join(functionsDir, functionName);
            logInfo(`  Downloading edge function from source...`);
            const downloadSuccess = await downloadEdgeFunction(functionName, SOURCE_REF, functionsDir, sourceConfig.dbPassword, false);
            
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
            
            logSuccess(`  ✓ Downloaded function: ${functionName}`);
            
            // For existing functions, compare with target before deploying
            if (!isNew) {
                logInfo(`  Comparing with target function...`);
                
                // Download target function for comparison (quiet mode to reduce noise)
                const targetCompareDir = fs.mkdtempSync(path.join(os.tmpdir(), `edge-compare-${functionName}-`));
                try {
                    const targetDownloadSuccess = await downloadEdgeFunction(functionName, TARGET_REF, targetCompareDir, targetConfig.dbPassword, true);
                    
                    if (targetDownloadSuccess) {
                        const targetFunctionDir = path.join(targetCompareDir, functionName);
                        if (fs.existsSync(targetFunctionDir)) {
                            // Get file counts for logging
                            const sourceFiles = getAllCodeFiles(functionDir);
                            const targetFiles = getAllCodeFiles(targetFunctionDir);
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
            
            // Deploy function to target
            const deploySuccess = deployEdgeFunction(functionName, functionDir, TARGET_REF, targetConfig.dbPassword);
            
            if (deploySuccess) {
                migratedFunctions.push(functionName);
                logSuccess(`  ✓ Function ${isNew ? 'created' : 'updated'} successfully`);
            } else {
                failedFunctions.push(functionName);
                logError(`  ✗ Function migration failed`);
            }
            
            console.log('');
        }
    }
    
    const dedupe = (arr) => Array.from(new Set(arr.filter(Boolean)));
    const attemptedFunctionNames = functionsToMigrate.map(({ function: func }) => func?.name).filter(Boolean);
    const uniqueMigratedFunctions = dedupe(migratedFunctions);
    const uniqueFailedFunctions = dedupe([...failedFunctions, ...missingFilterFunctions]);
    const uniqueSkippedFunctions = dedupe(skippedFunctions);

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
    identical: dedupe(identicalFunctions),
    incrementalMode,
    missingInSource: dedupe(missingFilterFunctions)
    };

    const failedFilePath = path.join(MIGRATION_DIR, 'edge_functions_failed.txt');
    const migratedFilePath = path.join(MIGRATION_DIR, 'edge_functions_migrated.txt');
    const skippedFilePath = path.join(MIGRATION_DIR, 'edge_functions_skipped.txt');
    const summaryJsonPath = path.join(MIGRATION_DIR, 'edge_functions_summary.json');

    const writeListFile = (filePath, list) => {
        const content = list.length > 0 ? `${list.join('\n')}\n` : '';
        fs.writeFileSync(filePath, content, 'utf8');
    };

    writeListFile(failedFilePath, uniqueFailedFunctions);
    writeListFile(migratedFilePath, uniqueMigratedFunctions);
    writeListFile(skippedFilePath, uniqueSkippedFunctions);
    fs.writeFileSync(summaryJsonPath, JSON.stringify(summary, null, 2), 'utf8');

    if (uniqueFailedFunctions.length > 0) {
        logWarning(`Failed edge functions recorded in: ${failedFilePath}`);
    } else {
        logSuccess('No edge function failures recorded.');
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
    
    console.log('');
    logSeparator();
    logSuccess(`${colors.bright}Migration Complete!${colors.reset}`);
    logSeparator();
    logSuccess(`Functions migrated: ${migratedCount}`);
    logInfo(`Functions skipped: ${skippedCount}`);
    if (failedCount > 0) {
        logError(`Functions failed: ${failedCount}`);
    }
    logSeparator();
    
    return { success: true, migrated: migratedCount, skipped: skippedCount, failed: failedCount };
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

