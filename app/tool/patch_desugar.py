#!/usr/bin/env python3
"""Enables core library desugaring (required by flutter_local_notifications) in the generated
android/app Gradle file (Kotlin DSL or Groovy). Idempotent."""
import pathlib, re, sys

app = pathlib.Path(__file__).resolve().parent.parent
kts = app / "android/app/build.gradle.kts"
groovy = app / "android/app/build.gradle"
DEP = "com.android.tools:desugar_jdk_libs:2.1.4"
if kts.exists():
    p, s = kts, kts.read_text()
    if "isCoreLibraryDesugaringEnabled" not in s:
        s, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", s, count=1)
        if n == 0:
            s = s.replace("android {", "android {\n    compileOptions {\n        isCoreLibraryDesugaringEnabled = true\n    }", 1)
    if DEP not in s:
        s += f'\ndependencies {{\n    coreLibraryDesugaring("{DEP}")\n}}\n'
elif groovy.exists():
    p, s = groovy, groovy.read_text()
    if "coreLibraryDesugaringEnabled" not in s:
        s, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        coreLibraryDesugaringEnabled true", s, count=1)
        if n == 0:
            s = s.replace("android {", "android {\n    compileOptions {\n        coreLibraryDesugaringEnabled true\n    }", 1)
    if DEP not in s:
        s += f"\ndependencies {{\n    coreLibraryDesugaring '{DEP}'\n}}\n"
else:
    sys.exit("android/app/build.gradle(.kts) not found")
p.write_text(s)
print(f"desugaring enabled in {p.relative_to(app)}")
