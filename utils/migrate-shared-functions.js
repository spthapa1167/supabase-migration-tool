#!/usr/bin/env node
/**
 * Migrate Edge Functions with Shared Files
 * Dedicated utility for migrating edge functions that have shared file dependencies
 * Handles bundling, import maps, and proper deployment of shared files
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync, spawn } = require('child_process');
const PROJECT_ROOT = path.resolve(__dirname, '..');
const LOCAL_FUNCTIONS_DIR = path.join(PROJECT_ROOT, 'supabase', 'functions');

// ANSI color codes
const colors = {
    reset: '\x1b[0m',
    bright: '\x1b[1m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    cyan: '\x1b[36m',
};

function logInfo(msg) {
    console.log(`[INFO] ${msg}`);
}

function logSuccess(msg) {
    console.log(`${colors.green}[SUCCESS]${colors.reset} ${msg}`);
}

function logError(msg) {
    console.error(`${colors.red}[ERROR]${colors.reset} ${msg}`);
}

function logWarning(msg) {
    console.log(`${colors.yellow}[WARNING]${colors.reset} ${msg}`);
}

// Load environment variables
function loadEnvFile() {
    const envFiles = ['.env.local', '.env'];
    for (const envFile of envFiles) {
        const envPath = path.join(PROJECT_ROOT, envFile);
        if (fs.existsSync(envPath)) {
            const content = fs.readFileSync(envPath, 'utf8');
            content.split('\n').forEach(line => {
                const trimmed = line.trim();
                if (trimmed && !trimmed.startsWith('#')) {
                    const [key, ...valueParts] = trimmed.split('=');
                    if (key && valueParts.length > 0) {
                        const value = valueParts.join('=').replace(/^["']|["']$/g, '');
                        process.env[key.trim()] = value;
                    }
                }
            });
            break;
        }
    }
}

loadEnvFile();

// Parse arguments
const args = process.argv.slice(2);
let SOURCE_REF = '';
let TARGET_REF = '';
let MIGRATION_DIR = '';
let FUNCTION_FILTER = [];

for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith('--functions=')) {
        const funcList = arg.split('=')[1];
        FUNCTION_FILTER = funcList.split(',').map(f => f.trim()).filter(Boolean);
    } else if (!SOURCE_REF) {
        SOURCE_REF = arg;
    } else if (!TARGET_REF) {
        TARGET_REF = arg;
    } else if (!MIGRATION_DIR) {
        MIGRATION_DIR = arg;
    }
}

if (!SOURCE_REF || !TARGET_REF || !MIGRATION_DIR) {
    logError('Usage: node migrate-shared-functions.js <source_ref> <target_ref> <migration_dir> [--functions=func1,func2]');
    process.exit(1);
}

MIGRATION_DIR = path.resolve(MIGRATION_DIR);
const FUNCTIONS_DIR = path.join(MIGRATION_DIR, 'edge_functions');
const SHARED_DIR = path.join(FUNCTIONS_DIR, '_shared');

// Check Docker
function checkDocker() {
    try {
        execSync('docker ps', { stdio: 'pipe', timeout: 5000 });
        return true;
    } catch {
        return false;
    }
}

// Link project
function linkProject(projectRef, dbPassword, accessToken = null) {
    try {
        // Prepare environment with access token if provided
        const env = { ...process.env };
        if (accessToken) {
            env.SUPABASE_ACCESS_TOKEN = accessToken;
        }
        
        try {
            execSync('supabase unlink --yes', { 
                stdio: 'pipe', 
                timeout: 5000,
                env: env
            });
        } catch {}
        
        if (dbPassword) {
            execSync(`supabase link --project-ref ${projectRef} --password "${dbPassword}"`, {
                stdio: 'pipe',
                timeout: 30000,
                env: env
            });
        } else {
            execSync(`supabase link --project-ref ${projectRef}`, {
                stdio: 'pipe',
                timeout: 30000,
                env: env
            });
        }
        return true;
    } catch (error) {
        logWarning(`Could not link to project ${projectRef}: ${error.message}`);
        return false;
    }
}

// Merge directories
function mergeDirectories(srcDir, destDir) {
    if (!fs.existsSync(srcDir)) return;
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

// Download function with shared files
async function downloadFunctionWithShared(functionName, projectRef, downloadDir, dbPassword, accessToken = null) {
    if (!checkDocker()) {
        throw new Error('Docker is not running');
    }

    // Prepare environment with access token if provided
    const env = { ...process.env };
    if (accessToken) {
        env.SUPABASE_ACCESS_TOKEN = accessToken;
    }

    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), `shared-func-${functionName}-`));
    const originalCwd = process.cwd();

    try {
        const supabaseDir = path.join(tempDir, 'supabase');
        const functionsDir = path.join(supabaseDir, 'functions');
        fs.mkdirSync(functionsDir, { recursive: true });
        fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${projectRef}"\n`);

        process.chdir(tempDir);

        if (!linkProject(projectRef, dbPassword, accessToken)) {
            throw new Error('Failed to link to project');
        }

        try {
            execSync(`supabase functions download ${functionName}`, {
                stdio: 'pipe',
                timeout: 60000,
                env: env
            });
        } catch (e) {
            const output = `${e.message}\n${e.stderr?.toString() || ''}\n${e.stdout?.toString() || ''}`;
            if (/legacy[- ]bundle/i.test(output)) {
                execSync(`supabase functions download --legacy-bundle ${functionName}`, {
                    stdio: 'pipe',
                    timeout: 60000,
                    env: env
                });
            } else {
                throw e;
            }
        }

        // Find downloaded function
        const downloadedPath = path.join(tempDir, 'supabase', 'functions', functionName);
        if (!fs.existsSync(downloadedPath)) {
            throw new Error('Downloaded function directory not found');
        }

        // Copy function
        const finalPath = path.join(downloadDir, functionName);
        fs.rmSync(finalPath, { recursive: true, force: true });
        fs.mkdirSync(path.dirname(finalPath), { recursive: true });
        fs.cpSync(downloadedPath, finalPath, { recursive: true });

        // Copy shared files from multiple possible locations
        const tempSharedDirs = [
            path.join(tempDir, 'supabase', 'functions', '_shared'),
            path.join(tempDir, 'supabase', 'functions', functionName, '_shared'),
            path.join(downloadedPath, '_shared'),
            path.join(tempDir, 'functions', '_shared'),
            path.join(tempDir, '_shared')
        ];

        let sharedFilesFound = false;
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
                        logInfo(`    Found ${actualFiles.length} shared file(s) at: ${path.basename(tempSharedDir)}`);
                        mergeDirectories(tempSharedDir, SHARED_DIR);
                        // Also copy directly to function's _shared directory
                        const functionSharedDir = path.join(finalPath, '_shared');
                        fs.mkdirSync(functionSharedDir, { recursive: true });
                        mergeDirectories(tempSharedDir, functionSharedDir);
                        sharedFilesFound = true;
                    }
                }
            }
        }

        // If no shared files found, try downloading all functions to get shared files
        if (!sharedFilesFound) {
            logWarning(`    No shared files found in download - trying to download all functions to collect shared files...`);
            try {
                // First, get list of all functions from the project
                const functionsList = execSync(`supabase functions list`, {
                    stdio: 'pipe',
                    timeout: 30000,
                    encoding: 'utf8',
                    env: env
                });
                
                // Parse function names from the list (format: function_name)
                const functionNames = functionsList.split('\n')
                    .map(line => line.trim())
                    .filter(line => line && !line.startsWith('NAME') && !line.startsWith('---') && !line.includes('│'))
                    .map(line => {
                        // Extract function name (first column)
                        const parts = line.split(/\s+/);
                        return parts[0];
                    })
                    .filter(name => name && name !== 'NAME' && name.length > 0);
                
                logInfo(`    Found ${functionNames.length} function(s) in project, downloading to collect shared files...`);
                
                // Download each function to collect shared files
                for (const funcName of functionNames) {
                    try {
                        execSync(`supabase functions download ${funcName}`, {
                            stdio: 'pipe',
                            timeout: 60000,
                            env: env
                        });
                    } catch (e) {
                        // Continue with other functions if one fails
                    }
                }
                
                // Check again after downloading all
                const allFunctionsSharedDir = path.join(tempDir, 'supabase', 'functions', '_shared');
                if (fs.existsSync(allFunctionsSharedDir)) {
                    const files = fs.readdirSync(allFunctionsSharedDir);
                    if (files.length > 0) {
                        const actualFiles = files.filter(f => {
                            const filePath = path.join(allFunctionsSharedDir, f);
                            try {
                                return fs.statSync(filePath).isFile();
                            } catch {
                                return false;
                            }
                        });
                        
                        if (actualFiles.length > 0) {
                            logInfo(`    Found ${actualFiles.length} shared file(s) after downloading all functions`);
                            mergeDirectories(allFunctionsSharedDir, SHARED_DIR);
                            const functionSharedDir = path.join(finalPath, '_shared');
                            fs.mkdirSync(functionSharedDir, { recursive: true });
                            mergeDirectories(allFunctionsSharedDir, functionSharedDir);
                            sharedFilesFound = true;
                        }
                    }
                }
                
                // Also check each downloaded function for local _shared directories
                const allFunctionsDir = path.join(tempDir, 'supabase', 'functions');
                if (fs.existsSync(allFunctionsDir)) {
                    const entries = fs.readdirSync(allFunctionsDir, { withFileTypes: true });
                    for (const entry of entries) {
                        if (entry.isDirectory() && entry.name !== '_shared' && entry.name !== functionName) {
                            const funcSharedDir = path.join(allFunctionsDir, entry.name, '_shared');
                            if (fs.existsSync(funcSharedDir)) {
                                const files = fs.readdirSync(funcSharedDir).filter(f => {
                                    const filePath = path.join(funcSharedDir, f);
                                    try {
                                        return fs.statSync(filePath).isFile();
                                    } catch {
                                        return false;
                                    }
                                });
                                if (files.length > 0) {
                                    logInfo(`    Found ${files.length} shared file(s) in ${entry.name}/_shared`);
                                    mergeDirectories(funcSharedDir, SHARED_DIR);
                                    const functionSharedDir = path.join(finalPath, '_shared');
                                    if (!fs.existsSync(functionSharedDir)) {
                                        fs.mkdirSync(functionSharedDir, { recursive: true });
                                    }
                                    mergeDirectories(funcSharedDir, functionSharedDir);
                                    sharedFilesFound = true;
                                }
                            }
                        }
                    }
                }
            } catch (e) {
                logWarning(`    Could not download all functions: ${e.message}`);
            }
        }
        
        // Final check: if still no shared files, try to get them from a function that uses them
        if (!sharedFilesFound) {
            logWarning(`    Still no shared files found - attempting to download a function that uses shared files...`);
            // Try downloading a few common function names that might have shared files
            const commonFunctionsWithShared = ['send-email', 'send-notification', 'send-password-reset', 'send-otp'];
            for (const commonFunc of commonFunctionsWithShared) {
                if (commonFunc === functionName) continue; // Skip the function we're already downloading
                try {
                    logInfo(`    Trying to download ${commonFunc} to get shared files...`);
                    execSync(`supabase functions download ${commonFunc}`, {
                        stdio: 'pipe',
                        timeout: 60000
                    });
                    
                    const commonFuncPath = path.join(tempDir, 'supabase', 'functions', commonFunc);
                    const commonFuncSharedDir = path.join(commonFuncPath, '_shared');
                    if (fs.existsSync(commonFuncSharedDir)) {
                        const files = fs.readdirSync(commonFuncSharedDir).filter(f => {
                            const filePath = path.join(commonFuncSharedDir, f);
                            try {
                                return fs.statSync(filePath).isFile();
                            } catch {
                                return false;
                            }
                        });
                        if (files.length > 0) {
                            logInfo(`    Found ${files.length} shared file(s) in ${commonFunc}/_shared: ${files.join(', ')}`);
                            mergeDirectories(commonFuncSharedDir, SHARED_DIR);
                            const functionSharedDir = path.join(finalPath, '_shared');
                            if (!fs.existsSync(functionSharedDir)) {
                                fs.mkdirSync(functionSharedDir, { recursive: true });
                            }
                            mergeDirectories(commonFuncSharedDir, functionSharedDir);
                            sharedFilesFound = true;
                            break;
                        }
                    }
                } catch (e) {
                    // Continue trying other functions
                }
            }
        }

        return true;
    } finally {
        process.chdir(originalCwd);
        fs.rmSync(tempDir, { recursive: true, force: true });
    }
}

// Create import map for shared files
function createImportMap(functionDir, sharedDir) {
    const importMapPath = path.join(functionDir, 'import_map.json');
    
    if (!fs.existsSync(sharedDir)) {
        return null;
    }

    const sharedFiles = fs.readdirSync(sharedDir).filter(f => {
        const filePath = path.join(sharedDir, f);
        return fs.statSync(filePath).isFile() && (f.endsWith('.ts') || f.endsWith('.js'));
    });

    if (sharedFiles.length === 0) {
        return null;
    }

    const imports = {};
    sharedFiles.forEach(file => {
        const name = file.replace(/\.(ts|js)$/, '');
        const relativePath = path.relative(functionDir, path.join(sharedDir, file));
        imports[`@shared/${name}`] = `./${relativePath}`;
        imports[`@shared/`] = `./${relativePath.replace(/\/[^/]+$/, '/')}`;
    });

    const importMap = {
        imports: imports
    };

    fs.writeFileSync(importMapPath, JSON.stringify(importMap, null, 2));
    return importMapPath;
}

// Bundle shared files into function (copy to function directory)
function bundleSharedFiles(functionDir, sharedDir) {
    if (!fs.existsSync(sharedDir)) {
        return false;
    }

    const functionSharedDir = path.join(functionDir, '_shared');
    fs.mkdirSync(functionSharedDir, { recursive: true });
    mergeDirectories(sharedDir, functionSharedDir);

    // Update imports in function files
    const functionFiles = ['index.ts', 'index.js', 'main.ts', 'main.js'];
    for (const fileName of functionFiles) {
        const filePath = path.join(functionDir, fileName);
        if (fs.existsSync(filePath)) {
            let content = fs.readFileSync(filePath, 'utf8');
            // Replace imports from ../_shared to ./_shared
            content = content.replace(/from\s+["']\.\.\/_shared\/([^"']+)["']/g, 'from "./_shared/$1"');
            content = content.replace(/from\s+["']@shared\/([^"']+)["']/g, 'from "./_shared/$1"');
            fs.writeFileSync(filePath, content);
        }
    }

    return true;
}

// Deploy function with shared files
async function deployFunctionWithShared(functionName, functionDir, targetRef, dbPassword, targetAccessToken = null) {
    // Prepare environment with access token if provided
    const env = { ...process.env };
    if (targetAccessToken) {
        env.SUPABASE_ACCESS_TOKEN = targetAccessToken;
    }
    
    const originalCwd = process.cwd();
    const functionsParentDir = path.dirname(functionDir);
    const supabaseDir = path.join(functionsParentDir, 'supabase', 'functions');

    try {
        // Create supabase/functions structure
        fs.mkdirSync(supabaseDir, { recursive: true });
        const configDir = path.join(functionsParentDir, 'supabase');
        const configPath = path.join(configDir, 'config.toml');
        if (!fs.existsSync(configPath)) {
            fs.writeFileSync(configPath, `project_id = "${targetRef}"\n`);
        }

        // Copy function
        const tempFunctionPath = path.join(supabaseDir, functionName);
        fs.rmSync(tempFunctionPath, { recursive: true, force: true });
        fs.cpSync(functionDir, tempFunctionPath, { recursive: true });

        // CRITICAL: Ensure shared files are in the function's _shared directory for deployment
        // The function code expects _shared to be in the same directory as index.ts
        const tempFunctionSharedDir = path.join(tempFunctionPath, '_shared');
        
        // Priority 1: Copy from function's local _shared (from bundling step)
        const functionSharedDir = path.join(functionDir, '_shared');
        if (fs.existsSync(functionSharedDir)) {
            fs.mkdirSync(tempFunctionSharedDir, { recursive: true });
            mergeDirectories(functionSharedDir, tempFunctionSharedDir);
            logInfo(`    Copied shared files from function's local _shared directory`);
        }

        // Priority 2: Copy shared files from global shared directory to function's _shared
        if (fs.existsSync(SHARED_DIR)) {
            if (!fs.existsSync(tempFunctionSharedDir)) {
                fs.mkdirSync(tempFunctionSharedDir, { recursive: true });
            }
            mergeDirectories(SHARED_DIR, tempFunctionSharedDir);
            logInfo(`    Copied shared files from global directory`);
        }

        // Priority 3: Check local repository for shared files
        const localSharedDir = path.join(LOCAL_FUNCTIONS_DIR, '_shared');
        if (fs.existsSync(localSharedDir)) {
            const localFiles = fs.readdirSync(localSharedDir).filter(f => {
                const filePath = path.join(localSharedDir, f);
                try {
                    return fs.statSync(filePath).isFile();
                } catch {
                    return false;
                }
            });
            if (localFiles.length > 0) {
                if (!fs.existsSync(tempFunctionSharedDir)) {
                    fs.mkdirSync(tempFunctionSharedDir, { recursive: true });
                }
                mergeDirectories(localSharedDir, tempFunctionSharedDir);
                logInfo(`    Copied ${localFiles.length} shared file(s) from local repository: ${localFiles.join(', ')}`);
            }
        }

        // Verify shared files are present
        if (fs.existsSync(tempFunctionSharedDir)) {
            const sharedFiles = fs.readdirSync(tempFunctionSharedDir).filter(f => {
                const filePath = path.join(tempFunctionSharedDir, f);
                try {
                    return fs.statSync(filePath).isFile();
                } catch {
                    return false;
                }
            });
            if (sharedFiles.length > 0) {
                logInfo(`    ✓ Shared files ready in function directory (${sharedFiles.length} file(s)): ${sharedFiles.join(', ')}`);
            } else {
                logWarning(`    ⚠ Function's _shared directory is empty - checking function code for required files...`);
                // Check function code to see what files it needs
                const indexPath = path.join(tempFunctionPath, 'index.ts');
                const indexJsPath = path.join(tempFunctionPath, 'index.js');
                let funcCode = '';
                if (fs.existsSync(indexPath)) {
                    funcCode = fs.readFileSync(indexPath, 'utf8');
                } else if (fs.existsSync(indexJsPath)) {
                    funcCode = fs.readFileSync(indexJsPath, 'utf8');
                }
                
                const sharedImports = funcCode.match(/["']\.?\.?\/_shared\/([^"']+)["']/g);
                if (sharedImports && sharedImports.length > 0) {
                    const neededFiles = sharedImports.map(imp => {
                        const match = imp.match(/\/([^"']+)["']/);
                        return match ? match[1] : null;
                    }).filter(Boolean);
                    logError(`    ✗ Missing shared files required by function: ${neededFiles.join(', ')}`);
                    logError(`    The function imports: ${sharedImports.join(', ')}`);
                    logError(`    Please ensure these files exist in one of:`);
                    logError(`      1. Local repository: ${localSharedDir}`);
                    logError(`      2. Source project (download all functions to get shared files)`);
                    logError(`      3. Manually copy to: ${tempFunctionSharedDir}`);
                    throw new Error(`Shared files not found: ${neededFiles.join(', ')}`);
                } else {
                    logWarning(`    Function code doesn't explicitly reference _shared - deployment may still work`);
                }
            }
        } else {
            logWarning(`    ⚠ Function's _shared directory not found - deployment may fail`);
        }

        // Also ensure shared files are in global deployment directory (for functions that might reference it)
        const deploymentSharedDir = path.join(supabaseDir, '_shared');
        if (fs.existsSync(SHARED_DIR)) {
            fs.mkdirSync(deploymentSharedDir, { recursive: true });
            mergeDirectories(SHARED_DIR, deploymentSharedDir);
        }
        if (fs.existsSync(functionSharedDir)) {
            if (!fs.existsSync(deploymentSharedDir)) {
                fs.mkdirSync(deploymentSharedDir, { recursive: true });
            }
            mergeDirectories(functionSharedDir, deploymentSharedDir);
        }

        process.chdir(configDir);

        if (!linkProject(targetRef, dbPassword, targetAccessToken)) {
            throw new Error('Failed to link to target project');
        }

        // Deploy
        logInfo(`    Deploying ${functionName}...`);
        const deployProcess = spawn('supabase', ['functions', 'deploy', functionName], {
            cwd: configDir,
            stdio: ['pipe', 'pipe', 'pipe'],
            shell: true,
            env: env
        });

        let stdout = '';
        let stderr = '';

        deployProcess.stdout.on('data', (data) => {
            stdout += data.toString();
        });

        deployProcess.stderr.on('data', (data) => {
            stderr += data.toString();
        });

        return new Promise((resolve, reject) => {
            deployProcess.on('close', (code) => {
                if (code === 0) {
                    logSuccess(`    ✓ Deployed ${functionName} successfully`);
                    resolve(true);
                } else {
                    logError(`    ✗ Failed to deploy ${functionName}`);
                    if (stderr) logError(`    Error: ${stderr}`);
                    reject(new Error(`Deployment failed with code ${code}`));
                }
            });

            deployProcess.on('error', (error) => {
                logError(`    ✗ Deployment error: ${error.message}`);
                reject(error);
            });
        });
    } finally {
        process.chdir(originalCwd);
    }
}

// Main migration logic
async function main() {
    logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    logInfo('  Migrate Edge Functions with Shared Files');
    logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    logInfo(`Source: ${SOURCE_REF}`);
    logInfo(`Target: ${TARGET_REF}`);
    logInfo(`Migration Directory: ${MIGRATION_DIR}`);
    console.log('');

    // Get source config
    const sourceEnvName = getEnvName(SOURCE_REF);
    const targetEnvName = getEnvName(TARGET_REF);
    
    const sourceConfig = {
        accessToken: process.env[`SUPABASE_${sourceEnvName}_ACCESS_TOKEN`] || '',
        dbPassword: process.env[`SUPABASE_${sourceEnvName}_DB_PASSWORD`] || ''
    };

    const targetConfig = {
        accessToken: process.env[`SUPABASE_${targetEnvName}_ACCESS_TOKEN`] || '',
        dbPassword: process.env[`SUPABASE_${targetEnvName}_DB_PASSWORD`] || ''
    };

    // Determine functions to migrate
    let functionsToMigrate = FUNCTION_FILTER;
    
    if (functionsToMigrate.length === 0) {
        // Try to read from skipped shared file
        const skippedFile = path.join(MIGRATION_DIR, 'edge_functions_skipped_shared.txt');
        if (fs.existsSync(skippedFile)) {
            const content = fs.readFileSync(skippedFile, 'utf8');
            functionsToMigrate = content.split('\n')
                .map(line => line.trim())
                .filter(line => line && !line.startsWith('#'));
        }
    }

    if (functionsToMigrate.length === 0) {
        logError('No functions specified for migration');
        process.exit(1);
    }

    logInfo(`Functions to migrate: ${functionsToMigrate.join(', ')}`);
    console.log('');

    // Ensure functions directory exists
    if (!fs.existsSync(FUNCTIONS_DIR)) {
        fs.mkdirSync(FUNCTIONS_DIR, { recursive: true });
    }

    const migrated = [];
    const failed = [];

    // First, check if shared files exist in local repository and copy them to global shared directory
    const localSharedDir = path.join(LOCAL_FUNCTIONS_DIR, '_shared');
    let localSharedFiles = [];
    if (fs.existsSync(localSharedDir)) {
        localSharedFiles = fs.readdirSync(localSharedDir).filter(f => {
            const filePath = path.join(localSharedDir, f);
            try {
                return fs.statSync(filePath).isFile();
            } catch {
                return false;
            }
        });
        if (localSharedFiles.length > 0) {
            logInfo(`Found ${localSharedFiles.length} shared file(s) in local repository: ${localSharedFiles.join(', ')}`);
            // Copy to global shared directory
            if (!fs.existsSync(SHARED_DIR)) {
                fs.mkdirSync(SHARED_DIR, { recursive: true });
            }
            mergeDirectories(localSharedDir, SHARED_DIR);
            logInfo(`  ✓ Copied shared files to migration directory`);
        }
    }
    
    // If no local shared files, try to download them from source project by downloading all functions
    if (localSharedFiles.length === 0) {
        logInfo(`No shared files in local repository - attempting to download from source project...`);
        const tempDownloadDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shared-download-'));
        const originalCwd = process.cwd();
        
        try {
            const supabaseDir = path.join(tempDownloadDir, 'supabase');
            const functionsDir = path.join(supabaseDir, 'functions');
            fs.mkdirSync(functionsDir, { recursive: true });
            fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${SOURCE_REF}"\n`);
            
            process.chdir(tempDownloadDir);
            
            // Prepare environment with source access token
            const sourceEnv = { ...process.env };
            if (sourceConfig.accessToken) {
                sourceEnv.SUPABASE_ACCESS_TOKEN = sourceConfig.accessToken;
            }
            
            if (linkProject(SOURCE_REF, sourceConfig.dbPassword, sourceConfig.accessToken)) {
                try {
                    logInfo(`  Getting list of functions from source project...`);
                    // Get list of all functions
                    let functionsList = '';
                    try {
                        functionsList = execSync(`supabase functions list`, {
                            stdio: 'pipe',
                            timeout: 30000,
                            encoding: 'utf8',
                            env: sourceEnv
                        });
                    } catch (e) {
                        logWarning(`  Could not list functions: ${e.message}`);
                        functionsList = '';
                    }
                    
                    // Parse function names from the list
                    const functionNames = functionsList.split('\n')
                        .map(line => line.trim())
                        .filter(line => line && !line.startsWith('NAME') && !line.startsWith('---') && !line.includes('│') && !line.startsWith('└') && !line.startsWith('├'))
                        .map(line => {
                            // Extract function name (first column, before any spaces or special chars)
                            const parts = line.split(/\s+/);
                            const name = parts[0];
                            return name && name.length > 0 && !name.includes('─') ? name : null;
                        })
                        .filter(name => name && name !== 'NAME');
                    
                    if (functionNames.length > 0) {
                        logInfo(`  Found ${functionNames.length} function(s), downloading to collect shared files...`);
                        // Download each function to collect shared files
                        for (const funcName of functionNames) {
                            try {
                                execSync(`supabase functions download ${funcName}`, {
                                    stdio: 'pipe',
                                    timeout: 60000,
                                    env: sourceEnv
                                });
                            } catch (e) {
                                // Continue with other functions if one fails
                            }
                        }
                    } else {
                        logWarning(`  No functions found in project or could not parse function list`);
                    }
                    
                    // Check for shared files in multiple locations
                    const downloadedSharedDir = path.join(tempDownloadDir, 'supabase', 'functions', '_shared');
                    const allFunctionsDir = path.join(tempDownloadDir, 'supabase', 'functions');
                    
                    // First check global _shared directory
                    if (fs.existsSync(downloadedSharedDir)) {
                        const downloadedFiles = fs.readdirSync(downloadedSharedDir).filter(f => {
                            const filePath = path.join(downloadedSharedDir, f);
                            try {
                                return fs.statSync(filePath).isFile();
                            } catch {
                                return false;
                            }
                        });
                        if (downloadedFiles.length > 0) {
                            logInfo(`  Found ${downloadedFiles.length} shared file(s) in global _shared: ${downloadedFiles.join(', ')}`);
                            if (!fs.existsSync(SHARED_DIR)) {
                                fs.mkdirSync(SHARED_DIR, { recursive: true });
                            }
                            mergeDirectories(downloadedSharedDir, SHARED_DIR);
                            localSharedFiles = downloadedFiles;
                            logInfo(`  ✓ Copied shared files from source project`);
                        }
                    }
                    
                    // Also check each function's _shared directory
                    if (fs.existsSync(allFunctionsDir)) {
                        const entries = fs.readdirSync(allFunctionsDir, { withFileTypes: true });
                        for (const entry of entries) {
                            if (entry.isDirectory() && entry.name !== '_shared') {
                                const funcSharedDir = path.join(allFunctionsDir, entry.name, '_shared');
                                if (fs.existsSync(funcSharedDir)) {
                                    const files = fs.readdirSync(funcSharedDir).filter(f => {
                                        const filePath = path.join(funcSharedDir, f);
                                        try {
                                            return fs.statSync(filePath).isFile();
                                        } catch {
                                            return false;
                                        }
                                    });
                                    if (files.length > 0) {
                                        logInfo(`  Found ${files.length} shared file(s) in ${entry.name}/_shared: ${files.join(', ')}`);
                                        if (!fs.existsSync(SHARED_DIR)) {
                                            fs.mkdirSync(SHARED_DIR, { recursive: true });
                                        }
                                        mergeDirectories(funcSharedDir, SHARED_DIR);
                                        // Add to localSharedFiles if not already there
                                        files.forEach(file => {
                                            if (!localSharedFiles.includes(file)) {
                                                localSharedFiles.push(file);
                                            }
                                        });
                                        logInfo(`  ✓ Copied shared files from ${entry.name}`);
                                    }
                                }
                            }
                        }
                    }
                    
                    if (localSharedFiles.length > 0) {
                        logInfo(`  ✓ Total ${localSharedFiles.length} shared file(s) collected: ${localSharedFiles.join(', ')}`);
                    }
                } catch (e) {
                    logWarning(`  Could not download all functions: ${e.message}`);
                }
            }
        } finally {
            process.chdir(originalCwd);
            fs.rmSync(tempDownloadDir, { recursive: true, force: true });
        }
    }

    // Process each function
    for (let i = 0; i < functionsToMigrate.length; i++) {
        const functionName = functionsToMigrate[i];
        logInfo(`[${i + 1}/${functionsToMigrate.length}] Processing: ${functionName}`);

        try {
            // Download function
            logInfo(`  Downloading ${functionName} from source...`);
            await downloadFunctionWithShared(functionName, SOURCE_REF, FUNCTIONS_DIR, sourceConfig.dbPassword, sourceConfig.accessToken);

            const functionDir = path.join(FUNCTIONS_DIR, functionName);
            if (!fs.existsSync(functionDir)) {
                throw new Error('Function directory not found after download');
            }
            
            // Ensure local shared files are in the function directory (highest priority)
            if (localSharedFiles.length > 0) {
                const functionSharedDir = path.join(functionDir, '_shared');
                if (!fs.existsSync(functionSharedDir)) {
                    fs.mkdirSync(functionSharedDir, { recursive: true });
                }
                mergeDirectories(localSharedDir, functionSharedDir);
                logInfo(`  ✓ Copied ${localSharedFiles.length} shared file(s) from local repository to function directory`);
            }

            // Check if shared files were downloaded
            logInfo(`  Checking for shared files...`);
            const globalSharedFiles = fs.existsSync(SHARED_DIR) 
                ? fs.readdirSync(SHARED_DIR).filter(f => {
                    const filePath = path.join(SHARED_DIR, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                })
                : [];
            
            if (globalSharedFiles.length > 0) {
                logInfo(`  Found ${globalSharedFiles.length} shared file(s) in global directory: ${globalSharedFiles.join(', ')}`);
            } else {
                logWarning(`  ⚠ No shared files found in global directory`);
            }

            // Check function code to see what shared files it needs
            const indexPath = path.join(functionDir, 'index.ts');
            const indexJsPath = path.join(functionDir, 'index.js');
            let functionCode = '';
            if (fs.existsSync(indexPath)) {
                functionCode = fs.readFileSync(indexPath, 'utf8');
            } else if (fs.existsSync(indexJsPath)) {
                functionCode = fs.readFileSync(indexJsPath, 'utf8');
            }
            
            // Extract shared file imports - capture just the filename
            // Extract shared file imports - match patterns like: "../_shared/emailConfig.ts", "./_shared/emailConfig.ts", "_shared/emailConfig.ts"
            const sharedImports = functionCode.match(/["']\.?\.?\/_shared\/([^"']+)["']/g);
            const neededFiles = sharedImports ? sharedImports.map(imp => {
                // Extract filename from import path - the capture group gets everything after _shared/
                const match = imp.match(/["']\.?\.?\/_shared\/([^"']+)["']/);
                if (match && match[1]) {
                    // Return just the filename (e.g., "emailConfig.ts")
                    // match[1] should already be just the filename since the regex captures after _shared/
                    const filename = match[1].trim();
                    // Safety check: remove any accidental _shared/ prefix if somehow included
                    return filename.replace(/^_shared\//, '');
                }
                return null;
            }).filter(Boolean) : [];
            
            if (neededFiles.length > 0) {
                logInfo(`  Function requires shared files: ${neededFiles.join(', ')}`);
            }

            // Bundle shared files into function directory
            logInfo(`  Bundling shared files into function directory...`);
            const functionSharedDir = path.join(functionDir, '_shared');
            
            // Priority 1: Use local repository shared files (most reliable source)
            if (localSharedFiles.length > 0) {
                if (!fs.existsSync(functionSharedDir)) {
                    fs.mkdirSync(functionSharedDir, { recursive: true });
                }
                mergeDirectories(localSharedDir, functionSharedDir);
                logInfo(`  ✓ Copied ${localSharedFiles.length} shared file(s) from local repository: ${localSharedFiles.join(', ')}`);
            }
            
            // Priority 2: Bundle from global shared directory (from downloads)
            if (fs.existsSync(SHARED_DIR)) {
                const globalFiles = fs.readdirSync(SHARED_DIR).filter(f => {
                    const filePath = path.join(SHARED_DIR, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                });
                if (globalFiles.length > 0) {
                    if (!fs.existsSync(functionSharedDir)) {
                        fs.mkdirSync(functionSharedDir, { recursive: true });
                    }
                    mergeDirectories(SHARED_DIR, functionSharedDir);
                    logInfo(`  ✓ Merged ${globalFiles.length} shared file(s) from global directory`);
                }
            }
            
            // Priority 3: Search other locations if still missing
            if (!fs.existsSync(functionSharedDir) || fs.readdirSync(functionSharedDir).length === 0) {
                if (neededFiles.length > 0) {
                    logInfo(`  Searching for required shared files in other locations...`);
                    const searchPaths = [
                        path.join(LOCAL_FUNCTIONS_DIR, '_shared'),
                        path.join(LOCAL_FUNCTIONS_DIR, functionName, '_shared'),
                        path.join(functionDir, 'functions', '_shared'),
                        path.join(FUNCTIONS_DIR, '_shared'),
                        path.join(PROJECT_ROOT, 'supabase', 'functions', '_shared')
                    ];
                    let foundInLocal = false;
                    for (const searchPath of searchPaths) {
                        if (fs.existsSync(searchPath)) {
                            const files = fs.readdirSync(searchPath).filter(f => {
                                const filePath = path.join(searchPath, f);
                                try {
                                    return fs.statSync(filePath).isFile();
                                } catch {
                                    return false;
                                }
                            });
                            if (files.length > 0) {
                                logInfo(`  Found ${files.length} shared file(s) at: ${path.relative(PROJECT_ROOT, searchPath)}`);
                                if (!fs.existsSync(functionSharedDir)) {
                                    fs.mkdirSync(functionSharedDir, { recursive: true });
                                }
                                mergeDirectories(searchPath, functionSharedDir);
                                logInfo(`  ✓ Copied shared files from ${path.relative(PROJECT_ROOT, searchPath)} to function directory`);
                                foundInLocal = true;
                                break;
                            }
                        }
                    }
                    
                    if (!foundInLocal && neededFiles.length > 0) {
                        logError(`  ✗ Shared files not found in any location`);
                        logError(`  Required files: ${neededFiles.join(', ')}`);
                        logError(`  Searched in:`);
                        searchPaths.forEach(p => logError(`    - ${p}`));
                        logError(`  Please ensure shared files are available. Options:`);
                        logError(`    1. Copy shared files from source project repository to: ${functionSharedDir}`);
                        logError(`    2. Download a function that uses shared files to get them:`);
                        logError(`       supabase functions download <function-with-shared-files> --project-ref ${SOURCE_REF}`);
                        throw new Error(`Function ${functionName} requires shared files but none were found: ${neededFiles.join(', ')}`);
                    }
                }
            }
            
            // Verify shared files are present
            if (fs.existsSync(functionSharedDir)) {
                const finalFiles = fs.readdirSync(functionSharedDir).filter(f => {
                    const filePath = path.join(functionSharedDir, f);
                    try {
                        return fs.statSync(filePath).isFile();
                    } catch {
                        return false;
                    }
                });
                if (finalFiles.length > 0) {
                    logInfo(`  ✓ Final check: ${finalFiles.length} shared file(s) ready: ${finalFiles.join(', ')}`);
                    // Verify all needed files are present
                    if (neededFiles.length > 0) {
                        const missingFiles = neededFiles.filter(needed => !finalFiles.includes(needed));
                        if (missingFiles.length > 0) {
                            logError(`  ✗ Missing required shared files: ${missingFiles.join(', ')}`);
                            throw new Error(`Missing required shared files: ${missingFiles.join(', ')}`);
                        }
                    }
                } else if (neededFiles.length > 0) {
                    logError(`  ✗ Shared files directory exists but is empty - required files: ${neededFiles.join(', ')}`);
                    throw new Error(`Shared files not found: ${neededFiles.join(', ')}`);
                }
            } else if (neededFiles.length > 0) {
                logError(`  ✗ Shared files directory not created - required files: ${neededFiles.join(', ')}`);
                throw new Error(`Shared files not found: ${neededFiles.join(', ')}`);
            }

            // Deploy to target
            logInfo(`  Deploying to target...`);
            await deployFunctionWithShared(functionName, functionDir, TARGET_REF, targetConfig.dbPassword, targetConfig.accessToken);

            migrated.push(functionName);
        } catch (error) {
            logError(`  ✗ Failed to migrate ${functionName}: ${error.message}`);
            failed.push(functionName);
        }

        console.log('');
    }

    // Summary
    logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    logInfo('  Migration Summary');
    logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    logSuccess(`Migrated: ${migrated.length}`);
    if (failed.length > 0) {
        logError(`Failed: ${failed.length} - ${failed.join(', ')}`);
    }
    console.log('');

    // Write results
    const resultFile = path.join(MIGRATION_DIR, 'shared_functions_migration_result.json');
    fs.writeFileSync(resultFile, JSON.stringify({
        timestamp: new Date().toISOString(),
        sourceRef: SOURCE_REF,
        targetRef: TARGET_REF,
        migrated,
        failed
    }, null, 2));

    if (failed.length > 0) {
        process.exit(1);
    }
}

function getEnvName(ref) {
    const prodRef = process.env.SUPABASE_PROD_PROJECT_REF || '';
    const testRef = process.env.SUPABASE_TEST_PROJECT_REF || '';
    const devRef = process.env.SUPABASE_DEV_PROJECT_REF || '';
    
    if (ref === prodRef) return 'PROD';
    if (ref === testRef) return 'TEST';
    if (ref === devRef) return 'DEV';
    return 'BACKUP';
}

main().catch(error => {
    logError(`Fatal error: ${error.message}`);
    process.exit(1);
});

