/**
 * Docker daemon preflight for Supabase CLI edge-function download/deploy.
 * Same behavior as edge_functions_migration.sh + edge-functions-migration.js.
 *
 * Env:
 *   EDGE_DOCKER_NO_AUTO_START=true   Do not run open/systemctl
 *   EDGE_DOCKER_START_WAIT_SEC       Max seconds to poll after auto-start (default 120)
 */

const { execSync } = require('child_process');

function checkDocker() {
    try {
        execSync('docker ps', { stdio: 'pipe', timeout: 5000 });
        return true;
    } catch {
        return false;
    }
}

const defaultLog = {
    info: (m) => console.log(`[INFO] ${m}`),
    success: (m) => console.log(`[SUCCESS] ${m}`),
    error: (m) => console.error(`[ERROR] ${m}`),
    warning: (m) => console.log(`[WARNING] ${m}`)
};

/**
 * @param {Partial<typeof defaultLog>} [log]
 */
async function ensureDockerRunning(log = {}) {
    const L = { ...defaultLog, ...log };
    L.info('Preflight: checking Docker (`docker ps`)…');
    if (checkDocker()) {
        L.success('Preflight: Docker is reachable.');
        return;
    }
    if (process.env.EDGE_DOCKER_NO_AUTO_START === 'true') {
        L.error('Docker is not running and EDGE_DOCKER_NO_AUTO_START=true (auto-start disabled).');
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
            L.info(`Waiting for Docker to be ready... (${waited / 1000}s / ${maxWaitMs / 1000}s)`);
            try {
                execSync('docker ps', { stdio: 'pipe', timeout: 10000 });
                L.success('Docker is running.');
                return true;
            } catch {
                /* keep polling */
            }
            await new Promise((r) => setTimeout(r, pollIntervalMs));
        }
        return false;
    };

    const isMac = process.platform === 'darwin';
    const isLinux = process.platform === 'linux';

    if (isMac) {
        L.info('Docker is not running. Attempting to start Docker Desktop...');
        try {
            execSync('open -a Docker', { stdio: 'pipe', timeout: 5000 });
        } catch {
            L.warning('Could not launch Docker Desktop (open -a Docker failed).');
        }
        if (await waitForDockerDaemon()) {
            return;
        }
    } else if (isLinux) {
        L.info('Docker is not running. Attempting systemctl start docker...');
        try {
            execSync('systemctl start docker', { stdio: 'pipe', timeout: 15000 });
        } catch {
            try {
                execSync('sudo -n systemctl start docker', { stdio: 'pipe', timeout: 15000 });
            } catch {
                L.warning('Could not start docker via systemctl (try: sudo systemctl start docker).');
            }
        }
        if (await waitForDockerDaemon()) {
            return;
        }
    }

    L.error('Docker is not running - required for edge function download and deploy.');
    L.info('Please start Docker and run this migration again.');
    if (isMac) {
        L.info('  macOS: Open Docker from Applications, or run: open -a Docker');
    } else if (isLinux) {
        L.info('  Linux: sudo systemctl start docker (or start your container runtime)');
    } else {
        L.info('  Windows: Start Docker Desktop from the Start menu');
    }
    throw new Error('Docker is not running');
}

module.exports = { checkDocker, ensureDockerRunning };
