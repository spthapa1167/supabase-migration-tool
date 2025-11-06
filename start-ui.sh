#!/bin/bash
# Start Web UI Server for Supabase Migration Tool

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if Node.js is installed
if ! command -v node >/dev/null 2>&1; then
    echo "❌ Node.js is not installed"
    echo "Please install Node.js from: https://nodejs.org/"
    exit 1
fi

# Check if dependencies are installed
if [ ! -d "node_modules" ]; then
    echo "📦 Installing dependencies..."
    npm install
fi

# Check if .env.local exists
if [ ! -f ".env.local" ]; then
    echo "⚠️  Warning: .env.local not found"
    echo "Make sure your environment variables are set before running migrations"
fi

# Start server
echo "🚀 Starting Supabase Migration Tool - Web UI Server"
echo ""
echo "   Server will be available at: http://localhost:${PORT:-3000}"
echo "   Press Ctrl+C to stop the server"
echo ""

node server.js

