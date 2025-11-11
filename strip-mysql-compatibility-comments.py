#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
strip_mysql_v2.py

Remove MySQL/MariaDB versioned compatibility comments of the form
    /*!50003 ... */
for versions earlier than MySQL 8.0 (i.e. version number < 80000).

Regular comments (/* ... */, -- ..., # ...) are kept as-is.
Comments like "/* bulk deletion */" inside triggers are preserved.
"""

import sys
from typing import List


def strip_versioned_comments(sql: str, version_threshold: int = 80000) -> str:
    """
    Scan the SQL text and unwrap all MySQL versioned comments of the form:

        /*!<digits> ... */

    If the version number is lower than `version_threshold`, the inner content
    is emitted as plain SQL. Otherwise the whole comment is kept as-is.

    This function correctly handles nested regular block comments "/* ... */"
    inside the versioned comment.
    """
    out: List[str] = []
    n = len(sql)
    i = 0

    while i < n:
        # Look for start of a versioned comment: "/*!"
        if i + 2 < n and sql[i] == "/" and sql[i + 1] == "*" and sql[i + 2] == "!":
            # Parse version digits after "/*!"
            j = i + 3
            while j < n and sql[j].isdigit():
                j += 1
            version_str = sql[i + 3:j]
            if not version_str:
                # Not actually a versioned comment, just output "/"
                out.append(sql[i])
                i += 1
                continue

            try:
                version = int(version_str)
            except ValueError:
                version = 0

            # Find the matching closing "*/"
            # Allow nested regular comments "/* ... */" inside.
            inner_start = j
            depth = 0
            k = j
            end_pos = None

            while k < n - 1:
                two = sql[k:k + 2]

                if two == "/*":
                    depth += 1
                    k += 2
                    continue

                if two == "*/":
                    if depth == 0:
                        end_pos = k
                        break
                    else:
                        depth -= 1
                        k += 2
                        continue

                k += 1

            if end_pos is None:
                # Malformed comment: just output the rest and stop
                out.append(sql[i:])
                break

            inner = sql[inner_start:end_pos]

            if version < version_threshold:
                # Unwrap: keep only the inner content as plain SQL
                out.append(inner)
            else:
                # Keep the whole comment as-is
                out.append(sql[i:end_pos + 2])

            # Jump past the closing "*/"
            i = end_pos + 2
        else:
            # Normal character, just copy
            out.append(sql[i])
            i += 1

    return "".join(out)


def main() -> None:
    """
    CLI entry point.
    Reads from file given as argv[1] (or stdin if not provided),
    writes cleaned SQL to stdout.
    """
    if len(sys.argv) > 1 and sys.argv[1] not in ("", "-"):
        with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
            sql_text = f.read()
    else:
        sql_text = sys.stdin.read()

    cleaned = strip_versioned_comments(sql_text, version_threshold=80000)
    sys.stdout.write(cleaned)


if __name__ == "__main__":
    main()
