// Supabase Migration Tool - Web UI JavaScript

const API_BASE = '';

// Get auth token from URL or localStorage
function getAuthToken() {
    const urlParams = new URLSearchParams(window.location.search);
    const token = urlParams.get('token') || localStorage.getItem('migrationToolToken');
    return token;
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
        btn.classList.remove('active', 'bg-primary-600', 'text-white', 'shadow-md');
        btn.classList.add('text-slate-600', 'hover:bg-slate-100');
    });

    // Show selected tab
    const selectedTab = document.getElementById(tabName);
    if (selectedTab) {
        selectedTab.classList.remove('hidden');
    }

    // Update button
    if (clickedElement) {
        clickedElement.classList.add('active', 'bg-primary-600', 'text-white', 'shadow-md');
        clickedElement.classList.remove('text-slate-600', 'hover:bg-slate-100');
    }

    // Load data for history tab
    if (tabName === 'history') {
        setTimeout(() => {
            loadHistory();
            loadPlans();
        }, 100);
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
        if (line.includes('ERROR') || line.includes('✗') || line.includes('Failed')) {
            className = 'text-error-400';
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
    
    // Apply styling based on content
    if (type === 'stderr' || text.includes('ERROR') || text.includes('✗') || text.includes('Failed')) {
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
