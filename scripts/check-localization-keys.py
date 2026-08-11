#!/usr/bin/env python3
"""Fail if code uses a localization key that Localizable.xcstrings lacks.

SwiftUI coalesces interpolated LocalizedStringKey text into "%@"-style lookup
keys, and NSLocalizedString looks up its literal key. When the catalog has no
entry for that key, the UI silently falls back to English at runtime, which no
catalog-side check can see (the key simply is not there). This script compares
the keys the compiler actually extracts (xcodebuild -exportLocalizations)
against the catalog, so a key used in code but missing from the catalog fails
CI instead of shipping.

Usage: check-localization-keys.py <en.xcloc> <Localizable.xcstrings> [allowlist]

The allowlist holds pre-existing gaps (one key per line, '#' for comments) so
the check can be enforcing for regressions from day one. Remove entries as the
gaps get fixed; stale entries are reported so the list cannot rot silently.
"""
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

XLIFF_NS = "urn:oasis:names:tc:xliff:document:1.2"


def extracted_keys(xcloc: Path, catalog_name: str) -> set:
    """Keys the compiler extracted for the given catalog, across all xliffs."""
    keys = set()
    for xliff in (xcloc / "Localized Contents").glob("*.xliff"):
        root = ET.parse(xliff).getroot()
        for file_el in root.iter(f"{{{XLIFF_NS}}}file"):
            if Path(file_el.get("original", "")).name != catalog_name:
                continue
            for unit in file_el.iter(f"{{{XLIFF_NS}}}trans-unit"):
                key = unit.get("id")
                if key:
                    keys.add(key)
    return keys


def main(argv: list) -> int:
    xcloc = Path(argv[1])
    catalog_path = Path(argv[2])
    allowlist_path = Path(argv[3]) if len(argv) > 3 else None

    catalog_keys = set(json.load(open(catalog_path, encoding="utf-8"))["strings"])
    used = extracted_keys(xcloc, catalog_path.name)
    if not used:
        print(f"error: no keys extracted from {xcloc}; export likely failed", file=sys.stderr)
        return 1

    allowed = set()
    if allowlist_path and allowlist_path.exists():
        for line in open(allowlist_path, encoding="utf-8"):
            line = line.rstrip("\n")
            if line and not line.lstrip().startswith("#"):
                allowed.add(line)

    missing = used - catalog_keys
    stale = allowed - missing
    if stale:
        print(f"note: {len(stale)} stale allowlist entr(ies), remove them:")
        for key in sorted(stale):
            print(f"  {key!r}")

    unexpected = sorted(missing - allowed)
    if unexpected:
        print(f"{len(unexpected)} key(s) used in code but missing from {catalog_path.name}:", file=sys.stderr)
        for key in unexpected:
            print(f"  {key!r}", file=sys.stderr)
        print("Add the key(s) to the catalog (or, for a pre-existing gap, to the allowlist).", file=sys.stderr)
        return 1

    print(f"OK: all {len(used)} extracted keys exist in {catalog_path.name} ({len(missing & allowed)} allowlisted).")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv))
