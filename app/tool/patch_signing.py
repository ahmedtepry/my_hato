#!/usr/bin/env python3
"""Adds a `release` signingConfig that reads android/key.properties to the generated Gradle file
(Kotlin DSL or Groovy), and makes the release build type use it. Idempotent."""
import pathlib, re, sys

app = pathlib.Path(__file__).resolve().parent.parent
kts = app / "android/app/build.gradle.kts"
groovy = app / "android/app/build.gradle"
if kts.exists():
    p, s = kts, kts.read_text()
    if 'create("release")' not in s:
        block = '''    signingConfigs {
        create("release") {
            val props = Properties()
            props.load(rootProject.file("key.properties").inputStream())
            storeFile = file(props.getProperty("storeFile"))
            storePassword = props.getProperty("storePassword")
            keyAlias = props.getProperty("keyAlias")
            keyPassword = props.getProperty("keyPassword")
        }
    }

    buildTypes {'''
        s = s.replace("    buildTypes {", block, 1)
    if "import java.util.Properties" not in s:
        s = "import java.util.Properties\n" + s
    s = re.sub(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)', 'signingConfig = signingConfigs.getByName("release")', s)
elif groovy.exists():
    p, s = groovy, groovy.read_text()
    if "signingConfigs {" not in s:
        block = '''    signingConfigs {
        release {
            def props = new Properties()
            props.load(rootProject.file("key.properties").newDataInputStream())
            storeFile file(props.getProperty("storeFile"))
            storePassword props.getProperty("storePassword")
            keyAlias props.getProperty("keyAlias")
            keyPassword props.getProperty("keyPassword")
        }
    }

    buildTypes {'''
        s = s.replace("    buildTypes {", block, 1)
    s = s.replace("signingConfig signingConfigs.debug", "signingConfig signingConfigs.release")
else:
    sys.exit("android/app/build.gradle(.kts) not found — run flutter create first")
if 'getByName("release")' not in s and "signingConfigs.release" not in s:
    sys.exit("could not switch the release build type to the release signing config")
p.write_text(s)
print(f"release signing configured in {p.relative_to(app)}")
