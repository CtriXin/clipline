#!/usr/bin/env bash
# Zero-Gradle ultra-fast APK builder using Android SDK build-tools directly.
# Requires: ANDROID_HOME (or ANDROID_SDK_ROOT) with platforms/android-34 and build-tools/34.0.0+
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PLATFORM="$(ls -d "$SDK"/platforms/android-* 2>/dev/null | sort -V | tail -1)"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
if [ -z "$PLATFORM" ] || [ -z "$BUILD_TOOLS" ]; then
  echo "Android SDK platforms / build-tools not found in $SDK" >&2
  exit 1
fi

OUT="build"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex"

# 1. Compile XML resources
"$BUILD_TOOLS/aapt2" compile --dir res -o "$OUT/res.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM/android.jar" \
  --manifest AndroidManifest.xml \
  --java "$OUT/gen" \
  -o "$OUT/unsigned.apk" \
  "$OUT/res.zip"

# 2. Compile Java sources
javac --release 11 \
  -classpath "$PLATFORM/android.jar" \
  -d "$OUT/classes" \
  $(find src "$OUT/gen" -name '*.java')

# 3. Dex bytecode
"$BUILD_TOOLS/d8" --min-api 26 --lib "$PLATFORM/android.jar" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

# 4. Add classes.dex to APK, zipalign, sign with debug keystore
(cd "$OUT/dex" && zip -q -u ../unsigned.apk classes.dex)
"$BUILD_TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

KEYSTORE="$OUT/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v -keystore "$KEYSTORE" -storepass android -alias androiddebugkey \
    -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Clipline,O=Clipline,C=CN" >/dev/null 2>&1
fi

"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$OUT/Clipline.apk" \
  "$OUT/aligned.apk"

ls -lh "$OUT/Clipline.apk"
echo "Built $OUT/Clipline.apk"
