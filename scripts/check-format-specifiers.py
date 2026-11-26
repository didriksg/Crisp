#!/usr/bin/env python3
"""Fail if a translation's printf specifiers differ from its English string.

String(format:) reads its arguments by the specifiers in the translated text, so a
zh-Hans "%d" where English has "%@" reads the wrong type and can crash Crisp for
everyone in that language. Compares the specifiers in argument order, positional
ones (%1$@) included. Blocking on every run, unlike check-translations.py.

Usage: check-format-specifiers.py [Localizable.xcstrings]
"""
import json
import re
import sys

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])")
SAME = {"q": "ll", "i": "d", "D": "d", "U": "u", "O": "o", "F": "f"}


def specifiers(text: str) -> dict:
    """Argument number -> specifier, without %%."""
    args, next_arg = {}, 1
    for match in SPEC.finditer(text):
        position, length, conversion = match.groups()
        if conversion == "%":
            continue
        arg = int(position) if position else next_arg
        next_arg = arg + 1
        args[arg] = SAME.get(length, length or "") + SAME.get(conversion, conversion)
    return args


def units(node):
    """Every non-empty stringUnit value under a localization, plural variations included."""
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if unit and unit.get("value"):
            yield unit["value"]
        for value in node.values():
            yield from units(value)


def main(path: str) -> int:
    data = json.load(open(path, encoding="utf-8"))
    source = data.get("sourceLanguage", "en")
    bad = []
    for key, entry in data.get("strings", {}).items():
        localizations = entry.get("localizations", {})
        english = specifiers(next(units(localizations.get(source, {})), key))
        for lang, localization in sorted(localizations.items()):
            if lang == source:
                continue
            for value in units(localization):
                if specifiers(value) != english:
                    bad.append((lang, key, value))
    for lang, key, value in bad:
        print(f"  [{lang}] {key!r} -> {value!r}", file=sys.stderr)
    if bad:
        print(f"{len(bad)} translation(s) with format specifiers that differ from English", file=sys.stderr)
        return 1
    print("Format specifiers match English in every translation")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "Crisp/Resources/Localizable.xcstrings"))
