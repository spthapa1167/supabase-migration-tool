#!/usr/bin/env python3
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("Usage: filter_policies.py <source_sql> <destination_sql>")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])

if not source.exists():
    raise SystemExit(f"Source SQL file not found: {source}")

disallowed_schemas = {"storage"}

statement = []
statements = []
with source.open("r", encoding="utf-8") as infile:
    for line in infile:
        statement.append(line)
        if line.rstrip().endswith(";"):
            statements.append("".join(statement))
            statement = []
if statement:
    statements.append("".join(statement))

def keep_statement(stmt: str) -> bool:
    lower_stmt = stmt.lower()
    return not any(f"{schema}." in lower_stmt or f'"{schema}"' in lower_stmt for schema in disallowed_schemas)

with destination.open("w", encoding="utf-8") as outfile:
    for stmt in statements:
        if keep_statement(stmt):
            outfile.write(stmt.strip() + "\n\n")
