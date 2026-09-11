#!/usr/bin/env python3
"""Point the generated Android release build at a real signing key.

`flutter create` writes a build file whose release build type is signed with the
**debug** key, with a TODO next to it. That is fine for `flutter run --release`
and for sideloading a test build, but it is not a release: the Android debug key
is a published, universally-known key, so a debug-signed build carries no
evidence at all about who produced it, and anyone can hand a user a modified
"update" that installs straight over it. For a messenger whose whole claim is
that you can tell what you are running, that matters.

This script rewrites the generated file so the release build type uses a key
from `android/key.properties`. It is a no-op — deliberately, and loudly — when
that file is absent, so the build still works for contributors who have no
keystore.

Usage:  apply-release-signing.py <path to app/android>

Nothing here is a secret: the keystore and its passwords live outside the repo
(CI secrets, or a local file that is gitignored) and only ever reach the build
machine.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "// aegis: release signing configured by deploy/apply-release-signing.py"

LOADER = f"""{MARKER}
import java.io.FileInputStream
import java.util.Properties

val aegisKeystoreProperties = Properties().apply {{
    load(FileInputStream(rootProject.file("key.properties")))
}}

"""

SIGNING_CONFIGS = """    signingConfigs {
        create("release") {
            keyAlias = aegisKeystoreProperties["keyAlias"] as String
            keyPassword = aegisKeystoreProperties["keyPassword"] as String
            storeFile = file(aegisKeystoreProperties["storeFile"] as String)
            storePassword = aegisKeystoreProperties["storePassword"] as String
        }
    }

"""

RELEASE_BUILD_TYPE = """    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
"""

# The exact block `flutter create` emits. Matching it literally rather than with
# a regex is on purpose: if a future Flutter changes the template, this fails
# with a clear message instead of silently producing an unsigned build.
GENERATED_BUILD_TYPES = """    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
"""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    android = Path(argv[1])
    gradle = android / "app" / "build.gradle.kts"
    key_properties = android / "key.properties"

    if not gradle.is_file():
        print(f"no {gradle}; run `flutter create` first", file=sys.stderr)
        return 1

    if not key_properties.is_file():
        print(
            f"no {key_properties} — leaving the release build DEBUG-SIGNED.\n"
            "  The APK will install and run, but it is not a distributable "
            "release: it is signed with Android's public debug key.\n"
            "  To sign for real, write key.properties (storeFile, storePassword, "
            "keyAlias, keyPassword) and re-run."
        )
        return 0

    source = gradle.read_text()
    if MARKER in source:
        print("release signing already configured")
        return 0

    if GENERATED_BUILD_TYPES not in source:
        print(
            "the generated build.gradle.kts does not contain the release build "
            "type this script knows how to replace.\n"
            "  Flutter's template has probably changed — update "
            "deploy/apply-release-signing.py rather than shipping an "
            "accidentally debug-signed build.",
            file=sys.stderr,
        )
        return 1

    source = source.replace(GENERATED_BUILD_TYPES, SIGNING_CONFIGS + RELEASE_BUILD_TYPE, 1)
    source = LOADER + source
    gradle.write_text(source)
    print(f"release signing configured from {key_properties}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
