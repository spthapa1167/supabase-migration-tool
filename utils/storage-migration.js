#!/usr/bin/env node
/**
 * Supabase Storage Migration Utility
 * Migrates storage buckets and files from source to target project
 * Uses @supabase/supabase-js library for all operations
 * 
 * Usage: node utils/storage-migration.js <source_ref> <target_ref> <migration_dir> [--include-files|--exclude-files]
 */

const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');
const path = require('path');

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
                    // Handle key=value format, supporting values with = signs
                    const equalIndex = trimmed.indexOf('=');
                    if (equalIndex > 0) {
                        const cleanKey = trimmed.substring(0, equalIndex).trim();
                        let value = trimmed.substring(equalIndex + 1).trim();
                        
                        // Remove surrounding quotes if present
                        if ((value.startsWith('"') && value.endsWith('"')) || 
                            (value.startsWith("'") && value.endsWith("'"))) {
                            value = value.slice(1, -1);
                        }
                        
                        // Only set if value is not empty (or if it's intentionally empty)
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
const INCLUDE_FILES = process.argv[5] !== '--exclude-files';
const FORCE_ALL_BUCKETS = process.argv.includes('--force-all') || process.argv.includes('--force') || process.argv.includes('--all-buckets') || process.argv.includes('--migrate-all');

// Get Supabase URLs and keys from environment
function getSupabaseConfig(projectRef) {
    // Determine environment name from project ref
    let envName = '';
    const prodRef = process.env.SUPABASE_PROD_PROJECT_REF || '';
    const testRef = process.env.SUPABASE_TEST_PROJECT_REF || '';
    const devRef = process.env.SUPABASE_DEV_PROJECT_REF || '';
    const backupRef = process.env.SUPABASE_BACKUP_PROJECT_REF || '';
    
    // Debug: Show what we're comparing
    logInfo(`Matching project ref: ${projectRef}`);
    logInfo(`  PROD ref: ${prodRef || 'NOT SET'} ${prodRef === projectRef ? '✓ MATCH' : ''}`);
    logInfo(`  TEST ref: ${testRef || 'NOT SET'} ${testRef === projectRef ? '✓ MATCH' : ''}`);
    logInfo(`  DEV ref: ${devRef || 'NOT SET'} ${devRef === projectRef ? '✓ MATCH' : ''}`);
    logInfo(`  BACKUP ref: ${backupRef || 'NOT SET'} ${backupRef === projectRef ? '✓ MATCH' : ''}`);
    
    if (prodRef === projectRef) {
        envName = 'PROD';
    } else if (testRef === projectRef) {
        envName = 'TEST';
    } else if (devRef === projectRef) {
        envName = 'DEV';
    } else if (backupRef === projectRef) {
        envName = 'BACKUP';
    }
    
    // Debug: Log which environment was detected
    if (envName) {
        logSuccess(`✓ Detected environment: ${envName} for project ref: ${projectRef}`);
    } else {
        logWarning(`✗ Could not determine environment name for project ref: ${projectRef}`);
    }
    
    // Try to get from environment-specific variables first
    let url = '';
    let anonKey = '';
    let serviceKey = '';
    let serviceKeySource = '';
    
    if (envName) {
        // Try environment-specific variables
        // URL: SUPABASE_PROD_URL, SUPABASE_TEST_URL, SUPABASE_DEV_URL
        const urlKey = `SUPABASE_${envName}_URL`;
        url = process.env[urlKey] || '';
        logInfo(`  Checking ${urlKey}: ${url ? 'FOUND' : 'NOT SET'}`);
        
        // Anon Key: SUPABASE_PROD_ANON_KEY, SUPABASE_TEST_ANON_KEY, SUPABASE_DEV_ANON_KEY
        const anonKeyKey = `SUPABASE_${envName}_ANON_KEY`;
        anonKey = process.env[anonKeyKey] || '';
        logInfo(`  Checking ${anonKeyKey}: ${anonKey ? 'FOUND' : 'NOT SET'}`);
        
        // Service Role Key: SUPABASE_PROD_SERVICE_ROLE_KEY, SUPABASE_TEST_SERVICE_ROLE_KEY, SUPABASE_DEV_SERVICE_ROLE_KEY, SUPABASE_BACKUP_SERVICE_ROLE_KEY
        const serviceKeyKey = `SUPABASE_${envName}_SERVICE_ROLE_KEY`;
        
        logInfo(`  Checking ${serviceKeyKey}: ${process.env[serviceKeyKey] ? 'FOUND (length: ' + process.env[serviceKeyKey].length + ')' : 'NOT SET'}`);
        
        if (process.env[serviceKeyKey]) {
            serviceKey = process.env[serviceKeyKey].trim();
            serviceKeySource = serviceKeyKey;
            // Validate JWT format (should start with "eyJ")
            if (!serviceKey.startsWith('eyJ')) {
                logWarning(`  ⚠ Service role key does not start with "eyJ" - may not be a valid JWT token`);
                logWarning(`  Key starts with: ${serviceKey.substring(0, Math.min(10, serviceKey.length))}...`);
            }
            logSuccess(`  ✓ Using service role key from: ${serviceKeySource}`);
        } else {
            logError(`  ✗ Service role key not found: ${serviceKeyKey}`);
        }
    }
    
    // Validate URL matches project ref, or construct URL from project ref (standard Supabase format)
    if (url) {
        // Extract project ref from URL if it's a Supabase URL
        const urlMatch = url.match(/https:\/\/([^\.]+)\.supabase\.co/);
        if (urlMatch && urlMatch[1] !== projectRef) {
            logWarning(`  URL project ref (${urlMatch[1]}) does not match provided project ref (${projectRef})`);
            logWarning(`  Overriding URL to match project ref: https://${projectRef}.supabase.co`);
            url = `https://${projectRef}.supabase.co`;
        }
    } else {
        url = `https://${projectRef}.supabase.co`;
        logInfo(`  Constructed URL from project ref: ${url}`);
    }
    
    // Get anon key from generic variables if env-specific not found
    if (!anonKey) {
        anonKey = process.env.SUPABASE_ANON_KEY || '';
        if (anonKey) {
            logInfo(`  Using generic SUPABASE_ANON_KEY`);
        }
    }
    
    // Get service role key from generic variable if env-specific not found
    if (!serviceKey) {
        if (process.env.SUPABASE_SERVICE_ROLE_KEY) {
            serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY.trim();
            serviceKeySource = 'SUPABASE_SERVICE_ROLE_KEY (generic)';
            // Validate JWT format
            if (!serviceKey.startsWith('eyJ')) {
                logWarning(`  ⚠ Generic service role key does not start with "eyJ" - may not be a valid JWT token`);
            }
            logInfo(`  Using generic SUPABASE_SERVICE_ROLE_KEY`);
        } else {
            logError(`  ✗ No service role key found for ${envName || 'project'}`);
        }
    }
    
    if (serviceKeySource) {
        logInfo(`  Final service role key source: ${serviceKeySource}`);
    }
    
    return { url, anonKey, serviceKey, envName };
}

// Validate arguments
if (!SOURCE_REF || !TARGET_REF || !MIGRATION_DIR) {
    logError('Missing required arguments');
    console.error(`Usage: node utils/storage-migration.js <source_ref> <target_ref> <migration_dir> [--include-files|--exclude-files]`);
    console.error('');
    console.error('Environment variables required in .env.local:');
    console.error('  - SUPABASE_PROD_PROJECT_REF, SUPABASE_TEST_PROJECT_REF, SUPABASE_DEV_PROJECT_REF, SUPABASE_BACKUP_PROJECT_REF');
    console.error('  - SUPABASE_PROD_URL, SUPABASE_TEST_URL, SUPABASE_DEV_URL, SUPABASE_BACKUP_URL (or auto-constructed)');
    console.error('  - SUPABASE_PROD_ANON_KEY, SUPABASE_TEST_ANON_KEY, SUPABASE_DEV_ANON_KEY, SUPABASE_BACKUP_ANON_KEY');
    console.error('  - SUPABASE_PROD_SERVICE_ROLE_KEY, SUPABASE_TEST_SERVICE_ROLE_KEY, SUPABASE_DEV_SERVICE_ROLE_KEY, SUPABASE_BACKUP_SERVICE_ROLE_KEY');
    console.error('');
    console.error('Note: URLs are automatically constructed from project refs as https://<project_ref>.supabase.co if not specified');
    process.exit(1);
}

// Validate migration directory
if (!fs.existsSync(MIGRATION_DIR)) {
    fs.mkdirSync(MIGRATION_DIR, { recursive: true });
    logInfo(`Created migration directory: ${MIGRATION_DIR}`);
}

// Initialize Supabase clients
const sourceConfig = getSupabaseConfig(SOURCE_REF);
const targetConfig = getSupabaseConfig(TARGET_REF);

// Debug: Show which environment variables were found
logSeparator();
logInfo(`${colors.bright}Configuration Summary${colors.reset}`);
logSeparator();
logInfo(`Source project ref: ${SOURCE_REF}`);
logInfo(`Target project ref: ${TARGET_REF}`);
logInfo(`Source config:`);
logInfo(`  URL: ${sourceConfig.url}`);
logInfo(`  Environment: ${sourceConfig.envName || 'UNKNOWN'}`);
logInfo(`  ServiceKey: ${sourceConfig.serviceKey ? '***' + sourceConfig.serviceKey.slice(-4) + ' (length: ' + sourceConfig.serviceKey.length + ')' : 'NOT SET'}`);
logInfo(`Target config:`);
logInfo(`  URL: ${targetConfig.url}`);
logInfo(`  Environment: ${targetConfig.envName || 'UNKNOWN'}`);
logInfo(`  ServiceKey: ${targetConfig.serviceKey ? '***' + targetConfig.serviceKey.slice(-4) + ' (length: ' + targetConfig.serviceKey.length + ')' : 'NOT SET'}`);
logSeparator();

if (!sourceConfig.serviceKey || !targetConfig.serviceKey) {
    logError('Service role keys not found in environment variables');
    logError('Please ensure service role keys are set in .env.local:');
    logError('  - SUPABASE_PROD_SERVICE_ROLE_KEY, SUPABASE_TEST_SERVICE_ROLE_KEY, SUPABASE_DEV_SERVICE_ROLE_KEY, SUPABASE_BACKUP_SERVICE_ROLE_KEY');
    logError('  - OR SUPABASE_SERVICE_ROLE_KEY (generic fallback)');
    process.exit(1);
}

// Verify URL format matches project ref
const sourceUrlMatch = sourceConfig.url.match(/https:\/\/([^\.]+)\.supabase\.co/);
const targetUrlMatch = targetConfig.url.match(/https:\/\/([^\.]+)\.supabase\.co/);
if (sourceUrlMatch && sourceUrlMatch[1] !== SOURCE_REF) {
    logWarning(`Source URL project ref (${sourceUrlMatch[1]}) does not match provided project ref (${SOURCE_REF})`);
}
if (targetUrlMatch && targetUrlMatch[1] !== TARGET_REF) {
    logWarning(`Target URL project ref (${targetUrlMatch[1]}) does not match provided project ref (${TARGET_REF})`);
}

// Create admin clients using @supabase/supabase-js library
// Using the service role key in JWT format - this bypasses RLS
logInfo(`Creating Supabase admin clients...`);
logInfo(`  Source URL: ${sourceConfig.url}`);
logInfo(`  Source Key: ${sourceConfig.serviceKey.substring(0, 20)}... (JWT format)`);
logInfo(`  Target URL: ${targetConfig.url}`);
logInfo(`  Target Key: ${targetConfig.serviceKey.substring(0, 20)}... (JWT format)`);

// Create clients with service role key (JWT format)
// Pattern: const supabase = createClient(supabaseUrl, supabaseKey)
// The service role key bypasses RLS (Row Level Security) policies
const sourceAdmin = createClient(sourceConfig.url, sourceConfig.serviceKey, {
    auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
    }
});

const targetAdmin = createClient(targetConfig.url, targetConfig.serviceKey, {
    auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
    }
});

// Get all buckets from a project using Supabase JS client
// Using the @supabase/supabase-js library as shown in the example
async function getBuckets(adminClient, projectName, projectUrl, serviceKey, envName) {
    try {
        logInfo(`Fetching buckets from ${projectName || 'project'}...`);
        
        // Use Supabase JS client's storage.listBuckets() method
        // The client is already initialized with the service role key which bypasses RLS
        logInfo(`  Using Supabase JS client to fetch buckets...`);
        logInfo(`  URL: ${projectUrl}`);
        logInfo(`  Service Key: ${serviceKey.substring(0, 20)}... (JWT format)`);
        
        const { data, error } = await adminClient.storage.listBuckets();
        
        if (error) {
            logError(`  Client error: ${error.message || JSON.stringify(error)}`);
            throw error;
        }
        
        const bucketList = Array.isArray(data) ? data : [];
        
        logSuccess(`Found ${bucketList.length} bucket(s) in ${projectName || 'project'}`);
        if (bucketList.length > 0) {
            bucketList.forEach((bucket, index) => {
                logInfo(`  ${index + 1}. ${bucket.name} (public: ${bucket.public || false})`);
            });
        }
        return bucketList;
    } catch (error) {
        logError(`Failed to get buckets from ${projectName || 'project'}`);
        logError(`  Error: ${error.message || JSON.stringify(error)}`);
        
        // Provide specific guidance for authentication errors
        if (error.message && (
            error.message.includes('signature') || 
            error.message.includes('JWT') || 
            error.message.includes('verification') ||
            error.message.includes('401') ||
            error.message.includes('403') ||
            error.message.includes('Invalid Compact JWS')
        )) {
            logError(`Authentication failed: Service role key may be invalid or does not match the project`);
            logError(`Please verify:`);
            if (envName) {
                logError(`  1. The service role key in .env.local matches the project (SUPABASE_${envName}_SERVICE_ROLE_KEY)`);
            } else {
                logError(`  1. The service role key in .env.local is set correctly (SUPABASE_PROD_SERVICE_ROLE_KEY, SUPABASE_TEST_SERVICE_ROLE_KEY, SUPABASE_DEV_SERVICE_ROLE_KEY, or SUPABASE_BACKUP_SERVICE_ROLE_KEY)`);
            }
            logError(`  2. The URL matches the project ref (https://<project_ref>.supabase.co)`);
            logError(`  3. The service role key is a valid JWT token (starts with "eyJ")`);
            logError(`  4. The service role key has not expired or been rotated`);
            logError(`  5. The service role key is for the correct project (check in Supabase Dashboard → Project Settings → API)`);
        }
        
        throw error; // Re-throw to indicate failure
    }
}

// Create bucket using multiple fallback methods
// Tries: 1) Supabase JS client, 2) REST API, 3) Direct SQL insert via PostgREST
async function createBucket(adminClient, projectUrl, serviceKey, bucketConfig) {
    // Method 1: Try Supabase JS client first (since listBuckets works with it)
    try {
        logInfo(`    Attempting Method 1: Supabase JS client...`);
        
        // Verify client is properly initialized
        if (!adminClient || !adminClient.storage) {
            throw new Error('Admin client not properly initialized');
        }
        
        const createOptions = {
            public: bucketConfig.public || false
        };
        
        const fileSizeLimit = bucketConfig.file_size_limit || bucketConfig.fileSizeLimit;
        if (fileSizeLimit !== null && fileSizeLimit !== undefined && fileSizeLimit !== '') {
            createOptions.fileSizeLimit = fileSizeLimit;
        }
        
        const allowedMimeTypes = bucketConfig.allowed_mime_types || bucketConfig.allowedMimeTypes;
        if (allowedMimeTypes !== null && allowedMimeTypes !== undefined && 
            (Array.isArray(allowedMimeTypes) ? allowedMimeTypes.length > 0 : allowedMimeTypes !== '')) {
            createOptions.allowedMimeTypes = allowedMimeTypes;
        }
        
        logInfo(`    Creating bucket with options: ${JSON.stringify(createOptions)}`);
        const { data, error } = await adminClient.storage.createBucket(bucketConfig.name, createOptions);
        
        if (!error && data) {
            logSuccess(`    ✓ Bucket created successfully using JS client`);
            return { success: true, bucket: data };
        }
        
        if (error) {
            logWarning(`    JS client failed: ${error.message || JSON.stringify(error)}`);
            if (error.statusCode) {
                logWarning(`    HTTP Status: ${error.statusCode}`);
            }
            // If it's an RLS error, the service role key might not be bypassing RLS for storage operations
            if (error.message && error.message.includes('row-level security')) {
                logWarning(`    Note: RLS policy is blocking bucket creation even with service role key`);
                logWarning(`    This may require manual bucket creation or RLS policy adjustment`);
            }
            // Continue to next method
        }
    } catch (error) {
        logWarning(`    JS client exception: ${error.message || JSON.stringify(error)}`);
        // Continue to next method
    }
    
    // Method 2: Try REST API with proper error handling
    try {
        logInfo(`    Attempting Method 2: Storage REST API...`);
        const https = require('https');
        const url = new URL(`${projectUrl}/storage/v1/bucket`);
        
        const requestBody = {
            id: bucketConfig.name,
            name: bucketConfig.name,
            public: bucketConfig.public || false
        };
        
        const fileSizeLimit = bucketConfig.file_size_limit || bucketConfig.fileSizeLimit;
        if (fileSizeLimit !== null && fileSizeLimit !== undefined && fileSizeLimit !== '') {
            requestBody.file_size_limit = fileSizeLimit;
        }
        
        const allowedMimeTypes = bucketConfig.allowed_mime_types || bucketConfig.allowedMimeTypes;
        if (allowedMimeTypes !== null && allowedMimeTypes !== undefined && 
            (Array.isArray(allowedMimeTypes) ? allowedMimeTypes.length > 0 : allowedMimeTypes !== '')) {
            requestBody.allowed_mime_types = allowedMimeTypes;
        }
        
        // Verify service key format
        if (!serviceKey || !serviceKey.startsWith('eyJ')) {
            logWarning(`    Service key format issue - skipping REST API method`);
            throw new Error('Invalid service key format');
        }
        
        const createResponse = await new Promise((resolve, reject) => {
            const req = https.request({
                hostname: url.hostname,
                port: 443,
                path: url.pathname,
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${serviceKey}`,
                    'apikey': serviceKey,
                    'Content-Type': 'application/json',
                    'Accept': 'application/json'
                }
            }, (res) => {
                let data = '';
                res.on('data', (chunk) => { data += chunk; });
                res.on('end', () => {
                    if (res.statusCode >= 200 && res.statusCode < 300) {
                        try {
                            const json = JSON.parse(data);
                            resolve({ data: json, statusCode: res.statusCode });
                        } catch (e) {
                            resolve({ data: { name: bucketConfig.name }, statusCode: res.statusCode });
                        }
                    } else {
                        let errorData = data;
                        let errorMessage = data;
                        try {
                            errorData = JSON.parse(data);
                            if (errorData.error) {
                                errorMessage = typeof errorData.error === 'string' ? errorData.error : 
                                    (errorData.error.message || JSON.stringify(errorData.error));
                            } else if (errorData.message) {
                                errorMessage = errorData.message;
                            } else {
                                errorMessage = JSON.stringify(errorData);
                            }
                        } catch (e) {
                            // Keep as string
                        }
                        reject({ statusCode: res.statusCode, data: errorData, message: errorMessage });
                    }
                });
            });
            
            req.on('error', (err) => {
                reject({ statusCode: 0, message: err.message, error: err });
            });
            
            req.write(JSON.stringify(requestBody));
            req.end();
        });
        
        logSuccess(`    ✓ Bucket created successfully using REST API`);
        return { success: true, bucket: createResponse.data };
        
    } catch (error) {
        logWarning(`    REST API failed: ${error.message || JSON.stringify(error)}`);
        if (error.statusCode === 401 || error.message.includes('Unauthorized')) {
            logWarning(`    Authentication failed - service role key may be invalid or expired`);
        }
        // Continue to next method
    }
    
    // Method 3: Skip - SQL execution via Supabase client is not available
    // Supabase doesn't expose a generic SQL execution RPC function
    // The SQL script will be provided in the error message for manual execution
    logInfo(`    Method 3: Skipped - SQL execution not available via API`);
    logInfo(`    SQL script will be provided for manual execution if all methods fail`);
    
    // All methods failed - provide comprehensive error message with SQL script
    const projectRef = projectUrl.match(/https:\/\/([^\.]+)\.supabase\.co/)?.[1] || 'unknown';
    const dashboardUrl = `https://supabase.com/dashboard/project/${projectRef}/storage/buckets`;
    
    // Generate SQL script for manual execution
    let sqlScript = `-- SQL script to create bucket: ${bucketConfig.name}\n`;
    sqlScript += `-- Run this in Supabase SQL Editor with service role key\n\n`;
    sqlScript += `INSERT INTO storage.buckets (id, name, public`;
    
    const fileSizeLimit = bucketConfig.file_size_limit || bucketConfig.fileSizeLimit;
    const hasFileSizeLimit = fileSizeLimit !== null && fileSizeLimit !== undefined && fileSizeLimit !== '';
    
    const allowedMimeTypes = bucketConfig.allowed_mime_types || bucketConfig.allowedMimeTypes;
    const hasMimeTypes = allowedMimeTypes !== null && allowedMimeTypes !== undefined && 
        (Array.isArray(allowedMimeTypes) ? allowedMimeTypes.length > 0 : allowedMimeTypes !== '');
    
    if (hasFileSizeLimit) {
        sqlScript += `, file_size_limit`;
    }
    if (hasMimeTypes) {
        sqlScript += `, allowed_mime_types`;
    }
    
    sqlScript += `)\nVALUES ('${bucketConfig.name}', '${bucketConfig.name}', ${bucketConfig.public || false}`;
    
    if (hasFileSizeLimit) {
        sqlScript += `, ${fileSizeLimit}`;
    }
    if (hasMimeTypes) {
        const mimeTypesJson = JSON.stringify(Array.isArray(allowedMimeTypes) ? allowedMimeTypes : [allowedMimeTypes]);
        sqlScript += `, '${mimeTypesJson}'::jsonb`;
    }
    
    sqlScript += `)\nON CONFLICT (id) DO NOTHING;`;
    
    logError(`Failed to create bucket ${bucketConfig.name} using all available methods`);
    logError(`  This indicates an RLS policy issue that cannot be bypassed programmatically`);
    logError(`  Solutions:`);
    logError(`    1. Manually create the bucket in Supabase Dashboard:`);
    logError(`       ${dashboardUrl}`);
    logError(`       - Bucket name: ${bucketConfig.name}`);
    logError(`       - Public: ${bucketConfig.public || false}`);
    logError(`    2. Run this SQL script in Supabase SQL Editor:`);
    logError(`       ${sqlScript.split('\n').map(line => `       ${line}`).join('\n')}`);
    logError(`    3. Check RLS policies on storage.buckets table in the target project`);
    logError(`    4. Verify the service role key is correct: Check Project Settings → API → service_role key`);
    
    return { 
        success: false, 
        error: { 
            message: 'All bucket creation methods failed. Manual creation required.',
            requiresManualCreation: true,
            bucketName: bucketConfig.name,
            dashboardUrl: dashboardUrl,
            sqlScript: sqlScript,
            bucketConfig: bucketConfig
        } 
    };
}

// List all files recursively in a bucket
async function listAllFilesRecursive(adminClient, bucketName, folder = '', files = []) {
    try {
        const { data, error } = await adminClient.storage.from(bucketName).list(folder);
        
        if (error) {
            throw error;
        }
        
        if (!data || data.length === 0) {
            return files;
        }
        
        for (const item of data) {
            if (item.id) {
                // It's a file
                files.push({
                    ...item,
                    path: folder ? `${folder}/${item.name}` : item.name
                });
            } else {
                // It's a folder, recursively list its contents
                const subFolderPath = folder ? `${folder}/${item.name}` : item.name;
                await listAllFilesRecursive(adminClient, bucketName, subFolderPath, files);
            }
        }
        
        return files;
    } catch (error) {
        logError(`Error listing files recursively in ${folder || 'root'}: ${error.message || error}`);
        return files;
    }
}

// Download file from source
async function downloadFile(adminClient, bucketName, filePath) {
    try {
        const { data, error } = await adminClient.storage.from(bucketName).download(filePath);
        
        if (error) {
            throw error;
        }
        
        // Convert blob to buffer
        const arrayBuffer = await data.arrayBuffer();
        return Buffer.from(arrayBuffer);
    } catch (error) {
        throw new Error(`Failed to download file ${filePath}: ${error.message || error}`);
    }
}

// Upload file to target
async function uploadFile(adminClient, bucketName, filePath, fileBuffer, contentType) {
    try {
        const { data, error } = await adminClient.storage
            .from(bucketName)
            .upload(filePath, fileBuffer, {
                contentType: contentType || 'application/octet-stream',
                upsert: true
            });
        
        if (error) {
            throw error;
        }
        
        return { success: true, data };
    } catch (error) {
        throw new Error(`Failed to upload file ${filePath}: ${error.message || error}`);
    }
}

// Save file to backup folder
function saveToBackup(backupDir, bucketName, filePath, fileBuffer) {
    const bucketBackupDir = path.join(backupDir, 'storage_files', bucketName);
    const fullFilePath = path.join(bucketBackupDir, filePath);
    const fileDir = path.dirname(fullFilePath);
    
    // Create directory structure
    if (!fs.existsSync(fileDir)) {
        fs.mkdirSync(fileDir, { recursive: true });
    }
    
    // Save file
    fs.writeFileSync(fullFilePath, fileBuffer);
    return fullFilePath;
}

// Format file size for display
function formatFileSize(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
}

function normalizeTimestamp(value) {
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
}

// Main migration function
async function migrateStorage() {
    logSeparator();
    logInfo(`${colors.bright}Supabase Storage Migration${colors.reset}`);
    logSeparator();
    logInfo(`Source: ${SOURCE_REF} (${sourceConfig.url})`);
    logInfo(`Target: ${TARGET_REF} (${targetConfig.url})`);
    logInfo(`Include Files: ${INCLUDE_FILES ? 'Yes' : 'No'}`);
    logInfo(`Migration Directory: ${MIGRATION_DIR}`);
    logSeparator();
    console.log('');
    
    // Track failed buckets for SQL script generation
    const failedBuckets = [];
    
    // Step 1: Get source buckets
    logStep(1, INCLUDE_FILES ? 4 : 2, 'Fetching source buckets...');
    let sourceBuckets = [];
    try {
        sourceBuckets = await getBuckets(sourceAdmin, 'Source', sourceConfig.url, sourceConfig.serviceKey, sourceConfig.envName);
        if (sourceBuckets.length === 0) {
            logWarning('No buckets found in source project');
        }
    } catch (error) {
        logError('Failed to fetch source buckets - cannot continue migration');
        throw error;
    }
    
    console.log('');
    
    // Step 2: Get target buckets
    logStep(2, INCLUDE_FILES ? 4 : 2, 'Fetching target buckets...');
    let targetBuckets = [];
    try {
        targetBuckets = await getBuckets(targetAdmin, 'Target', targetConfig.url, targetConfig.serviceKey, targetConfig.envName);
    } catch (error) {
        logError('Failed to fetch target buckets - cannot continue migration');
        throw error;
    }
    const targetBucketMap = new Map(targetBuckets.map(b => [b.name, b]));
    
    console.log('');
    logSeparator();
    logInfo(`${colors.bright}Starting Bucket Migration${colors.reset}`);
    logSeparator();
    console.log('');
    
    let migratedCount = 0;
    let filesMigratedCount = 0;
    let skippedCount = 0;
    
    // Step 3: Smart migration - compare buckets and files
    // Default behavior: Only migrate buckets that are new (exist in source but not in target)
    // With --files: Migrate all buckets with files
    for (let i = 0; i < sourceBuckets.length; i++) {
        const sourceBucket = sourceBuckets[i];
        const bucketName = sourceBucket.name;
        
        if (!bucketName) {
            logError(`Bucket ${i + 1} has no name: ${JSON.stringify(sourceBucket)}`);
            continue;
        }
        
        logInfo(`${colors.bright}Bucket ${i + 1}/${sourceBuckets.length}: ${bucketName}${colors.reset}`);
        logInfo(`  Source Configuration:`);
        logInfo(`    - Public: ${sourceBucket.public || false}`);
        logInfo(`    - File Size Limit: ${sourceBucket.file_size_limit || sourceBucket.fileSizeLimit || 'None'}`);
        logInfo(`    - Allowed MIME Types: ${sourceBucket.allowed_mime_types || sourceBucket.allowedMimeTypes || 'All'}`);
        
        // Check if bucket exists in target
        const existingBucket = targetBucketMap.get(bucketName);
        let bucketNeedsCreation = false;
        let bucketConfigMatches = false;
        let isNewBucket = false;
        
        if (existingBucket) {
            logInfo(`  Target Configuration:`);
            logInfo(`    - Public: ${existingBucket.public || false}`);
            logInfo(`    - File Size Limit: ${existingBucket.file_size_limit || existingBucket.fileSizeLimit || 'None'}`);
            logInfo(`    - Allowed MIME Types: ${existingBucket.allowed_mime_types || existingBucket.allowedMimeTypes || 'All'}`);
            
            // Compare bucket configurations
            const sourcePublic = sourceBucket.public || false;
            const targetPublic = existingBucket.public || false;
            const sourceSizeLimit = sourceBucket.file_size_limit || sourceBucket.fileSizeLimit || null;
            const targetSizeLimit = existingBucket.file_size_limit || existingBucket.fileSizeLimit || null;
            const sourceMimeTypes = sourceBucket.allowed_mime_types || sourceBucket.allowedMimeTypes || null;
            const targetMimeTypes = existingBucket.allowed_mime_types || existingBucket.allowedMimeTypes || null;
            
            bucketConfigMatches = (
                sourcePublic === targetPublic &&
                sourceSizeLimit === targetSizeLimit &&
                JSON.stringify(sourceMimeTypes) === JSON.stringify(targetMimeTypes)
            );
            
            if (bucketConfigMatches) {
                logSuccess(`  ✓ Bucket exists in target with matching configuration`);
            } else {
                logWarning(`  ⚠ Bucket exists in target but configuration differs - note: bucket updates via API are not supported`);
                logInfo(`    Continuing with file migration only...`);
            }
            
            // If files are not included AND force flag is not set, skip this bucket (it already exists)
            if (!INCLUDE_FILES && !FORCE_ALL_BUCKETS) {
                logInfo(`  ⏭️  Skipping bucket (already exists in target, and file migration not requested)`);
                logInfo(`      Use --force-all to migrate all buckets regardless of existence`);
                console.log('');
                continue;
            }
            
            // If force flag is set, we'll still process the bucket (for configuration sync)
            if (FORCE_ALL_BUCKETS && !INCLUDE_FILES) {
                logInfo(`  🔄 Force mode: Processing bucket for configuration sync (files not included)`);
            }
        } else {
            bucketNeedsCreation = true;
            isNewBucket = true;
            logInfo(`  ✓ Bucket does not exist in target - will create (new bucket)`);
        }
        
        // Step 4: Migrate files if requested
        let bucketFilesMigrated = 0;
        let bucketFilesSkipped = 0;
        let bucketCreated = false;
        
        if (INCLUDE_FILES) {
            // List source files first to get count
            logInfo(`  Analyzing files in source bucket...`);
            const sourceFiles = await listAllFilesRecursive(sourceAdmin, bucketName);
            
            // List target files for comparison
            let targetFiles = [];
            if (existingBucket) {
                logInfo(`  Analyzing files in target bucket...`);
                targetFiles = await listAllFilesRecursive(targetAdmin, bucketName);
            }
            
            const sourceFileCount = sourceFiles.length;
            const targetFileCount = targetFiles.length;
            
            logInfo(`  File count comparison:`);
            logInfo(`    Source: ${sourceFileCount} file(s)`);
            logInfo(`    Target: ${targetFileCount} file(s)`);
            
            // Create target file map for comparison
            const targetFileMap = new Map(targetFiles.map(f => [f.path, { 
                etag: f.etag || f.metadata?.etag || '', 
                size: f.metadata?.size ?? f.size ?? 0,
                updatedAt: normalizeTimestamp(f.updated_at ?? f.updatedAt ?? f.last_accessed_at ?? f.metadata?.last_modified ?? null)
            }]));
            
            // Compare files by ETag
            let filesToMigrate = [];
            let identicalFiles = 0;
            
            for (const sourceFile of sourceFiles) {
                const filePath = sourceFile.path;
                const sourceEtag = sourceFile.etag || sourceFile.metadata?.etag || '';
                const targetFile = targetFileMap.get(filePath);
                const targetEtag = targetFile?.etag || '';
                const sourceSize = sourceFile.metadata?.size ?? sourceFile.size ?? 0;
                const targetSize = targetFile?.size ?? 0;
                const sourceUpdated = normalizeTimestamp(sourceFile.updated_at ?? sourceFile.updatedAt ?? sourceFile.last_accessed_at ?? sourceFile.metadata?.last_modified ?? null);
                const targetUpdated = targetFile?.updatedAt ?? null;
                
                const etagMatch = Boolean(targetEtag && sourceEtag && targetEtag === sourceEtag);
                const sizeMatch = sourceSize === targetSize && sourceSize !== null;
                const updatedMatch = sourceUpdated !== null && targetUpdated !== null && sourceUpdated === targetUpdated;
                
                if (etagMatch || (sizeMatch && updatedMatch)) {
                    identicalFiles++;
                } else {
                    filesToMigrate.push(sourceFile);
                }
            }
            
            // Check if bucket is completely identical
            const filesIdentical = (sourceFileCount === targetFileCount && identicalFiles === sourceFileCount);
            const bucketIdentical = bucketConfigMatches && filesIdentical;
            
            if (bucketIdentical) {
                logSuccess(`  ✓ Bucket is identical (configuration + ${sourceFileCount} file(s)) - skipping migration`);
                skippedCount += sourceFileCount;
                console.log('');
                continue;
            }
            
            // If bucket doesn't exist and has files, create it
            if (bucketNeedsCreation) {
                logInfo(`  Creating bucket in target...`);
                const bucketConfig = {
                    name: bucketName,
                    public: sourceBucket.public || false,
                    file_size_limit: sourceBucket.file_size_limit || sourceBucket.fileSizeLimit || null,
                    allowed_mime_types: sourceBucket.allowed_mime_types || sourceBucket.allowedMimeTypes || null
                };
                
                const bucketResult = await createBucket(targetAdmin, targetConfig.url, targetConfig.serviceKey, bucketConfig);
                
                if (!bucketResult.success) {
                    logError(`  ✗ Failed to create bucket: ${bucketName}`);
                    if (bucketResult.error) {
                        if (bucketResult.error.requiresManualCreation) {
                            // Track failed bucket for SQL script generation
                            failedBuckets.push({
                                name: bucketResult.error.bucketName,
                                config: bucketResult.error.bucketConfig,
                                sqlScript: bucketResult.error.sqlScript,
                                dashboardUrl: bucketResult.error.dashboardUrl
                            });
                            
                            logError(`    ⚠ Manual creation required`);
                            logError(`    Option 1: Create in Supabase Dashboard:`);
                            logError(`      ${bucketResult.error.dashboardUrl}`);
                            logError(`      - Bucket name: ${bucketResult.error.bucketName}`);
                            logError(`      - Public: ${bucketConfig.public || false}`);
                            if (bucketResult.error.sqlScript) {
                                logError(`    Option 2: Run SQL script in Supabase SQL Editor (see SQL file at end)`);
                            }
                            logWarning(`  ⏭️  Skipping this bucket - SQL script will be saved for batch execution`);
                        } else {
                            logError(`    Error: ${bucketResult.error.message || JSON.stringify(bucketResult.error)}`);
                        }
                    }
                    continue;
                }
                
                bucketCreated = true;
                migratedCount++;
                logSuccess(`  ✓ Bucket created successfully`);
                
                // Wait a moment for bucket to be available
                logInfo(`  Waiting for bucket to be available...`);
                await new Promise(resolve => setTimeout(resolve, 2000));
            } else if (filesToMigrate.length > 0) {
                logInfo(`  Bucket exists - will migrate ${filesToMigrate.length} file(s) (${identicalFiles} identical, skipped)`);
            }
            
            // Migrate files if needed
            if (filesToMigrate.length > 0) {
                console.log('');
                logStep(4, 4, `Migrating ${filesToMigrate.length} file(s) for bucket: ${bucketName}...`);
                
                // Create backup directory
                const backupDir = path.join(MIGRATION_DIR, 'storage_files', bucketName);
                if (!fs.existsSync(backupDir)) {
                    fs.mkdirSync(backupDir, { recursive: true });
                    logInfo(`  Created backup directory: ${backupDir}`);
                }
                
                logInfo(`  Processing ${filesToMigrate.length} file(s) to migrate...`);
                console.log('');
                
                for (let j = 0; j < filesToMigrate.length; j++) {
                    const sourceFile = filesToMigrate[j];
                    const filePath = sourceFile.path;
                    const sourceSize = sourceFile.metadata?.size || sourceFile.size || 0;
                    
                    logInfo(`  [${j + 1}/${filesToMigrate.length}] ${filePath} (${formatFileSize(sourceSize)})`);
                    
                    try {
                        // Download from source
                        logInfo(`    ↓ Downloading from source...`);
                        const fileBuffer = await downloadFile(sourceAdmin, bucketName, filePath);
                        
                        // Save to backup
                        const backupPath = saveToBackup(MIGRATION_DIR, bucketName, filePath, fileBuffer);
                        logInfo(`    💾 Saved to backup: ${path.relative(MIGRATION_DIR, backupPath)}`);
                        
                        // Upload to target
                        logInfo(`    ↑ Uploading to target...`);
                        const contentType = sourceFile.metadata?.mimetype || sourceFile.metadata?.contentType || 'application/octet-stream';
                        await uploadFile(targetAdmin, bucketName, filePath, fileBuffer, contentType);
                        logSuccess(`    ✓ Migrated successfully`);
                        bucketFilesMigrated++;
                        filesMigratedCount++;
                    } catch (error) {
                        logError(`    ✗ Failed: ${error.message || error}`);
                    }
                    console.log('');
                }
            } else if (existingBucket) {
                logSuccess(`  ✓ All files are identical - no file migration needed`);
                skippedCount += identicalFiles;
            }
            
            // Summary for this bucket
            if (filesToMigrate.length > 0 || bucketCreated) {
                console.log('');
                logInfo(`  Summary for ${bucketName}:`);
                if (bucketCreated) {
                    logSuccess(`    ✓ Bucket created`);
                }
                if (bucketFilesMigrated > 0) {
                    logSuccess(`    ✓ Files migrated: ${bucketFilesMigrated}`);
                }
                if (identicalFiles > 0) {
                    logInfo(`    ○ Files skipped (identical): ${identicalFiles}`);
                }
            }
            console.log('');
        } else {
            // Files not included - only create NEW buckets (incremental mode)
            // This is the default behavior: only migrate bucket names that are newly added to source
            if (bucketNeedsCreation && isNewBucket) {
                logInfo(`  Creating new bucket in target (incremental mode: only new buckets)...`);
                const bucketConfig = {
                    name: bucketName,
                    public: sourceBucket.public || false,
                    file_size_limit: sourceBucket.file_size_limit || sourceBucket.fileSizeLimit || null,
                    allowed_mime_types: sourceBucket.allowed_mime_types || sourceBucket.allowedMimeTypes || null
                };
                
                const bucketResult = await createBucket(targetAdmin, targetConfig.url, targetConfig.serviceKey, bucketConfig);
                
                if (!bucketResult.success) {
                    logError(`  ✗ Failed to create bucket: ${bucketName}`);
                    if (bucketResult.error) {
                        if (bucketResult.error.requiresManualCreation) {
                            // Track failed bucket for SQL script generation
                            failedBuckets.push({
                                name: bucketResult.error.bucketName,
                                config: bucketResult.error.bucketConfig,
                                sqlScript: bucketResult.error.sqlScript,
                                dashboardUrl: bucketResult.error.dashboardUrl
                            });
                            
                            logError(`    ⚠ Manual creation required`);
                            logError(`    Option 1: Create in Supabase Dashboard:`);
                            logError(`      ${bucketResult.error.dashboardUrl}`);
                            logError(`      - Bucket name: ${bucketResult.error.bucketName}`);
                            logError(`      - Public: ${bucketConfig.public || false}`);
                            if (bucketResult.error.sqlScript) {
                                logError(`    Option 2: Run SQL script in Supabase SQL Editor (see SQL file at end)`);
                            }
                            logWarning(`  ⏭️  Skipping this bucket - SQL script will be saved for batch execution`);
                        } else {
                            logError(`    Error: ${bucketResult.error.message || JSON.stringify(bucketResult.error)}`);
                        }
                    }
                    continue;
                }
                
                migratedCount++;
                logSuccess(`  ✓ New bucket created successfully (bucket name only, no files)`);
            } else {
                // Bucket already exists - skip in default mode (no files) unless force flag is set
                if (!FORCE_ALL_BUCKETS) {
                    logInfo(`  ⏭️  Bucket already exists in target - skipping (use --files to migrate files or --force-all to sync all buckets)`);
                } else {
                    logInfo(`  🔄 Force mode: Bucket exists but will be processed for configuration sync`);
                }
            }
            console.log('');
        }
    }
    
    // Create README in backup folder
    if (INCLUDE_FILES && migratedCount > 0) {
        const readmePath = path.join(MIGRATION_DIR, 'storage_files', 'README.md');
        const readmeContent = `# Storage Files Backup

This folder contains files from source buckets for manual upload to target if needed.

## Migration Summary
- Source: ${SOURCE_REF} (${sourceConfig.url})
- Target: ${TARGET_REF} (${targetConfig.url})
- Buckets migrated: ${migratedCount}
- Files migrated: ${filesMigratedCount}
- Files skipped (identical): ${skippedCount}
- Date: ${new Date().toISOString()}

## Manual Upload Instructions

See individual bucket folders for files and upload instructions.

### Using Supabase Dashboard
1. Go to: ${targetConfig.url.replace('https://', 'https://supabase.com/dashboard/project/')}/storage/buckets
2. Select the bucket and upload files

### Using Supabase JS Client
\`\`\`javascript
const { createClient } = require('@supabase/supabase-js');
const supabase = createClient('${targetConfig.url}', 'YOUR_SERVICE_ROLE_KEY');

// Upload file
const { data, error } = await supabase.storage
  .from('bucket-name')
  .upload('file-path', fileBuffer, {
    contentType: 'application/octet-stream',
    upsert: true
  });
\`\`\`
`;
        fs.writeFileSync(readmePath, readmeContent);
        logInfo(`Created README: ${readmePath}`);
    }
    
    // Generate SQL script file for failed buckets
    if (failedBuckets.length > 0) {
        const sqlFilePath = path.join(MIGRATION_DIR, 'create_buckets.sql');
        let sqlContent = `-- SQL Script to Create Storage Buckets\n`;
        sqlContent += `-- Generated: ${new Date().toISOString()}\n`;
        sqlContent += `-- Source: ${SOURCE_REF} (${sourceConfig.url})\n`;
        sqlContent += `-- Target: ${TARGET_REF} (${targetConfig.url})\n`;
        sqlContent += `-- \n`;
        sqlContent += `-- Instructions:\n`;
        sqlContent += `-- 1. Open Supabase Dashboard → SQL Editor\n`;
        sqlContent += `-- 2. Copy and paste this entire script\n`;
        sqlContent += `-- 3. Run the script (it will create all buckets)\n`;
        sqlContent += `-- 4. Re-run the migration to transfer files\n`;
        sqlContent += `-- \n\n`;
        
        failedBuckets.forEach((bucket, index) => {
            sqlContent += `-- Bucket ${index + 1}/${failedBuckets.length}: ${bucket.name}\n`;
            sqlContent += bucket.sqlScript;
            sqlContent += `\n\n`;
        });
        
        fs.writeFileSync(sqlFilePath, sqlContent);
        logSeparator();
        logWarning(`${colors.bright}⚠ Manual Bucket Creation Required${colors.reset}`);
        logSeparator();
        logWarning(`${failedBuckets.length} bucket(s) could not be created automatically due to RLS policies`);
        logInfo(`SQL script saved to: ${sqlFilePath}`);
        logInfo(`Please run this script in Supabase SQL Editor, then re-run the migration`);
        logSeparator();
        console.log('');
    }
    
    console.log('');
    logSeparator();
    logSuccess(`${colors.bright}Migration Complete!${colors.reset}`);
    logSeparator();
    logSuccess(`Buckets migrated: ${migratedCount}`);
    if (failedBuckets.length > 0) {
        logWarning(`Buckets requiring manual creation: ${failedBuckets.length} (see create_buckets.sql)`);
    }
    if (INCLUDE_FILES) {
        logSuccess(`Files migrated: ${filesMigratedCount}`);
        logInfo(`Files skipped (identical): ${skippedCount}`);
    }
    logSeparator();
    
    return { 
        success: true, 
        buckets: migratedCount, 
        files: filesMigratedCount,
        failedBuckets: failedBuckets.length,
        sqlScriptPath: failedBuckets.length > 0 ? path.join(MIGRATION_DIR, 'create_buckets.sql') : null
    };
}

// Run migration
logInfo('Starting storage migration process...');
console.log('');

migrateStorage()
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
