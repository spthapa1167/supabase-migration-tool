#!/bin/bash
# Wrapper: Develop → Test (Schema Only)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/duplicate_schema.sh" dev test "$@"

