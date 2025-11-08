#!/usr/bin/env node
/**
 * Supabase Edge Functions Migration Utility
 * Migrates edge functions from source to target project
 * Uses Supabase Management API and CLI for operations
 * 
 * Usage: node utils/edge-functions-migration.js <source_ref> <target_ref> <migration_dir>
 */

const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

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
const MIGRATION_DIR = process.argv[4];

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

// Download edge function code using Supabase CLI
function downloadEdgeFunction(functionName, projectRef, downloadDir, dbPassword) {
    try {
        logInfo(`    Downloading function code: ${functionName}...`);
        
        // Check if Docker is running (required for function download)
        if (!checkDocker()) {
            logError(`    ✗ Docker is not running - required for downloading functions`);
            logError(`    Please start Docker Desktop and try again`);
            throw new Error('Docker is not running');
        }
        
        // Create temporary directory for download
        const tempDir = path.join(downloadDir, '.temp');
        if (!fs.existsSync(tempDir)) {
            fs.mkdirSync(tempDir, { recursive: true });
        }
        
        // Create supabase functions directory structure
        const functionsDir = path.join(tempDir, 'supabase', 'functions');
        if (!fs.existsSync(functionsDir)) {
            fs.mkdirSync(functionsDir, { recursive: true });
        }
        
        // Create a minimal config.toml for supabase link
        const configTomlPath = path.join(tempDir, 'supabase', 'config.toml');
        if (!fs.existsSync(path.dirname(configTomlPath))) {
            fs.mkdirSync(path.dirname(configTomlPath), { recursive: true });
        }
        fs.writeFileSync(configTomlPath, `project_id = "${projectRef}"\n`);
        
        // Change to temp directory and link
        const originalCwd = process.cwd();
        process.chdir(tempDir);
        
        try {
            // Link to project (in temp directory)
            logInfo(`    Linking to source project...`);
            if (!linkProject(projectRef, dbPassword)) {
                throw new Error('Failed to link to project');
            }
            
            // Download function (project is now linked)
            // Try regular download first, then legacy bundle if that fails
            try {
                execSync(`supabase functions download ${functionName}`, {
                    stdio: 'pipe',
                    timeout: 60000
                });
            } catch (e) {
                // If regular download fails, try legacy bundle (for functions deployed with older CLI)
                if (e.message && (e.message.includes('Docker') || e.message.includes('docker'))) {
                    logInfo(`    Regular download failed, trying legacy bundle...`);
                    execSync(`supabase functions download --legacy-bundle ${functionName}`, {
                        stdio: 'pipe',
                        timeout: 60000
                    });
                } else {
                    throw e;
                }
            }
        } catch (e) {
            process.chdir(originalCwd);
            throw new Error(`Failed to download function: ${e.message}`);
        } finally {
            process.chdir(originalCwd);
        }
        
        // Check if download was successful
        const downloadedFunctionPath = path.join(functionsDir, functionName);
        if (fs.existsSync(downloadedFunctionPath)) {
            // Move to final location
            const finalFunctionPath = path.join(downloadDir, functionName);
            if (fs.existsSync(finalFunctionPath)) {
                fs.rmSync(finalFunctionPath, { recursive: true, force: true });
            }
            fs.renameSync(downloadedFunctionPath, finalFunctionPath);
            
            // Cleanup temp directory
            fs.rmSync(tempDir, { recursive: true, force: true });
            
            logSuccess(`    ✓ Downloaded function: ${functionName}`);
            return true;
        } else {
            fs.rmSync(tempDir, { recursive: true, force: true });
            throw new Error(`Downloaded function directory not found`);
        }
    } catch (error) {
        logError(`    ✗ Failed to download function ${functionName}: ${error.message}`);
        return false;
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
    console.log('');
    
    // Determine which functions need migration
    const functionsToMigrate = [];
    const functionsToSkip = [];
    
    for (const sourceFunction of sourceFunctions) {
        const functionName = sourceFunction.name;
        const existingFunction = targetFunctionMap.get(functionName);
        
        if (existingFunction) {
            // Function exists - we'll download and redeploy to ensure it's up to date
            // Note: We can't easily compare code versions, so we redeploy
            functionsToMigrate.push({ function: sourceFunction, isNew: false });
        } else {
            // New function - needs deployment
            functionsToMigrate.push({ function: sourceFunction, isNew: true });
        }
    }
    
    // Check if all functions are already in target
    if (functionsToMigrate.length === 0) {
        logSuccess(`✓ All source functions already exist in target - no migration needed`);
        skippedCount = sourceFunctions.length;
    } else {
        logInfo(`Functions to migrate: ${functionsToMigrate.length}`);
        logInfo(`  - New functions: ${functionsToMigrate.filter(f => f.isNew).length}`);
        logInfo(`  - Existing functions (will update): ${functionsToMigrate.filter(f => !f.isNew).length}`);
        console.log('');
        
        // Process each function
        for (let i = 0; i < functionsToMigrate.length; i++) {
            const { function: sourceFunction, isNew } = functionsToMigrate[i];
            const functionName = sourceFunction.name;
            
            if (!functionName) {
                logError(`Function ${i + 1} has no name: ${JSON.stringify(sourceFunction)}`);
                continue;
            }
            
            logInfo(`${colors.bright}Function ${i + 1}/${functionsToMigrate.length}: ${functionName}${colors.reset}`);
            
            if (isNew) {
                logInfo(`  Status: NEW - will create in target`);
            } else {
                logInfo(`  Status: EXISTS - will update in target`);
                const existingFunction = targetFunctionMap.get(functionName);
                logInfo(`  Source ID: ${sourceFunction.id || 'N/A'}`);
                logInfo(`  Target ID: ${existingFunction.id || 'N/A'}`);
            }
            
            // Download function from source
            const functionDir = path.join(functionsDir, functionName);
            const downloadSuccess = downloadEdgeFunction(functionName, SOURCE_REF, functionsDir, sourceConfig.dbPassword);
            
            if (!downloadSuccess) {
                logWarning(`  ⚠ Could not download function code - skipping deployment`);
                logWarning(`    Function may need to be deployed manually from codebase`);
                failedCount++;
                console.log('');
                continue;
            }
            
            // Check if function directory was created
            if (!fs.existsSync(functionDir)) {
                logWarning(`  ⚠ Function directory not found after download - skipping`);
                failedCount++;
                console.log('');
                continue;
            }
            
            // Deploy function to target
            const deploySuccess = deployEdgeFunction(functionName, functionDir, TARGET_REF, targetConfig.dbPassword);
            
            if (deploySuccess) {
                migratedCount++;
                logSuccess(`  ✓ Function ${isNew ? 'created' : 'updated'} successfully`);
            } else {
                failedCount++;
                logError(`  ✗ Function migration failed`);
            }
            
            console.log('');
        }
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

