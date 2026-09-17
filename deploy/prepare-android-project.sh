#!/usr/bin/env bash
# Turn the project `flutter create` generates into the one Shoal actually needs.
#
# `flutter create` emits a generic app. Everything below is the difference
# between that and this product, and none of it is optional:
#
#   * INTERNET is declared only in the debug/profile manifests, so a release
#     build has NO NETWORK AT ALL -- every socket fails, and all of this app's
#     traffic runs from Rust.
#   * MainActivity extends FlutterActivity, but local_auth needs
#     FlutterFragmentActivity, and nothing sets FLAG_SECURE, so screenshots and
#     screen recording are permitted and the app is readable in the switcher.
#   * There is no background service, no launcher aliases for the disguise
#     feature, and minSdk is below what local_auth requires.
#
# This lived inline in deploy/build-apk.sh, and CI did not do any of it -- so the
# APK CI produced installed and then could not reach the network. One script,
# called by both, is what stops those two builds diverging again.
#
# Usage:  prepare-android-project.sh            (from the app/ directory)
#
# Every step is idempotent. `dart` and `python3` must be on PATH.
set -euo pipefail

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

if [ ! -d android ]; then
  echo "prepare-android-project.sh: no android/ here; run it from app/ after" \
       "\`flutter create\`" >&2
  exit 1
fi

# Size the Gradle daemon's heap to the machine it is actually running on.
#
# Flutter's template writes `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G`.
# -Xmx is a ceiling rather than a reservation, so that is harmless on a large
# machine -- but on a small VPS the JVM keeps growing instead of collecting, and
# the kernel kills it. The build dies with a bare "Killed", or Gradle reports
# that its daemon "disappeared unexpectedly", neither of which points at memory.
#
# Half of what the machine reports as available, clamped to [1.5G, 4G]: enough
# for R8 and the Kotlin compiler on an app this size, and low enough that the
# OOM killer is not the thing that decides when the build ends.
GRADLE_PROPS="android/gradle.properties"
if [ -f "$GRADLE_PROPS" ]; then
  avail_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  heap_mb=$(( avail_mb / 2 ))
  [ "$heap_mb" -lt 1536 ] && heap_mb=1536
  [ "$heap_mb" -gt 4096 ] && heap_mb=4096
  log "capping the Gradle heap at ${heap_mb}m (machine reports ${avail_mb}m available)"
  python3 - "$GRADLE_PROPS" "$heap_mb" <<'PY'
import re
import sys

path, heap = sys.argv[1], int(sys.argv[2])
s = open(path).read()
# Metaspace is class metadata, not heap; 4G of it is never needed and on a small
# box it is memory the heap cannot have.
args = f"org.gradle.jvmargs=-Xmx{heap}m -XX:MaxMetaspaceSize=512m " \
       "-XX:+HeapDumpOnOutOfMemoryError"
if re.search(r"^org\.gradle\.jvmargs=.*$", s, re.M):
    s = re.sub(r"^org\.gradle\.jvmargs=.*$", args, s, count=1, flags=re.M)
else:
    s = s.rstrip("\n") + "\n" + args + "\n"
open(path, "w").write(s)
print(f"gradle heap set to {heap}m")
PY
fi

# The app's own identity: its name in the installer and launcher, and the
# package name Android installs it under.
#
# `flutter create --project-name shoal` leaves BOTH wrong, and nothing has ever
# corrected them:
#
#   * android:label="shoal" on <application>. This is what the package installer
#     and the app-info screen show -- the launcher aliases carry "Shoal", but
#     the installer never looks at those.
#   * applicationId "com.example.shoal". com.example is the reserved example
#     namespace: Play rejects it outright, and several vendor installers refuse
#     it too, which shows up as a bare "app not installed" with no reason given.
#
# Only applicationId changes, not namespace. applicationId is the package
# Android installs under; namespace is what the Kotlin sources and the generated
# R class use, and the manifest's ".MainActivity" resolves against it. Changing
# namespace without moving every source file would leave the manifest pointing
# at a class that does not exist.
#
# Override with SHOAL_APPLICATION_ID if you publish under your own domain.
APP_ID="${SHOAL_APPLICATION_ID:-io.github.monxley.shoal}"
python3 - "$APP_ID" <<'PY' || log "warning: could not set the app's name and id"
import re
import sys

app_id = sys.argv[1]

manifest = "android/app/src/main/AndroidManifest.xml"
s = open(manifest).read()
new = re.sub(r'android:label="[^"]*"', 'android:label="Shoal"', s, count=1)
if new != s:
    open(manifest, "w").write(new)
    print('set android:label="Shoal"')

gradle = "android/app/build.gradle.kts"
s = open(gradle).read()
new, n = re.subn(
    r'applicationId\s*=\s*"[^"]*"', f'applicationId = "{app_id}"', s, count=1
)
if n and new != s:
    open(gradle, "w").write(new)
    print(f"set applicationId = {app_id}")
elif not n:
    raise SystemExit("could not find applicationId in " + gradle)
PY

# Generate the Shoal launcher icon (all densities + adaptive) from the bundled
# source PNG, per the flutter_launcher_icons config in pubspec.yaml.
#
# Verified, not hoped for. This used to be `>/dev/null 2>&1 || log warning`, so
# when it silently did nothing the build shipped the stock Flutter logo and said
# nothing about it -- which is exactly what happened. The icons `flutter create`
# just wrote are hashed first; if they are unchanged afterwards the tool did not
# do its job, and the build stops rather than producing an APK wearing someone
# else's mark.
log "generating launcher icon"
ICON_BEFORE="$(cat android/app/src/main/res/mipmap-*/ic_launcher.png 2>/dev/null | sha256sum | cut -d' ' -f1)"
dart run flutter_launcher_icons
ICON_AFTER="$(cat android/app/src/main/res/mipmap-*/ic_launcher.png 2>/dev/null | sha256sum | cut -d' ' -f1)"
if [ "$ICON_BEFORE" = "$ICON_AFTER" ]; then
  echo "launcher icons are byte-identical to the ones flutter create wrote:" >&2
  echo "flutter_launcher_icons ran but changed nothing. Fix it rather than" >&2
  echo "shipping the stock Flutter logo as this app's identity." >&2
  exit 1
fi
log "launcher icon generated (mipmaps changed)"

# Flutter's generated MAIN manifest has no INTERNET permission — it ships only
# in the debug/profile manifests, so a release build would have no network at
# all and every socket (all our traffic runs from Rust) would fail. Declare the
# network permissions in the main manifest so they're present in every build.
# Both are "normal" permissions: granted silently at install, no user prompt.
MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ] && ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  log "adding INTERNET + network-state + notification + biometric + media permissions to AndroidManifest"
  awk '/<application/ && !d {
        print "    <uses-permission android:name=\"android.permission.INTERNET\"/>";
        print "    <uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\"/>";
        print "    <uses-permission android:name=\"android.permission.POST_NOTIFICATIONS\"/>";
        print "    <uses-permission android:name=\"android.permission.USE_BIOMETRIC\"/>";
        print "    <uses-permission android:name=\"android.permission.FOREGROUND_SERVICE\"/>";
        print "    <uses-permission android:name=\"android.permission.FOREGROUND_SERVICE_DATA_SYNC\"/>";
        # Voice messages. RECORD_AUDIO is a runtime permission: the recorder
        # asks for it the first time the user holds the mic button.
        print "    <uses-permission android:name=\"android.permission.RECORD_AUDIO\"/>";
        # Camera for the in-chat photo attachment. Declared optional so the
        # app still installs on a device without one (gallery still works).
        print "    <uses-permission android:name=\"android.permission.CAMERA\"/>";
        print "    <uses-feature android:name=\"android.hardware.camera\" android:required=\"false\"/>";
        print "    <uses-feature android:name=\"android.hardware.microphone\" android:required=\"false\"/>";
        d=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

# Register the background foreground-service in the manifest (idempotent), so
# the app can keep receiving 24/7. Inserted just before </application>.
if [ -f "$MANIFEST" ] && ! grep -q 'ShoalBackgroundService' "$MANIFEST"; then
  log "registering ShoalBackgroundService in AndroidManifest"
  awk '/<\/application>/ && !s {
        print "        <service android:name=\".ShoalBackgroundService\" android:exported=\"false\" android:foregroundServiceType=\"dataSync\"/>";
        s=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

# Android 11+ package visibility: declare the browser intent so url_launcher can
# open the release/APK download link.
#
# Keyed on the https intent, NOT on <queries>: Flutter's template ships its own
# <queries> block for PROCESS_TEXT, so the old "add the block if there isn't
# one" check silently did nothing on current Flutter and the update link could
# not be opened at all. The intent goes inside the existing block when there is
# one.
python3 - <<'PY' || log "warning: could not add the browser <queries> intent"
import re

p = "android/app/src/main/AndroidManifest.xml"
s = open(p).read()
if 'android:scheme="https"' in s:
    raise SystemExit(0)

intent = (
    "        <intent>\n"
    '            <action android:name="android.intent.action.VIEW"/>\n'
    '            <data android:scheme="https"/>\n'
    "        </intent>\n"
)
if "<queries>" in s:
    s = s.replace("<queries>\n", "<queries>\n" + intent, 1)
else:
    m = re.search(r"^([ \t]*)<application", s, re.M)
    indent = m.group(1) if m else "    "
    s = s[: m.start()] + indent + "<queries>\n" + intent + indent + "</queries>\n" + s[m.start() :]
open(p, "w").write(s)
print("declared the https VIEW intent for url_launcher")
PY

# (Core-library desugaring and the plugin compileSdk alignment used to be
# patched here too. They live in deploy/enable-core-library-desugaring.py and
# deploy/align-plugin-compile-sdk.py now -- one implementation each, called
# from both build paths, rather than two that can disagree.)

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
pkg = m.group(0).strip() if m else "package com.example.shoal"
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
    private val secureChannel = "shoal/screen_security"
    private val backgroundChannel = "shoal/background"
    private val disguiseChannel = "shoal/disguise"

    // Launcher aliases (declared in the manifest): exactly one is enabled at a
    // time, which is the icon + name shown in the launcher.
    private val disguiseAliases = mapOf(
        "default" to ".LauncherDefault",
        "calculator" to ".DisguiseCalculator",
        "notes" to ".DisguiseNotes",
        "weather" to ".DisguiseWeather",
        "clock" to ".DisguiseClock",
        "calendar" to ".DisguiseCalendar",
        "files" to ".DisguiseFiles",
        "flashlight" to ".DisguiseFlashlight"
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
                val intent = Intent(this, ShoalBackgroundService::class.java)
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
    // Where the launcher aliases actually live: the namespace the manifest
    // expanded ".LauncherDefault" against, which is this class's own package.
    private val aliasPackage: String
        get() = javaClass.name.substringBeforeLast('.')

    private fun applyDisguise(which: String) {
        val target = if (disguiseAliases.containsKey(which)) which else "default"
        for ((key, cls) in disguiseAliases) {
            val state = if (key == target) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            packageManager.setComponentEnabledSetting(
                // The class lives in the namespace, which is NOT necessarily
                // packageName: packageName is the applicationId, and the two
                // differ as soon as the app ships under a real package name.
                // Derived from this class rather than hardcoded, so it stays
                // right whatever either of them is set to.
                ComponentName(packageName, aliasPackage + cls),
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
svc = os.path.join(os.path.dirname(p), "ShoalBackgroundService.kt")
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
class ShoalBackgroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "shoal_background"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(
                    channelId, "Shoal background",
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
            .setContentTitle("Shoal")
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
    "disg_clock.xml": vec(
        '  <path android:fillColor="#263238" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#ECEFF1" android:pathData="M54,54m-34,0a34,34 0,1 1,68 0a34,34 0,1 1,-68 0"/>\n'
        '  <path android:fillColor="#263238" android:pathData="M51,28h6v28h-6z M54,54h22v6h-22z"/>\n'),
    "disg_calendar.xml": vec(
        '  <path android:fillColor="#FFFFFF" android:pathData="M14,20h80v74h-80z"/>\n'
        '  <path android:fillColor="#EF5350" android:pathData="M14,20h80v20h-80z"/>\n'
        '  <path android:fillColor="#B0BEC5" android:pathData="M26,52h12v12h-12z M48,52h12v12h-12z M70,52h12v12h-12z M26,72h12v12h-12z M48,72h12v12h-12z"/>\n'),
    "disg_files.xml": vec(
        '  <path android:fillColor="#1E1E24" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#FFCA28" android:pathData="M20,34h28l8,8h32v40h-68z"/>\n'),
    "disg_flashlight.xml": vec(
        '  <path android:fillColor="#212121" android:pathData="M0,0h108v108h-108z"/>\n'
        '  <path android:fillColor="#FFEE58" android:pathData="M40,20h28l-4,16h-20z"/>\n'
        '  <path android:fillColor="#CFD8DC" android:pathData="M44,40h20v40h-20z"/>\n'),
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
        <activity-alias android:name=".LauncherDefault" android:enabled="true" android:exported="true" android:targetActivity=".MainActivity" android:icon="@mipmap/ic_launcher" android:label="Shoal">
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
        <activity-alias android:name=".DisguiseClock" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_clock" android:label="Clock">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseCalendar" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_calendar" android:label="Calendar">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseFiles" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_files" android:label="Files">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
        <activity-alias android:name=".DisguiseFlashlight" android:enabled="false" android:exported="true" android:targetActivity=".MainActivity" android:icon="@drawable/disg_flashlight" android:label="Flashlight">
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

