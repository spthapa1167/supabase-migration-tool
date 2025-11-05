#!/bin/bash
# Wrapper: Develop → Production (Schema Only)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/duplicate_schema.sh" dev prod "$@"

