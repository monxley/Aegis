#!/usr/bin/env bash
# Build an F-Droid repository out of already-signed Shoal APKs.
#
#   deploy/fdroid-repo.sh <apk-dir> <output-dir>
#
# The result is a directory the F-Droid app can be pointed at directly:
# APKs plus a signed index. Users add one URL and get updates through F-Droid
# from then on, with no Google account, no Play Services and no sideloading
# prompt each time.
#
# WHY A REPOSITORY OF OUR OWN, RATHER THAN f-droid.org
#
# f-droid.org builds from source on its own machines and signs the result with
# ITS key, not ours. That is a good property for them and a real cost for us:
# the APK a user gets from f-droid.org would have a different signature from
# the one on GitHub Releases, so nobody could move between the two without
# uninstalling and losing their identity. A repository we sign ourselves keeps
# one signature across every channel. Submitting to f-droid.org as well is
# still worth doing later -- it is where people look -- but it is a separate
# decision with that consequence attached.
#
# THE INDEX IS SIGNED WITH THE APP'S RELEASE KEY
#
# F-Droid identifies a repository by the fingerprint of the key that signed its
# index, and users pin it in the URL they add. Reusing the release key means one
# key to keep and one fingerprint to publish, and it cannot drift from the APK
# signature. It also means a compromise of that key is a compromise of both --
# which is already true in practice, since both live in the same place. To
# separate them, point KEYSTORE at a different file: nothing else here assumes
# they are the same.
set -euo pipefail

APK_DIR="${1:?usage: fdroid-repo.sh <apk-dir> <output-dir>}"
OUT="${2:?usage: fdroid-repo.sh <apk-dir> <output-dir>}"

REPO_URL="${FDROID_REPO_URL:-https://monxley.github.io/shoal/fdroid/repo}"
KEYSTORE="${KEYSTORE:?set KEYSTORE to the .jks that signs the index}"
KEY_ALIAS="${KEY_ALIAS:?set KEY_ALIAS}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:?set KEYSTORE_PASSWORD}"
KEY_PASSWORD="${KEY_PASSWORD:-$KEYSTORE_PASSWORD}"
PKG="${SHOAL_APPLICATION_ID:-io.github.monxley.shoal}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

command -v fdroid >/dev/null 2>&1 || fail "fdroidserver is not installed (pip install fdroidserver)"

shopt -s nullglob
apks=("$APK_DIR"/*.apk)
[ "${#apks[@]}" -gt 0 ] || fail "no APKs in $APK_DIR"

# The fingerprint this repository stands behind: the certificate in the
# keystore that also signs the index.
EXPECTED_FP="$(keytool -list -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
  -storepass "$KEYSTORE_PASSWORD" -v 2>/dev/null \
  | awk '/SHA256:/ {gsub(/:/,"",$2); print tolower($2); exit}')"
[ -n "$EXPECTED_FP" ] || fail "could not read the certificate fingerprint from $KEYSTORE"

# Only APKs signed with THAT key may go in.
#
# This project's releases up to v0.3.0 were signed with a local Android debug
# key, a different certificate entirely. Android will not install across a
# signature change, so an F-Droid repository offering both would list updates
# that every phone then refuses -- reported to the user as a failed install with
# no reason given, which is exactly the trail we have already spent a day
# following once. Mixed signers are dropped here, loudly, rather than shipped.
APKSIGNER="$(find "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}/build-tools" \
  -name apksigner 2>/dev/null | sort | tail -1 || true)"
[ -n "$APKSIGNER" ] || fail "apksigner not found; cannot check what signed these APKs,
     and publishing an APK whose signature has not been checked is how a
     repository ends up offering updates nobody can install."

log "checking what signed each APK (expecting ${EXPECTED_FP:0:16}...)"
accepted=()
for apk in "${apks[@]}"; do
  fp="$("$APKSIGNER" verify --print-certs "$apk" 2>/dev/null \
        | awk '/SHA-256 digest:/ {print tolower($NF); exit}')"
  if [ "$fp" = "$EXPECTED_FP" ]; then
    echo "    ok      $(basename "$apk")"
    accepted+=("$apk")
  else
    echo "    SKIPPED $(basename "$apk") -- signed by ${fp:-unknown}, not this repository's key" >&2
  fi
done
[ "${#accepted[@]}" -gt 0 ] || fail "none of the APKs are signed with $KEY_ALIAS from $KEYSTORE.
     A repository of them would be a list of updates no phone can install."
apks=("${accepted[@]}")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"
cp "${apks[@]}" "$WORK/repo/"
cp -r "$HERE/fdroid/metadata" "$WORK/metadata"
log "building a repository from ${#apks[@]} APK(s)"

# fdroidserver reads passwords from this file, so it never reaches a log or a
# process list.
( umask 077
  cat > "$WORK/config.yml" <<YAML
repo_url: "$REPO_URL"
repo_name: "Shoal"
repo_description: "Official releases of Shoal, the anonymous post-quantum messenger. Signed with the same key as the APKs on GitHub."
repo_icon: "icon.png"
archive_older: 0
keystore: "$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE")"
repo_keyalias: "$KEY_ALIAS"
keystorepass: "$KEYSTORE_PASSWORD"
keypass: "$KEY_PASSWORD"
make_current_version_link: false
YAML
)
mkdir -p "$WORK/repo/icons"
cp "$HERE/app/assets/logo/icon_legacy.png" "$WORK/repo/icons/icon.png" 2>/dev/null || true

( cd "$WORK" && fdroid update --pretty --verbose ) || fail "fdroid update failed"

# --- Prove the repository is actually usable, rather than assume it ----------
#
# A broken index does not look broken: the files exist, the build is green, and
# the failure surfaces only on a user's phone as "repository unavailable". So
# every property the client checks gets checked here.

log "verifying the repository"

for f in repo/index-v1.json repo/index.jar repo/entry.json repo/index-v2.json; do
  [ -s "$WORK/$f" ] || fail "$f is missing or empty -- fdroid update did not produce a usable index"
done

# The client refuses an index whose JAR signature does not verify.
if command -v jarsigner >/dev/null 2>&1; then
  jarsigner -verify "$WORK/repo/index.jar" >/dev/null \
    || fail "repo/index.jar does not verify -- clients would reject this repository"
  echo "    index.jar signature verifies"
else
  echo "    WARNING: jarsigner absent, index signature not verified here" >&2
fi

python3 - "$WORK/repo/index-v2.json" "$PKG" <<'PY' || fail "the index does not describe the app"
import json, sys
index, pkg = json.load(open(sys.argv[1])), sys.argv[2]
pkgs = index.get("packages", {})
if pkg not in pkgs:
    sys.exit(f"    {pkg} is not in the index (found: {list(pkgs) or 'nothing'})")
versions = pkgs[pkg].get("versions", {})
if not versions:
    sys.exit(f"    {pkg} is in the index with no versions attached")
meta = pkgs[pkg].get("metadata", {})
name = meta.get("name", {})
for locale in ("en-US", "ru"):
    if locale not in name:
        sys.exit(f"    no '{locale}' name in the index: the localised metadata "
                 f"was not picked up (found: {list(name)})")
codes = sorted(v["manifest"]["versionCode"] for v in versions.values())
print(f"    {pkg}: {len(versions)} version(s), versionCode {codes}")
print(f"    localised into: {', '.join(sorted(name))}")
PY

# The fingerprint is what users pin when they add the repository. It is the
# SHA-256 of the signing certificate -- the same value apksigner prints for the
# APKs, because it is the same key.
FINGERPRINT="$(python3 - "$WORK/repo/entry.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("index", {}).get("sha256", ""))
PY
)"
CERT_FP="$EXPECTED_FP"

mkdir -p "$OUT"
rm -rf "${OUT:?}/repo"
cp -r "$WORK/repo" "$OUT/repo"

# A landing page, so the repository URL is something a person can be sent.
# Generated here rather than in docs/build.py because the fingerprint is not
# known until the key exists.
cat > "$OUT/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shoal on F-Droid</title>
<meta name="description" content="Add the Shoal F-Droid repository to get signed updates without Google Play.">
<link rel="canonical" href="https://monxley.github.io/shoal/fdroid/">
<link rel="stylesheet" href="../assets/site.css">
</head>
<body>
<main id="main">
<section class="hero">
<p class="kicker">F-Droid</p>
<h1>Updates without a store account</h1>
<p class="lead">Add this repository in the F-Droid app and Shoal updates like any
other app on your phone. Every build is signed with the same key as the APKs on
GitHub, so you can move between the two without reinstalling.</p>
<pre><code>${REPO_URL}?fingerprint=${CERT_FP}</code></pre>
<p class="note">Fingerprint <code>${CERT_FP}</code>. F-Droid pins it when you add
the repository: if it ever differs, the repository is not this one. Compare it
with the certificate on any release APK &mdash;
<code>apksigner verify --print-certs</code> prints the same value.</p>
<p class="cta"><a class="btn primary" href="../">Shoal</a>
<a class="btn" href="https://github.com/monxley/shoal">Source</a></p>
<aside class="alpha"><strong>Alpha software.</strong> Shoal has not had an
external security audit. The protocol and its implementation may contain flaws.</aside>
</section>
</main>
</body>
</html>
HTML

log "Done."
echo "    repository : $OUT/repo"
echo "    add in F-Droid:"
echo "      ${REPO_URL}?fingerprint=${CERT_FP}"
[ -n "$FINGERPRINT" ] && echo "    index sha256: $FINGERPRINT"
