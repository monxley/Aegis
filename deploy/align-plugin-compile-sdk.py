#!/usr/bin/env python3
"""Raise every Android subproject's compileSdk to the level the plugins demand.

Plugins declare a *minimum* compileSdk in their AAR metadata, and Gradle checks
it against whatever each module actually compiles with. Those two things drift:
`flutter_plugin_android_lifecycle` now requires 36, while `file_picker` 8.0.7
still hardcodes 34, so the build fails with

    Dependency ':flutter_plugin_android_lifecycle' requires libraries and
    applications that depend on it to compile against version 36 or later
    :file_picker is currently compiled against android-34

Upgrading `file_picker` is not available here: the versions that compile against
36 pull in `web ^1.0.0`, and the pinned flutter_rust_bridge needs `web ^0.5.0`.

So this does what the error itself recommends, applied to the plugin subprojects
rather than only to `:app`. Raising compileSdk changes only which APIs are
*visible at compile time* — it is not targetSdk (runtime behaviour) and not
minSdk (which devices can install), so it cannot change how the app behaves on a
phone.

Usage:  align-plugin-compile-sdk.py <path to app/android> [sdk]

Idempotent.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "// aegis: plugin compileSdk aligned by deploy/align-plugin-compile-sdk.py"

# The Gradle snippet reaches AGP's extension by reflection rather than by type.
# That is deliberate: the root build file has no AGP types on its own classpath
# (Flutter's template declares plugins in settings.gradle.kts), so naming
# `com.android.build.gradle.BaseExtension` here would simply not compile. The
# property name is stable across AGP 8, and when it is absent the build says so
# and carries on to fail with the original, more informative error rather than
# silently doing nothing.
BLOCK = """
{marker}
subprojects {{
    afterEvaluate {{
        val androidExtension = extensions.findByName("android")
        if (androidExtension != null) {{
            val setter = androidExtension.javaClass.methods.firstOrNull {{
                it.name == "setCompileSdk" && it.parameterCount == 1
            }}
            if (setter == null) {{
                logger.lifecycle(
                    "aegis: ${{project.name}} has no setCompileSdk; leaving its " +
                        "compileSdk alone"
                )
            }} else {{
                setter.invoke(androidExtension, {sdk})
            }}
        }}
    }}
}}
"""


def main(argv: list[str]) -> int:
    if not 2 <= len(argv) <= 3:
        print(__doc__, file=sys.stderr)
        return 2

    gradle = Path(argv[1]) / "build.gradle.kts"
    sdk = int(argv[2]) if len(argv) == 3 else 36

    if not gradle.is_file():
        print(f"no {gradle}; run `flutter create` first", file=sys.stderr)
        return 1

    source = gradle.read_text()
    if MARKER in source:
        print("plugin compileSdk already aligned")
        return 0

    gradle.write_text(
        source.rstrip("\n") + "\n" + BLOCK.format(marker=MARKER, sdk=sdk)
    )
    print(f"plugin compileSdk aligned to {sdk}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
