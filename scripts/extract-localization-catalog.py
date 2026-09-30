#!/usr/bin/env python3
"""Refresh the app string catalog from SwiftUI's user-facing literals.

Xcode extracts these at build time, but keeping the catalog in source control
lets CI detect a newly introduced string before a release. Values for locales
other than English are intentionally marked needs_review until a native-speaker
review supplies the final translation.
"""
from __future__ import annotations

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Resources/Localizable.xcstrings"
LOCALES = ("en", "zh-Hans", "es", "fr", "de", "ja", "pt-BR")
CALLS = ("Text", "Button", "Section", "Label", "Toggle", "Picker", "NavigationLink", "LabeledContent")
STRING = r'"((?:\\.|[^"\\])*)"'
PATTERN = re.compile(r"(?:" + "|".join(CALLS) + r")\s*\(\s*" + STRING)

def decode(value: str) -> str:
    # Decode Swift's escaped quote/newline syntax without running UTF-8
    # source text through unicode_escape (which turns characters such as ·
    # into mojibake).
    return (value.replace(r'\"', '"')
                 .replace(r'\\', '\\')
                 .replace(r'\n', '\n'))

def main() -> None:
    data = json.loads(CATALOG.read_text()) if CATALOG.exists() else {"sourceLanguage": "en", "strings": {}}
    strings = data.setdefault("strings", {})
    strings = {key: value for key, value in strings.items() if "Â" not in key}
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        if path.name == "LocalizedCopy.swift":
            continue
        for match in PATTERN.finditer(path.read_text(errors="ignore")):
            key = decode(match.group(1))
            if not key or "\\(" in key or key.isnumeric():
                continue
            entry = strings.setdefault(key, {"extractionState": "manual", "localizations": {}})
            entry.setdefault("extractionState", "manual")
            localizations = entry.setdefault("localizations", {})
            for locale in LOCALES:
                localizations.setdefault(locale, {
                    "stringUnit": {"state": "needs_review", "value": key}
                })
    data["sourceLanguage"] = "en"
    data["version"] = "1.0"
    CATALOG.write_text(json.dumps({"sourceLanguage": data["sourceLanguage"],
                                   "strings": dict(sorted(strings.items())),
                                   "version": data["version"]},
                                  ensure_ascii=False, indent=2) + "\n")

if __name__ == "__main__":
    main()
