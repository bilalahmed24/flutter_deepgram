#!/usr/bin/env python3
"""Compute line coverage from lcov files produced by `dart test --coverage`.

Usage:
  python3 tool/coverage.py <lcov-file-or-dir> [--lib-root PATH]

Accepts a single .lcov file or a directory containing .lcov files (merged).
Prints per-file coverage and an overall summary. Files under `lib/` only.
"""

import argparse
import glob
import os
import re
import sys


def parse_lcov(path: str) -> dict:
    per_file: dict = {}
    current: str | None = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("SF:"):
                current = line[3:]
                per_file.setdefault(current, {"hit": 0, "found": 0})
            elif line.startswith("DA:") and current is not None:
                parts = line[3:].split(",")
                if parts and parts[0].isdigit():
                    per_file[current]["found"] += 1
                    if len(parts) > 1 and int(parts[1]) > 0:
                        per_file[current]["hit"] += 1
            elif line == "end_of_record":
                current = None
    return per_file


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="lcov file or directory of lcov files")
    parser.add_argument("--lib-root", default=None, help="prefix to strip")
    parser.add_argument(
        "--min", type=float, default=0.0, help="fail below this overall ratio"
    )
    args = parser.parse_args()

    paths = []
    if os.path.isdir(args.source):
        paths = sorted(
            glob.glob(os.path.join(args.source, "**", "*.lcov"), recursive=True)
        )
    else:
        paths = [args.source]
    if not paths:
        print("no lcov files found", file=sys.stderr)
        return 2

    merged: dict = {}
    for path in paths:
        for file, counts in parse_lcov(path).items():
            entry = merged.setdefault(file, {"hit": 0, "found": 0})
            entry["hit"] += counts["hit"]
            entry["found"] += counts["found"]

    total_hit = 0
    total_found = 0
    rows = []
    for file in sorted(merged):
        counts = merged[file]
        # Normalize path.
        norm = file
        if args.lib_root:
            norm = re.sub(args.lib_root, "", norm)
        norm = norm.lstrip("./")
        found = counts["found"]
        hit = counts["hit"]
        if "lib/" in norm or norm.startswith("lib/"):
            total_hit += hit
            total_found += found
            pct = 100.0 * hit / found if found else 100.0
            rows.append((pct, hit, found, norm))

    rows.sort()
    for pct, hit, found, name in rows:
        print(f"{pct:6.1f}%  {hit:5d}/{found:<5d}  {name}")

    overall = 100.0 * total_hit / total_found if total_found else 0.0
    print("-" * 60)
    print(f"OVERALL: {overall:.1f}%  ({total_hit}/{total_found} lib lines)")
    if overall < args.min:
        print(f"BELOW MINIMUM {args.min:.1f}%", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
