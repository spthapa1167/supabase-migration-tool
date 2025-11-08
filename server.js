#!/usr/bin/env node
/**
 * Supabase Migration Tool - Web UI Server
 * Minimal Node.js server to manage migrations via web interface
 */

const express = require('express');
const { spawn, exec } = require('child_process');
const path = require('path');
const fs = require('fs').promises;
const cors = require('cors');
const dotenv = require('dotenv');
const openBrowser = (...args) => import('open').then(mod => mod.default(...args));

const app = express();
const PORT = process.env.PORT || 3000;
const PROJECT_ROOT = process.cwd();

const stripAnsi = (input = '') =>
    typeof input === 'string' ? input.replace(/\u001B\[[0-9;]*m/g, '') : '';

// Load environment variables from .env.local
dotenv.config({ path: path.join(PROJECT_ROOT, '.env.local') });

// Get access key from environment
const TOOL_UI_ACCESS_KEY = process.env.TOOL_UI_ACCESS_KEY || '';

// Middleware
app.use(cors());
app.use(express.json());

// Authentication middleware
function authenticate(req, res, next) {
    // Skip authentication for login endpoint, login page, and static assets
    if (req.path === '/api/auth/login' || 
        req.path === '/login.html' || 
        req.path === '/' ||
        req.path.startsWith('/login') ||
        !req.path.startsWith('/api')) {
        return next();
    }
    
    // Check for session token in header, query, or body
    const token = req.headers.authorization?.replace('Bearer ', '') || 
                  req.query.token || 
                  req.body.token;
    
    // If no access key is configured, allow all requests (development mode)
    if (!TOOL_UI_ACCESS_KEY) {
        return next();
    }
    
    if (!token || token !== TOOL_UI_ACCESS_KEY) {
        return res.status(401).json({ error: 'Unauthorized - Invalid or missing access key' });
    }
    
    next();
}

// Apply authentication to API routes (except login and delete endpoint which handles auth manually)
app.use('/api', (req, res, next) => {
    // Skip authentication for login endpoint
    if (req.path === '/auth/login') {
        return next();
    }
    // Skip authentication for delete endpoint (it handles auth manually with better logging)
    if (req.method === 'DELETE' && req.path.startsWith('/migration-plans/')) {
        return next();
    }
    authenticate(req, res, next);
});

// Serve static files (login page is public)
app.use(express.static(PROJECT_ROOT));

// Store active processes with metadata
const activeProcesses = new Map();

// Helper function to execute shell scripts with streaming
function executeScript(scriptPath, args = [], options = {}) {
    return new Promise((resolve, reject) => {
        const fullPath = path.join(PROJECT_ROOT, scriptPath);
        
        // Check if script exists
        fs.access(fullPath, fs.constants.F_OK)
            .then(() => {
                const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
                const allArgs = args.filter(arg => arg !== null && arg !== undefined);
                
                const child = spawn('bash', [fullPath, ...allArgs], {
                    cwd: PROJECT_ROOT,
                    env: { ...process.env, ...options.env || {} }
                });

                const output = {
                    processId,
                    stdout: '',
                    stderr: '',
                    exitCode: null,
                    status: 'running',
                    logs: [] // Store logs for streaming
                };

                // Handle stdout
                child.stdout.on('data', (data) => {
                    const text = data.toString();
                    output.stdout += text;
                    output.logs.push({ type: 'stdout', data: text, timestamp: Date.now() });
                    
                    // Emit to SSE if connected
                    if (options.sseCallback) {
                        options.sseCallback({ type: 'stdout', data: text });
                    }
                });

                // Handle stderr
                child.stderr.on('data', (data) => {
                    const text = data.toString();
                    output.stderr += text;
                    output.logs.push({ type: 'stderr', data: text, timestamp: Date.now() });
                    
                    // Emit to SSE if connected
                    if (options.sseCallback) {
                        options.sseCallback({ type: 'stderr', data: text });
                    }
                });

                child.on('close', (code) => {
                    output.exitCode = code;
                    output.status = code === 0 ? 'completed' : 'failed';
                    
                    // Emit completion
                    if (options.sseCallback) {
                        options.sseCallback({ type: 'complete', status: output.status, exitCode: code });
                    }
                    
                    activeProcesses.delete(processId);
                    resolve(output);
                });

                child.on('error', (error) => {
                    output.status = 'error';
                    output.error = error.message;
                    
                    // Emit error
                    if (options.sseCallback) {
                        options.sseCallback({ type: 'error', error: error.message });
                    }
                    
                    activeProcesses.delete(processId);
                    reject(output);
                });

                activeProcesses.set(processId, { child, output });
            })
            .catch(() => {
                reject({ error: `Script not found: ${scriptPath}` });
            });
    });
}

function normalizePathForClient(filePath) {
    return `/${path.relative(PROJECT_ROOT, filePath).split(path.sep).join('/')}`;
}

async function buildEdgeComparisonPayload(cleanOutput) {
    const diffMatch = cleanOutput.match(/EDGE_DIFF_JSON=([^\n]+)/);
    const reportMatch = cleanOutput.match(/EDGE_REPORT_HTML=([^\n]+)/);
    const sourceListMatch = cleanOutput.match(/EDGE_SOURCE_LIST=([^\n]+)/);
    const targetListMatch = cleanOutput.match(/EDGE_TARGET_LIST=([^\n]+)/);

    let diffPath = diffMatch ? diffMatch[1].trim() : null;
    let reportPath = reportMatch ? reportMatch[1].trim() : null;

    if (!diffPath && reportPath) {
        diffPath = reportPath.replace(/\.html?$/, '.json');
    }

    if (!diffPath) {
        throw new Error('Unable to determine diff JSON path from planner output');
    }

    const diffAbsolute = path.isAbsolute(diffPath)
        ? diffPath
        : path.join(PROJECT_ROOT, diffPath);

    const diffContent = await fs.readFile(diffAbsolute, 'utf-8');
    const plannerData = JSON.parse(diffContent);

    if (!reportPath && diffPath.endsWith('.json')) {
        reportPath = diffPath.replace(/\.json$/, '.html');
    }

    const reportAbsolute = reportPath
        ? (path.isAbsolute(reportPath) ? reportPath : path.join(PROJECT_ROOT, reportPath))
        : null;

    const plannerInventory = plannerData.edge_functions_snapshot || plannerData.edge_function_inventory || {};

    const defaultSourceSnapshot = Array.isArray(plannerInventory.source)
        ? plannerInventory.source
        : Array.isArray(plannerInventory.source_functions)
            ? plannerInventory.source_functions
            : [];

    const defaultTargetSnapshot = Array.isArray(plannerInventory.target)
        ? plannerInventory.target
        : Array.isArray(plannerInventory.target_functions)
            ? plannerInventory.target_functions
            : [];

    const deriveSnapshot = (types) => {
        const set = new Set();
        if (Array.isArray(plannerData.edge_functions)) {
            plannerData.edge_functions.forEach((item) => {
                const action = item.action || item.type;
                const name = item.function || item.name;
                if (name && types.includes(action)) {
                    set.add(name);
                }
            });
        }
        return Array.from(set).sort();
    };

    const parseSnapshotMatch = (match, fallbackList, deriveTypes) => {
        if (match) {
            try {
                const parsed = JSON.parse(match[1].trim());
                if (Array.isArray(parsed)) {
                    return parsed;
                }
            } catch (error) {
                console.warn('Unable to parse EDGE_*_LIST output', error);
            }
        }
        if (Array.isArray(fallbackList) && fallbackList.length > 0) {
            return fallbackList;
        }
        const derived = deriveSnapshot(deriveTypes);
        return derived.length ? derived : [];
    };

    const sourceSnapshot = parseSnapshotMatch(sourceListMatch, defaultSourceSnapshot, ['add', 'create', 'modify', 'update']);
    const targetSnapshot = parseSnapshotMatch(targetListMatch, defaultTargetSnapshot, ['modify', 'update', 'remove', 'delete']);

    const edgeFunctions = Array.isArray(plannerData.edge_functions)
        ? plannerData.edge_functions.map((item) => ({
              name: item.function,
              action: item.type,
              diff: Array.isArray(item.diff) ? item.diff : [],
              diffPreview: Array.isArray(item.diff) ? item.diff.slice(0, 120) : []
          }))
        : [];

    const summary = {
        add: plannerData.summary?.edge_add ?? 0,
        remove: plannerData.summary?.edge_remove ?? 0,
        modify: plannerData.summary?.edge_modify ?? 0,
        total: edgeFunctions.length
    };

    return {
        summary,
        edgeFunctions,
        reportUrl: reportAbsolute ? normalizePathForClient(reportAbsolute) : null,
        diffJsonUrl: normalizePathForClient(diffAbsolute),
        generatedAt: plannerData.generated_at,
        sourceEnv: plannerData.source_env,
        targetEnv: plannerData.target_env,
        sourceSnapshot,
        targetSnapshot,
        logs: cleanOutput
    };
}

// API Routes

// Get server info
app.get('/api/info', (req, res) => {
    // Get app name (check both spellings for backward compatibility)
    const appName = process.env.SUPABASE_APP_NAME || process.env.SUPABSE_APP_NAME || 'Supabase Migration Tool';
    
    res.json({
        name: 'Supabase Migration Tool',
        version: '2.0',
        projectRoot: PROJECT_ROOT,
        appName: appName,
        environments: {
            prod: {
                name: 'Production',
                projectName: process.env.SUPABASE_PROD_PROJECT_NAME || 'N/A',
                projectRef: process.env.SUPABASE_PROD_PROJECT_REF || 'N/A',
                poolerRegion: process.env.SUPABASE_PROD_POOLER_REGION || 'aws-1-us-east-2',
                poolerPort: process.env.SUPABASE_PROD_POOLER_PORT || '6543'
            },
            test: {
                name: 'Test/Staging',
                projectName: process.env.SUPABASE_TEST_PROJECT_NAME || 'N/A',
                projectRef: process.env.SUPABASE_TEST_PROJECT_REF || 'N/A',
                poolerRegion: process.env.SUPABASE_TEST_POOLER_REGION || 'aws-1-us-east-2',
                poolerPort: process.env.SUPABASE_TEST_POOLER_PORT || '6543'
            },
            dev: {
                name: 'Development',
                projectName: process.env.SUPABASE_DEV_PROJECT_NAME || 'N/A',
                projectRef: process.env.SUPABASE_DEV_PROJECT_REF || 'N/A',
                poolerRegion: process.env.SUPABASE_DEV_POOLER_REGION || 'aws-1-us-east-2',
                poolerPort: process.env.SUPABASE_DEV_POOLER_PORT || '6543'
            },
            backup: {
                name: 'Backup',
                projectName: process.env.SUPABASE_BACKUP_PROJECT_NAME || 'N/A',
                projectRef: process.env.SUPABASE_BACKUP_PROJECT_REF || 'N/A',
                poolerRegion: process.env.SUPABASE_BACKUP_POOLER_REGION || 'aws-1-us-east-2',
                poolerPort: process.env.SUPABASE_BACKUP_POOLER_PORT || '6543'
            }
        },
        scripts: {
            main: 'scripts/supabase_migration.sh',
            plan: 'scripts/migration_plan.sh',
            database: 'scripts/components/database_migration.sh',
            storage: 'scripts/components/storage_buckets_migration.sh',
            edgeFunctions: 'scripts/components/edge_functions_migration.sh',
            secrets: 'scripts/components/secrets_migration.sh'
        }
    });
});

// Get list of backups/migrations
app.get('/api/migrations', async (req, res) => {
    try {
        const backupsDir = path.join(PROJECT_ROOT, 'backups');
        const plansDir = path.join(PROJECT_ROOT, 'migration_plans');
        
        const migrations = [];
        const plans = [];

        // Get migrations
        try {
            const backupDirs = await fs.readdir(backupsDir);
            for (const dir of backupDirs) {
                const dirPath = path.join(backupsDir, dir);
                const stat = await fs.stat(dirPath);
                if (stat.isDirectory()) {
                    const reportPath = path.join(dirPath, 'result.html');
                    const logPath = path.join(dirPath, 'migration.log');
                    const reportExists = await fs.access(reportPath).then(() => true).catch(() => false);
                    const logExists = await fs.access(logPath).then(() => true).catch(() => false);
                    
                    migrations.push({
                        name: dir,
                        path: `/backups/${dir}`,
                        reportPath: reportExists ? `/backups/${dir}/result.html` : null,
                        logPath: logExists ? `/backups/${dir}/migration.log` : null,
                        timestamp: stat.mtime
                    });
                }
            }
        } catch (err) {
            // backups directory doesn't exist yet
        }

        // Get migration plans
        try {
            const planFiles = await fs.readdir(plansDir);
            for (const file of planFiles) {
                if (file.endsWith('.html')) {
                    const filePath = path.join(plansDir, file);
                    const stat = await fs.stat(filePath);
                    plans.push({
                        name: file,
                        path: `/migration_plans/${file}`,
                        timestamp: stat.mtime
                    });
                }
            }
        } catch (err) {
            // migration_plans directory doesn't exist yet
        }

        res.json({ migrations, plans });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Delete migration plan
app.delete('/api/migration-plans/:planName', async (req, res) => {
    // Authentication is handled by the global middleware, but we check here too for safety
    const token = req.headers.authorization?.replace('Bearer ', '') || 
                  req.query.token || 
                  req.body.token;
    
    if (TOOL_UI_ACCESS_KEY && (!token || token !== TOOL_UI_ACCESS_KEY)) {
        console.log('[DELETE] Authentication failed - missing or invalid token');
        return res.status(401).json({ error: 'Unauthorized - Invalid or missing access key' });
    }
    
    try {
        // Decode the plan name (it may be URL encoded)
        const planName = decodeURIComponent(req.params.planName);
        console.log(`[DELETE] Attempting to delete plan: "${planName}"`);
        
        const plansDir = path.join(PROJECT_ROOT, 'migration_plans');
        const planPath = path.join(plansDir, planName);
        
        console.log(`[DELETE] Plans directory: ${plansDir}`);
        console.log(`[DELETE] Full plan path: ${planPath}`);
        
        // Security check: ensure the file is within the plans directory
        // Use resolve to get absolute paths for comparison
        const resolvedPlanPath = path.resolve(planPath);
        const resolvedPlansDir = path.resolve(plansDir);
        
        console.log(`[DELETE] Resolved plan path: ${resolvedPlanPath}`);
        console.log(`[DELETE] Resolved plans dir: ${resolvedPlansDir}`);
        
        if (!resolvedPlanPath.startsWith(resolvedPlansDir)) {
            console.error(`[DELETE] Security check failed: path traversal attempt detected`);
            return res.status(400).json({ error: 'Invalid plan name - security check failed' });
        }
        
        // Check if file exists
        try {
            const stats = await fs.stat(planPath);
            console.log(`[DELETE] Plan file exists: ${planPath} (${stats.size} bytes)`);
        } catch (err) {
            console.error(`[DELETE] Plan file not found: ${planPath}`, err.message);
            return res.status(404).json({ error: `Plan not found: ${planName}` });
        }
        
        // Delete the file
        console.log(`[DELETE] Deleting file: ${planPath}`);
        await fs.unlink(planPath);
        console.log(`[DELETE] Successfully deleted plan: ${planPath}`);
        
        res.json({ message: 'Plan deleted successfully', planName: planName });
    } catch (error) {
        console.error('[DELETE] Error deleting plan:', error);
        console.error('[DELETE] Error stack:', error.stack);
        res.status(500).json({ error: error.message || 'Failed to delete plan' });
    }
});

// Get migration log
app.get('/api/migrations/:migrationName/log', async (req, res) => {
    try {
        const logPath = path.join(PROJECT_ROOT, 'backups', req.params.migrationName, 'migration.log');
        const content = await fs.readFile(logPath, 'utf-8');
        res.json({ content });
    } catch (error) {
        // Try alternative log file names
        try {
            const altLogPath = path.join(PROJECT_ROOT, 'backups', req.params.migrationName, 'duplication.log');
            const content = await fs.readFile(altLogPath, 'utf-8');
            res.json({ content });
        } catch (altError) {
            res.status(404).json({ error: 'Log not found' });
        }
    }
});

// Get migration report
app.get('/api/migrations/:migrationName/report', async (req, res) => {
    try {
        const reportPath = path.join(PROJECT_ROOT, 'backups', req.params.migrationName, 'result.html');
        const content = await fs.readFile(reportPath, 'utf-8');
        res.send(content);
    } catch (error) {
        res.status(404).send('<html><body><h1>Report not found</h1></body></html>');
    }
});

// Execute migration plan with streaming
app.post('/api/migration-plan', async (req, res) => {
    const { sourceEnv, targetEnv, outputDir, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const args = [sourceEnv, targetEnv];
        if (outputDir) {
            args.push(outputDir);
        }

        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        // SSE callback
        const sseCallback = (data) => {
            res.write(`data: ${JSON.stringify(data)}\n\n`);
        };

        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/migration_plan.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'migration-plan',
                sourceEnv,
                targetEnv,
                startTime: new Date().toISOString()
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        const args = [sourceEnv, targetEnv];
        if (outputDir) {
            args.push(outputDir);
        }

        try {
            const result = await executeScript('scripts/migration_plan.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Execute main migration with streaming
app.post('/api/migration', async (req, res) => {
    const { sourceEnv, targetEnv, options = {}, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    const args = [sourceEnv, targetEnv];
    
    // Always add --auto-confirm for web UI (non-interactive)
    args.push('--auto-confirm');
    
    if (options.data) args.push('--data');
    if (options.users) args.push('--users');
    if (options.files) args.push('--files');
    if (options.backup) args.push('--backup');
    if (options.dryRun) args.push('--dry-run');

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/supabase_migration.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'main-migration',
                sourceEnv,
                targetEnv,
                options,
                startTime: new Date().toISOString(),
                endpoint: '/api/migration'
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        try {
            const result = await executeScript('scripts/supabase_migration.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Execute database migration with streaming
app.post('/api/migration/database', async (req, res) => {
    const { sourceEnv, targetEnv, migrationDir, options = {}, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    const args = [sourceEnv, targetEnv];
    if (migrationDir) args.push(migrationDir);
    if (options.data) args.push('--data');
    if (options.users) args.push('--users');
    if (options.backup) args.push('--backup');

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/components/database_migration.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'database-migration',
                sourceEnv,
                targetEnv,
                options,
                startTime: new Date().toISOString(),
                endpoint: '/api/migration/database'
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        try {
            const result = await executeScript('scripts/components/database_migration.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Execute storage migration with streaming
app.post('/api/migration/storage', async (req, res) => {
    const { sourceEnv, targetEnv, migrationDir, options = {}, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    const args = [sourceEnv, targetEnv];
    if (migrationDir) args.push(migrationDir);
    if (options.files) args.push('--file');

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/components/storage_buckets_migration.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'storage-migration',
                sourceEnv,
                targetEnv,
                options,
                startTime: new Date().toISOString(),
                endpoint: '/api/migration/storage'
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        try {
            const result = await executeScript('scripts/components/storage_buckets_migration.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Execute edge functions migration with streaming
app.post('/api/migration/edge-functions', async (req, res) => {
    const { sourceEnv, targetEnv, migrationDir, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    const args = [sourceEnv, targetEnv];
    if (migrationDir) args.push(migrationDir);

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/components/edge_functions_migration.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'edge-functions-migration',
                sourceEnv,
                targetEnv,
                startTime: new Date().toISOString(),
                endpoint: '/api/migration/edge-functions'
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        try {
            const result = await executeScript('scripts/components/edge_functions_migration.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Execute secrets migration with streaming
app.post('/api/migration/secrets', async (req, res) => {
    const { sourceEnv, targetEnv, migrationDir, options = {}, stream } = req.body;
    
    if (!sourceEnv || !targetEnv) {
        return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
    }

    const args = [sourceEnv, targetEnv];
    if (migrationDir) args.push(migrationDir);
    if (options.values) args.push('--values');

    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/components/secrets_migration.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const allArgs = args.filter(arg => arg !== null && arg !== undefined);
            const child = spawn('bash', [fullPath, ...allArgs], {
                cwd: PROJECT_ROOT,
                env: process.env
            });

            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };

            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });

            // Store process with metadata
            activeProcesses.set(processId, { 
                child, 
                output,
                type: 'secrets-migration',
                sourceEnv,
                targetEnv,
                options,
                startTime: new Date().toISOString(),
                endpoint: '/api/migration/secrets'
            });
            
            req.on('close', () => {
                if (child && !child.killed) {
                    child.kill();
                }
                activeProcesses.delete(processId);
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming mode
        try {
            const result = await executeScript('scripts/components/secrets_migration.sh', args);
            res.json(result);
        } catch (error) {
            res.status(500).json(error);
        }
    }
});

// Authentication endpoint (public - no auth required)
app.post('/api/auth/login', (req, res) => {
    const { accessKey } = req.body;
    
    if (!accessKey) {
        return res.status(400).json({ error: 'Access key is required' });
    }
    
    if (!TOOL_UI_ACCESS_KEY) {
        // If no access key is configured, allow access (development mode)
        return res.json({ 
            success: true, 
            token: 'dev-token',
            message: 'Authentication successful (development mode - no access key configured)' 
        });
    }
    
    if (accessKey === TOOL_UI_ACCESS_KEY) {
        res.json({ 
            success: true, 
            token: TOOL_UI_ACCESS_KEY,
            message: 'Authentication successful' 
        });
    } else {
        res.status(401).json({ error: 'Invalid access key' });
    }
});

// Get all active jobs
app.get('/api/jobs/active', (req, res) => {
    const jobs = [];
    
    activeProcesses.forEach((process, processId) => {
        if (process.output && process.output.status === 'running') {
            jobs.push({
                processId,
                type: process.type || 'unknown',
                sourceEnv: process.sourceEnv || 'N/A',
                targetEnv: process.targetEnv || 'N/A',
                startTime: process.startTime || new Date().toISOString(),
                status: process.output.status,
                endpoint: process.endpoint || '/api/process/' + processId
            });
        }
    });
    
    res.json({ jobs });
});

// Stream migration logs (for real-time updates)
app.get('/api/migration/:processId/logs', (req, res) => {
    const { processId } = req.params;
    const process = activeProcesses.get(processId);
    
    if (!process) {
        return res.status(404).json({ error: 'Process not found' });
    }

    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    // Send current output
    if (process.output.stdout) {
        res.write(`data: ${JSON.stringify({ type: 'stdout', data: process.output.stdout })}\n\n`);
    }
    if (process.output.stderr) {
        res.write(`data: ${JSON.stringify({ type: 'stderr', data: process.output.stderr })}\n\n`);
    }

    // Watch for new output
    const interval = setInterval(() => {
        if (process.output.status !== 'running') {
            clearInterval(interval);
            res.write(`data: ${JSON.stringify({ type: 'complete', status: process.output.status, exitCode: process.output.exitCode })}\n\n`);
            res.end();
        }
    }, 1000);

    req.on('close', () => {
        clearInterval(interval);
    });
});

// Test connection for an environment
// Generate snapshot for all environments
app.post('/api/all-envs-snapshot', async (req, res) => {
    const { stream } = req.body;
    
    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/all_envs_snapshot.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const child = spawn('bash', [fullPath, 'snapshots'], {
                cwd: PROJECT_ROOT,
                env: process.env,
                stdio: ['pipe', 'pipe', 'pipe']
            });
            
            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };
            
            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });
            
            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });
            
            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                
                // Try to find the generated snapshot file
                const snapshotsDir = path.join(PROJECT_ROOT, 'snapshots');
                fs.readdir(snapshotsDir)
                    .then(files => {
                        const snapshotFiles = files.filter(f => f.startsWith('all_envs_snapshot_') && f.endsWith('.json'));
                        snapshotFiles.sort().reverse(); // Get most recent first
                        
                        if (snapshotFiles.length > 0) {
                            const latestSnapshot = path.join(snapshotsDir, snapshotFiles[0]);
                            return fs.readFile(latestSnapshot, 'utf8');
                        }
                        return null;
                    })
                    .then(snapshotData => {
                        if (snapshotData) {
                            try {
                                const snapshotJson = JSON.parse(snapshotData);
                                res.write(`data: ${JSON.stringify({ type: 'snapshot', data: snapshotJson })}\n\n`);
                            } catch (e) {
                                // Ignore parse errors
                            }
                        }
                        res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                        res.end();
                    })
                    .catch(() => {
                        res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                        res.end();
                    });
            });
            
            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });
            
            // Store process
            activeProcesses.set(processId, {
                child,
                output,
                type: 'all-envs-snapshot',
                startTime: new Date().toISOString(),
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming response - execute and return snapshot data
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/all_envs_snapshot.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const { exec } = require('child_process');
            const { promisify } = require('util');
            const execAsync = promisify(exec);
            
            await execAsync(`bash "${fullPath}" snapshots`, {
                cwd: PROJECT_ROOT,
                env: process.env
            });
            
            // Read the latest snapshot file
            const snapshotsDir = path.join(PROJECT_ROOT, 'snapshots');
            const files = await fs.readdir(snapshotsDir);
            const snapshotFiles = files.filter(f => f.startsWith('all_envs_snapshot_') && f.endsWith('.json'));
            snapshotFiles.sort().reverse();
            
            if (snapshotFiles.length > 0) {
                const latestSnapshot = path.join(snapshotsDir, snapshotFiles[0]);
                const snapshotData = await fs.readFile(latestSnapshot, 'utf8');
                const snapshotJson = JSON.parse(snapshotData);
                res.json(snapshotJson);
            } else {
                res.status(500).json({ error: 'Snapshot file not found' });
            }
        } catch (error) {
            res.status(500).json({ error: error.message });
        }
    }
});

app.post('/api/connection-test', async (req, res) => {
    const { env, stream } = req.body;
    
    if (!env) {
        return res.status(400).json({ error: 'env is required' });
    }
    
    // If streaming requested, use SSE
    if (stream === true) {
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        
        const processId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        try {
            const fullPath = path.join(PROJECT_ROOT, 'scripts/components/connection_test.sh');
            await fs.access(fullPath, fs.constants.F_OK);
            
            const child = spawn('bash', [fullPath, env, '--verbose'], {
                cwd: PROJECT_ROOT,
                env: process.env,
                stdio: ['pipe', 'pipe', 'pipe']
            });
            
            const output = {
                processId,
                stdout: '',
                stderr: '',
                exitCode: null,
                status: 'running'
            };
            
            child.stdout.on('data', (data) => {
                const text = data.toString();
                output.stdout += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });
            
            child.stderr.on('data', (data) => {
                const text = data.toString();
                output.stderr += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });
            
            child.on('close', (code) => {
                output.exitCode = code;
                output.status = code === 0 ? 'completed' : 'failed';
                res.write(`data: ${JSON.stringify({ type: 'complete', status: output.status, exitCode: code })}\n\n`);
                res.end();
            });
            
            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.end();
            });
            
            // Store process
            activeProcesses.set(processId, {
                child,
                output,
                type: 'connection-test',
                env: env,
                startTime: new Date().toISOString(),
            });
        } catch (error) {
            res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
            res.end();
        }
    } else {
        // Non-streaming response (not typically used for this endpoint)
        res.status(400).json({ error: 'Streaming is required for connection tests' });
    }
});

app.post('/api/edge-comparison', async (req, res) => {
    try {
        const { sourceEnv, targetEnv, stream } = req.body || {};

        if (!sourceEnv || !targetEnv) {
            return res.status(400).json({ error: 'sourceEnv and targetEnv are required' });
        }

        if (sourceEnv === targetEnv) {
            return res.status(400).json({ error: 'sourceEnv and targetEnv must be different' });
        }

        const args = [sourceEnv, targetEnv];
        const scriptPath = path.join(PROJECT_ROOT, 'scripts/components/compare_edge_functions.sh');

        if (stream === true) {
            res.setHeader('Content-Type', 'text/event-stream');
            res.setHeader('Cache-Control', 'no-cache');
            res.setHeader('Connection', 'keep-alive');

            try {
                await fs.access(scriptPath, fs.constants.F_OK);
            } catch (error) {
                res.write(`data: ${JSON.stringify({ type: 'error', error: 'compare_edge_functions.sh not found' })}\n\n`);
                res.write(`data: ${JSON.stringify({ type: 'complete', status: 'error' })}\n\n`);
                res.end();
                return;
            }

            const child = spawn('bash', [scriptPath, ...args], {
                cwd: PROJECT_ROOT,
                env: { ...process.env }
            });

            let stdoutBuffer = '';
            let stderrBuffer = '';

            child.stdout.on('data', (chunk) => {
                const text = chunk.toString();
                stdoutBuffer += text;
                res.write(`data: ${JSON.stringify({ type: 'stdout', data: text })}\n\n`);
            });

            child.stderr.on('data', (chunk) => {
                const text = chunk.toString();
                stderrBuffer += text;
                res.write(`data: ${JSON.stringify({ type: 'stderr', data: text })}\n\n`);
            });

            child.on('close', async (code) => {
                const combinedOutput = `${stdoutBuffer}\n${stderrBuffer}`;
                const cleanOutput = stripAnsi(combinedOutput);

                if (code === 0) {
                    try {
                        const payload = await buildEdgeComparisonPayload(cleanOutput);
                        payload.status = 'completed';
                        res.write(`data: ${JSON.stringify({ type: 'result', data: payload })}\n\n`);
                    } catch (error) {
                        res.write(`data: ${JSON.stringify({ type: 'error', error: error.message, logs: cleanOutput })}\n\n`);
                    }
                } else {
                    res.write(`data: ${JSON.stringify({ type: 'error', error: `Edge comparison failed with exit code ${code}`, exitCode: code, logs: cleanOutput })}\n\n`);
                }

                res.write(`data: ${JSON.stringify({ type: 'complete', status: code === 0 ? 'completed' : 'failed', exitCode: code })}\n\n`);
                res.end();
            });

            child.on('error', (error) => {
                res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
                res.write(`data: ${JSON.stringify({ type: 'complete', status: 'error' })}\n\n`);
                res.end();
            });

            req.on('close', () => {
                if (!child.killed) {
                    child.kill();
                }
            });

            return;
        }

        const result = await executeScript('scripts/components/compare_edge_functions.sh', args);
        const combinedOutput = `${result.stdout || ''}\n${result.stderr || ''}`;
        const cleanOutput = stripAnsi(combinedOutput);
        const payload = await buildEdgeComparisonPayload(cleanOutput);

        res.json({
            status: result.status,
            ...payload
        });
    } catch (error) {
        console.error('Edge comparison error:', error);
        res.status(500).json({ error: error.message || 'Failed to generate edge comparison' });
    }
});

// Get process status
app.get('/api/process/:processId', (req, res) => {
    const { processId } = req.params;
    const process = activeProcesses.get(processId);
    
    if (!process) {
        return res.status(404).json({ error: 'Process not found' });
    }

    res.json(process.output);
});

// Kill process
app.delete('/api/process/:processId', (req, res) => {
    const { processId } = req.params;
    const process = activeProcesses.get(processId);
    
    if (!process) {
        return res.status(404).json({ error: 'Process not found' });
    }

    process.child.kill();
    activeProcesses.delete(processId);
    res.json({ message: 'Process killed' });
});

// Serve login page as default
app.get('/', (req, res) => {
    res.sendFile(path.join(PROJECT_ROOT, 'login.html'));
});

// Serve main UI page (public - authentication handled client-side)
app.get('/app', (req, res) => {
    res.sendFile(path.join(PROJECT_ROOT, 'ui.html'));
});

// Serve static files for reports and logs
app.use('/backups', express.static(path.join(PROJECT_ROOT, 'backups')));
app.use('/migration_plans', express.static(path.join(PROJECT_ROOT, 'migration_plans')));

// Start server
app.listen(PORT, () => {
    console.log(`🚀 Supabase Migration Tool - Web UI Server`);
    console.log(`   Server running on http://localhost:${PORT}`);
    console.log(`   Project root: ${PROJECT_ROOT}`);
    
    // Open browser to login page automatically
    const url = `http://localhost:${PORT}`;
    
    // Small delay to ensure server is fully ready
    setTimeout(() => {
        openBrowser(url).then(() => {
            console.log(`   ✅ Opened login page in default browser`);
        }).catch((err) => {
            console.log(`   ⚠️  Could not open browser automatically: ${err.message}`);
            console.log(`   Please open ${url} manually in your browser`);
        });
    }, 500);
});

