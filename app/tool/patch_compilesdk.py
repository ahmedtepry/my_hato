#!/usr/bin/env python3
"""Compiles every Android plugin library against API 36 (some plugins still pin 34, which newer
AndroidX dependencies reject in checkAarMetadata). Only compileSdk changes; minSdk/targetSdk stay.
Patches the generated root android/build.gradle(.kts). Idempotent."""
import pathlib, sys

app = pathlib.Path(__file__).resolve().parent.parent
kts = app / "android/build.gradle.kts"
groovy = app / "android/build.gradle"
MARK = "// myhato: plugin compileSdk 36"
if kts.exists():
    p = kts
    block = f"""{MARK}
subprojects {{
    afterEvaluate {{
        val ext = extensions.findByName("android")
        if (ext is com.android.build.gradle.LibraryExtension && (ext.compileSdk ?: 0) < 36) {{
            ext.compileSdk = 36
        }}
    }}
}}
"""
elif groovy.exists():
    p = groovy
    block = f"""{MARK}
subprojects {{
    afterEvaluate {{ project ->
        if (project.plugins.hasPlugin("com.android.library")) {{
            project.android {{ compileSdkVersion 36 }}
        }}
    }}
}}
"""
else:
    sys.exit("android/build.gradle(.kts) not found")
s = p.read_text()
if MARK not in s:
    p.write_text(block + "\n" + s)
print(f"plugin compileSdk 36 in {p.relative_to(app)}")
