#!/usr/bin/env bash
# Create the signing key Aegis releases are signed with, once, and print exactly
# what to put in GitHub's repository secrets.
#
# WHY THIS IS NOT OPTIONAL
#
# Android identifies an app by its signing key. Two APKs with the same package
# name but different keys are, to Android, different apps that refuse to replace
# one another -- reported on the phone as a bare "App not installed".
#
# Without a key of its own, Gradle falls back to the debug keystore at
# ~/.android/debug.keystore. A fresh CI runner has no such file, so Gradle
# GENERATES A NEW RANDOM ONE EVERY RUN. Every CI build is therefore signed by a
# different key than the last, and no build can ever be installed over its
# predecessor. That is a permanent condition, not a glitch: it cannot be fixed
# by rebuilding, only by giving the project a stable key.
#
# It is also what makes an update meaningful. A debug-signed APK is evidence of
# nothing about who built it -- the debug key is public and anyone can sign a
# modified "update" with it. For a messenger whose claim is that you can tell
# what you are running, the signature is part of the product.
#
# Usage:
#
#     deploy/make-release-key.sh            # writes ./aegis-release.jks
#     deploy/make-release-key.sh /path/to/aegis-release.jks
#
# Then follow the four secrets it prints. Run it ONCE and keep the file: losing
# it means users can no longer update, only uninstall and reinstall from scratch.
set -euo pipefail

KEYSTORE="${1:-aegis-release.jks}"
ALIAS="${AEGIS_KEY_ALIAS:-aegis}"
# 10000 days ~ 27 years. Android wants a key that outlives the app; a key that
# expires strands every installed user on the version they have.
DAYS="${AEGIS_KEY_DAYS:-10000}"

if [ -e "$KEYSTORE" ]; then
  echo "refusing to overwrite $KEYSTORE -- it may be the key your users already"
  echo "have installed. Move it aside first if you really mean to replace it." >&2
  exit 1
fi

command -v keytool >/dev/null 2>&1 || {
  echo "keytool not found; install a JDK (e.g. apt install default-jdk)" >&2
  exit 1
}

# A random passphrase, so the key's strength does not depend on someone
# inventing one at 2am. It is printed once, below, and stored only in the
# repository secret.
if command -v openssl >/dev/null 2>&1; then
  PASSWORD="$(openssl rand -base64 30 | tr -d '\n/+=' | cut -c1-32)"
else
  PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-32)"
fi

umask 077
keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity "$DAYS" \
  -storepass "$PASSWORD" -keypass "$PASSWORD" \
  -dname "CN=Aegis, OU=Aegis, O=Aegis, L=, ST=, C=" \
  >/dev/null

B64="$(base64 -w0 "$KEYSTORE" 2>/dev/null || base64 "$KEYSTORE" | tr -d '\n')"
FINGERPRINT="$(keytool -list -v -keystore "$KEYSTORE" -storepass "$PASSWORD" \
  | grep 'SHA256:' | head -1 | sed 's/^[[:space:]]*//')"

cat <<INFO

  Created $KEYSTORE
  $FINGERPRINT

  BACK IT UP NOW, somewhere you will still have in five years, and keep the
  passphrase below with it. There is no way to recreate this key: lose it and
  every installed copy of Aegis is stranded on the version it has.

  Set these four repository secrets (Settings -> Secrets and variables ->
  Actions -> New repository secret), or with the gh CLI:

    gh secret set ANDROID_KEYSTORE_PASSWORD --body '$PASSWORD'
    gh secret set ANDROID_KEY_ALIAS         --body '$ALIAS'
    gh secret set ANDROID_KEY_PASSWORD      --body '$PASSWORD'
    gh secret set ANDROID_KEYSTORE_BASE64   < <(printf '%s' "\$(base64 -w0 $KEYSTORE)")

  The base64 of the keystore is long; if you are pasting by hand, it is in
  ${KEYSTORE}.base64 (delete that file afterwards).

  Once those are set, every CI build is signed by this key, installs over the
  previous one, and the build log names the key that signed it.

INFO

printf '%s' "$B64" > "${KEYSTORE}.base64"
echo "  wrote ${KEYSTORE}.base64"
echo
