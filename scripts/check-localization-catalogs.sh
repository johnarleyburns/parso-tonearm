#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Keep the catalog contract executable. Xcode will happily compile a catalog
# with one missing locale and silently fall back to English, which is exactly
# the kind of release-only gap this project is trying to eliminate.
python3 - <<'PY'
import json
import pathlib
import re
import sys

locales = {"en", "zh-Hans", "es", "fr", "de", "ja", "pt-BR"}
catalogs = [
    pathlib.Path("Resources/Localizable.xcstrings"),
    pathlib.Path("Resources/InfoPlist.xcstrings"),
    pathlib.Path("ShareExtension/Localizable.xcstrings"),
    pathlib.Path("WatchApp/Localizable.xcstrings"),
    pathlib.Path("SiriIntentsExtension/Localizable.xcstrings"),
    pathlib.Path("WidgetsExtension/Localizable.xcstrings"),
]
errors = []

def values_for(localization):
    unit = localization.get("stringUnit")
    if unit:
        return [unit.get("value", "")]
    variations = localization.get("variations", {})
    values = []
    for category in variations.values():
        for variant in category.values():
            values.extend(values_for(variant))
    return values

for path in catalogs:
    if not path.is_file():
        errors.append(f"missing catalog: {path}")
        continue
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        errors.append(f"invalid JSON in {path}: {exc}")
        continue
    for key, entry in data.get("strings", {}).items():
        actual = set(entry.get("localizations", {}))
        missing = locales - actual
        if missing:
            errors.append(f"{path}: {key!r} missing {', '.join(sorted(missing))}")
        for locale, localization in entry.get("localizations", {}).items():
            if not any(str(value).strip() for value in values_for(localization)):
                errors.append(f"{path}: {key!r} has an empty {locale} value")

info = pathlib.Path("Resources/InfoPlist.xcstrings")
if info.is_file():
    display = json.loads(info.read_text()).get("strings", {}).get("CFBundleDisplayName", {})
    for locale, localization in display.get("localizations", {}).items():
        if "Platterhead" not in " ".join(values_for(localization)):
            errors.append(f"{info}: CFBundleDisplayName must remain Platterhead in {locale}")

# A ratchet catches newly introduced hand-written plural branches while the
# existing strings are migrated incrementally into catalog entries. Keep this
# baseline in the guard, rather than allowing the count to grow silently.
plural_pattern = re.compile(r"==\s*1\s*\?")
plural_hits = []
for root in (pathlib.Path("Sources"), pathlib.Path("WatchApp"), pathlib.Path("WidgetsExtension"), pathlib.Path("ShareExtension")):
    for path in root.rglob("*.swift"):
        if path.name == "LocalizedCopy.swift":
            continue
        for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            if plural_pattern.search(line):
                plural_hits.append((path, line_number))
if len(plural_hits) > 21:
    errors.append(f"hand-written plural branches grew from the current baseline of 21 to {len(plural_hits)}")

if errors:
    print("localization catalog guard failed:")
    print("\n".join(f"  - {error}" for error in errors))
    sys.exit(1)
print(f"localization catalog guard: {len(catalogs)} catalogs, all seven locales present")
PY
