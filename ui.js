// Supabase Migration Tool - Web UI JavaScript

const API_BASE = '';

let appInfoData = null;
let cliManualLoaded = false;
let uiManualLoaded = false;
let lastEdgeComparison = null;
let edgeComparisonInFlight = false;

// Persist token from query string (if present) and clean URL
(() => {
    const params = new URLSearchParams(window.location.search);
    const tokenFromUrl = params.get('token');
    if (tokenFromUrl) {
        localStorage.setItem('migrationToolToken', tokenFromUrl);
        params.delete('token');
        const newQuery = params.toString();
        const newUrl = window.location.pathname + (newQuery ? `?${newQuery}` : '') + window.location.hash;
        window.history.replaceState({}, document.title, newUrl);
    }
})();

// Get auth token from URL or localStorage
function getAuthToken() {
    const storedToken = localStorage.getItem('migrationToolToken');
    if (storedToken) {
        return storedToken;
    }

    const params = new URLSearchParams(window.location.search);
    const tokenFromUrl = params.get('token');
    if (tokenFromUrl) {
        localStorage.setItem('migrationToolToken', tokenFromUrl);
        params.delete('token');
        const newQuery = params.toString();
        const newUrl = window.location.pathname + (newQuery ? `?${newQuery}` : '') + window.location.hash;
        window.history.replaceState({}, document.title, newUrl);
        return tokenFromUrl;
    }

    return null;
}

// Set auth token for API requests
function getAuthHeaders() {
    const token = getAuthToken();
    return {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`
    };
}

// Check authentication on page load
if (!getAuthToken()) {
    window.location.href = '/';
}

// Active jobs tracking
let activeJobs = [];
let jobsCheckInterval = null;

// Tab switching (handled in HTML now, but keeping for compatibility)
function switchTab(tabName, clickedElement) {
    // Hide all tabs
    document.querySelectorAll('.tab-content').forEach(tab => {
        tab.classList.add('hidden');
    });
    document.querySelectorAll('.tab-button').forEach(btn => {
        btn.classList.remove('active');
    });

    // Show selected tab
    const selectedTab = document.getElementById(tabName);
    if (selectedTab) {
        selectedTab.classList.remove('hidden');
    }

    // Update button
    if (clickedElement) {
        clickedElement.classList.add('active');
    }

    // Load data for history tab
    if (tabName === 'history') {
        setTimeout(() => {
            loadHistory();
            loadPlans();
        }, 100);
    }
    
    // Load data for connection test tab
    if (tabName === 'connection-test') {
        // Load environments immediately (no API call, hardcoded)
        loadEnvironmentsList();
    }

    if (tabName === 'edge-comparison') {
        onEdgeComparisonTabOpen();
    }

    if (tabName === 'cli-manual' && !cliManualLoaded) {
        loadManualContent('cliManualContainer', 'MIGRATION_GUIDE.md').then(() => {
            cliManualLoaded = true;
        }).catch(() => {
            cliManualLoaded = false;
        });
    }

    if (tabName === 'ui-manual' && !uiManualLoaded) {
        loadManualContent('uiManualContainer', 'WEB_UI_GUIDE.md').then(() => {
            uiManualLoaded = true;
        }).catch(() => {
            uiManualLoaded = false;
        });
    }
}

// Show loading indicator
function showLoading(elementId) {
    const loader = document.getElementById(elementId);
    if (loader) {
        loader.classList.remove('hidden');
        loader.innerHTML = `
            <svg class="animate-spin h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
        `;
    }
}

function hideLoading(elementId) {
    const loader = document.getElementById(elementId);
    if (loader) loader.classList.add('hidden');
}

// Show result message with modern styling
function showResult(elementId, message, type = 'info') {
    const resultDiv = document.getElementById(elementId);
    const alertClasses = {
        error: 'bg-error-50 border-error-200 text-error-800',
        success: 'bg-success-50 border-success-200 text-success-800',
        info: 'bg-primary-50 border-primary-200 text-primary-800',
        warning: 'bg-warning-50 border-warning-200 text-warning-800'
    };
    const iconClasses = {
        error: 'text-error-600',
        success: 'text-success-600',
        info: 'text-primary-600',
        warning: 'text-warning-600'
    };
    const icons = {
        error: `<svg class="w-5 h-5 ${iconClasses[type]}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>`,
        success: `<svg class="w-5 h-5 ${iconClasses[type]}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>`,
        info: `<svg class="w-5 h-5 ${iconClasses[type]}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>`,
        warning: `<svg class="w-5 h-5 ${iconClasses[type]}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>
        </svg>`
    };
    
    resultDiv.innerHTML = `
        <div class="flex items-start space-x-3 p-4 rounded-xl border-2 ${alertClasses[type]} animate-fade-in">
            <div class="flex-shrink-0">${icons[type]}</div>
            <div class="flex-1">${message}</div>
        </div>
    `;
}

// Format log output (for static display)
function formatLogOutput(output) {
    if (!output) return '';
    
    let html = '';
    const lines = output.split('\n');
    lines.forEach(line => {
        if (!line.trim()) return;
        let className = 'text-slate-300';
        const lowered = line.toLowerCase();
         if (line.includes('ERROR') || line.includes('✗') || line.includes('Failed')) {
             className = 'text-error-400';
        } else if (lowered.includes('retrieved') && lowered.includes(' via ')) {
            className = 'text-success-400';
        } else if (lowered.includes('returned no rows')) {
            className = 'text-neutral-400';
        } else if (lowered.includes('trying next endpoint')) {
            className = 'text-warning-400';
        } else if (line.includes('SUCCESS') || line.includes('✓') || line.includes('Completed')) {
            className = 'text-success-400';
        } else if (line.includes('WARNING') || line.includes('⚠')) {
            className = 'text-warning-400';
        }
        html += `<div class="log-line ${className} font-mono text-sm mb-1">${escapeHtml(line)}</div>`;
    });
    return html;
}

// Add log line with proper styling
function addLogLine(container, text, type = 'stdout') {
    const logLine = document.createElement('div');
    logLine.className = 'font-mono text-sm mb-1';
    
    const normalizedText = text.toLowerCase();
    
    // Apply styling based on content
    if (normalizedText.includes('retrieved') && normalizedText.includes(' via ')) {
        logLine.classList.add('text-success-400', 'font-semibold');
    } else if (normalizedText.includes('returned no rows')) {
        logLine.classList.add('text-neutral-400', 'italic');
    } else if (normalizedText.includes('trying next endpoint')) {
        logLine.classList.add('text-warning-400', 'italic');
    } else if (type === 'stderr' || text.includes('ERROR') || text.includes('✗') || text.includes('Failed')) {
        logLine.classList.add('text-error-400');
    } else if (text.includes('SUCCESS') || text.includes('✓') || text.includes('Completed')) {
        logLine.classList.add('text-success-400');
    } else if (text.includes('WARNING') || text.includes('⚠')) {
        logLine.classList.add('text-warning-400');
    } else {
        logLine.classList.add('text-slate-300');
    }
    
    logLine.textContent = text;
    container.appendChild(logLine);
    
    // Auto-scroll to bottom
    container.scrollTop = container.scrollHeight;
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Format date for display
function formatDate(timestamp) {
    if (!timestamp) return 'Unknown date';
    
    try {
        const date = new Date(timestamp);
        if (isNaN(date.getTime())) return 'Unknown date';
        
        // Format: "Nov 5, 2025 at 10:14 PM"
        const options = {
            year: 'numeric',
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit',
            hour12: true
        };
        return date.toLocaleString('en-US', options);
    } catch (error) {
        return 'Unknown date';
    }
}

// Load app info (app name and environment project names)
async function loadAppInfo() {
    try {
        const response = await fetch(`${API_BASE}/api/info`, {
            headers: getAuthHeaders()
        });
        if (!response.ok) {
            throw new Error('Failed to load app info');
        }
        
        const data = await response.json();
        appInfoData = data;
        
        const envInfoElement = document.getElementById('envInfo');
        if (envInfoElement && data.environments) {
            const envOrder = ['prod', 'test', 'dev', 'backup'];
            const envBadgeColors = {
                prod: 'bg-error-100 text-error-700',
                test: 'bg-warning-100 text-warning-700',
                dev: 'bg-success-100 text-success-700',
                backup: 'bg-primary-100 text-primary-700'
            };

            const envBadges = [];

            envOrder.forEach(key => {
                const envData = data.environments[key];
                if (!envData || !envData.projectName || envData.projectName === 'N/A') {
                    return;
                }

                const badgeClass = envBadgeColors[key] || 'bg-neutral-100 text-neutral-700';
                const projectName = escapeHtml(envData.projectName);
                const projectRef = escapeHtml(envData.projectRef || 'N/A');
                const poolerRegion = escapeHtml(envData.poolerRegion || 'aws-1-us-east-2');
                const poolerPort = escapeHtml(envData.poolerPort || '6543');
                const directHostRaw = envData.projectRef && envData.projectRef !== 'N/A'
                    ? `db.${envData.projectRef}.supabase.co`
                    : '';
                const directHost = directHostRaw ? escapeHtml(directHostRaw) : '';

                envBadges.push(`
                    <span class="inline-flex items-center space-x-2 px-2.5 py-1 rounded-full text-xs font-semibold border border-neutral-200 bg-white/80">
                        <span class="inline-flex items-center justify-center w-6 h-6 rounded-full ${badgeClass}">${key.toUpperCase()}</span>
                        <span class="text-neutral-700">${projectName}</span>
                    </span>
                `);
            });

            if (envInfoElement) {
                envInfoElement.innerHTML = envBadges.length
                    ? envBadges.join('<span class="text-neutral-300">•</span>')
                    : '<span class="text-neutral-500 italic">No environment projects configured</span>';
            }
        }
    } catch (error) {
        console.error('Error loading app info:', error);
    }
 }

// Load environments list for connection test (hardcoded)
function loadEnvironmentsList() {
    const envsList = document.getElementById('environmentsList');
    if (!envsList) {
        console.error('environmentsList element not found');
        return;
    }
    
    // Hardcoded environments - no API call needed
    const environments = [
        { key: 'dev', name: 'Development', color: 'success', icon: '🟢' },
        { key: 'test', name: 'Test/Staging', color: 'warning', icon: '🟡' },
        { key: 'prod', name: 'Production', color: 'error', icon: '🔴' },
        { key: 'backup', name: 'Backup', color: 'info', icon: '🔵' }
    ];
    
    // Use inline styles for colors to avoid Tailwind dynamic class issues
    const colorClasses = {
        'error': { bg: '#fee2e2', text: '#991b1b' },
        'warning': { bg: '#fef3c7', text: '#92400e' },
        'success': { bg: '#d1fae5', text: '#065f46' },
        'info': { bg: '#dbeafe', text: '#1d4ed8' }
    };
    
    // Build HTML for each environment
    const envsHTML = environments.map(env => {
        const colorStyle = colorClasses[env.color] || colorClasses.success;
        
        return `
            <div class="bg-neutral-50 border-2 border-neutral-200 rounded-xl p-6 hover:border-primary-300 hover:shadow-md transition-all duration-200">
                <div class="flex items-center justify-between">
                    <div class="flex-1">
                        <div class="flex items-center space-x-4 mb-3">
                            <div class="flex items-center justify-center w-12 h-12 rounded-xl" style="background-color: ${colorStyle.bg};">
                                <span class="text-2xl">${env.icon}</span>
                            </div>
                            <div class="flex-1">
                                <div class="flex items-center space-x-3 mb-2">
                                    <h4 class="text-lg font-bold text-neutral-900">${env.name}</h4>
                                    <span class="inline-block px-2 py-1 text-xs font-semibold rounded" style="background-color: ${colorStyle.bg}; color: ${colorStyle.text};">${env.key.toUpperCase()}</span>
                                </div>
                                <div class="space-y-1">
                                    <p class="text-sm text-neutral-700">
                                        <span class="font-semibold">Environment:</span> 
                                        <span class="text-neutral-900 ml-1">${env.name}</span>
                                    </p>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="ml-6">
                        <button onclick="testConnection('${env.key}')" 
                            class="px-8 py-3 bg-primary-600 text-white text-sm font-semibold rounded-lg hover:bg-primary-700 shadow-md hover:shadow-lg transition-all duration-200 flex items-center space-x-2 min-w-[140px] justify-center">
                            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                            </svg>
                            <span>Test Connection</span>
                        </button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
    
    envsList.innerHTML = envsHTML;
}

// Test connection for an environment
async function testConnection(env) {
    const testResults = document.getElementById('testResults');
    const testResultsContent = document.getElementById('testResultsContent');
    const testResultsTitle = document.getElementById('testResultsTitle');
    
    if (!testResults || !testResultsContent || !testResultsTitle) return;
    
    // Show results section
    testResults.classList.remove('hidden');
    
    // Set title
    const envNames = {
        'prod': 'Production',
        'test': 'Test/Staging',
        'dev': 'Development',
        'backup': 'Backup'
    };
    const envName = envNames[env] || env;
    testResultsTitle.textContent = `Test Results: ${envName}`;
    
    // Create results container with summary and log
    const resultsContainer = document.createElement('div');
    resultsContainer.className = 'space-y-4';
    
    // Summary card
    const summaryCard = document.createElement('div');
    summaryCard.className = 'bg-gradient-to-r from-primary-50 to-primary-100 border-2 border-primary-200 rounded-xl p-6 mb-4';
    summaryCard.id = `testSummary_${env}`;
    const envConfig = appInfoData?.environments?.[env] || {};
    const poolerRegion = escapeHtml(envConfig.poolerRegion || 'aws-1-us-east-2');
    const poolerPort = escapeHtml(envConfig.poolerPort || '6543');
    const directHostRaw = envConfig.projectRef && envConfig.projectRef !== 'N/A' ? `db.${envConfig.projectRef}.supabase.co` : '';
    const directHost = directHostRaw ? escapeHtml(directHostRaw) : '';
    const configLine = directHost ? `Pooler ${poolerRegion}:${poolerPort} • Direct ${directHost}` : `Pooler ${poolerRegion}:${poolerPort}`;
    summaryCard.innerHTML = `
        <div class="flex items-center justify-between">
            <div class="flex items-center space-x-4">
                <div class="flex items-center justify-center w-16 h-16 bg-white rounded-xl shadow-md">
                    <svg class="w-8 h-8 text-primary-500 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                    </svg>
                </div>
                <div>
                    <h4 class="text-xl font-bold text-primary-900">${envNames[env]}</h4>
                    <p class="status-text text-sm text-primary-700 mt-1">Running connection tests...</p>
                    <p class="config-detail text-xs text-primary-600 mt-1">${configLine}</p>
                    <p class="connection-detail text-xs text-success-600 mt-1 hidden"></p>
                </div>
            </div>
            <div class="text-right">
                <div class="flex items-center space-x-6">
                    <div class="text-center">
                        <div class="text-3xl font-bold text-primary-600" id="testPassed_${env}">0</div>
                        <div class="text-xs text-primary-600 font-semibold mt-1">Passed</div>
                    </div>
                    <div class="text-center">
                        <div class="text-3xl font-bold text-error-600" id="testFailed_${env}">0</div>
                        <div class="text-xs text-error-600 font-semibold mt-1">Failed</div>
                    </div>
                    <div class="text-center">
                        <div class="text-3xl font-bold text-neutral-600" id="testTotal_${env}">0</div>
                        <div class="text-xs text-neutral-600 font-semibold mt-1">Total</div>
                    </div>
                </div>
            </div>
        </div>
    `;
    
    // Log container with better visibility for live logs
    const logContainer = document.createElement('div');
    logContainer.className = 'log-container bg-slate-900 rounded-xl p-6 max-h-[500px] overflow-y-auto custom-scrollbar font-mono text-sm';
    logContainer.id = `connectionTestLog_${env}`;
    logContainer.innerHTML = '<div class="text-slate-400 text-xs mb-2">Live logs will appear here...</div>';
    
    resultsContainer.appendChild(summaryCard);
    resultsContainer.appendChild(logContainer);
    testResultsContent.innerHTML = '';
    testResultsContent.appendChild(resultsContainer);
    
    // Scroll to results
    testResults.scrollIntoView({ behavior: 'smooth', block: 'start' });
    
    // Use the shared test function
    await testConnectionForEnv(env, false);
    
    // Note: testConnectionForEnv will update the summary and log containers
    // that were created above
}

// Update test summary during execution
function updateTestSummary(env, passed, failed, total) {
    const passedEl = document.getElementById(`testPassed_${env}`);
    const failedEl = document.getElementById(`testFailed_${env}`);
    const totalEl = document.getElementById(`testTotal_${env}`);
    
    if (passedEl) passedEl.textContent = passed;
    if (failedEl) failedEl.textContent = failed;
    if (totalEl) totalEl.textContent = total;
}

// Update test summary with final status
function updateTestSummaryFinal(env, passed, failed, total, skipped, success, connectionDetail = '') {
    const summaryCard = document.getElementById(`testSummary_${env}`);
    if (!summaryCard) return;
    
    // Update counts
    updateTestSummary(env, passed, failed, total);
    const statusText = summaryCard.querySelector('.status-text');
    const connectionDetailEl = summaryCard.querySelector('.connection-detail');
     
    // Update card styling based on result
    if (success && failed === 0) {
        summaryCard.className = 'bg-gradient-to-r from-success-50 to-success-100 border-2 border-success-200 rounded-xl p-6';
        const iconContainer = summaryCard.querySelector('.w-16');
        if (iconContainer) {
            iconContainer.innerHTML = `
                <svg class="w-8 h-8 text-success-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
            `;
        }
        if (statusText) {
            statusText.textContent = 'All tests passed!';
            statusText.className = 'status-text text-sm text-success-700 mt-1 font-semibold';
        }
        if (connectionDetailEl) {
            if (connectionDetail) {
                connectionDetailEl.textContent = `Connected via ${connectionDetail}`;
                connectionDetailEl.className = 'connection-detail text-xs text-success-600 mt-1';
            } else {
                connectionDetailEl.textContent = '';
                connectionDetailEl.className = 'connection-detail text-xs text-success-600 mt-1 hidden';
            }
        }
    } else if (failed > 0) {
        summaryCard.className = 'bg-gradient-to-r from-error-50 to-error-100 border-2 border-error-200 rounded-xl p-6';
        const iconContainer = summaryCard.querySelector('.w-16');
        if (iconContainer) {
            iconContainer.innerHTML = `
                <svg class="w-8 h-8 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
            `;
        }
        if (statusText) {
            statusText.textContent = `${failed} test(s) failed`;
            statusText.className = 'status-text text-sm text-error-700 mt-1 font-semibold';
        }
        if (connectionDetailEl) {
            if (connectionDetail) {
                connectionDetailEl.textContent = connectionDetail;
                connectionDetailEl.className = 'connection-detail text-xs text-error-600 mt-1';
            } else {
                connectionDetailEl.textContent = '';
                connectionDetailEl.className = 'connection-detail text-xs text-error-600 mt-1 hidden';
            }
        }
    } else {
        // Neutral outcome (no failures but not marked success)
        summaryCard.className = 'bg-gradient-to-r from-warning-50 to-warning-100 border-2 border-warning-200 rounded-xl p-6';
        const iconContainer = summaryCard.querySelector('.w-16');
        if (iconContainer) {
            iconContainer.innerHTML = `
                <svg class="w-8 h-8 text-warning-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>
                </svg>
            `;
        }
        if (statusText) {
            statusText.textContent = 'Tests finished with warnings';
            statusText.className = 'status-text text-sm text-warning-700 mt-1 font-semibold';
        }
        if (connectionDetailEl) {
            if (connectionDetail) {
                connectionDetailEl.textContent = connectionDetail;
                connectionDetailEl.className = 'connection-detail text-xs text-warning-600 mt-1';
            } else {
                connectionDetailEl.textContent = '';
                connectionDetailEl.className = 'connection-detail text-xs text-warning-600 mt-1 hidden';
            }
        }
    }
}

// Test all connections
async function testAllConnections() {
    const testResults = document.getElementById('testResults');
    const testResultsContent = document.getElementById('testResultsContent');
    const testResultsTitle = document.getElementById('testResultsTitle');
    
    if (!testResults || !testResultsContent || !testResultsTitle) return;
    
    // Show results section
    testResults.classList.remove('hidden');
    testResultsTitle.textContent = 'Test Results: All Environments';
    
    // Create container for all environment results
    const allResultsContainer = document.createElement('div');
    allResultsContainer.className = 'space-y-6';
    allResultsContainer.id = 'allTestResults';
    
    testResultsContent.innerHTML = '';
    testResultsContent.appendChild(allResultsContainer);
    
    // Scroll to results
    testResults.scrollIntoView({ behavior: 'smooth', block: 'start' });
    
    // Test all environments in parallel
    const environments = ['dev', 'test', 'prod', 'backup'];
    const envNames = {
        'prod': 'Production',
        'test': 'Test/Staging',
        'dev': 'Development',
        'backup': 'Backup'
    };
    
    // Create result containers for each environment
    environments.forEach(env => {
        const envContainer = document.createElement('div');
        envContainer.className = 'bg-white border-2 border-neutral-200 rounded-xl p-6';
        envContainer.id = `envResult_${env}`;
        
        // Summary card
        const summaryCard = document.createElement('div');
        summaryCard.className = 'bg-gradient-to-r from-primary-50 to-primary-100 border-2 border-primary-200 rounded-xl p-6 mb-4';
        summaryCard.id = `testSummary_${env}`;
        const envConfig = appInfoData?.environments?.[env] || {};
        const poolerRegion = escapeHtml(envConfig.poolerRegion || 'aws-1-us-east-2');
        const poolerPort = escapeHtml(envConfig.poolerPort || '6543');
        const directHostRaw = envConfig.projectRef && envConfig.projectRef !== 'N/A' ? `db.${envConfig.projectRef}.supabase.co` : '';
        const directHost = directHostRaw ? escapeHtml(directHostRaw) : '';
        const configLine = directHost ? `Pooler ${poolerRegion}:${poolerPort} • Direct ${directHost}` : `Pooler ${poolerRegion}:${poolerPort}`;
        summaryCard.innerHTML = `
            <div class="flex items-center justify-between">
                <div class="flex items-center space-x-4">
                    <div class="flex items-center justify-center w-16 h-16 bg-white rounded-xl shadow-md">
                        <svg class="w-8 h-8 text-primary-500 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                        </svg>
                    </div>
                    <div>
                        <h4 class="text-xl font-bold text-primary-900">${envNames[env]}</h4>
                        <p class="status-text text-sm text-primary-700 mt-1">Running connection tests...</p>
                        <p class="config-detail text-xs text-primary-600 mt-1">${configLine}</p>
                        <p class="connection-detail text-xs text-success-600 mt-1 hidden"></p>
                    </div>
                </div>
                <div class="text-right">
                    <div class="flex items-center space-x-6">
                        <div class="text-center">
                            <div class="text-3xl font-bold text-primary-600" id="testPassed_${env}">0</div>
                            <div class="text-xs text-primary-600 font-semibold mt-1">Passed</div>
                        </div>
                        <div class="text-center">
                            <div class="text-3xl font-bold text-error-600" id="testFailed_${env}">0</div>
                            <div class="text-xs text-error-600 font-semibold mt-1">Failed</div>
                        </div>
                        <div class="text-center">
                            <div class="text-3xl font-bold text-neutral-600" id="testTotal_${env}">0</div>
                            <div class="text-xs text-neutral-600 font-semibold mt-1">Total</div>
                        </div>
                    </div>
                </div>
            </div>
        `;
        
        // Log container with better visibility for live logs
        const logContainer = document.createElement('div');
        logContainer.className = 'log-container bg-slate-900 rounded-xl p-6 max-h-[400px] overflow-y-auto custom-scrollbar font-mono text-sm';
        logContainer.id = `connectionTestLog_${env}`;
        logContainer.innerHTML = '<div class="text-slate-400 text-xs mb-2">Live logs will appear here...</div>';
        
        envContainer.appendChild(summaryCard);
        envContainer.appendChild(logContainer);
        allResultsContainer.appendChild(envContainer);
    });
    
    // Run tests for all environments
    const testPromises = environments.map(env => testConnectionForEnv(env, true));
    await Promise.all(testPromises);
}

// Test connection for a specific environment (used by both single and all tests)
async function testConnectionForEnv(env, isAllTests = false) {
    const envNames = {
        'prod': 'Production',
        'test': 'Test/Staging',
        'dev': 'Development',
        'backup': 'Backup'
    };
    const envName = envNames[env] || env;
    
    const envConfig = appInfoData?.environments?.[env] || {};
    const poolerRegion = escapeHtml(envConfig.poolerRegion || 'aws-1-us-east-2');
    const poolerPort = escapeHtml(envConfig.poolerPort || '6543');
    const directHostRaw = envConfig.projectRef && envConfig.projectRef !== 'N/A' ? `db.${envConfig.projectRef}.supabase.co` : '';
    const directHost = directHostRaw ? escapeHtml(directHostRaw) : '';
    const configLine = directHost ? `Pooler ${poolerRegion}:${poolerPort} • Direct ${directHost}` : `Pooler ${poolerRegion}:${poolerPort}`;
    
    const logContainer = document.getElementById(`connectionTestLog_${env}`);
    if (!logContainer) return;
    
    const TOTAL_TESTS = 13;
    let passedCount = 0;
    let failedCount = 0;
    let totalCount = 0;
    let skippedCount = 0;
    let lastConnectionLabel = '';
    let lastFailureDetail = '';
    
    try {
        const response = await fetch(`${API_BASE}/api/connection-test`, {
            method: 'POST',
            headers: {
                ...getAuthHeaders(),
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                env: env,
                stream: true
            })
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            
            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';
            
            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));
                        
                        if (data.type === 'stdout' || data.type === 'stderr') {
                            const text = data.data;
                            if (!text || text.trim() === '') return; // Skip empty lines
                            
                            const logLine = document.createElement('div');
                            logLine.className = 'mb-1 py-0.5';
                            
                            // Parse test results - be more flexible with patterns
                            const cleanText = text.replace(/\033\[[0-9;]*m/g, ''); // Remove ANSI codes
                            
                            const totalMatch = cleanText.match(/Total Tests:\s*(\d+)/i);
                            const passedMatch = cleanText.match(/Passed:\s*(\d+)/i);
                            const failedMatch = cleanText.match(/Failed:\s*(\d+)/i);
                            const skippedMatch = cleanText.match(/Skipped:\s*(\d+)/i);
                            if (totalMatch || passedMatch || failedMatch || skippedMatch) {
                                if (totalMatch) {
                                    totalCount = parseInt(totalMatch[1], 10) || totalCount;
                                }
                                if (passedMatch) {
                                    passedCount = parseInt(passedMatch[1], 10) || passedCount;
                                }
                                if (failedMatch) {
                                    failedCount = parseInt(failedMatch[1], 10) || failedCount;
                                }
                                if (skippedMatch) {
                                    skippedCount = parseInt(skippedMatch[1], 10) || skippedCount;
                                }
                                totalCount = Math.min(totalCount, TOTAL_TESTS);
                                passedCount = Math.min(passedCount, TOTAL_TESTS);
                                failedCount = Math.min(failedCount, TOTAL_TESTS);
                                skippedCount = Math.min(skippedCount, TOTAL_TESTS - passedCount - failedCount);
                                updateTestSummary(env, passedCount, failedCount, totalCount);
                                logLine.className += ' text-primary-300';
                                logLine.textContent = cleanText;
                                const placeholder = logContainer.querySelector('.text-slate-400.text-xs');
                                if (placeholder) {
                                    placeholder.remove();
                                }
                                logContainer.appendChild(logLine);
                                requestAnimationFrame(() => {
                                    logContainer.scrollTop = logContainer.scrollHeight;
                                });
                                continue;
                            }
                            
                            if (cleanText.includes('✅') || cleanText.includes('PASS:') || cleanText.match(/PASS:/i)) {
                                logLine.className += ' text-success-400 font-semibold';
                                if (cleanText.includes('PASS:') || cleanText.includes('✅')) {
                                    passedCount++;
                                    totalCount++;
                                    if (totalCount > TOTAL_TESTS) {
                                        totalCount = TOTAL_TESTS;
                                    }
                                    if (passedCount > TOTAL_TESTS) {
                                        passedCount = TOTAL_TESTS;
                                    }
                                    updateTestSummary(env, passedCount, failedCount, totalCount);
                                    const match = cleanText.match(/Database connectivity \(([^)]+)\)/i);
                                    if (match) {
                                        lastConnectionLabel = match[1];
                                    }
                                }
                            } else if (cleanText.includes('❌') || cleanText.includes('FAIL:') || cleanText.match(/FAIL:/i)) {
                                logLine.className += ' text-error-400 font-semibold';
                                if (cleanText.includes('FAIL:') || cleanText.includes('❌')) {
                                    failedCount++;
                                    totalCount++;
                                    if (totalCount > TOTAL_TESTS) {
                                        totalCount = TOTAL_TESTS;
                                    }
                                    if (failedCount > TOTAL_TESTS) {
                                        failedCount = TOTAL_TESTS;
                                    }
                                    updateTestSummary(env, passedCount, failedCount, totalCount);
                                    lastFailureDetail = cleanText;
                                }
                            } else if (cleanText.includes('⚠️') || cleanText.includes('SKIP:') || cleanText.match(/SKIP:/i)) {
                                logLine.className += ' text-warning-400';
                                if (cleanText.includes('SKIP:') || cleanText.includes('⚠️')) {
                                    skippedCount++;
                                    if (skippedCount > TOTAL_TESTS) {
                                        skippedCount = TOTAL_TESTS;
                                    }
                                }
                            } else if (cleanText.includes('[INFO]') || cleanText.includes('━━') || cleanText.includes('━━━')) {
                                logLine.className += ' text-primary-400';
                            } else if (cleanText.includes('[SUCCESS]') || cleanText.match(/SUCCESS/i)) {
                                logLine.className += ' text-success-400';
                            } else if (cleanText.includes('[ERROR]') || cleanText.match(/ERROR/i)) {
                                logLine.className += ' text-error-400';
                            } else {
                                logLine.className += ' text-slate-300';
                            }
                            
                            logLine.textContent = cleanText;
                            
                            // Remove placeholder text if exists
                            const placeholder = logContainer.querySelector('.text-slate-400.text-xs');
                            if (placeholder) {
                                placeholder.remove();
                            }
                            
                            logContainer.appendChild(logLine);
                            
                            // Auto-scroll to bottom for live log viewing
                            requestAnimationFrame(() => {
                                logContainer.scrollTop = logContainer.scrollHeight;
                            });
                        } else if (data.type === 'complete') {
                            const success = data.status === 'completed' && failedCount === 0;
                            if (totalCount < TOTAL_TESTS) {
                                totalCount = TOTAL_TESTS;
                            }
                            if (passedCount > totalCount) {
                                passedCount = totalCount;
                            }
                            const connectionDetail = success ? lastConnectionLabel : lastFailureDetail;
                            updateTestSummaryFinal(env, passedCount, failedCount, totalCount, skippedCount, success, connectionDetail);
                            
                            // Add final summary to log
                            const summaryLine = document.createElement('div');
                            summaryLine.className = `mt-4 p-4 border-2 rounded-xl ${success ? 'bg-success-50 border-success-200 text-success-800' : 'bg-error-50 border-error-200 text-error-800'}`;
                            summaryLine.innerHTML = `
                                <div class="flex items-center justify-between">
                                    <div class="flex items-center space-x-2">
                                        ${success ? `
                                            <svg class="w-6 h-6 text-success-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                                            </svg>
                                            <span class="font-semibold">All tests passed! (${envName})</span>
                                        ` : `
                                            <svg class="w-6 h-6 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                                            </svg>
                                            <span class="font-semibold">Some tests failed.</span>
                                        `}
                                    </div>
                                    <div class="text-sm font-semibold">
                                        ${passedCount} passed, ${failedCount} failed${skippedCount > 0 ? `, ${skippedCount} skipped` : ''}
                                    </div>
                                </div>
                                ${connectionDetail ? `<div class="mt-2 text-xs ${success ? 'text-success-600' : 'text-error-600'}">${escapeHtml(connectionDetail)}</div>` : ''}
                            `;
                            logContainer.appendChild(summaryLine);
                        } else if (data.type === 'error') {
                            const errorLine = document.createElement('div');
                            errorLine.className = 'mt-4 p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800';
                            errorLine.innerHTML = `
                                <div class="flex items-center space-x-2">
                                    <svg class="w-6 h-6 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                                    </svg>
                                    <span class="font-semibold">Error: ${escapeHtml(data.error)}</span>
                                </div>
                            `;
                            logContainer.appendChild(errorLine);
                            lastFailureDetail = data.error;
                            if (totalCount < TOTAL_TESTS) {
                                totalCount = TOTAL_TESTS;
                            }
                            updateTestSummaryFinal(env, passedCount, failedCount, totalCount, skippedCount, false, lastFailureDetail);
                        }
                    } catch (e) {
                        console.error('Error parsing SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error(`Error testing connection for ${env}:`, error);
        const errorDiv = document.createElement('div');
        errorDiv.className = 'p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800';
        errorDiv.innerHTML = `
            <div class="flex items-center space-x-2">
                <svg class="w-6 h-6 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <span class="font-semibold">Error: ${escapeHtml(error.message)}</span>
            </div>
        `;
        logContainer.appendChild(errorDiv);
        lastFailureDetail = error.message;
        if (totalCount < TOTAL_TESTS) {
            totalCount = TOTAL_TESTS;
        }
        updateTestSummaryFinal(env, passedCount, failedCount, totalCount, skippedCount, false, lastFailureDetail);
    }
}

// Close test results
function closeTestResults() {
    const testResults = document.getElementById('testResults');
    if (testResults) {
        testResults.classList.add('hidden');
    }
}

function setEdgeCompareStatus(message = '', tone = 'info') {
    const statusEl = document.getElementById('edgeCompareStatus');
    if (!statusEl) return;

    const toneClasses = {
        info: 'text-neutral-600',
        success: 'text-success-600',
        error: 'text-error-600',
        warning: 'text-warning-600'
    };

    statusEl.className = 'text-sm';
    if (toneClasses[tone]) {
        statusEl.classList.add(toneClasses[tone]);
    } else {
        statusEl.classList.add(toneClasses.info);
    }

    statusEl.textContent = message || '';
}

function renderEdgeComparisonResult(data, targetContainer = null) {
    const container = targetContainer || document.getElementById('edgeComparisonResult');
    if (!container) return;

    const summary = data?.summary || {};
    const edgeFunctions = Array.isArray(data?.edgeFunctions) ? data.edgeFunctions : [];
    const generatedAt = data?.generatedAt ? formatDate(data.generatedAt) : null;
    const sourceSnapshot = Array.isArray(data?.sourceSnapshot) ? data.sourceSnapshot : [];
    const targetSnapshot = Array.isArray(data?.targetSnapshot) ? data.targetSnapshot : [];

    const metricCards = [
        { label: 'To Deploy', value: summary.add || 0, tone: 'text-success-600' },
        { label: 'To Review', value: summary.remove || 0, tone: 'text-error-600' },
        { label: 'Updates', value: summary.modify || 0, tone: 'text-warning-600' },
        { label: 'Total Functions', value: summary.total || 0, tone: 'text-primary-600' }
    ]
        .map(metric => `
            <div class="metric-card">
                <h4>${escapeHtml(metric.label)}</h4>
                <p class="${metric.tone}">${metric.value}</p>
            </div>
        `)
        .join('');

    const reportButtons = [`
        ${data?.reportUrl ? `<a href="${data.reportUrl}" target="_blank" rel="noopener" class="btn-secondary">View HTML Report</a>` : ''}
        ${data?.diffJsonUrl ? `<a href="${data.diffJsonUrl}" target="_blank" rel="noopener" class="px-4 py-2 bg-neutral-200 text-neutral-700 text-sm font-semibold rounded-lg hover:bg-neutral-300 transition-colors">Download JSON Diff</a>` : ''}
    `]
        .filter(Boolean)
        .join('');

    const actionBadgeMap = {
        add: { label: 'Deploy', classes: 'bg-success-100 text-success-700' },
        remove: { label: 'Review', classes: 'bg-error-100 text-error-700' },
        modify: { label: 'Redeploy', classes: 'bg-warning-100 text-warning-700' }
    };

    const renderSnapshotList = (items) => {
        if (!items.length) {
            return '<li class="px-3 py-2 bg-neutral-100 rounded-lg text-sm text-neutral-500">None detected</li>';
        }
        return items
            .map((name) => `<li class="px-3 py-2 bg-neutral-100 border border-neutral-200 rounded-lg text-sm text-neutral-700">${escapeHtml(name)}</li>`)
            .join('');
    };

    const tableRows = edgeFunctions.length
        ? edgeFunctions
              .map(item => {
                  const badge = actionBadgeMap[item.action] || { label: 'Unknown', classes: 'bg-neutral-100 text-neutral-700' };
                  const diffLines = Array.isArray(item.diff) ? item.diff : [];
                  const diffSummary = diffLines.length ? `View diff (${diffLines.length} lines)` : 'No diff available';
                  const diffContent = diffLines.length
                      ? `
                          <details class="group">
                              <summary class="cursor-pointer text-sm font-semibold text-primary-600 flex items-center justify-between">
                                  <span>${escapeHtml(diffSummary)}</span>
                                  <svg class="w-4 h-4 text-primary-500 group-open:rotate-180 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                                  </svg>
                              </summary>
                              <pre class="mt-3 bg-slate-900 text-slate-100 rounded-xl p-4 text-xs leading-5 overflow-x-auto whitespace-pre-wrap">${escapeHtml(diffLines.join('\n'))}</pre>
                          </details>
                      `
                      : '<p class="text-sm text-neutral-600">No code changes detected. Ensure function exists in both environments.</p>';

                  return `
                      <tr class="hover:bg-neutral-50">
                          <td class="px-6 py-4 whitespace-nowrap text-sm font-semibold text-neutral-900">${escapeHtml(item.name || 'Unnamed')}</td>
                          <td class="px-6 py-4 whitespace-nowrap text-sm">
                              <span class="badge ${badge.classes}">${badge.label}</span>
                          </td>
                          <td class="px-6 py-4 text-sm text-neutral-600">${item.action === 'modify' ? 'Definitions differ' : item.action === 'add' ? 'New function in source' : item.action === 'remove' ? 'Target-only function' : 'No change detected'}</td>
                          <td class="px-6 py-4 text-sm">${diffContent}</td>
                      </tr>
                  `;
              })
              .join('')
        : `
            <tr>
                <td colspan="4" class="px-6 py-8 text-center text-sm text-neutral-500">
                    <div class="flex flex-col items-center space-y-2">
                        <svg class="w-8 h-8 text-success-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                        </svg>
                        <span class="font-semibold">No edge function differences detected.</span>
                        <span class="text-xs text-neutral-400">Source and target are aligned for edge functions.</span>
                    </div>
                </td>
            </tr>
        `;

    container.innerHTML = `
        <div class="glass-card animate-fade-in space-y-5">
            <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-6">
                <div>
                    <h3 class="text-xl font-bold text-primary-900">Edge Function Sync</h3>
                    <p class="text-sm text-neutral-600 mt-1">
                        Source <span class="font-semibold">${escapeHtml(data?.sourceEnv || '')}</span>
                        → Target <span class="font-semibold">${escapeHtml(data?.targetEnv || '')}</span>
                    </p>
                    ${generatedAt ? `<p class="text-xs text-neutral-500 mt-1">Generated ${escapeHtml(generatedAt)}</p>` : ''}
                </div>
                <div class="metrics-grid">
                    ${metricCards}
                </div>
            </div>
            ${reportButtons ? `<div class="flex flex-wrap gap-3">${reportButtons}</div>` : ''}
        </div>
        <div class="glass-card animate-fade-in">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="border border-neutral-200 rounded-2xl p-4 bg-white/70">
                    <div class="flex items-center justify-between mb-3">
                        <h4 class="text-sm font-semibold text-primary-900">Source (${escapeHtml(data?.sourceEnv || '')})</h4>
                        <span class="text-xs font-semibold text-primary-600 bg-primary-50 px-2.5 py-1 rounded-full">${sourceSnapshot.length} function(s)</span>
                    </div>
                    <ul class="space-y-2 max-h-56 overflow-y-auto">
                        ${renderSnapshotList(sourceSnapshot)}
                    </ul>
                </div>
                <div class="border border-neutral-200 rounded-2xl p-4 bg-white/70">
                    <div class="flex items-center justify-between mb-3">
                        <h4 class="text-sm font-semibold text-primary-900">Target (${escapeHtml(data?.targetEnv || '')})</h4>
                        <span class="text-xs font-semibold text-primary-600 bg-primary-50 px-2.5 py-1 rounded-full">${targetSnapshot.length} function(s)</span>
                    </div>
                    <ul class="space-y-2 max-h-56 overflow-y-auto">
                        ${renderSnapshotList(targetSnapshot)}
                    </ul>
                </div>
            </div>
        </div>
        <div class="glass-card animate-fade-in">
            <div class="flex items-center justify-between mb-4">
                <h3 class="text-lg font-semibold text-primary-900">Edge Functions</h3>
            </div>
            <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-neutral-200">
                    <thead class="bg-neutral-50">
                        <tr>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-neutral-700 uppercase tracking-wider">Function</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-neutral-700 uppercase tracking-wider">Action</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-neutral-700 uppercase tracking-wider">Summary</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-neutral-700 uppercase tracking-wider">Diff</th>
                        </tr>
                    </thead>
                    <tbody class="bg-white divide-y divide-neutral-200">
                        ${tableRows}
                    </tbody>
                </table>
            </div>
        </div>
    `;
}

async function performEdgeComparison(source, target, { auto = false } = {}) {
    const resultContainer = document.getElementById('edgeComparisonResult');
    if (!resultContainer) return;

    if (edgeComparisonInFlight) {
        if (!auto) {
            setEdgeCompareStatus('An edge comparison is already running. Please wait...', 'warning');
        }
        return;
    }

    edgeComparisonInFlight = true;
    const runButton = document.querySelector('#edgeCompareForm button[type="submit"]');
    if (runButton) {
        runButton.disabled = true;
        runButton.classList.add('opacity-70', 'cursor-not-allowed');
    }

    setEdgeCompareStatus(auto ? 'Refreshing edge comparison...' : 'Running edge comparison...', 'info');
    showLoading('edgeCompareLoading');

    resultContainer.innerHTML = `
        <div class="space-y-4">
            <div class="glass-card animate-fade-in">
                <div id="edgeCompareLogHeader" class="flex items-center space-x-3 p-4 bg-primary-50 border-2 border-primary-200 rounded-xl text-primary-800">
                    <svg class="w-5 h-5 text-primary-600 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                    </svg>
                    <div>
                        <strong>Edge comparison running...</strong>
                        <span class="ml-2 px-2 py-1 bg-primary-600 text-white text-xs font-semibold rounded-full">RUNNING</span>
                    </div>
                </div>
                <div id="edgeCompareLogContainer" class="log-container bg-slate-900 rounded-xl p-4 mt-4 max-h-96 overflow-y-auto custom-scrollbar"></div>
            </div>
            <div id="edgeCompareSummary" class="space-y-6"></div>
        </div>
    `;

    const logHeader = resultContainer.querySelector('#edgeCompareLogHeader');
    const logContainer = resultContainer.querySelector('#edgeCompareLogContainer');
    const summaryContainer = resultContainer.querySelector('#edgeCompareSummary');

    if (logContainer) {
        logContainer.classList.add('streaming');
        addLogLine(logContainer, `Source: ${source} → Target: ${target}`, 'stdout');
    }

    const setHeaderState = (state, exitCode = null) => {
        if (!logHeader) return;
        if (state === 'completed') {
            logHeader.className = 'flex items-center space-x-3 p-4 bg-success-50 border-2 border-success-200 rounded-xl text-success-800';
            logHeader.innerHTML = `
                <svg class="w-5 h-5 text-success-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                    <strong>Edge comparison completed</strong>
                    <span class="ml-2 px-2 py-1 bg-success-600 text-white text-xs font-semibold rounded-full">COMPLETED</span>
                    ${exitCode !== null ? `<span class="ml-2 text-xs text-success-700">Exit code ${exitCode}</span>` : ''}
                </div>
            `;
        } else if (state === 'failed') {
            logHeader.className = 'flex items-center space-x-3 p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800';
            logHeader.innerHTML = `
                <svg class="w-5 h-5 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                    <strong>Edge comparison failed</strong>
                    <span class="ml-2 px-2 py-1 bg-error-600 text-white text-xs font-semibold rounded-full">FAILED</span>
                    ${exitCode !== null ? `<span class="ml-2 text-xs text-error-700">Exit code ${exitCode}</span>` : ''}
                </div>
            `;
        } else {
            logHeader.className = 'flex items-center space-x-3 p-4 bg-primary-50 border-2 border-primary-200 rounded-xl text-primary-800';
            logHeader.innerHTML = `
                <svg class="w-5 h-5 text-primary-600 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                </svg>
                <div>
                    <strong>Edge comparison running...</strong>
                    <span class="ml-2 px-2 py-1 bg-primary-600 text-white text-xs font-semibold rounded-full">RUNNING</span>
                </div>
            `;
        }
    };

    let streamStatus = 'running';
    let exitCode = null;
    let comparisonPayload = null;

    const consumeStream = () => new Promise((resolve, reject) => {
        fetch(`${API_BASE}/api/edge-comparison`, {
            method: 'POST',
            headers: {
                ...getAuthHeaders(),
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                sourceEnv: source,
                targetEnv: target,
                stream: true
            })
        })
            .then(response => {
                if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                }

                if (!response.body) {
                    throw new Error('Streaming not supported in this browser');
                }

                const reader = response.body.getReader();
                const decoder = new TextDecoder();
                let buffer = '';

                const finalize = () => {
                    if (logContainer) {
                        logContainer.classList.remove('streaming');
                    }
                    if (streamStatus === 'completed') {
                        if (comparisonPayload) {
                            renderEdgeComparisonResult(comparisonPayload, summaryContainer);
                            const timestamp = comparisonPayload.generatedAt ? `Generated ${formatDate(comparisonPayload.generatedAt)}` : 'Edge comparison completed.';
                            setEdgeCompareStatus(timestamp, 'success');
                        } else {
                            summaryContainer.innerHTML = `
                                <div class="glass-card bg-success-50 border border-success-200 text-success-800 p-6 animate-fade-in">
                                    <p class="font-semibold">Edge comparison completed. No diff payload was generated.</p>
                                </div>
                            `;
                            setEdgeCompareStatus('Edge comparison completed.', 'success');
                        }
                    } else {
                        if (!summaryContainer.innerHTML) {
                            summaryContainer.innerHTML = `
                                <div class="glass-card bg-error-50 border border-error-200 text-error-700 p-6 animate-fade-in">
                                    <p class="font-semibold">Edge comparison failed. Review the logs above for details.</p>
                                </div>
                            `;
                        }
                        if (streamStatus !== 'failed') {
                            setEdgeCompareStatus('Edge comparison ended with issues. Check logs.', 'warning');
                        }
                    }

                    setHeaderState(streamStatus, exitCode);
                    resolve();
                };

                const processLine = (line) => {
                    if (!line.startsWith('data: ')) return;
                    try {
                        const payload = JSON.parse(line.substring(6));
                        if (payload.type === 'stdout' || payload.type === 'stderr') {
                            if (!logContainer) return;
                            const logLines = payload.data.split('\n');
                            logLines.forEach(logLine => {
                                if (logLine.trim()) {
                                    addLogLine(logContainer, logLine, payload.type);
                                }
                            });
                        } else if (payload.type === 'result') {
                            comparisonPayload = payload.data;
                        } else if (payload.type === 'error') {
                            streamStatus = 'failed';
                            if (payload.error) {
                                addLogLine(logContainer, `ERROR: ${payload.error}`, 'stderr');
                                setEdgeCompareStatus(payload.error, 'error');
                            }
                            if (Array.isArray(payload.logs)) {
                                payload.logs.forEach(logLine => addLogLine(logContainer, logLine, 'stderr'));
                            } else if (payload.logs) {
                                addLogLine(logContainer, payload.logs, 'stderr');
                            }
                        } else if (payload.type === 'complete') {
                            streamStatus = payload.status || 'completed';
                            exitCode = payload.exitCode ?? null;
                        }
                    } catch (parseError) {
                        // Ignore malformed SSE payloads
                    }
                };

                const readStream = () => {
                    reader.read().then(({ done, value }) => {
                        if (done) {
                            if (buffer.trim()) {
                                processLine(buffer.trim());
                            }
                            finalize();
                            return;
                        }

                        buffer += decoder.decode(value, { stream: true });
                        const lines = buffer.split('\n');
                        buffer = lines.pop() || '';
                        lines.forEach(line => {
                            if (line.trim()) {
                                processLine(line.trim());
                            }
                        });
                        readStream();
                    }).catch((error) => {
                        streamStatus = 'failed';
                        addLogLine(logContainer, `Stream error: ${error.message}`, 'stderr');
                        setEdgeCompareStatus(error.message, 'error');
                        finalize();
                    });
                };

                readStream();
        })
            .catch(error => {
                streamStatus = 'failed';
                setEdgeCompareStatus(error.message || 'Failed to run edge comparison', 'error');
                if (logContainer) {
                    addLogLine(logContainer, `ERROR: ${error.message}`, 'stderr');
                    logContainer.classList.remove('streaming');
                }
                setHeaderState('failed');
                resolve();
            });
    });

    try {
        await consumeStream();
        lastEdgeComparison = { source, target };
        if (streamStatus === 'completed') {
            setTimeout(loadPlans, 1000);
        }
    } catch (error) {
        console.error('Edge comparison error:', error);
        const message = error?.message || 'Failed to run edge comparison';
        if (summaryContainer && !summaryContainer.innerHTML) {
            summaryContainer.innerHTML = `
                <div class="glass-card bg-error-50 border border-error-200 text-error-700 p-6 animate-fade-in">
                    <p class="font-semibold">${escapeHtml(message)}</p>
                    <p class="text-sm mt-1">Check server logs for more details.</p>
                </div>
            `;
        }
        setEdgeCompareStatus(message, 'error');
        setHeaderState('failed', exitCode);
    } finally {
        hideLoading('edgeCompareLoading');
        edgeComparisonInFlight = false;
        const submitButton = document.querySelector('#edgeCompareForm button[type="submit"]');
        if (submitButton) {
            submitButton.disabled = false;
            submitButton.classList.remove('opacity-70', 'cursor-not-allowed');
        }
    }
}

function onEdgeComparisonTabOpen() {
    const sourceSelect = document.getElementById('edgeCompareSource');
    const targetSelect = document.getElementById('edgeCompareTarget');

    if (!sourceSelect || !targetSelect) {
        return;
    }

    if (lastEdgeComparison) {
        sourceSelect.value = lastEdgeComparison.source;
        targetSelect.value = lastEdgeComparison.target;
    }

    syncSourceTargetDropdowns('edgeCompareSource', 'edgeCompareTarget');

    setEdgeCompareStatus('Select source and target environments, then run the comparison.', 'info');
}

// Generate snapshot for all environments
async function generateAllEnvsSnapshot() {
    const snapshotResults = document.getElementById('snapshotResults');
    const snapshotLoading = document.getElementById('snapshotLoading');
    const comparisonTable = document.getElementById('comparisonTable');
    const snapshotTimestamp = document.getElementById('snapshotTimestamp');
    const snapshotLogWrapper = document.getElementById('snapshotLog');
    const snapshotLogHeader = document.getElementById('snapshotLogHeader');
    const snapshotLogStream = document.getElementById('snapshotLogStream');
    
    if (!snapshotResults || !snapshotLoading || !comparisonTable) return;
    
    const setSnapshotLogState = (state, exitCode = null) => {
        if (!snapshotLogHeader) return;
        if (state === 'completed') {
            snapshotLogHeader.className = 'flex items-center space-x-3 p-4 bg-success-50 border-2 border-success-200 rounded-xl text-success-800';
            snapshotLogHeader.innerHTML = `
                <svg class="w-5 h-5 text-success-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                    <strong>Snapshot completed</strong>
                    <span class="ml-2 px-2 py-1 bg-success-600 text-white text-xs font-semibold rounded-full">COMPLETED</span>
                    ${exitCode !== null ? `<span class="ml-2 text-xs text-success-700">Exit code ${exitCode}</span>` : ''}
                </div>
            `;
        } else if (state === 'failed') {
            snapshotLogHeader.className = 'flex items-center space-x-3 p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800';
            snapshotLogHeader.innerHTML = `
                <svg class="w-5 h-5 text-error-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                    <strong>Snapshot failed</strong>
                    <span class="ml-2 px-2 py-1 bg-error-600 text-white text-xs font-semibold rounded-full">FAILED</span>
                    ${exitCode !== null ? `<span class="ml-2 text-xs text-error-700">Exit code ${exitCode}</span>` : ''}
                </div>
            `;
        } else {
            snapshotLogHeader.className = 'flex items-center space-x-3 p-4 bg-primary-50 border-2 border-primary-200 rounded-xl text-primary-800';
            snapshotLogHeader.innerHTML = `
                <svg class="w-5 h-5 text-primary-600 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                </svg>
                <div>
                    <strong>Generating snapshot...</strong>
                    <span class="ml-2 px-2 py-1 bg-primary-600 text-white text-xs font-semibold rounded-full">RUNNING</span>
                </div>
            `;
        }
    };
    
    const resetSnapshotLog = () => {
        if (!snapshotLogWrapper || !snapshotLogStream) return;
        snapshotLogWrapper.classList.remove('hidden');
        snapshotLogStream.innerHTML = '<div class="text-slate-400 text-xs mb-2">Live snapshot logs will appear here...</div>';
        snapshotLogStream.classList.add('streaming');
        setSnapshotLogState('running');
    };
    
    const appendSnapshotLog = (rawText, type = 'stdout') => {
        if (!snapshotLogStream) return;
        const cleaned = rawText.replace(/\u001b\[[0-9;]*m/g, '');
        cleaned.split('\n').forEach(line => {
            if (line.trim()) {
                addLogLine(snapshotLogStream, line, type);
            }
        });
        snapshotLogStream.scrollTop = snapshotLogStream.scrollHeight;
    };
    
    // Show loading, hide results
    snapshotLoading.classList.remove('hidden');
    snapshotResults.classList.add('hidden');
    comparisonTable.innerHTML = '';
    resetSnapshotLog();
    appendSnapshotLog('Starting environment snapshot generation...', 'stdout');
    
    try {
        const response = await fetch(`${API_BASE}/api/all-envs-snapshot`, {
            method: 'POST',
            headers: {
                ...getAuthHeaders(),
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                stream: true
            })
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let snapshotData = null;
        let streamStatus = 'running';
        let exitCode = null;
        
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            
            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';
            
            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));
                        
                        if ((data.type === 'stdout' || data.type === 'stderr') && data.data) {
                            appendSnapshotLog(data.data, data.type);
                            continue;
                        }
                        
                        if (data.type === 'snapshot') {
                            snapshotData = data.data;
                        } else if (data.type === 'complete') {
                            streamStatus = data.status || 'completed';
                            exitCode = data.exitCode ?? null;

                            // Processing complete
                            snapshotLoading.classList.add('hidden');
                            if (snapshotLogStream) {
                                snapshotLogStream.classList.remove('streaming');
                            }
                            setSnapshotLogState(streamStatus, exitCode);
                            if (streamStatus === 'completed') {
                                appendSnapshotLog('Snapshot generation completed successfully.', 'stdout');
                            } else {
                                appendSnapshotLog('Snapshot process ended with issues. Review logs above.', 'stderr');
                            }
                            
                            if (snapshotData) {
                                displaySnapshotComparison(snapshotData);
                                snapshotResults.classList.remove('hidden');
                                
                                // Scroll to results
                                snapshotResults.scrollIntoView({ behavior: 'smooth', block: 'start' });
                            } else {
                                comparisonTable.innerHTML = `
                                    <div class="p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800">
                                        <p class="font-semibold">Error: Snapshot data not received</p>
                                    </div>
                                `;
                                snapshotResults.classList.remove('hidden');
                            }
                        } else if (data.type === 'error') {
                            streamStatus = 'failed';
                            if (snapshotLogStream) {
                                snapshotLogStream.classList.remove('streaming');
                            }
                            setSnapshotLogState('failed');
                            if (data.error) {
                                appendSnapshotLog(`ERROR: ${data.error}`, 'stderr');
                            }
                            snapshotLoading.classList.add('hidden');
                            comparisonTable.innerHTML = `
                                <div class="p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800">
                                    <p class="font-semibold">Error: ${escapeHtml(data.error)}</p>
                                </div>
                            `;
                            snapshotResults.classList.remove('hidden');
                        }
                    } catch (e) {
                        console.error('Error parsing SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error generating snapshot:', error);
        snapshotLoading.classList.add('hidden');
        if (snapshotLogStream) {
            snapshotLogStream.classList.remove('streaming');
            appendSnapshotLog(`ERROR: ${error.message}`, 'stderr');
        }
        setSnapshotLogState('failed');
        comparisonTable.innerHTML = `
            <div class="p-4 bg-error-50 border-2 border-error-200 rounded-xl text-error-800">
                <p class="font-semibold">Error: ${escapeHtml(error.message)}</p>
            </div>
        `;
        snapshotResults.classList.remove('hidden');
    }
}

// Display snapshot comparison
function displaySnapshotComparison(snapshotData) {
    const comparisonTable = document.getElementById('comparisonTable');
    const snapshotTimestamp = document.getElementById('snapshotTimestamp');
    
    if (!comparisonTable) return;
    
    // Set timestamp
    if (snapshotTimestamp && snapshotData.timestamp) {
        snapshotTimestamp.textContent = `Generated: ${new Date(snapshotData.timestamp).toLocaleString()}`;
    }
    
    // Extract environment data
    const envs = snapshotData.environments || {};
    const envOrder = ['dev', 'test', 'prod', 'backup'];
    const envDisplay = {
        dev: { label: 'Development', short: 'Dev', icon: '🟢', iconClass: 'text-success-600' },
        test: { label: 'Test/Staging', short: 'Test', icon: '🟡', iconClass: 'text-warning-600' },
        prod: { label: 'Production', short: 'Prod', icon: '🔴', iconClass: 'text-error-600' },
        backup: { label: 'Backup', short: 'Backup', icon: '🔵', iconClass: 'text-primary-600' }
    };

    const sanitizeValue = (value) => (value && value !== 'N/A' ? value : '');

    const envColumns = envOrder.map((key) => {
        const base = envDisplay[key] || { label: key.toUpperCase(), short: key.toUpperCase(), icon: '⚪️', iconClass: 'text-neutral-400' };
        const data = envs[key] || {};
        const counts = data.counts || {};
        const tableRows = Array.isArray(data.tableRows) ? data.tableRows : [];
        const storageBucketObjects = Array.isArray(data.storageBucketObjects) ? data.storageBucketObjects : [];

        const projectName = sanitizeValue(data.projectName);
        const projectRef = sanitizeValue(data.projectRef);
        const envData = {
            ...data,
            name: data.name || base.label,
            projectName: projectName || projectRef || 'N/A',
            projectRef
        };

        return {
            key,
            displayLabel: base.label,
            shortLabel: base.short,
            icon: base.icon,
            iconClass: base.iconClass,
            counts,
            tableRows,
            storageBucketObjects,
            envData
        };
    });

    const formatNumber = (value) => {
        if (typeof value === 'number' && Number.isFinite(value)) return value.toLocaleString();
        const numeric = Number(value);
        return Number.isFinite(numeric) ? numeric.toLocaleString() : (value ?? '0');
    };
    
    // Define comparison rows
    const rows = [
        { label: 'Tables', key: 'tables' },
        { label: 'Total Table Rows', key: 'totalRows' },
        { label: 'Views', key: 'views' },
        { label: 'Functions', key: 'functions' },
        { label: 'Sequences', key: 'sequences' },
        { label: 'Indexes', key: 'indexes' },
        { label: 'Policies', key: 'policies' },
        { label: 'Triggers', key: 'triggers' },
        { label: 'Types', key: 'types' },
        { label: 'Enums', key: 'enums' },
        { label: 'Auth Users', key: 'authUsers' },
        { label: 'Edge Functions', key: 'edgeFunctions' },
        { label: 'Storage Buckets', key: 'buckets' },
        { label: 'Storage Objects', key: 'storageObjects' },
        { label: 'Secrets', key: 'secrets' }
    ];
    
    // Generate comparison table
    let tableHTML = `
        <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-neutral-200">
                <thead class="bg-neutral-50">
                    <tr>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-neutral-700 uppercase tracking-wider">Object Type</th>
                        ${envColumns.map(col => `
                            <th class="px-6 py-3 text-center text-xs font-semibold text-neutral-700 uppercase tracking-wider">
                                <div class="flex items-center justify-center space-x-2">
                                    <span class="${col.iconClass}">${col.icon}</span>
                                    <span>${escapeHtml(col.envData.name || col.displayLabel)}</span>
                                </div>
                                <div class="text-xs font-normal text-neutral-500 mt-1">${escapeHtml(col.envData.projectName || col.envData.projectRef || 'N/A')}</div>
                            </th>
                        `).join('')}
                    </tr>
                </thead>
                <tbody class="bg-white divide-y divide-neutral-200">
    `;
    
    rows.forEach(row => {
        const values = envColumns.map(col => {
            const raw = col.counts?.[row.key];
            if (typeof raw === 'number' && Number.isFinite(raw)) return raw;
            const numeric = Number(raw);
            return Number.isFinite(numeric) ? numeric : 0;
        });
        
        const allSame = values.every((val, idx, arr) => idx === 0 || val === arr[0]);
        const rowClass = allSame ? '' : 'bg-warning-50';
        
        // Highlight differences
        const getCellClass = (val, idx) => {
            const othersMatch = values.every((other, otherIdx) => otherIdx === idx || other === val);
            const classes = [];
            if (!othersMatch) {
                classes.push('font-semibold', 'text-primary-700');
            }
            if (!val || Number(val) === 0) {
                const filtered = classes.filter(cls => !cls.startsWith('text-'));
                filtered.push('text-neutral-400');
                return filtered.join(' ');
            }
            return classes.join(' ');
        };
        
        tableHTML += `
            <tr class="${rowClass} hover:bg-neutral-50">
                <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-neutral-900">${escapeHtml(row.label)}</td>
                ${values.map((val, idx) => `
                    <td class="px-6 py-4 whitespace-nowrap text-sm text-center ${getCellClass(val, idx)}">${formatNumber(val)}</td>
                `).join('')}
            </tr>
        `;
    });
    
    tableHTML += `
                </tbody>
            </table>
        </div>
    `;
    
    const renderMetricCard = (envData, items, title, valueFormatter, emptyMessage) => {
        const displayName = escapeHtml(envData.name || 'Environment');
        const projectInfo = escapeHtml(envData.projectName || envData.projectRef || 'N/A');
        if (!items.length) {
            return `
                <div class="border border-neutral-200 rounded-xl bg-white p-4 shadow-sm">
                    <div class="flex items-center justify-between mb-3">
                        <div>
                            <p class="text-sm font-semibold text-primary-800">${title}</p>
                            <p class="text-xs text-neutral-500">${projectInfo}</p>
                        </div>
                        <span class="text-xs text-neutral-400 uppercase tracking-wide">${displayName}</span>
                    </div>
                    <p class="text-sm text-neutral-500">${emptyMessage}</p>
                </div>
            `;
        }

        const listItems = items
            .slice()
            .sort((a, b) => (b.rows ?? b.objects ?? 0) - (a.rows ?? a.objects ?? 0))
            .map(item => valueFormatter(item))
            .join('');

        return `
            <div class="border border-neutral-200 rounded-xl bg-white p-4 shadow-sm">
                <div class="flex items-center justify-between mb-3">
                    <div>
                        <p class="text-sm font-semibold text-primary-800">${title}</p>
                        <p class="text-xs text-neutral-500">${projectInfo}</p>
                    </div>
                    <span class="text-xs text-neutral-400 uppercase tracking-wide">${displayName}</span>
                </div>
                <div class="space-y-2 max-h-64 overflow-y-auto custom-scrollbar pr-2">
                    ${listItems}
                </div>
            </div>
        `;
    };

    const renderTableRowItem = ({ schema, table, rows }) => `
        <div class="flex items-center justify-between rounded-lg bg-neutral-50 px-3 py-2 text-sm">
            <span class="font-medium text-neutral-700">${escapeHtml([schema, table].filter(Boolean).join('.'))}</span>
            <span class="text-primary-700 font-semibold">${formatNumber(rows)}</span>
        </div>
    `;

    const renderStorageObjectItem = ({ bucket, objects }) => `
        <div class="flex items-center justify-between rounded-lg bg-neutral-50 px-3 py-2 text-sm">
            <span class="font-medium text-neutral-700">${escapeHtml(bucket || 'Default')}</span>
            <span class="text-primary-700 font-semibold">${formatNumber(objects)}</span>
        </div>
    `;

    const tableCards = envColumns.map(col =>
        renderMetricCard(
            col.envData,
            col.tableRows,
            col.displayLabel,
            renderTableRowItem,
            'No table data available'
        )
    ).join('');

    const storageCards = envColumns.map(col =>
        renderMetricCard(
            col.envData,
            col.storageBucketObjects,
            col.displayLabel,
            renderStorageObjectItem,
            'No storage objects found'
        )
    ).join('');

    const detailSections = `
        <div class="mt-8 space-y-8">
            <div>
                <h4 class="text-base font-semibold text-primary-900 mb-3">Table Row Breakdown</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
                    ${tableCards}
                </div>
            </div>
            <div>
                <h4 class="text-base font-semibold text-primary-900 mb-3">Storage Objects per Bucket</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
                    ${storageCards}
                </div>
            </div>
        </div>
    `;
    
    comparisonTable.innerHTML = tableHTML + detailSections;
}

// Helper function to stream logs via SSE
function streamMigrationLogs(endpoint, body, resultElementId, loadingElementId) {
    const resultDiv = document.getElementById(resultElementId);
    const logContainer = document.createElement('div');
    logContainer.className = 'log-container bg-slate-900 rounded-xl p-6 mt-4 max-h-96 overflow-y-auto custom-scrollbar';
    logContainer.id = `${resultElementId}_log`;
    
    let logContent = '';
    let status = 'running';
    
    // Show initial state
    resultDiv.innerHTML = `
        <div class="flex items-center space-x-3 p-4 bg-primary-50 border-2 border-primary-200 rounded-xl text-primary-800 animate-fade-in">
            <svg class="w-5 h-5 text-primary-600 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
            </svg>
            <div>
                <strong>Migration Running...</strong>
                <span class="ml-2 px-2 py-1 bg-primary-600 text-white text-xs font-semibold rounded-full">RUNNING</span>
            </div>
        </div>
    `;
    logContainer.classList.add('streaming');
    resultDiv.appendChild(logContainer);
    
    if (loadingElementId) showLoading(loadingElementId);
    
    // Use fetch with streaming for SSE
    fetch(`${API_BASE}${endpoint}`, {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify({ ...body, stream: true })
    })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        
        function readStream() {
            reader.read().then(({ done, value }) => {
                if (done) {
                    // Process any remaining buffer
                    if (buffer.trim()) {
                        processSSEData(buffer);
                    }
                    
                    // Update final status
                    const statusClass = status === 'completed' ? 'success' : 'error';
                    const statusText = status === 'completed' ? 'Completed' : 'Failed';
                    const statusBadge = status === 'completed' ? 'COMPLETED' : 'FAILED';
                    const badgeColor = status === 'completed' ? 'bg-success-600' : 'bg-error-600';
                    
                    // Remove streaming indicator
                    logContainer.classList.remove('streaming');
                    
                    // Update header with final status
                    const header = resultDiv.querySelector('.flex.items-center');
                    if (header) {
                        header.className = `flex items-center space-x-3 p-4 ${statusClass === 'success' ? 'bg-success-50 border-success-200 text-success-800' : 'bg-error-50 border-error-200 text-error-800'} border-2 rounded-xl animate-fade-in`;
                        header.innerHTML = `
                            <svg class="w-5 h-5 ${statusClass === 'success' ? 'text-success-600' : 'text-error-600'}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                ${statusClass === 'success' ? 
                                    '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>' :
                                    '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>'
                                }
                            </svg>
                            <div>
                                <strong>Migration ${statusText}</strong>
                                <span class="ml-2 px-2 py-1 ${badgeColor} text-white text-xs font-semibold rounded-full">${statusBadge}</span>
                            </div>
                        `;
                    }
                    
                    if (loadingElementId) hideLoading(loadingElementId);
                    
                    // Reload history if this is main migration
                    if (resultElementId === 'mainResult') {
                        setTimeout(loadHistory, 1000);
                    }
                    return;
                }
                
                // Decode chunk and add to buffer
                buffer += decoder.decode(value, { stream: true });
                
                // Process complete lines (ending with \n)
                const lines = buffer.split('\n');
                buffer = lines.pop() || ''; // Keep incomplete line in buffer
                
                lines.forEach(line => {
                    if (line.trim()) {
                        processSSEData(line);
                    }
                });
                
                readStream();
            }).catch(error => {
                status = 'failed';
                addLogLine(logContainer, `Stream Error: ${error.message}`, 'stderr');
                if (loadingElementId) hideLoading(loadingElementId);
            });
        }
        
        function processSSEData(line) {
            if (line.startsWith('data: ')) {
                try {
                    const data = JSON.parse(line.substring(6));
                    
                    if (data.type === 'stdout' || data.type === 'stderr') {
                        // Process data line by line
                        const logLines = data.data.split('\n');
                        logLines.forEach(logLine => {
                            if (logLine.trim()) {
                                addLogLine(logContainer, logLine, data.type);
                                logContent += logLine + '\n';
                            }
                        });
                    } else if (data.type === 'complete') {
                        status = data.status;
                        addLogLine(logContainer, `\n[Migration ${data.status} - Exit code: ${data.exitCode}]`, data.status === 'completed' ? 'stdout' : 'stderr');
                    } else if (data.type === 'error') {
                        status = 'failed';
                        addLogLine(logContainer, `ERROR: ${data.error}`, 'stderr');
                    }
                } catch (e) {
                    // Ignore parse errors
                }
            }
        }
        
        readStream();
    })
    .catch(error => {
        if (loadingElementId) hideLoading(loadingElementId);
        showResult(resultElementId, `Error: ${error.message}`, 'error');
    });
}

// Production migration confirmation state
let pendingMigrationAction = null;

// Show production confirmation modal
function showProdConfirmModal(migrationType, sourceEnv, targetEnv, migrationAction) {
    // Store the migration action to execute after confirmation
    // Wrap the action in a function to ensure it's called correctly
    pendingMigrationAction = {
        type: migrationType,
        source: sourceEnv,
        target: targetEnv,
        action: () => {
            // Execute the migration action immediately
            if (typeof migrationAction === 'function') {
                migrationAction();
            } else {
                console.error('Migration action is not a function:', migrationAction);
            }
        }
    };
    
    // Reset form
    document.getElementById('migrationReason').value = '';
    document.getElementById('proceedConfirmation').value = '';
    document.getElementById('prodConfirmError').classList.add('hidden');
    document.getElementById('prodConfirmButton').disabled = true;
    
    // Show modal
    document.getElementById('prodConfirmModal').classList.remove('hidden');
    
    // Focus on reason field
    setTimeout(() => {
        document.getElementById('migrationReason').focus();
    }, 100);
}

// Close production confirmation modal
function closeProdConfirmModal() {
    document.getElementById('prodConfirmModal').classList.add('hidden');
    pendingMigrationAction = null;
    document.getElementById('migrationReason').value = '';
    document.getElementById('proceedConfirmation').value = '';
    document.getElementById('prodConfirmError').classList.add('hidden');
}

// Confirm production migration
function confirmProdMigration() {
    const reason = document.getElementById('migrationReason').value.trim();
    const confirmation = document.getElementById('proceedConfirmation').value.trim();
    const errorDiv = document.getElementById('prodConfirmError');
    const errorMessage = document.getElementById('prodConfirmErrorMessage');
    
    // Validate reason
    if (!reason || reason.length < 10) {
        errorMessage.textContent = 'Please provide a detailed reason (at least 10 characters)';
        errorDiv.classList.remove('hidden');
        return;
    }
    
    // Validate confirmation text
    if (confirmation !== 'PROCEED') {
        errorMessage.textContent = 'Please type "PROCEED" exactly to confirm';
        errorDiv.classList.remove('hidden');
        return;
    }
    
    // Store the action before closing modal
    const migrationAction = pendingMigrationAction ? pendingMigrationAction.action : null;
    const migrationType = pendingMigrationAction ? pendingMigrationAction.type : '';
    const migrationSource = pendingMigrationAction ? pendingMigrationAction.source : '';
    const migrationTarget = pendingMigrationAction ? pendingMigrationAction.target : '';
    
    // Close modal
    closeProdConfirmModal();
    
    // Execute the pending migration action
    if (migrationAction) {
        // Log the reason to console (could also send to server)
        console.log(`Production migration reason: ${reason}`);
        console.log(`Migration: ${migrationType} from ${migrationSource} to ${migrationTarget}`);
        
        // Execute the migration action
        try {
            migrationAction();
        } catch (error) {
            console.error('Error executing migration:', error);
            showResult('mainResult', `Error starting migration: ${error.message}`, 'error');
        }
    } else {
        console.error('No migration action found');
    }
}

// Check if target is production and show confirmation
function checkProdMigration(targetEnv, migrationType, sourceEnv, migrationAction) {
    if (targetEnv && targetEnv.toLowerCase() === 'prod') {
        showProdConfirmModal(migrationType, sourceEnv, targetEnv, migrationAction);
        return false; // Prevent default submission
    }
    return true; // Allow submission
}


// Migration Plan Form
document.getElementById('planForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('planSource').value;
    const target = document.getElementById('planTarget').value;

    if (source === target) {
        showResult('planResult', 'Source and target environments must be different!', 'error');
        return;
    }
    
    // Check for production migration
    const startPlanMigration = () => {
        streamMigrationLogs('/api/migration-plan', {
            sourceEnv: source,
            targetEnv: target
        }, 'planResult', 'planLoading');
    };
    
    if (!checkProdMigration(target, 'Migration Plan', source, startPlanMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startPlanMigration();
});

// Main Migration Form
document.getElementById('mainMigrationForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('mainSource').value;
    const target = document.getElementById('mainTarget').value;

    if (source === target) {
        showResult('mainResult', 'Source and target environments must be different!', 'error');
        return;
    }

    const options = {
        data: document.getElementById('mainData').checked,
        users: document.getElementById('mainUsers').checked,
        files: document.getElementById('mainFiles').checked,
        backup: document.getElementById('mainBackup').checked,
        dryRun: document.getElementById('mainDryRun').checked
    };
    
    // Check for production migration
    const startMainMigration = () => {
        streamMigrationLogs('/api/migration', {
            sourceEnv: source,
            targetEnv: target,
            options
        }, 'mainResult', 'mainLoading');
        
        // Reload history after a delay (assuming migration will take some time)
        setTimeout(loadHistory, 5000);
    };
    
    if (!checkProdMigration(target, 'Main Migration', source, startMainMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startMainMigration();
});

// Database Migration Form
document.getElementById('dbForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('dbSource').value;
    const target = document.getElementById('dbTarget').value;

    if (source === target) {
        showResult('dbResult', 'Source and target environments must be different!', 'error');
        return;
    }
    
    const options = {
        data: document.getElementById('dbData').checked,
        users: document.getElementById('dbUsers').checked,
        backup: document.getElementById('dbBackup').checked
    };
    
    // Check for production migration
    const startDbMigration = () => {
        streamMigrationLogs('/api/migration/database', {
            sourceEnv: source,
            targetEnv: target,
            options
        }, 'dbResult', null);
    };
    
    if (!checkProdMigration(target, 'Database Migration', source, startDbMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startDbMigration();
});

// Storage Migration Form
document.getElementById('storageForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('storageSource').value;
    const target = document.getElementById('storageTarget').value;

    if (source === target) {
        showResult('storageResult', 'Source and target environments must be different!', 'error');
        return;
    }
    
    const options = {
        files: document.getElementById('storageFiles').checked
    };
    
    // Check for production migration
    const startStorageMigration = () => {
        streamMigrationLogs('/api/migration/storage', {
            sourceEnv: source,
            targetEnv: target,
            options
        }, 'storageResult', null);
    };
    
    if (!checkProdMigration(target, 'Storage Migration', source, startStorageMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startStorageMigration();
});

// Edge Functions Migration Form
document.getElementById('edgeForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('edgeSource').value;
    const target = document.getElementById('edgeTarget').value;

    if (source === target) {
        showResult('edgeResult', 'Source and target environments must be different!', 'error');
        return;
    }
    
    // Check for production migration
    const startEdgeMigration = () => {
        streamMigrationLogs('/api/migration/edge-functions', {
            sourceEnv: source,
            targetEnv: target
        }, 'edgeResult', null);
    };
    
    if (!checkProdMigration(target, 'Edge Functions Migration', source, startEdgeMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startEdgeMigration();
});

// Secrets Migration Form
document.getElementById('secretsForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const source = document.getElementById('secretsSource').value;
    const target = document.getElementById('secretsTarget').value;

    if (source === target) {
        showResult('secretsResult', 'Source and target environments must be different!', 'error');
        return;
    }
    
    const options = {
        values: document.getElementById('secretsValues').checked
    };
    
    // Check for production migration
    const startSecretsMigration = () => {
        streamMigrationLogs('/api/migration/secrets', {
            sourceEnv: source,
            targetEnv: target,
            options
        }, 'secretsResult', null);
    };
    
    if (!checkProdMigration(target, 'Secrets Migration', source, startSecretsMigration)) {
        return; // Modal shown, wait for confirmation
    }

    // If not production, proceed directly
    startSecretsMigration();
});

// Format migration type name for display
function formatMigrationType(type) {
    if (!type) return 'Migration';
    // Convert kebab-case to Title Case
    return type
        .split('-')
        .map(word => word.charAt(0).toUpperCase() + word.slice(1))
        .join(' ');
}

// Load active jobs and update indicator
async function loadActiveJobs() {
    try {
        const response = await fetch(`${API_BASE}/api/jobs/active`, {
            headers: getAuthHeaders()
        });
        const data = await response.json();
        activeJobs = data.jobs || [];
        
        const indicator = document.getElementById('activeJobsIndicator');
        const jobsTextElement = document.getElementById('activeJobsText');
        
        if (activeJobs.length > 0) {
            indicator.classList.remove('hidden');
            
            // Show migration names
            if (activeJobs.length === 1) {
                const job = activeJobs[0];
                const typeName = formatMigrationType(job.type);
                jobsTextElement.textContent = `${typeName} (${job.sourceEnv} → ${job.targetEnv}) running...`;
            } else {
                // Show count and first job name
                const firstJob = activeJobs[0];
                const typeName = formatMigrationType(firstJob.type);
                jobsTextElement.textContent = `${activeJobs.length} jobs running (${typeName}...)`;
            }
        } else {
            indicator.classList.add('hidden');
        }
    } catch (error) {
        console.error('Error loading active jobs:', error);
    }
}

// Show active jobs modal
function showActiveJobs() {
    if (activeJobs.length === 0) return;
    
    const modal = document.createElement('div');
    modal.className = 'fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4';
    modal.innerHTML = `
        <div class="bg-white rounded-2xl shadow-2xl max-w-2xl w-full max-h-[80vh] flex flex-col animate-slide-up">
            <div class="flex items-center justify-between p-6 border-b border-neutral-200">
                <h2 class="text-xl font-bold text-primary-900">Active Jobs</h2>
                <button onclick="this.closest('.fixed').remove()" 
                    class="p-2 hover:bg-neutral-100 rounded-lg transition-colors duration-200">
                    <svg class="w-6 h-6 text-neutral-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
                    </svg>
                </button>
            </div>
            <div class="flex-1 overflow-y-auto p-6">
                <div class="space-y-4">
                    ${activeJobs.map(job => `
                        <div class="bg-neutral-50 border-2 border-neutral-200 rounded-xl p-4 hover:border-primary-300 transition-colors">
                            <div class="flex items-center justify-between mb-2">
                                <div class="flex items-center space-x-2">
                                    <svg class="w-5 h-5 text-warning-600 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                                    </svg>
                                    <span class="font-semibold text-primary-900">${job.type.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase())}</span>
                                </div>
                                <span class="px-2 py-1 bg-warning-100 text-warning-700 text-xs font-semibold rounded-full">Running</span>
                            </div>
                            <div class="text-sm text-neutral-600 space-y-1">
                                <p><strong>Source:</strong> ${job.sourceEnv}</p>
                                <p><strong>Target:</strong> ${job.targetEnv}</p>
                                <p><strong>Started:</strong> ${new Date(job.startTime).toLocaleString()}</p>
                            </div>
                            <button onclick="navigateToJob('${job.processId}')" 
                                class="mt-3 w-full px-4 py-2 bg-primary-500 text-white text-sm font-semibold rounded-lg hover:bg-primary-600 transition-colors">
                                View Job Details
                            </button>
                        </div>
                    `).join('')}
                </div>
            </div>
        </div>
    `;
    document.body.appendChild(modal);
    
    // Close on backdrop click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });
}

// Navigate to job
function navigateToJob(processId) {
    // Find which tab this job belongs to and switch to it
    const job = activeJobs.find(j => j.processId === processId);
    if (!job) return;
    
    // Map job types to tabs
    const tabMap = {
        'migration-plan': 'migration-plan',
        'main-migration': 'main-migration',
        'database-migration': 'components',
        'storage-migration': 'components',
        'edge-functions-migration': 'components',
        'secrets-migration': 'components'
    };
    
    const tabName = tabMap[job.type] || 'history';
    const tabButton = Array.from(document.querySelectorAll('.tab-button')).find(btn => 
        btn.textContent.toLowerCase().includes(tabName.split('-')[0])
    );
    
    if (tabButton) {
        switchTab(tabName, tabButton);
        // Scroll to the result area
        setTimeout(() => {
            const resultDiv = document.querySelector(`#${tabName}Result, #planResult, #mainResult`);
            if (resultDiv) {
                resultDiv.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }, 100);
    }
}

// Load migration history
async function loadHistory() {
    try {
        const response = await fetch(`${API_BASE}/api/migrations`, {
            headers: getAuthHeaders()
        });
        
        if (!response.ok) {
            throw new Error(`Failed to load migrations: ${response.statusText}`);
        }
        
        const data = await response.json();
        const migrations = data.migrations || [];
        
        const historyList = document.getElementById('historyList');
        if (!historyList) {
            console.error('historyList element not found');
            return;
        }
        
        if (migrations.length === 0) {
            historyList.innerHTML = `
                <div class="text-center py-12 text-slate-500">
                    <svg class="w-16 h-16 mx-auto mb-4 text-slate-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                    </svg>
                    <p class="text-lg font-medium">No migrations found</p>
                    <p class="text-sm">Run a migration to see it here</p>
                </div>
            `;
            return;
        }
        
        // Sort migrations by timestamp (newest first)
        const sortedMigrations = [...migrations].sort((a, b) => {
            const dateA = new Date(a.timestamp || 0);
            const dateB = new Date(b.timestamp || 0);
            return dateB - dateA;
        });
        
        historyList.innerHTML = sortedMigrations.map(migration => `
            <div class="bg-white border-2 border-slate-200 rounded-xl p-4 hover:border-primary-300 hover:shadow-md transition-all duration-200">
                <div class="flex items-center justify-between">
                    <div class="flex-1">
                        <h3 class="font-semibold text-slate-900 mb-1">${escapeHtml(migration.name)}</h3>
                        <p class="text-sm text-slate-500">
                            <svg class="w-4 h-4 inline-block mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
                            </svg>
                            ${formatDate(migration.timestamp)}
                        </p>
                    </div>
                    <div class="flex items-center space-x-2">
                        ${migration.logPath ? `
                            <button onclick="viewLog('${migration.logPath}')" 
                                class="px-3 py-1.5 bg-slate-100 text-slate-700 text-sm font-medium rounded-lg hover:bg-slate-200 transition-colors">
                                View Log
                            </button>
                        ` : ''}
                        ${migration.reportPath ? `
                            <button onclick="viewReport('${migration.reportPath}')" 
                                class="px-3 py-1.5 bg-primary-600 text-white text-sm font-medium rounded-lg hover:bg-primary-700 transition-colors">
                                View Report
                            </button>
                        ` : ''}
                    </div>
                </div>
            </div>
        `).join('');
    } catch (error) {
        console.error('Error loading history:', error);
        const historyList = document.getElementById('historyList');
        if (historyList) {
            historyList.innerHTML = `
                <div class="text-center py-12 text-red-500">
                    <p class="text-lg font-medium">Error loading migration history</p>
                    <p class="text-sm">${error.message}</p>
                </div>
            `;
        }
    }
}

// Load migration plans
async function loadPlans() {
    try {
        const response = await fetch(`${API_BASE}/api/migrations`, {
            headers: getAuthHeaders()
        });
        const data = await response.json();
        const plans = data.plans || [];
        
        const plansList = document.getElementById('plansList');
        if (!plansList) return;
        
        if (plans.length === 0) {
            plansList.innerHTML = `
                <div class="text-center py-12 text-slate-500">
                    <svg class="w-16 h-16 mx-auto mb-4 text-slate-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"></path>
                    </svg>
                    <p class="text-lg font-medium">No migration plans found</p>
                    <p class="text-sm">Generate a migration plan to see it here</p>
                </div>
            `;
            return;
        }
        
        // Sort plans by timestamp (newest first)
        const sortedPlans = [...plans].sort((a, b) => {
            const dateA = new Date(a.timestamp || 0);
            const dateB = new Date(b.timestamp || 0);
            return dateB - dateA;
        });
        
        plansList.innerHTML = sortedPlans.map(plan => `
            <div class="bg-white border-2 border-slate-200 rounded-xl p-4 hover:border-primary-300 hover:shadow-md transition-all duration-200">
                <div class="flex items-center justify-between">
                    <div class="flex-1">
                        <h3 class="font-semibold text-slate-900 mb-1">${escapeHtml(plan.name)}</h3>
                        <p class="text-sm text-slate-500">
                            <svg class="w-4 h-4 inline-block mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
                            </svg>
                            ${formatDate(plan.timestamp)}
                        </p>
                    </div>
                    <div class="flex items-center space-x-2">
                        <button onclick="window.open('${plan.path}', '_blank')" 
                            class="px-4 py-2 bg-primary-600 text-white text-sm font-semibold rounded-lg hover:bg-primary-700 shadow-md hover:shadow-lg transition-all duration-200">
                            View Plan
                        </button>
                    </div>
                </div>
            </div>
        `).join('');
    } catch (error) {
        console.error('Error loading plans:', error);
    }
}

// View log
async function viewLog(logPath) {
    try {
        // Extract migration name from path like /backups/migration_name/migration.log
        const migrationName = logPath.split('/').filter(Boolean)[1];
        
        const response = await fetch(`${API_BASE}/api/migrations/${migrationName}/log`);
        const data = await response.json();
        
        const logModal = document.getElementById('logModal');
        const logContent = document.getElementById('logContent');
        logContent.innerHTML = formatLogOutput(data.content);
        logModal.classList.remove('hidden');
    } catch (error) {
        alert(`Error loading log: ${error.message}`);
    }
}

// View report
function viewReport(reportPath) {
    window.open(reportPath, '_blank');
}

// Close log modal
function closeLogModal() {
    document.getElementById('logModal').classList.add('hidden');
}

// Sync all dropdown pairs
function syncAllDropdowns() {
    syncSourceTargetDropdowns('planSource', 'planTarget');
    syncSourceTargetDropdowns('mainSource', 'mainTarget');
    syncSourceTargetDropdowns('dbSource', 'dbTarget');
    syncSourceTargetDropdowns('storageSource', 'storageTarget');
    syncSourceTargetDropdowns('edgeSource', 'edgeTarget');
    syncSourceTargetDropdowns('secretsSource', 'secretsTarget');
    syncSourceTargetDropdowns('edgeCompareSource', 'edgeCompareTarget');
}

// Load environments on page load
async function loadEnvironments() {
    try {
        const response = await fetch(`${API_BASE}/api/environments`, {
            headers: getAuthHeaders()
        });
        if (!response.ok) {
            // If environments endpoint doesn't exist, use hardcoded list
            // Still sync dropdowns even with hardcoded values
            setTimeout(() => {
                syncAllDropdowns();
            }, 100);
            return;
        }
        const envs = await response.json();
        
        // Populate all select elements
        document.querySelectorAll('select[id$="Source"], select[id$="Target"]').forEach(select => {
            const currentValue = select.value;
            select.innerHTML = '<option value="">Select...</option>' + 
                envs.map(env => `<option value="${env}" ${env === currentValue ? 'selected' : ''}>${env}</option>`).join('');
        });
        
        // Sync dropdowns after environments are loaded
        setTimeout(() => {
            syncAllDropdowns();
        }, 100);
    } catch (error) {
        console.error('Error loading environments:', error);
        // Still sync dropdowns even if loading fails
        setTimeout(() => {
            syncAllDropdowns();
        }, 100);
    }
}

// Logout function
function logout() {
    // Clear the stored token
    localStorage.removeItem('migrationToolToken');
    
    // Clear any active job polling
    if (jobsCheckInterval) {
        clearInterval(jobsCheckInterval);
        jobsCheckInterval = null;
    }
    
    // Redirect to login page
    window.location.href = '/';
}

// Function to sync source/target dropdowns (disable same env in opposite dropdown)
function syncSourceTargetDropdowns(sourceId, targetId) {
    const sourceSelect = document.getElementById(sourceId);
    const targetSelect = document.getElementById(targetId);
    
    if (!sourceSelect || !targetSelect) return;
    
    // Remove existing listeners to avoid duplicates
    const sourceClone = sourceSelect.cloneNode(true);
    sourceSelect.parentNode.replaceChild(sourceClone, sourceSelect);
    const targetClone = targetSelect.cloneNode(true);
    targetSelect.parentNode.replaceChild(targetClone, targetSelect);
    
    // Get fresh references after cloning
    const freshSourceSelect = document.getElementById(sourceId);
    const freshTargetSelect = document.getElementById(targetId);
    
    // Function to update disabled states
    function updateDisabledStates() {
        const sourceValue = freshSourceSelect.value;
        const targetValue = freshTargetSelect.value;
        
        // Enable all options first
        Array.from(freshTargetSelect.options).forEach(option => {
            if (option.value !== '') { // Don't disable the "Select..." option
                option.disabled = false;
                option.style.opacity = '1';
                option.style.cursor = 'pointer';
            }
        });
        Array.from(freshSourceSelect.options).forEach(option => {
            if (option.value !== '') { // Don't disable the "Select..." option
                option.disabled = false;
                option.style.opacity = '1';
                option.style.cursor = 'pointer';
            }
        });
        
        // Disable selected source in target dropdown
        if (sourceValue) {
            Array.from(freshTargetSelect.options).forEach(option => {
                if (option.value === sourceValue) {
                    option.disabled = true;
                    option.style.opacity = '0.5';
                    option.style.cursor = 'not-allowed';
                }
            });
        }
        
        // Disable selected target in source dropdown
        if (targetValue) {
            Array.from(freshSourceSelect.options).forEach(option => {
                if (option.value === targetValue) {
                    option.disabled = true;
                    option.style.opacity = '0.5';
                    option.style.cursor = 'not-allowed';
                }
            });
        }
        
        // If target is same as source, clear target
        if (sourceValue && targetValue === sourceValue) {
            freshTargetSelect.value = '';
            updateDisabledStates(); // Recursive call to update states
        }
        
        // If source is same as target, clear source
        if (targetValue && sourceValue === targetValue) {
            freshSourceSelect.value = '';
            updateDisabledStates(); // Recursive call to update states
        }
    }
    
    // Update on change
    freshSourceSelect.addEventListener('change', updateDisabledStates);
    freshTargetSelect.addEventListener('change', updateDisabledStates);
    
    // Initial update
    updateDisabledStates();
}

// Initialize production confirmation modal handlers
function initProdConfirmModal() {
    const reasonInput = document.getElementById('migrationReason');
    const proceedInput = document.getElementById('proceedConfirmation');
    const confirmButton = document.getElementById('prodConfirmButton');
    
    if (reasonInput && proceedInput && confirmButton) {
        function updateConfirmButton() {
            const reason = reasonInput.value.trim();
            const confirmation = proceedInput.value.trim();
            confirmButton.disabled = !(reason.length >= 10 && confirmation === 'PROCEED');
        }
        
        reasonInput.addEventListener('input', updateConfirmButton);
        proceedInput.addEventListener('input', updateConfirmButton);
        
        // Allow Enter key to submit when button is enabled
        proceedInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter' && !confirmButton.disabled) {
                e.preventDefault();
                confirmProdMigration();
            }
        });
        
        // Also allow Enter in reason field to move to confirmation field
        reasonInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                proceedInput.focus();
            }
        });
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
    // Check authentication
    if (!getAuthToken()) {
        window.location.href = '/';
        return;
    }
    
    // Initialize production confirmation modal
    initProdConfirmModal();

    const edgeCompareForm = document.getElementById('edgeCompareForm');
    if (edgeCompareForm) {
        edgeCompareForm.addEventListener('submit', (event) => {
            event.preventDefault();
            const source = document.getElementById('edgeCompareSource')?.value;
            const target = document.getElementById('edgeCompareTarget')?.value;

            if (!source || !target) {
                setEdgeCompareStatus('Please select both source and target environments.', 'warning');
                return;
            }

            if (source === target) {
                setEdgeCompareStatus('Source and target environments must be different.', 'error');
                return;
            }

            performEdgeComparison(source, target, { auto: false });
        });
    }
    
    loadAppInfo();
    loadEnvironments();
    loadHistory();
    loadPlans();
    loadActiveJobs();
    
    // Sync dropdowns will be called after environments are loaded
    // (handled in loadEnvironments function)
    
    // Poll for active jobs every 5 seconds
    jobsCheckInterval = setInterval(loadActiveJobs, 5000);
    
    // Clean up on page unload
    window.addEventListener('beforeunload', () => {
        if (jobsCheckInterval) {
            clearInterval(jobsCheckInterval);
        }
    });
});

async function loadManualContent(containerId, sourcePath) {
    const container = document.getElementById(containerId);
    if (!container) return;

    try {
        const response = await fetch(sourcePath);
        if (!response.ok) {
            throw new Error(`Unable to load ${sourcePath}`);
        }
        const markdown = await response.text();
        let htmlContent = '';
        if (window.marked) {
            htmlContent = window.marked.parse(markdown);
        } else {
            htmlContent = `<pre class="whitespace-pre-wrap">${escapeHtml(markdown)}</pre>`;
        }
        container.innerHTML = `<article class="space-y-4 prose prose-slate max-w-none">${htmlContent}</article>`;
    } catch (error) {
        container.innerHTML = `<div class="text-error-600 text-center">${escapeHtml(error.message)}</div>`;
        throw error;
    }
}
