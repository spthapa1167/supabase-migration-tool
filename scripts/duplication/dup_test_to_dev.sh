#!/bin/bash
# Wrapper: Test → Develop (Full)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/duplicate_full.sh" test dev "$@"

