#!/bin/bash
# Setup and Validation Script for Supabase Project Duplication Tool
# This script validates your configuration and ensures everything is ready

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Supabase Project Duplication Tool - Setup & Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Check if .env.local exists
log_info "Step 1: Checking environment configuration..."

if [ ! -f .env.local ]; then
    log_warning ".env.local file not found!"
    echo ""
    log_info "Creating .env.local from template..."
    if [ -f .env.example ]; then
        cp .env.example .env.local
        log_success ".env.local created from .env.example"
        log_warning "Please edit .env.local with your Supabase project details"
        log_info "Then run this script again: ./setup.sh"
        exit 0
    else
        log_error ".env.example not found. Cannot create .env.local"
        exit 1
    fi
fi

log_success ".env.local file exists"
echo ""

# Step 2: Load and validate environment variables
log_info "Step 2: Validating environment variables..."

source .env.local

# Required variables
REQUIRED_VARS=(
    "SUPABASE_ACCESS_TOKEN"
    "SUPABASE_PROD_PROJECT_REF"
    "SUPABASE_PROD_DB_PASSWORD"
    "SUPABASE_TEST_PROJECT_REF"
    "SUPABASE_TEST_DB_PASSWORD"
    "SUPABASE_DEV_PROJECT_REF"
    "SUPABASE_DEV_DB_PASSWORD"
    "SUPABASE_BACKUP_PROJECT_REF"
    "SUPABASE_BACKUP_DB_PASSWORD"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ] || [[ "${!var}" == *"your_"* ]] || [[ "${!var}" == *"here"* ]]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Missing or incomplete environment variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    log_warning "Please edit .env.local and fill in all required values"
    exit 1
fi

log_success "All required environment variables are set"
echo ""

# Step 3: Validate project references format
log_info "Step 3: Validating project reference formats..."

PROJECT_REFS=(
    "$SUPABASE_PROD_PROJECT_REF"
    "$SUPABASE_TEST_PROJECT_REF"
    "$SUPABASE_DEV_PROJECT_REF"
    "$SUPABASE_BACKUP_PROJECT_REF"
)

INVALID_REFS=()
for ref in "${PROJECT_REFS[@]}"; do
    if ! [[ "$ref" =~ ^[a-z0-9]{20}$ ]]; then
        INVALID_REFS+=("$ref")
    fi
done

if [ ${#INVALID_REFS[@]} -gt 0 ]; then
    log_warning "Some project references may be invalid (should be 20 lowercase alphanumeric characters):"
    for ref in "${INVALID_REFS[@]}"; do
        echo "  - $ref"
    done
    log_info "Project references typically look like: abcdefghijklmnopqrst"
else
    log_success "Project reference formats look valid"
fi
echo ""

# Step 4: Check for duplicate project references
log_info "Step 4: Checking for duplicate project references..."

TOTAL_REFS=${#PROJECT_REFS[@]}
UNIQUE_REFS=$(printf '%s\n' "${PROJECT_REFS[@]}" | sort -u | wc -l)
if [ "$UNIQUE_REFS" -lt "$TOTAL_REFS" ]; then
    log_error "Duplicate project references detected!"
    log_error "Each environment must have a unique project reference"
    exit 1
fi

log_success "All project references are unique"
echo ""

# Step 5: Check Supabase CLI
log_info "Step 5: Checking Supabase CLI installation..."

if ! command -v supabase &> /dev/null; then
    log_error "Supabase CLI is not installed"
    log_info "Install it with: npm install -g supabase"
    log_info "Or visit: https://supabase.com/docs/guides/cli/getting-started"
    exit 1
fi

SUPABASE_VERSION=$(supabase --version 2>/dev/null | head -1 || echo "unknown")
log_success "Supabase CLI is installed: $SUPABASE_VERSION"
echo ""

# Step 6: Check PostgreSQL tools
log_info "Step 6: Checking PostgreSQL tools..."

MISSING_TOOLS=()
for tool in pg_dump pg_restore psql; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log_warning "Some PostgreSQL tools are missing:"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    log_info "Install PostgreSQL client tools for your system"
    log_info "macOS: brew install postgresql"
    log_info "Ubuntu: sudo apt-get install postgresql-client"
else
    log_success "All PostgreSQL tools are available"
fi
echo ""

# Step 7: Test Supabase authentication
log_info "Step 7: Testing Supabase authentication..."

export SUPABASE_ACCESS_TOKEN
if supabase projects list &> /dev/null; then
    log_success "Successfully authenticated with Supabase"
else
    log_warning "Could not authenticate with Supabase"
    log_info "This may be due to:"
    log_info "  1. Invalid access token"
    log_info "  2. Network connectivity issues"
    log_info "  3. Supabase API issues"
    log_info ""
    log_info "You can still proceed, but authentication will be tested when you run scripts"
fi
echo ""

# Step 8: Verify project access (optional)
log_info "Step 8: Verifying project access..."

if supabase projects list &> /dev/null; then
    PROJECTS=$(supabase projects list 2>/dev/null | grep -E "^\s+[a-z0-9]{20}" | awk '{print $3}' || echo "")
    
    FOUND_PROJECTS=0
    for ref in "${PROJECT_REFS[@]}"; do
        if echo "$PROJECTS" | grep -q "$ref"; then
            FOUND_PROJECTS=$((FOUND_PROJECTS + 1))
        fi
    done
    
    if [ "$FOUND_PROJECTS" -eq 3 ]; then
        log_success "All three projects are accessible"
    elif [ "$FOUND_PROJECTS" -gt 0 ]; then
        log_warning "Found $FOUND_PROJECTS out of 3 projects"
        log_info "Some projects may not be accessible or may have different reference IDs"
    else
        log_warning "Could not verify project access"
        log_info "Make sure your access token has access to all three projects"
    fi
else
    log_warning "Skipping project verification (authentication failed)"
fi
echo ""

# Step 9: Check Docker (for schema pulling)
log_info "Step 9: Checking Docker (optional, for schema pulling)..."

if docker ps &> /dev/null; then
    log_success "Docker is running"
    log_info "You can use 'db pull' commands to extract schema from production"
else
    log_warning "Docker is not running"
    log_info "Docker is required for 'supabase db pull' command"
    log_info "You can still use duplication scripts, but schema pulling will require Docker"
fi
echo ""

# Step 10: Make scripts executable
log_info "Step 10: Ensuring scripts are executable..."

chmod +x scripts/*.sh lib/*.sh sync_*.sh setup.sh validate.sh 2>/dev/null || true
log_success "Scripts are executable"
echo ""

# Final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Setup validation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "Your configuration:"
echo "  Production: $SUPABASE_PROD_PROJECT_REF"
echo "  Test:       $SUPABASE_TEST_PROJECT_REF"
echo "  Develop:   $SUPABASE_DEV_PROJECT_REF"
echo ""

log_info "Quick start commands:"
echo "  Full duplication:    ./scripts/dup_prod_to_test.sh"
echo "  Schema-only:          ./scripts/schema_prod_to_test.sh"
echo "  See all options:      ./scripts/README.md"
echo ""

log_info "Documentation:"
echo "  README.md              - Overview and quick start"
echo "  DUPLICATION_GUIDE.md   - Complete duplication guide"
echo "  MIGRATION_GUIDE.md     - Migration workflow guide"
echo ""

log_success "You're ready to use the Supabase Project Duplication Tool! 🚀"
echo ""

