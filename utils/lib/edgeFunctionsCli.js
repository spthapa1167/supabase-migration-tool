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

const runSupabaseCommand = (executable, args, options) => {
    try {
        execFileSync(executable, args, options);
        return { success: true };
    } catch (err) {
        return { success: false, error: err };
    }
};

const runSupabaseCommand = (executable, args, options) => {
    try {
        execFileSync(executable, args, options);
        return { success: true };
    } catch (err) {
        return { success: false, error: err };
    }
};

const runDockerSupabaseCommand = (tempRoot, projectRef, dbPassword, args, logger) => {
    const baseArgs = [
        'run',
        '--rm',
        '-v',
        `${tempRoot}:/workspace`,
        '-w',
        '/workspace'
    ];

    if (process.env.SUPABASE_ACCESS_TOKEN) {
        baseArgs.push('-e', `SUPABASE_ACCESS_TOKEN=${process.env.SUPABASE_ACCESS_TOKEN}`);
    }

    if (dbPassword) {
        baseArgs.push('-e', `SUPABASE_DB_PASSWORD=${dbPassword}`);
    }

    const dockerArgs = baseArgs.concat(['supabase/cli:latest']).concat(args);
    return runSupabaseCommand('docker', dockerArgs, {
        stdio: 'pipe',
        timeout: 120000
    });
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

        const runDownload = (cliExecutable, extraArgs = []) => {
            const args = ['functions', 'download', functionName, ...extraArgs];
            const result = runSupabaseCommand(cliExecutable, args, {
                stdio: 'pipe',
                timeout: 90000
            });
            if (!result.success) {
                const message = result.error?.message || '';
                if (message.includes('Function not found') || message.includes('does not exist')) {
                    const notFoundError = new Error(message);
                    notFoundError.notFound = true;
                    throw notFoundError;
                }
                return result.error;
            }
            return null;
        };

        logger.info(`Downloading edge function ${functionName} via Supabase CLI...`);
        let cliError = runDownload('supabase');
        const errorMessages = [];

        const formatError = (label, err) => {
            if (!err) return '';
            const stderr = err.stderr ? err.stderr.toString() : '';
            const stdout = err.stdout ? err.stdout.toString() : '';
            return `${label}:\n${err.message || ''}\n${stderr}\n${stdout}`;
        };

        if (cliError) {
            errorMessages.push(formatError('Supabase CLI', cliError));
            const combined = `${cliError.message || ''}\n${cliError.stderr ? cliError.stderr.toString() : ''}\n${cliError.stdout ? cliError.stdout.toString() : ''}`;
            if (/invalid eszip/i.test(combined) || /legacy[- ]bundle/i.test(combined) || /eszip v2/i.test(combined) || /docker/i.test(combined)) {
                logger.warning('Regular download failed, trying legacy bundle...');
                const legacyError = runDownload('supabase', ['--legacy-bundle']);
                if (!legacyError) {
                    cliError = null;
                } else {
                    errorMessages.push(formatError('Supabase CLI --legacy-bundle', legacyError));
                    logger.warning('Legacy bundle download failed; attempting Supabase CLI via npx (latest)...');
                    const npmCacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'supabase-npm-cache-'));
                    const env = {
                        ...process.env,
                        npm_config_cache: npmCacheDir
                    };
                    const npxArgs = ['--yes', 'supabase@latest', 'functions', 'download', functionName];
                    const npxResult = runSupabaseCommand('npx', npxArgs, {
                        stdio: 'pipe',
                        timeout: 150000,
                        env
                    });
                    if (!npxResult.success) {
                        errorMessages.push(formatError('npx supabase@latest', npxResult.error));
                        logger.warning('npx supabase@latest failed; attempting Supabase CLI via Docker...');

                        const linkResult = runDockerSupabaseCommand(
                            tempRoot,
                            projectRef,
                            dbPassword,
                            ['link', '--project-ref', projectRef].concat(dbPassword ? ['--password', dbPassword] : []),
                            logger
                        );

                        if (!linkResult.success) {
                            errorMessages.push(formatError('Docker supabase link', linkResult.error));
                        }

                        const dockerResult = runDockerSupabaseCommand(
                            tempRoot,
                            projectRef,
                            dbPassword,
                            ['functions', 'download', functionName],
                            logger
                        );

                        if (!dockerResult.success) {
                            errorMessages.push(formatError('Docker supabase functions download', dockerResult.error));
                            fs.rmSync(npmCacheDir, { recursive: true, force: true });
                            throw new Error(`All Supabase CLI download attempts failed:\n${errorMessages.join('\n---\n')}`);
                        }

                        fs.rmSync(npmCacheDir, { recursive: true, force: true });
                        cliError = null;
                    } else {
                        fs.rmSync(npmCacheDir, { recursive: true, force: true });
                        cliError = null;
                    }
                }
            } else {
                throw cliError;
            }
        }

        if (cliError) {
            throw cliError;
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

