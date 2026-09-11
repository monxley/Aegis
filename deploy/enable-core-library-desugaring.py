#!/usr/bin/env python3
"""Turn on Android core library desugaring in the generated Gradle build.

`flutter_local_notifications` schedules notifications with `java.time`, which
does not exist on older Android versions, so it declares in its AAR metadata
that the app must enable **core library desugaring** — the compiler then rewrites
those calls against a backported implementation. `flutter create` does not
enable it, so the release build fails at `checkReleaseAarMetadata` with a
message about a flag the developer never set.

This is not optional and it is not a workaround: without it the notification
plugin genuinely cannot run on the minSdk this app supports.

Usage:  enable-core-library-desugaring.py <path to app/android>

Idempotent, and it matches Flutter's emitted block literally — if a future
Flutter changes the template this fails with a clear message rather than
silently producing a build that cannot schedule a notification.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "// aegis: core library desugaring enabled by deploy/enable-core-library-desugaring.py"

# Kept in step with what flutter_local_notifications asks for. Desugaring is a
# compile-time rewrite, so this version affects the generated code and is worth
# pinning rather than floating.
DESUGAR_JDK_LIBS = "com.android.tools:desugar_jdk_libs:2.1.4"

# The exact block `flutter create` emits.
GENERATED_COMPILE_OPTIONS = """    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
"""

PATCHED_COMPILE_OPTIONS = f"""    compileOptions {{
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        {MARKER}
        isCoreLibraryDesugaringEnabled = true
    }}
"""

DEPENDENCIES_BLOCK = f"""
dependencies {{
    coreLibraryDesugaring("{DESUGAR_JDK_LIBS}")
}}
"""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    gradle = Path(argv[1]) / "app" / "build.gradle.kts"
    if not gradle.is_file():
        print(f"no {gradle}; run `flutter create` first", file=sys.stderr)
        return 1

    source = gradle.read_text()
    if MARKER in source:
        print("core library desugaring already enabled")
        return 0

    if GENERATED_COMPILE_OPTIONS not in source:
        print(
            "the generated build.gradle.kts does not contain the compileOptions "
            "block this script knows how to patch.\n"
            "  Flutter's template has probably changed — update "
            "deploy/enable-core-library-desugaring.py rather than shipping a "
            "build that fails on AAR metadata.",
            file=sys.stderr,
        )
        return 1

    source = source.replace(GENERATED_COMPILE_OPTIONS, PATCHED_COMPILE_OPTIONS, 1)
    source = source.rstrip("\n") + "\n" + DEPENDENCIES_BLOCK
    gradle.write_text(source)
    print(f"core library desugaring enabled ({DESUGAR_JDK_LIBS})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
