#!/usr/bin/env python3
"""
Rewrite INSERT statements to append ON CONFLICT DO NOTHING; every row remains as-is, only the terminating semicolon is replaced.
"""

import sys

if len(sys.argv) != 3:
    print("Usage: sql_add_on_conflict.py <input.sql> <output.sql>", file=sys.stderr)
    sys.exit(1)

input_path, output_path = sys.argv[1], sys.argv[2]

try:
    with open(input_path, "r", encoding="utf-8") as f_in, open(output_path, "w", encoding="utf-8") as f_out:
        inside = False
        buffer = []
        for line in f_in:
            if not inside and line.upper().startswith("INSERT INTO"):
                inside = True
                buffer = [line]
                continue
            if inside:
                buffer.append(line)
                if line.rstrip().endswith(";"):
                    statement = "".join(buffer)
                    statement = statement.rstrip().rstrip(";") + " ON CONFLICT DO NOTHING;\n"
                    f_out.write(statement)
                    inside = False
                continue
            f_out.write(line)
        if inside:
            statement = "".join(buffer)
            statement = statement.rstrip().rstrip(";") + " ON CONFLICT DO NOTHING;\n"
            f_out.write(statement)
except FileNotFoundError:
    print(f"[ERROR] File not found: {input_path}", file=sys.stderr)
    sys.exit(1)

