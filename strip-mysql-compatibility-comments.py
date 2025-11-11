#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
strip-mysql-compatibility-comments.py

Stream-process a large MySQL/MariaDB dump and remove versioned
compatibility comments of the form:

    /*!<digits> ... */

for versions earlier than MySQL 8.0 (i.e. version number < 80000).

Everything else is written as-is, including regular code comments:

    /* comment inside of the trigger */
    -- some comment
    # another comment

The script never loads the whole file into memory.
It reads line by line and only keeps one versioned comment block
in memory at a time.

Usage:
    python strip-mysql-compatibility-comments.py input.sql output.sql
"""

import os
import sys
from typing import Tuple, Optional


def find_conditional_end(comment: str) -> Tuple[Optional[int], Optional[int]]:
    """
    Given a string that starts with a versioned comment:

        /*!<digits>...

    find the index of the closing "*/" that terminates THIS comment,
    correctly handling nested regular block comments "/* ... */" inside.

    Returns:
        (end_pos, digits_end)

        end_pos   - index where the closing "*/" starts (or None if not found)
        digits_end - index right after the version digits (i.e. start of inner content)
    """
    n = len(comment)
    # comment[0:3] should be "/*!"
    j = 3
    while j < n and comment[j].isdigit():
        j += 1
    digits_end = j
    version_str = comment[3:digits_end]
    if not version_str:
        return None, None

    depth = 0
    k = digits_end
    end_pos = None

    while k < n - 1:
        two = comment[k:k + 2]

        if two == "/*":
            # nested regular block comment
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

    return end_pos, digits_end


def process_dump_stream(
    in_path: str,
    out_path: str,
    version_threshold: int = 80000,
) -> None:
    """
    Stream-process input dump:

    - read line by line
    - for each '/*!<digits>' block, read until its matching '*/'
      (across multiple lines, with nested '/* ... */' support)
    - if version < threshold: unwrap (emit only inner content)
    - else: keep the whole comment as-is
    - write everything to out_path
    - print progress to stderr
    """
    total_size = os.path.getsize(in_path)
    processed_bytes = 0
    last_percent_reported = -1.0

    with open(in_path, "r", encoding="utf-8", errors="replace") as fin, \
         open(out_path, "w", encoding="utf-8", errors="replace") as fout:

        while True:
            line = fin.readline()
            if not line:
                break  # EOF

            processed_bytes += len(line.encode("utf-8", errors="replace"))
            # We may modify 'line' as we consume versioned comments
            pos = 0

            while True:
                idx = line.find("/*!", pos)
                if idx == -1:
                    # No more versioned comments in this line/tail
                    fout.write(line[pos:])
                    break

                # Check that we actually have digits after /*! (versioned comment)
                j = idx + 3
                while j < len(line) and line[j].isdigit():
                    j += 1
                if j == idx + 3:
                    # Not a "/*!<digits>" pattern; treat as normal text up to "/*!"
                    fout.write(line[pos:idx + 3])
                    pos = idx + 3
                    continue

                # We have '/*!<digits>' starting at idx.
                # Collect the full comment block (which may span multiple lines).
                comment = line[idx:]

                while True:
                    end_pos, digits_end = find_conditional_end(comment)
                    if end_pos is not None:
                        break

                    # Need more data (comment not closed yet)
                    next_line = fin.readline()
                    if not next_line:
                        # EOF inside comment - just output what we have and exit
                        fout.write(line[pos:idx])
                        fout.write(comment)
                        return

                    processed_bytes += len(next_line.encode("utf-8", errors="replace"))
                    comment += next_line

                    # Progress update here as well
                    percent = (processed_bytes / total_size) * 100 if total_size > 0 else 100.0
                    if percent - last_percent_reported >= 1.0:
                        last_percent_reported = percent
                        print(f"{percent:5.1f}%...", file=sys.stderr, flush=True)

                # At this point we have a full '/*!<digits> ... */' in 'comment'
                version_str = comment[3:digits_end]
                try:
                    version = int(version_str)
                except ValueError:
                    version = 0

                inner = comment[digits_end:end_pos]   # content inside the comment
                tail = comment[end_pos + 2:]          # what follows after '*/' (could be ';;' etc.)

                # Write everything before the comment from the original 'line'
                fout.write(line[pos:idx])

                # Decide whether to unwrap or keep the comment
                if version < version_threshold:
                    # Unwrap: emit only the inner content
                    fout.write(inner)
                else:
                    # Keep the whole comment block as-is
                    fout.write(comment[:end_pos + 2])

                # Now we continue processing the tail of the comment
                line = tail
                pos = 0

            # Progress update after each (original) line
            percent = (processed_bytes / total_size) * 100 if total_size > 0 else 100.0
            if percent - last_percent_reported >= 1.0:
                last_percent_reported = percent
                print(f"{percent:5.1f}%...", file=sys.stderr, flush=True)

    # Final 100% report
    print("100.0%... done.", file=sys.stderr, flush=True)


def main() -> None:
    if len(sys.argv) != 3:
        print(
            "Usage: python strip-mysql-compatibility-comments.py input.sql output.sql",
            file=sys.stderr,
        )
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2]

    if not os.path.isfile(in_path):
        print(f"Input file not found: {in_path}", file=sys.stderr)
        sys.exit(1)

    process_dump_stream(in_path, out_path, version_threshold=80000)


if __name__ == "__main__":
    main()
