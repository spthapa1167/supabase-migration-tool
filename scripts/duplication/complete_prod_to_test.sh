#!/bin/bash
# Complete Migration: Production → Test
# Migrates ALL aspects: Database, Storage, Edge Functions, Secrets, Auth, Realtime, Cron

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

exec "$PROJECT_ROOT/scripts/duplicate_complete.sh" prod test "$@"

