#!/usr/bin/env bash
# Build the Aegis Android APK on a plain Linux VPS, entirely from the console
# (no GUI, no GitHub Actions). Made for a Debian/Ubuntu box you SSH into.
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/build-apk.sh | bash
#
# It installs a JDK, the Flutter SDK, the Android command-line SDK + NDK, and
# Rust, then builds an installable debug APK and tells you how to copy it to
# your phone. FULLY ROOTLESS: everything lands under $HOME, no sudo/apt needed
# (a portable JDK is downloaded if `java` is absent). Only needs git + curl,
# which you already have if this script was fetched.
#
# Needs ~8 GB free disk and ~2 GB RAM. On a <2 GB box the build may be OOM-killed
# ("Killed"); without root you can't add swap, so build on a bigger box.
set -euo pipefail

REPO="${REPO:-https://github.com/monxley/Aegis}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
SDK="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
NDK_VER="26.3.11579264"
PLATFORM="android-34"
BUILDTOOLS="34.0.0"
WORK="${WORK:-$HOME/aegis-build}"
FRB_VERSION="2.0.0"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Extract a zip without requiring `unzip` (portable, no root): unzip if present,
# else python3, else the JDK's `jar`.
extract_zip() { # $1=zip  $2=dest_dir
  if have unzip; then unzip -q "$1" -d "$2"
  elif have python3; then python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$1" "$2"
  else ( mkdir -p "$2" && cd "$2" && jar xf "$1" ); fi
}

# 1. JDK — NO ROOT. Use an existing java, else drop a portable Temurin 17 under
#    $HOME. (git/curl are already present since this script was fetched + can
#    clone.)
if have java; then
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
else
  if [ ! -x "$HOME/jdk/bin/java" ]; then
    log "installing a portable JDK 17 under \$HOME (no root)"
    case "$(uname -m)" in
      x86_64|amd64) JARCH=x64 ;;
      aarch64|arm64) JARCH=aarch64 ;;
      *) JARCH=x64 ;;
    esac
    mkdir -p "$HOME/jdk"; tmp="$(mktemp -d)"
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/$JARCH/jdk/hotspot/normal/eclipse?project=jdk" -o "$tmp/jdk.tar.gz"
    tar -xzf "$tmp/jdk.tar.gz" -C "$tmp"
    jdir="$(find "$tmp" -maxdepth 1 -type d -name 'jdk-17*' | head -1)"
    rm -rf "$HOME/jdk"; mv "$jdir" "$HOME/jdk"; rm -rf "$tmp"
  fi
  export JAVA_HOME="$HOME/jdk"; export PATH="$HOME/jdk/bin:$PATH"
fi

# 2. Rust + Android targets + tooling.
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "installing Rust (rustup)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android >/dev/null
have cargo-ndk || { log "installing cargo-ndk"; cargo install cargo-ndk; }
[ -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ] || \
  { log "installing flutter_rust_bridge_codegen"; cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked; }

# 3. Flutter SDK.
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  log "cloning Flutter (stable)"
  git clone --depth 1 -b stable https://github.com/flutter/flutter "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$HOME/.cargo/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR" 2>/dev/null || true

# 4. Android command-line SDK + platform + build-tools + NDK.
export ANDROID_SDK_ROOT="$SDK"
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  log "installing Android command-line tools"
  mkdir -p "$SDK/cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o "$tmp/clt.zip"
  extract_zip "$tmp/clt.zip" "$tmp"
  rm -rf "$SDK/cmdline-tools/latest"; mv "$tmp/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$tmp"
fi
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
log "installing Android SDK packages (platform $PLATFORM, build-tools $BUILDTOOLS, NDK)"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "platforms;$PLATFORM" "build-tools;$BUILDTOOLS" "ndk;$NDK_VER" >/dev/null
export ANDROID_NDK_HOME="$SDK/ndk/$NDK_VER"
flutter config --android-sdk "$SDK" >/dev/null 2>&1 || true

# 5. Source + bindings + native engine + APK. Always build from a FRESH clone so
#    a stale local checkout can't be shipped by mistake (to build a local tree,
#    run the flutter/codegen/ndk steps by hand). REPO/main are overridable.
log "cloning $REPO (fresh, so the APK is always current)"
rm -rf "$WORK"; git clone --depth 1 "$REPO" "$WORK"; SRC="$WORK"
log "building @ $(cd "$SRC" && git rev-parse --short HEAD)"
cd "$SRC/app"

log "generating bindings + platform folders"
export FLUTTER_ALLOW_ROOT=true   # this VPS session runs as root; that's fine here
flutter create --platforms=android --project-name aegis . >/dev/null
flutter pub get >/dev/null

# Flutter's generated MAIN manifest has no INTERNET permission — it ships only
# in the debug/profile manifests, so a release build would have no network at
# all and every socket (all our traffic runs from Rust) would fail. Declare the
# network permissions in the main manifest so they're present in every build.
# Both are "normal" permissions: granted silently at install, no user prompt.
MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ] && ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  log "adding INTERNET + network-state + notification + biometric permissions to AndroidManifest"
  awk '/<application/ && !d {
        print "    <uses-permission android:name=\"android.permission.INTERNET\"/>";
        print "    <uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\"/>";
        print "    <uses-permission android:name=\"android.permission.POST_NOTIFICATIONS\"/>";
        print "    <uses-permission android:name=\"android.permission.USE_BIOMETRIC\"/>";
        print "    <uses-permission android:name=\"android.permission.FOREGROUND_SERVICE\"/>";
        print "    <uses-permission android:name=\"android.permission.FOREGROUND_SERVICE_DATA_SYNC\"/>";
        d=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

# Register the background foreground-service in the manifest (idempotent), so
# the app can keep receiving 24/7. Inserted just before </application>.
if [ -f "$MANIFEST" ] && ! grep -q 'AegisBackgroundService' "$MANIFEST"; then
  log "registering AegisBackgroundService in AndroidManifest"
  awk '/<\/application>/ && !s {
        print "        <service android:name=\".AegisBackgroundService\" android:exported=\"false\" android:foregroundServiceType=\"dataSync\"/>";
        s=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

# Android 11+ package visibility: declare the browser intent so url_launcher can
# open the release/APK download link. Inserted just before <application>.
if [ -f "$MANIFEST" ] && ! grep -q '<queries>' "$MANIFEST"; then
  log "adding <queries> for the update download link"
  awk '/<application/ && !q {
        print "    <queries>";
        print "        <intent>";
        print "            <action android:name=\"android.intent.action.VIEW\"/>";
        print "            <data android:scheme=\"https\"/>";
        print "        </intent>";
        print "    </queries>";
        q=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

# flutter_local_notifications needs Java 8+ core-library desugaring enabled in
# the app module. Patch the generated Gradle (Kotlin or Groovy DSL) idempotently.
python3 - <<'PY' || log "warning: could not patch Gradle for desugaring"
import glob, os, re
cands = glob.glob("android/app/build.gradle.kts") + glob.glob("android/app/build.gradle")
if not cands:
    raise SystemExit(0)
p = cands[0]
s = open(p).read()
kts = p.endswith(".kts")
if "coreLibraryDesugaring" in s:
    raise SystemExit(0)
# 1) enable desugaring inside android { compileOptions { ... } }
if kts:
    flag = "        isCoreLibraryDesugaringEnabled = true\n"
else:
    flag = "        coreLibraryDesugaringEnabled true\n"
m = re.search(r"compileOptions\s*\{", s)
if m:
    s = s[:m.end()] + "\n" + flag + s[m.end():]
# 2) add the desugar dependency (top-level dependencies { } block; create if none)
dep = ('    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n'
       if kts else
       "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n")
dm = re.search(r"\ndependencies\s*\{", s)
if dm:
    s = s[:dm.end()] + "\n" + dep + s[dm.end():]
else:
    s = s.rstrip() + "\n\ndependencies {\n" + dep + "}\n"
open(p, "w").write(s)
print("patched", p, "for core-library desugaring")
PY

# local_auth (biometric unlock) needs Android minSdk 23. Raise it in the
# generated Gradle whether it's the flutter default placeholder or a literal.
python3 - <<'PY' || log "warning: could not patch minSdk"
import glob, re
cands = glob.glob("android/app/build.gradle.kts") + glob.glob("android/app/build.gradle")
if not cands:
    raise SystemExit(0)
p = cands[0]
s = open(p).read()
before = s
# flutter.minSdkVersion placeholder → 23
s = re.sub(r"(minSdk(?:Version)?\s*=?\s*)flutter\.minSdkVersion", r"\g<1>23", s)
# a literal below 23 → 23
def bump(m):
    return m.group(1) + "23" if int(m.group(2)) < 23 else m.group(0)
s = re.sub(r"(minSdk(?:Version)?\s*=?\s*)(\d+)", bump, s)
if s != before:
    open(p, "w").write(s)
    print("patched", p, "minSdk → 23")
PY

# Screenshot / screen-recording protection (FLAG_SECURE) + a runtime toggle.
# Rewrite the generated MainActivity so it (1) sets FLAG_SECURE in onCreate — so
# screenshots and screen recording are blocked from the very first frame, blank
# in the app switcher, secure by default — and (2) exposes a MethodChannel the
# Dart side calls to turn the flag on/off when the user changes the setting.
# Extends FlutterFragmentActivity so the biometric plugin (local_auth) works.
# The package line is preserved.
python3 - <<'PY' || log "warning: could not patch MainActivity for FLAG_SECURE"
import glob, re
cands = glob.glob("android/app/src/main/kotlin/**/MainActivity.kt", recursive=True)
if not cands:
    raise SystemExit(0)
p = cands[0]
s = open(p).read()
if "FLAG_SECURE" in s:
    raise SystemExit(0)
m = re.search(r"^\s*package\s+[\w.]+", s, re.M)
pkg = m.group(0).strip() if m else "package com.example.aegis"
open(p, "w").write(pkg + """

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val secureChannel = "aegis/screen_security"
    private val backgroundChannel = "aegis/background"
    private val disguiseChannel = "aegis/disguise"

    // Launcher aliases (declared in the manifest): exactly one is enabled at a
    // time, which is the icon + name shown in the launcher.
    private val disguiseAliases = mapOf(
        "default" to ".LauncherDefault",
        "calculator" to ".DisguiseCalculator",
        "notes" to ".DisguiseNotes",
        "weather" to ".DisguiseWeather"
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        // Secure by default: block screenshots / screen recording immediately.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val on = call.arguments as? Boolean ?: true
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backgroundChannel)
            .setMethodCallHandler { call, result ->
                val intent = Intent(this, AegisBackgroundService::class.java)
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, disguiseChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "setDisguise") {
                    val which = call.arguments as? String ?: "default"
                    applyDisguise(which)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    // Enable the chosen launcher alias and disable the others, so the app shows
    // a single disguised (or real) icon + name. DONT_KILL_APP keeps us running.
    private fun applyDisguise(which: String) {
        val target = if (disguiseAliases.containsKey(which)) which else "default"
        for ((key, cls) in disguiseAliases) {
            val state = if (key == target) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            packageManager.setComponentEnabledSetting(
                ComponentName(packageName, packageName + cls),
                state,
                PackageManager.DONT_KILL_APP
            )
        }
    }
}
""")
print("patched", p, "for FLAG_SECURE + toggle + background + disguise channels")

# Write the foreground service next to MainActivity (same package/dir), so the
# app can keep polling and receiving 24/7 with a quiet persistent notification.
import os
pkg_name = pkg.replace("package", "").strip()
svc = os.path.join(os.path.dirname(p), "AegisBackgroundService.kt")
open(svc, "w").write("package " + pkg_name + """

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// A minimal foreground service: it runs no logic itself, it just keeps the app
// process alive (with a quiet, ongoing notification) so the Dart poll timer
// keeps pulling messages while the app is backgrounded — 24/7 delivery.
class AegisBackgroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "aegis_background"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(
                    channelId, "Aegis background",
                    NotificationManager.IMPORTANCE_MIN
                )
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Aegis")
            .setContentText("Active — receiving messages")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1001, notification)
        }
        return START_STICKY
    }
}
""")
print("wrote", svc)
PY

# Disguise icons: simple vector drawables for the launcher aliases (calculator,
# notes, weather), so the app can masquerade as an ordinary utility.
python3 - <<'PY' || log "warning: could not write disguise icons"
import os
d = "android/app/src/main/res/drawable"
os.makedirs(d, exist_ok=True)
def vec(body):
    return ('<vector xmlns:android="http://schemas.android.com/apk/res/android" '
            'android:width="108dp" android:height="108dp" '
            'android:viewportWidth="108" android:viewportHeight="108">\n'
            + body + '</vector>\n')
icons = {
    "disg_calc.xml": vec(
        '  <path android:fillColor="#37474F" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#ECEFF1" android:pathData="M22,16h64v24h-64z"/>\n'
        '  <path android:fillColor="#FF7043" android:pathData="M66,50h20v42h-20z"/>\n'
        '  <path android:fillColor="#90A4AE" android:pathData="M22,50h16v16h-16z M46,50h16v16h-16z M22,74h16v16h-16z M46,74h16v16h-16z"/>\n'),
    "disg_notes.xml": vec(
        '  <path android:fillColor="#FBC02D" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#FFFFFF" android:pathData="M24,30h60v9h-60z M24,50h60v9h-60z M24,70h40v9h-40z"/>\n'),
    "disg_weather.xml": vec(
        '  <path android:fillColor="#4FC3F7" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#FFEE58" android:pathData="M42,42m-18,0a18,18 0,1 1,36 0a18,18 0,1 1,-36 0"/>\n'
        '  <path android:fillColor="#FFFFFF" android:pathData="M40,74h36a13,13 0,0 0,-2 -25a18,18 0,0 0,-33 5a11,11 0,0 0,-1 20z"/>\n'),
}
for name, xml in icons.items():
    open(os.path.join(d, name), "w").write(xml)
print("wrote disguise icons")
PY

# Turn the launcher entry into swappable aliases so the app can disguise itself.
# Remove MainActivity's own LAUNCHER filter and add one alias per identity
# (real + decoys); MainActivity toggles which is enabled at runtime.
python3 - <<'PY' || log "warning: could not add launcher aliases"
import re
p = "android/app/src/main/AndroidManifest.xml"
s = open(p).read()
if "activity-alias" in s:
    raise SystemExit(0)
# Drop the launcher intent-filter from MainActivity (its only intent-filter).
s2 = re.sub(r"\s*<intent-filter>.*?LAUNCHER.*?</intent-filter>", "", s, count=1, flags=re.S)
if s2 == s:
    raise SystemExit(0)
aliases = """
        <activity-alias android:name=".LauncherDefault" android:enabled="true" android:exported="true" android:targetActivity=".MainActivity" android:icon="@mipmap/ic_launcher" android:label="Aegis">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseCalculator" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_calc" android:label="Calculator">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseNotes" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_notes" android:label="Notes">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseWeather" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_weather" android:label="Weather">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
"""
# Insert the aliases right after MainActivity's </activity>.
s2 = s2.replace("</activity>", "</activity>\n" + aliases, 1)
open(p, "w").write(s2)
print("added launcher aliases to the manifest")
PY

mkdir -p lib/src/rust           # codegen canonicalizes this path before creating it
flutter_rust_bridge_codegen generate

# FRB's codegen writes rust/src/frb_generated.rs but does NOT wire it into the
# crate root, so `mod frb_generated;` is missing and the glue (frb_get_rust_
# content_hash, the wire_* fns) never gets compiled into the .so. The library
# then builds clean but fails at load with:
#   undefined symbol: frb_get_rust_content_hash
# Declare the module now that the generated file exists (idempotent).
if [ -f rust/src/frb_generated.rs ] && ! grep -qE '^\s*(pub\s+)?mod frb_generated;' rust/src/lib.rs; then
  log "wiring 'mod frb_generated;' into rust/src/lib.rs (codegen leaves it out)"
  printf '\nmod frb_generated;\n' >> rust/src/lib.rs
fi

log "cross-compiling the Rust engine for Android (a few minutes)"
( cd rust && rm -f Cargo.lock && \
  cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../android/app/src/main/jniLibs build --release )

log "building the APK (a few minutes)"
flutter build apk --debug

APK="$SRC/app/build/app/outputs/flutter-apk/app-debug.apk"
IP="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo YOUR_VPS_IP)"
echo
log "Done. APK: $APK"
echo "Copy it to your phone — easiest from the console:"
echo "  cd $(dirname "$APK") && python3 -m http.server 8080"
echo "  then on your phone open:  http://$IP:8080/app-debug.apk"
echo "  (open port 8080 in the firewall for that download, then Ctrl-C the server)"
echo "On Android: allow 'install from unknown sources' and open the APK."
echo "The seed node is baked in, so it connects with no setup."
