/**
 * Supabase edge function deploy via CLI with strategy selection (--use-api vs --use-docker).
 * Env: EDGE_DEPLOY_STRATEGY, EDGE_DEPLOY_TIMEOUT_USE_API_MS, EDGE_DEPLOY_TIMEOUT_USE_DOCKER_MS
 */
const { spawn } = require('child_process');

const STRATEGY_USE_API = 'use-api';
const STRATEGY_USE_DOCKER = 'use-docker';

const DEFAULT_TIMEOUT_MS = {
    [STRATEGY_USE_API]: 90000,
    [STRATEGY_USE_DOCKER]: 180000
};

function getDeployStrategyOrder() {
    const forced = (process.env.EDGE_DEPLOY_STRATEGY || '').trim().toLowerCase();
    if (forced === STRATEGY_USE_API || forced === STRATEGY_USE_DOCKER) {
        return [forced];
    }
    return [STRATEGY_USE_API, STRATEGY_USE_DOCKER];
}

function getTimeoutMsForStrategy(strategyId) {
    const envKey =
        strategyId === STRATEGY_USE_API
            ? 'EDGE_DEPLOY_TIMEOUT_USE_API_MS'
            : 'EDGE_DEPLOY_TIMEOUT_USE_DOCKER_MS';
    const raw = process.env[envKey];
    if (raw !== undefined && raw !== '') {
        const n = parseInt(raw, 10);
        if (!Number.isNaN(n) && n > 0) {
            return n;
        }
    }
    return DEFAULT_TIMEOUT_MS[strategyId] ?? 120000;
}

function buildDeployArgs(functionName, strategyId) {
    const args = ['functions', 'deploy', functionName];
    if (strategyId === STRATEGY_USE_API) {
        args.push('--use-api');
    } else if (strategyId === STRATEGY_USE_DOCKER) {
        args.push('--use-docker');
    }
    return args;
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function retryWithBackoff429(fn, maxRetries, initialDelay, onRateLimit) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            return await fn();
        } catch (error) {
            lastError = error;
            const errorMessage = error.message || error.toString();
            const stderr = error.stderr ? error.stderr.toString() : '';
            const stdout = error.stdout ? error.stdout.toString() : '';
            const code = error.code || '';
            const combinedOutput = `${errorMessage}\n${stderr}\n${stdout}\n${code}`;
            const isRateLimit = /429|Too Many Requests|ThrottlerException|status 429/i.test(combinedOutput);

            if (isRateLimit && attempt < maxRetries) {
                const delay = initialDelay * Math.pow(2, attempt);
                if (typeof onRateLimit === 'function') {
                    onRateLimit(delay, attempt + 1, maxRetries + 1);
                }
                await sleep(delay);
                continue;
            }
            throw error;
        }
    }
    throw lastError;
}

function runSupabaseFunctionDeploySpawn({ cwd, env, functionName, strategyId, timeoutMs }) {
    return new Promise((resolve, reject) => {
        const args = buildDeployArgs(functionName, strategyId);
        const child = spawn('supabase', args, {
            cwd,
            stdio: ['pipe', 'pipe', 'pipe'],
            env
        });

        let stdout = '';
        let stderr = '';
        let settled = false;

        const timer = setTimeout(() => {
            child.kill();
            const err = new Error(`Deployment timeout after ${timeoutMs}ms (${strategyId})`);
            err.stdout = stdout;
            err.stderr = stderr;
            err.code = 'TIMEOUT';
            err.strategyId = strategyId;
            err.timedOut = true;
            finish(() => reject(err));
        }, timeoutMs);

        const doneTimer = () => clearTimeout(timer);

        const finish = (fn) => {
            if (settled) {
                return;
            }
            settled = true;
            doneTimer();
            fn();
        };

        child.stdout.on('data', (data) => {
            stdout += data.toString();
        });
        child.stderr.on('data', (data) => {
            stderr += data.toString();
        });

        child.on('error', (err) => {
            err.stdout = stdout;
            err.stderr = stderr;
            err.strategyId = strategyId;
            finish(() => reject(err));
        });

        child.on('close', (code) => {
            if (code === 0) {
                finish(() => resolve({ stdout, stderr, strategyId }));
            } else {
                const err = new Error(`Deployment failed with exit code ${code}`);
                err.stdout = stdout;
                err.stderr = stderr;
                err.code = code;
                err.strategyId = strategyId;
                finish(() => reject(err));
            }
        });
    });
}

async function runDeployOneStrategy(cwd, env, functionName, strategyId, options = {}) {
    const timeoutMs = options.timeoutMs ?? getTimeoutMsForStrategy(strategyId);
    const maxRetries = options.maxRetries ?? 3;
    const initialDelay = options.initialDelay ?? 2000;
    const onRateLimit = options.onRateLimit;

    return retryWithBackoff429(
        () => runSupabaseFunctionDeploySpawn({ cwd, env, functionName, strategyId, timeoutMs }),
        maxRetries,
        initialDelay,
        onRateLimit
    );
}

function createDeployStrategyContext() {
    let sticky = null;
    const strategyChanges = [];

    return {
        getSticky: () => sticky,
        setSticky: (v) => {
            sticky = v;
        },
        getOrder: getDeployStrategyOrder,
        strategyChanges,
        probeBannerLogged: false,
        lockBannerLogged: false,
        recordStrategyChange(fromStrategy, toStrategy, functionName) {
            strategyChanges.push({ from: fromStrategy, to: toStrategy, functionName });
        }
    };
}

/**
 * Deploy with sticky strategy: probe until first lock, reuse sticky, on sticky failure re-probe full order.
 */
async function deployWithProbeAndSticky({
    cwd,
    env,
    functionName,
    context,
    onRateLimit
}) {
    const order = context.getOrder();

    const tryStrategy = async (strategyId) => {
        const timeoutMs = getTimeoutMsForStrategy(strategyId);
        return runDeployOneStrategy(cwd, env, functionName, strategyId, {
            timeoutMs,
            onRateLimit
        });
    };

    if (order.length === 1) {
        const s = order[0];
        const result = await tryStrategy(s);
        context.setSticky(s);
        return { ...result, strategyUsed: s, probed: false, forcedSingle: true };
    }

    const sticky = context.getSticky();
    if (sticky) {
        try {
            const result = await tryStrategy(sticky);
            return { ...result, strategyUsed: sticky, probed: false };
        } catch (stickyErr) {
            context.setSticky(null);
            let lastErr = stickyErr;
            for (const s of order) {
                try {
                    const result = await tryStrategy(s);
                    context.setSticky(s);
                    if (s !== sticky) {
                        context.recordStrategyChange(sticky, s, functionName);
                    }
                    return {
                        ...result,
                        strategyUsed: s,
                        probed: true,
                        recoveredAfterStickyFailure: true,
                        previousSticky: sticky
                    };
                } catch (err) {
                    lastErr = err;
                }
            }
            throw lastErr;
        }
    }

    let lastErr;
    for (const s of order) {
        try {
            const result = await tryStrategy(s);
            context.setSticky(s);
            return { ...result, strategyUsed: s, probed: true };
        } catch (err) {
            lastErr = err;
        }
    }
    throw lastErr;
}

module.exports = {
    STRATEGY_USE_API,
    STRATEGY_USE_DOCKER,
    getDeployStrategyOrder,
    getTimeoutMsForStrategy,
    buildDeployArgs,
    runSupabaseFunctionDeploySpawn,
    runDeployOneStrategy,
    createDeployStrategyContext,
    deployWithProbeAndSticky,
    retryWithBackoff429
};
