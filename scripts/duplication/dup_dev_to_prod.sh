#!/bin/bash
# Wrapper: Develop → Production (Full)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/duplicate_full.sh" dev prod "$@"

