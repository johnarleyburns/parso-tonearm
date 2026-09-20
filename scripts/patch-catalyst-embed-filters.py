#!/usr/bin/env python3
"""Adds `platformFilters = (ios, );` to the PBXBuildFile entries embedding
TonearmShareExtension/TonearmWidgetsExtension/TonearmWatch into the Tonearm
app target.

Why this exists: Mac Catalyst can't embed content built for iOS/watchOS
("This target is built for macOS but contains embedded content built for
iOS, which is not allowed"). XcodeGen's YAML `platforms: [iOS]` on these
dependency entries (project.yml) does NOT emit the native `platformFilters`
attribute for a `target:`+`embed: true` dependency as of XcodeGen 2.45.4/
2.46.0 (confirmed directly — regenerating with either version produces no
platformFilters attribute at all), so this has to be patched onto the
generated project.pbxproj by hand, every time `xcodegen generate` runs.

Idempotent: does nothing if the attribute is already present on a line.
Called from scripts/generate-project.sh, right after `xcodegen generate`,
so `make project` always produces a project that can build for Mac
Catalyst without a separate manual step.
"""
import re
import sys

PBXPROJ = "Tonearm.xcodeproj/project.pbxproj"

# Each entry: the exact PBXBuildFile comment XcodeGen generates for these
# three embeds, matched loosely enough to survive a GUID/ordering change.
TARGETS = [
    "TonearmShareExtension.appex in Embed Foundation Extensions",
    "TonearmWidgetsExtension.appex in Embed Foundation Extensions",
    "TonearmWatch.app in Embed Watch Content",
]


def main() -> int:
    with open(PBXPROJ, encoding="utf-8") as f:
        content = f.read()

    total = 0
    for label in TARGETS:
        pattern = re.compile(
            r"(/\* " + re.escape(label) + r" \*/ = \{isa = PBXBuildFile; fileRef = [^;]+;)"
            r"( platformFilters = \([^)]*\);)?"
            r"( settings = \{[^}]*\};)?"
            r" \};"
        )

        def repl(m: re.Match) -> str:
            prefix = m.group(1)
            existing_filter = m.group(2)
            settings = m.group(3) or ""
            if existing_filter:
                return m.group(0)  # already patched
            return f"{prefix} platformFilters = (ios, );{settings} }};"

        content, n = pattern.subn(repl, content)
        if n == 0:
            print(f"warning: no PBXBuildFile match found for '{label}' — "
                  "xcodegen's output shape may have changed", file=sys.stderr)
        total += n

    with open(PBXPROJ, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"==> patched {total} Catalyst embed platformFilters entries in {PBXPROJ}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
