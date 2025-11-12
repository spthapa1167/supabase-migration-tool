#!/usr/bin/env node

/**
 * Edge Function Comparison Utility
 *
 * Usage: node utils/edge-functions-compare.js <source_env> <target_env> [output_dir]
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { createManagementClient } = require('./lib/edgeFunctionsClient');
const { ensureSupabaseCli, ensureDockerRunning, downloadEdgeFunctionWithCli } = require('./lib/edgeFunctionsCli');
const PROJECT_ROOT = path.resolve(__dirname, '..');

const COLORS = {
    reset: '\x1b[0m',
    blue: '\x1b[34m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    red: '\x1b[31m'
};

const logInfo = (msg) => console.error(`${COLORS.blue}[INFO]${COLORS.reset} ${msg}`);
const logSuccess = (msg) => console.error(`${COLORS.green}[SUCCESS]${COLORS.reset} ${msg}`);
const logWarning = (msg) => console.error(`${COLORS.yellow}[WARNING]${COLORS.reset} ${msg}`);
const logError = (msg) => console.error(`${COLORS.red}[ERROR]${COLORS.reset} ${msg}`);

const loadEnvFile = () => {
    for (const file of ['.env.local', '.env']) {
        if (!fs.existsSync(file)) continue;
        const raw = fs.readFileSync(file, 'utf8');
        raw.split('\n').forEach((line) => {
            if (!line || line.trim().startsWith('#')) return;
            const idx = line.indexOf('=');
            if (idx === -1) return;
            const key = line.slice(0, idx).trim();
            let value = line.slice(idx + 1).trim();
            if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith('\'') && value.endsWith('\''))) {
                value = value.slice(1, -1);
            }
            process.env[key] = value;
        });
        logInfo(`Loaded environment variables from ${file}`);
        break;
    }
};

loadEnvFile();

const SOURCE_ENV = process.argv[2];
const TARGET_ENV = process.argv[3];
const OUTPUT_DIR = path.resolve(process.argv[4] || path.join(process.cwd(), 'migration_plans'));

if (!SOURCE_ENV || !TARGET_ENV) {
    logError('Usage: node utils/edge-functions-compare.js <source_env> <target_env> [output_dir]');
    process.exit(1);
}

if (SOURCE_ENV === TARGET_ENV) {
    logError('Source and target environments must be different');
    process.exit(1);
}

const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;
if (!ACCESS_TOKEN) {
    logError('SUPABASE_ACCESS_TOKEN not set in environment');
    process.exit(1);
}

const envToRef = (env) => {
    switch (env.toLowerCase()) {
        case 'prod':
        case 'production':
        case 'main':
            return process.env.SUPABASE_PROD_PROJECT_REF || '';
        case 'test':
        case 'staging':
            return process.env.SUPABASE_TEST_PROJECT_REF || '';
        case 'dev':
        case 'develop':
            return process.env.SUPABASE_DEV_PROJECT_REF || '';
        case 'backup':
        case 'bkup':
        case 'bkp':
            return process.env.SUPABASE_BACKUP_PROJECT_REF || '';
        default:
            return '';
    }
};

const envToPassword = (env) => {
    switch (env.toLowerCase()) {
        case 'prod':
        case 'production':
        case 'main':
            return process.env.SUPABASE_PROD_DB_PASSWORD || '';
        case 'test':
        case 'staging':
            return process.env.SUPABASE_TEST_DB_PASSWORD || '';
        case 'dev':
        case 'develop':
            return process.env.SUPABASE_DEV_DB_PASSWORD || '';
        case 'backup':
        case 'bkup':
        case 'bkp':
            return process.env.SUPABASE_BACKUP_DB_PASSWORD || '';
        default:
            return '';
    }
};

const SOURCE_REF = envToRef(SOURCE_ENV);
const TARGET_REF = envToRef(TARGET_ENV);
const SOURCE_PASSWORD = envToPassword(SOURCE_ENV);
const TARGET_PASSWORD = envToPassword(TARGET_ENV);

if (!SOURCE_REF || !TARGET_REF) {
    logError('Unable to resolve project references from environment variables');
    process.exit(1);
}

const commandExists = (cmd) => spawnSync('which', [cmd], { stdio: 'ignore' }).status === 0;

const HAS_DIFF = commandExists('diff');

if (!HAS_DIFF) {
    logWarning('The "diff" command is not available; diff output will be omitted.');
}

const cliLogger = {
    info: logInfo,
    success: logSuccess,
    warning: logWarning,
    error: logError
};

try {
    ensureSupabaseCli(cliLogger);
    ensureDockerRunning(cliLogger);
} catch (err) {
    process.exit(1);
}
const cleanupPath = (p) => {
    try {
        fs.rmSync(p, { recursive: true, force: true });
    } catch (_) { /* ignore */ }
};

const managementClient = createManagementClient(ACCESS_TOKEN);

const findFunctionDirectory = (rootDir, functionName) => {
    if (!rootDir || !fs.existsSync(rootDir)) return null;

    const directCandidates = [
        path.join(rootDir, 'supabase', 'functions', functionName),
        path.join(rootDir, functionName),
        rootDir
    ];

    for (const candidate of directCandidates) {
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
};

const downloadFunction = async (projectRef, env, functionName, password, baseDir) => {
    const functionDir = path.join(baseDir, functionName);
    cleanupPath(functionDir);
    fs.mkdirSync(functionDir, { recursive: true });

    try {
        if (managementClient) {
            const maxAttempts = 3;
            let apiSuccess = false;
            for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
                const apiTempDir = fs.mkdtempSync(path.join(os.tmpdir(), `edge-api-${env}-${functionName}-${attempt}-`));
                try {
                    cliLogger.info(`Downloading ${functionName} via Management API bundle (attempt ${attempt}/${maxAttempts})...`);
                    await managementClient.downloadFunctionCode(projectRef, functionName, apiTempDir);
                    const apiFunctionDir = findFunctionDirectory(apiTempDir, functionName);
                    if (apiFunctionDir) {
                        fs.rmSync(functionDir, { recursive: true, force: true });
                        fs.mkdirSync(functionDir, { recursive: true });
                        fs.cpSync(apiFunctionDir, functionDir, { recursive: true });
                        apiSuccess = true;
                        fs.rmSync(apiTempDir, { recursive: true, force: true });
                        break;
                    }
                    cliLogger.warning(`Management API bundle download succeeded but files not located for ${functionName}; retrying...`);
                } catch (apiError) {
                    cliLogger.warning(`Management API download attempt ${attempt}/${maxAttempts} failed for ${functionName}: ${apiError.message}`);
                } finally {
                    fs.rmSync(apiTempDir, { recursive: true, force: true });
                }
            }
            if (apiSuccess) {
                return { dir: functionDir, available: true };
            }
            cliLogger.warning(`Management API download exhausted retries for ${functionName}; falling back to CLI`);
        }

        downloadEdgeFunctionWithCli(projectRef, functionName, functionDir, password, cliLogger);
        return { dir: functionDir, available: true };
    } catch (err) {
        if (err && (err.notFound || err.status === 404)) {
            logWarning(`Edge function '${functionName}' not found in ${env}; treating as missing code.`);
            cleanupPath(functionDir);
            fs.mkdirSync(functionDir, { recursive: true });
            return { dir: functionDir, available: false };
        }
        const localDir = path.join(PROJECT_ROOT, 'supabase', 'functions', functionName);
        if (fs.existsSync(localDir)) {
            logWarning(`Using local repository copy for ${functionName} (download failed).`);
            cleanupPath(functionDir);
            fs.mkdirSync(functionDir, { recursive: true });
            fs.cpSync(localDir, functionDir, { recursive: true });
            return { dir: functionDir, available: true, localFallback: true };
        }
        throw err;
    }
};

const listFilesRecursive = (dir) => {
    const files = new Map();
    if (!fs.existsSync(dir)) return files;
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            for (const [rel, content] of listFilesRecursive(fullPath)) {
                files.set(path.join(entry.name, rel), content);
            }
        } else {
            const relPath = entry.name;
            const data = fs.readFileSync(fullPath, 'utf8').replace(/\r\n/g, '\n');
            files.set(relPath, data);
        }
    }
    return files;
};

const runDiff = (srcContent, tgtContent, relPath, name) => {
    if (!HAS_DIFF) return [];
    const srcTmp = path.join(os.tmpdir(), `edge-src-${Date.now()}-${Math.random()}`);
    const tgtTmp = path.join(os.tmpdir(), `edge-tgt-${Date.now()}-${Math.random()}`);
    fs.writeFileSync(srcTmp, srcContent, 'utf8');
    fs.writeFileSync(tgtTmp, tgtContent, 'utf8');
    const result = spawnSync('diff', ['-u', tgtTmp, srcTmp], { encoding: 'utf8' });
    cleanupPath(srcTmp);
    cleanupPath(tgtTmp);
    if (result.status === 0 || !result.stdout) return [];
    const header = [`--- target:${name}/${relPath}`, `+++ source:${name}/${relPath}`];
    return header.concat(result.stdout.trim().split('\n'));
};

const collectEnvironment = async (env, ref, password, tmpRoot) => {
    const envDir = path.join(tmpRoot, env);
    fs.mkdirSync(envDir, { recursive: true });

    logInfo(`Fetching edge functions from ${env} (${ref})`);
    const functions = await managementClient.fetchFunctionList(ref).catch((err) => {
        throw new Error(`Failed to fetch functions for ${env}: ${err.message}`);
    });

    const names = Array.isArray(functions) ? functions : [];
    names.sort();
    const codeDir = path.join(envDir, 'code');
    fs.mkdirSync(codeDir, { recursive: true });

    const availability = {};
    for (const name of names) {
        const result = await downloadFunction(ref, env, name, password, codeDir);
        availability[name] = result.available;
    }

    return {
        names,
        codeDir,
        availability
    };
};

(async function main() {
    const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'edge-compare-'));
    try {
        const [sourceData, targetData] = await Promise.all([
            collectEnvironment(SOURCE_ENV, SOURCE_REF, SOURCE_PASSWORD, tmpRoot),
            collectEnvironment(TARGET_ENV, TARGET_REF, TARGET_PASSWORD, tmpRoot)
        ]);

        const sourceMap = new Map();
        const targetMap = new Map();
        const sourceAvailability = sourceData.availability;
        const targetAvailability = targetData.availability;

        for (const name of sourceData.names) {
            sourceMap.set(name, listFilesRecursive(path.join(sourceData.codeDir, name)));
        }
        for (const name of targetData.names) {
            targetMap.set(name, listFilesRecursive(path.join(targetData.codeDir, name)));
        }

        const allNames = Array.from(new Set([...sourceMap.keys(), ...targetMap.keys()])).sort();

        const diffs = [];
        let adds = 0;
        let removes = 0;
        let modifies = 0;

        for (const name of allNames) {
            const srcFiles = sourceMap.get(name);
            const tgtFiles = targetMap.get(name);

            if (!srcFiles) {
                removes++;
                diffs.push({ function: name, type: 'remove', summary: 'Present only in target', diff: [] });
                continue;
            }
            if (!tgtFiles) {
                adds++;
                diffs.push({ function: name, type: 'add', summary: 'Present only in source', diff: [] });
                continue;
            }

            const filePaths = new Set([...srcFiles.keys(), ...tgtFiles.keys()]);
            let diffOutput = [];

            if (HAS_DIFF) {
                for (const relPath of filePaths) {
                    const srcContent = srcFiles.get(relPath) || '';
                    const tgtContent = tgtFiles.get(relPath) || '';
                    if (srcContent !== tgtContent) {
                        diffOutput = diffOutput.concat(runDiff(srcContent, tgtContent, relPath, name));
                    }
                }
            }

            if (!sourceAvailability[name] || !targetAvailability[name]) {
                modifies++;
                diffs.push({
                    function: name,
                    type: 'modify',
                    summary: sourceAvailability[name] && !targetAvailability[name]
                        ? 'Code missing in target (CLI download failed)'
                        : !sourceAvailability[name] && targetAvailability[name]
                            ? 'Code missing in source (CLI download failed)'
                            : 'Code unavailable in one or both environments',
                    diff: diffOutput
                });
                continue;
            }

            if (diffOutput.length > 0 || srcFiles.size !== tgtFiles.size) {
                modifies++;
                diffs.push({ function: name, type: 'modify', summary: 'Code differs', diff: diffOutput });
            }
        }

        const summary = {
            source_count: sourceData.names.length,
            target_count: targetData.names.length,
            adds,
            removes,
            modifies
        };

        fs.mkdirSync(OUTPUT_DIR, { recursive: true });
        const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '');
        const baseName = `edge_diff_${SOURCE_ENV}_to_${TARGET_ENV}_${timestamp}`;
        const jsonPath = path.join(OUTPUT_DIR, `${baseName}.json`);
        const htmlPath = path.join(OUTPUT_DIR, `${baseName}.html`);

        const payload = {
            source_env: SOURCE_ENV,
            target_env: TARGET_ENV,
            source_ref: SOURCE_REF,
            target_ref: TARGET_REF,
            generated_at: new Date().toISOString(),
            summary,
            edge_functions: diffs,
            source_functions: sourceData.names,
            target_functions: targetData.names
        };

        fs.writeFileSync(jsonPath, JSON.stringify(payload, null, 2), 'utf8');

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>Edge Function Comparison: ${SOURCE_ENV} → ${TARGET_ENV}</title>
<style>
body { font-family: 'Inter', sans-serif; background: #f8fafc; color: #0f172a; margin: 0; padding: 32px; }
.container { max-width: 960px; margin: 0 auto; background: white; border-radius: 24px; box-shadow: 0 24px 48px rgba(15, 23, 42, 0.12); padding: 32px; }
.metrics { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 32px; }
.metric-card { flex: 1 1 180px; background: linear-gradient(135deg, rgba(99,102,241,.1), rgba(129,140,248,.06)); border: 1px solid rgba(99,102,241,.2); border-radius: 16px; padding: 16px; }
.metric-card h3 { font-size: .85rem; letter-spacing: .04em; color: #4338ca; margin-bottom: 6px; text-transform: uppercase; }
.metric-card p { font-size: 1.6rem; font-weight: 700; color: #1e1b4b; }
.snapshots { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; margin-bottom: 32px; }
.snapshot-card { border: 1px solid rgba(148,163,184,.3); border-radius: 20px; padding: 20px; background: rgba(248,250,252,.9); }
.snapshot-card h3 { font-size: 1rem; font-weight: 600; margin-bottom: 12px; color: #1e1b4b; }
.snapshot-card ul { list-style: none; margin: 0; padding: 0; max-height: 220px; overflow-y: auto; }
.snapshot-card li { padding: 6px 10px; border-radius: 10px; background: rgba(148,163,184,.12); margin-bottom: 6px; color: #334155; font-size: .9rem; }
.edge-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
.edge-table th, .edge-table td { border: 1px solid rgba(148,163,184,.35); padding: 12px; text-align: left; vertical-align: top; }
.edge-table thead { background: rgba(99,102,241,.08); color: #312e81; }
.badge { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 999px; font-size: .75rem; font-weight: 600; }
.badge-add { background: rgba(34,197,94,.15); color: #166534; }
.badge-remove { background: rgba(248,113,113,.15); color: #991b1b; }
.badge-modify { background: rgba(251,191,36,.15); color: #92400e; }
pre { font-family: 'JetBrains Mono', monospace; font-size: .85rem; background: #0f172a; color: #e2e8f0; padding: 12px; border-radius: 12px; max-height: 240px; overflow-y: auto; white-space: pre-wrap; }
.no-diff { font-size: 1rem; color: #475569; margin-top: 8px; }
</style>
</head>
<body>
    <div class="container">
        <h1>Edge Function Comparison</h1>
        <p class="meta">Synchronize <strong>${SOURCE_ENV}</strong> → <strong>${TARGET_ENV}</strong></p>
        <div class="metrics">
            <div class="metric-card"><h3>Source Functions</h3><p>${summary.source_count}</p></div>
            <div class="metric-card"><h3>Target Functions</h3><p>${summary.target_count}</p></div>
            <div class="metric-card"><h3>To Deploy</h3><p>${summary.adds}</p></div>
            <div class="metric-card"><h3>To Redeploy</h3><p>${summary.modifies}</p></div>
            <div class="metric-card"><h3>Review Target-Only</h3><p>${summary.removes}</p></div>
        </div>
        <div class="snapshots">
            <div class="snapshot-card">
                <h3>Source (${SOURCE_ENV})</h3>
                <ul>${sourceData.names.length ? sourceData.names.map((name) => `<li>${name}</li>`).join('') : '<li><em>None detected</em></li>'}</ul>
            </div>
            <div class="snapshot-card">
                <h3>Target (${TARGET_ENV})</h3>
                <ul>${targetData.names.length ? targetData.names.map((name) => `<li>${name}</li>`).join('') : '<li><em>None detected</em></li>'}</ul>
            </div>
        </div>
        ${diffs.length ? `<table class="edge-table">
            <thead>
                <tr>
                    <th>Function</th>
                    <th>Action</th>
                    <th>Summary</th>
                    <th>Diff</th>
                </tr>
            </thead>
            <tbody>
                ${diffs.map((diff) => {
                    const badgeClass = diff.type === 'add' ? 'badge-add' : diff.type === 'remove' ? 'badge-remove' : 'badge-modify';
                    const badgeLabel = diff.type === 'add' ? 'Deploy' : diff.type === 'remove' ? 'Review' : 'Redeploy';
                    const diffText = diff.diff && diff.diff.length ? `<pre>${diff.diff.join('\n')}</pre>` : 'No diff available';
                    return `<tr>
                        <td>${diff.function}</td>
                        <td><span class="badge ${badgeClass}">${badgeLabel}</span></td>
                        <td>${diff.summary}</td>
                        <td>${diffText}</td>
                    </tr>`;
                }).join('')}
            </tbody>
        </table>` : '<p class="no-diff">No edge function differences detected.</p>'}
    </div>
</body>
</html>`;

        fs.writeFileSync(htmlPath, html, 'utf8');

        logSuccess('Edge function comparison completed');
        console.log(JSON.stringify({
            json_path: jsonPath,
            html_path: htmlPath,
            summary,
            log_status: 'completed'
        }));
        process.exit(0);
    } catch (error) {
        logError(error.message);
        console.log(JSON.stringify({ error: error.message, log_status: 'error' }));
        process.exit(1);
    } finally {
        cleanupPath(tmpRoot);
    }
})();
