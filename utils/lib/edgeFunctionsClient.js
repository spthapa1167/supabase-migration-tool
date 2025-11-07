#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { createClient } = require('@supabase/supabase-js');

const ensureCommand = (cmd) => spawnSync('which', [cmd], { stdio: 'ignore' }).status === 0;

const ensureUnzip = () => {
    if (!ensureCommand('unzip')) {
        throw new Error('The "unzip" command is required but was not found on PATH.');
    }
};

const createManagementClient = (accessToken) => {
    if (!accessToken) {
        throw new Error('SUPABASE_ACCESS_TOKEN is required');
    }

    const client = createClient('https://api.supabase.com', accessToken, {
        auth: {
            persistSession: false,
            autoRefreshToken: false
        },
        global: {
            headers: {
                Authorization: `Bearer ${accessToken}`,
                apikey: accessToken,
                'X-Client-Info': 'edge-functions-tool/1.0'
            }
        }
    });

    const fetchWithClient = async (url, options = {}) => {
        const response = await client.fetch(url, options);
        if (!response) {
            throw new Error('Empty response from Supabase Management API');
        }
        return response;
    };

    const fetchJson = async (url) => {
        const response = await fetchWithClient(url, {
            method: 'GET',
            headers: {
                Accept: 'application/json'
            }
        });

        if (!response.ok) {
            const body = await response.text();
            const error = new Error(`HTTP ${response.status}: ${body.slice(0, 200)}`);
            error.status = response.status;
            throw error;
        }

        return response.json();
    };

    const downloadZip = async (url) => {
        const response = await fetchWithClient(url, {
            method: 'GET',
            headers: {
                Accept: 'application/zip'
            }
        });

        if (!response.ok) {
            const body = await response.text();
            const error = new Error(`HTTP ${response.status}: ${body.slice(0, 200)}`);
            error.status = response.status;
            throw error;
        }

        const arrayBuffer = await response.arrayBuffer();
        return Buffer.from(arrayBuffer);
    };

    const extractZipBuffer = (buffer, destination) => {
        ensureUnzip();
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'edge-zip-'));
        const zipPath = path.join(tmpDir, 'bundle.zip');
        fs.writeFileSync(zipPath, buffer);
        fs.mkdirSync(destination, { recursive: true });
        const result = spawnSync('unzip', ['-q', zipPath, '-d', destination], { stdio: 'ignore' });
        fs.rmSync(tmpDir, { recursive: true, force: true });
        if (result.status !== 0) {
            throw new Error('Unable to extract edge function bundle');
        }
    };

    const fetchFunctionList = async (projectRef) => {
        const url = `https://api.supabase.com/v1/projects/${projectRef}/functions`;
        const data = await fetchJson(url);
        if (!Array.isArray(data)) {
            throw new Error('Unexpected response format from edge function list API');
        }
        return data
            .map((fn) => fn && typeof fn.name === 'string' ? fn.name : null)
            .filter(Boolean)
            .sort();
    };

    const downloadFunctionCode = async (projectRef, functionName, destination) => {
        const url = `https://api.supabase.com/v1/projects/${projectRef}/functions/${functionName}/download`;
        const buffer = await downloadZip(url);
        extractZipBuffer(buffer, destination);
    };

    return {
        fetchFunctionList,
        downloadFunctionCode
    };
};

module.exports = {
    ensureUnzip,
    createManagementClient
};

