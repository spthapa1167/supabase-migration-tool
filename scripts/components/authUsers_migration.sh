#!/usr/bin/env bash

# Thin wrapper that delegates auth user migration to the Node.js implementation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_SCRIPT="${PROJECT_ROOT}/utils/auth-users-migrate.js"

# Handle help flags before delegating to Node.js
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<EOF
Usage: $(basename "$0") <source_env> <target_env> [migration_dir] [--replace] [--increment]

Migrates authentication users and identities from source to target environment.

Arguments:
  source_env     Source environment (prod, test, dev, backup)
  target_env     Target environment (prod, test, dev, backup)
  migration_dir  Directory to store migration files (optional, auto-generated if not provided)

Options:
  --replace      Replace all target auth users (destructive). Without this flag, runs in incremental/upsert mode.
  --increment    Explicitly request incremental mode (default behavior if --replace is not used)
  -h, --help     Show this help message

Default Behavior:
  By default, runs in incremental/upsert mode - existing auth users in target are preserved,
  and new users from source are added. Use --replace to clear target auth data first.

Examples:
  # Incremental migration (default - upsert mode)
  $0 dev test

  # Replace mode (destructive - clears target auth users first)
  $0 dev test --replace

  # Custom migration directory
  $0 dev test backups/custom_auth_migration --replace

Returns:
  0 on success, 1 on failure

Migration artifacts are stored in: backups/auth_users_migration_<source>_to_<target>_<timestamp>/

EOF
    exit 0
fi

if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] node command not found. Please install Node.js." >&2
    exit 1
fi

cd "$PROJECT_ROOT"
exec node "$NODE_SCRIPT" "$@"


