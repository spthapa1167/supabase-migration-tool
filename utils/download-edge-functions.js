#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const { ensureSupabaseCli, ensureDockerRunning, downloadEdgeFunctionWithCli, defaultLogger } = require('./lib/edgeFunctionsCli');

const PROJECT_REF = process.argv[2];
const LIST_FILE = process.argv[3];
const DESTINATION_DIR = process.argv[4];
const ENV_NAME = process.argv[5] || '';
const DB_PASSWORD = process.argv[6] || '';

const log = (level, message) => {
    const levels = {
        info: '\x1b[34m[INFO]\x1b[0m',
        success: '\x1b[32m[SUCCESS]\x1b[0m',
        warning: '\x1b[33m[WARNING]\x1b[0m',
        error: '\x1b[31m[ERROR]\x1b[0m'
    };
    console.error(`${levels[level] || '[LOG]'} ${message}`);
};

const exitWithError = (message) => {
    log('error', message);
    process.exit(1);
};

const run = async () => {
    if (!PROJECT_REF || !LIST_FILE || !DESTINATION_DIR) {
        exitWithError('Usage: node utils/download-edge-functions.js <project_ref> <list_file> <destination_dir> [env_name] [db_password]');
    }

    if (!fs.existsSync(LIST_FILE) || !fs.statSync(LIST_FILE).size) {
        exitWithError(`Edge function list file ${LIST_FILE} is missing or empty`);
    }

    ensureSupabaseCli();
    ensureDockerRunning();

    const rawList = fs.readFileSync(LIST_FILE, 'utf8').split('\n').map((line) => line.trim()).filter(Boolean);
    if (!rawList.length) {
        exitWithError(`No edge functions specified in ${LIST_FILE}`);
    }

    const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), `edge-download-${ENV_NAME || 'env'}-`));
    fs.mkdirSync(DESTINATION_DIR, { recursive: true });

    try {
        for (const name of rawList) {
            log('info', `Downloading edge function ${name} from ${ENV_NAME || PROJECT_REF}...`);
            const destination = path.join(DESTINATION_DIR, name);
            try {
                downloadEdgeFunctionWithCli(PROJECT_REF, name, destination, DB_PASSWORD, defaultLogger);
            } catch (err) {
                if (err && err.notFound) {
                    log('warning', `Edge function '${name}' not found in ${ENV_NAME || PROJECT_REF}; creating empty placeholder.`);
                    fs.rmSync(destination, { recursive: true, force: true });
                    fs.mkdirSync(destination, { recursive: true });
                } else {
                    throw err;
                }
            }
        }
        log('success', `Edge function code downloaded for ${ENV_NAME || PROJECT_REF}`);
    } catch (err) {
        exitWithError(err.message);
    } finally {
        fs.rmSync(tempRoot, { recursive: true, force: true });
    }
};

run();

