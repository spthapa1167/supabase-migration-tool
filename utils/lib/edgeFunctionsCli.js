#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, execFileSync } = require('child_process');

const COLORS = {
    reset: '\x1b[0m',
    blue: '\x1b[34m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    red: '\x1b[31m'
};

const defaultLogger = {
    info: (msg) => console.error(`${COLORS.blue}[INFO]${COLORS.reset} ${msg}`),
    success: (msg) => console.error(`${COLORS.green}[SUCCESS]${COLORS.reset} ${msg}`),
    warning: (msg) => console.error(`${COLORS.yellow}[WARNING]${COLORS.reset} ${msg}`),
    error: (msg) => console.error(`${COLORS.red}[ERROR]${COLORS.reset} ${msg}`)
};

const ensureSupabaseCli = (logger = defaultLogger) => {
    try {
        execFileSync('supabase', ['--version'], { stdio: 'pipe', timeout: 5000 });
        return true;
    } catch (err) {
        logger.error('Supabase CLI not found. Please install it before running this command.');
        throw err;
    }
};

const ensureDockerRunning = (logger = defaultLogger) => {
    try {
        execFileSync('docker', ['ps'], { stdio: 'pipe', timeout: 5000 });
        return true;
    } catch (err) {
        logger.error('Docker is not running. Please start Docker Desktop and retry.');
        throw err;
    }
};

const linkProject = (projectRef, dbPassword, cwd, logger = defaultLogger) => {
    try {
        try {
            execFileSync('supabase', ['unlink', '--yes'], { stdio: 'pipe', timeout: 10000, cwd });
        } catch (_) {
            // already unlinked
        }

        if (dbPassword) {
            execFileSync('supabase', ['link', '--project-ref', projectRef, '--password', dbPassword], {
                stdio: 'pipe',
                timeout: 30000,
                cwd
            });
        } else {
            logger.warning('No database password provided; attempting CLI link without password.');
            execFileSync('supabase', ['link', '--project-ref', projectRef], {
                stdio: 'pipe',
                timeout: 30000,
                cwd
            });
        }
        return true;
    } catch (err) {
        logger.warning(`Unable to link Supabase CLI for ${projectRef}: ${err.message}`);
        return false;
    }
};

const resolveDownloadedPath = (workspace, functionName) => {
    const candidates = [
        path.join(workspace, 'supabase', 'functions', functionName),
        path.join(workspace, 'functions', functionName)
    ];

    for (const candidate of candidates) {
        if (fs.existsSync(candidate)) {
            return candidate;
        }
    }

    return null;
};

const downloadEdgeFunctionWithCli = (projectRef, functionName, destination, dbPassword, logger = defaultLogger) => {
    const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), `edge-cli-${functionName}-`));
    const originalCwd = process.cwd();

    try {
        const supabaseDir = path.join(tempRoot, 'supabase');
        const configDir = path.join(supabaseDir);
        const functionsDir = path.join(supabaseDir, 'functions');

        fs.mkdirSync(functionsDir, { recursive: true });
        fs.writeFileSync(path.join(supabaseDir, 'config.toml'), `project_id = "${projectRef}"\n`);

        process.chdir(tempRoot);

        logger.info(`Linking Supabase CLI to project ${projectRef}...`);
        if (!linkProject(projectRef, dbPassword, tempRoot, logger)) {
            const error = new Error('Failed to link project for Supabase CLI');
            error.linkFailed = true;
            throw error;
        }

        logger.info(`Downloading edge function ${functionName} via Supabase CLI...`);
        try {
            execFileSync('supabase', ['functions', 'download', functionName], {
                stdio: 'pipe',
                timeout: 60000
            });
        } catch (err) {
            const message = err.message || '';
            if (message.includes('Function not found') || message.includes('does not exist')) {
                const notFoundError = new Error(message);
                notFoundError.notFound = true;
                throw notFoundError;
            }
            logger.warning('Regular download failed, trying legacy bundle...');
            try {
                execFileSync('supabase', ['functions', 'download', '--legacy-bundle', functionName], {
                    stdio: 'pipe',
                    timeout: 60000
                });
            } catch (legacyErr) {
                const legacyMessage = legacyErr.message || '';
                if (legacyMessage.includes('Function not found') || legacyMessage.includes('does not exist')) {
                    const notFoundError = new Error(legacyMessage);
                    notFoundError.notFound = true;
                    throw notFoundError;
                }
                throw legacyErr;
            }
        }

        const downloadedPath = resolveDownloadedPath(tempRoot, functionName);
        if (!downloadedPath) {
            throw new Error('Downloaded function directory not found');
        }

        fs.rmSync(destination, { recursive: true, force: true });
        fs.mkdirSync(path.dirname(destination), { recursive: true });
        fs.renameSync(downloadedPath, destination);

        logger.success(`Downloaded function: ${functionName}`);
        return { path: destination, status: 'downloaded' };
    } catch (err) {
        throw err;
    } finally {
        process.chdir(originalCwd);
        fs.rmSync(tempRoot, { recursive: true, force: true });
    }
};

module.exports = {
    ensureSupabaseCli,
    ensureDockerRunning,
    downloadEdgeFunctionWithCli,
    defaultLogger
};

