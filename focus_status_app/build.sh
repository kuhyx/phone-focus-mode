#!/usr/bin/env bash
# ============================================================
# Focus Status App builder (no Gradle, no Kotlin).
# Compiles a minimal Java APK with aapt2 + javac + d8 + apksigner.
# Produces: build/focus_status.apk  (debug-signed)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
# Pick highest-numbered build-tools directory.
BUILD_TOOLS_DIR="$(ls -1d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
# Pick highest-numbered platform.
PLATFORM_DIR="$(ls -1d "$SDK"/platforms/android-*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
PLATFORM_JAR="$PLATFORM_DIR/android.jar"

[ -d "$BUILD_TOOLS_DIR" ] || { echo "ERROR: build-tools not found under $SDK" >&2; exit 1; }
[ -f "$PLATFORM_JAR" ]    || { echo "ERROR: android.jar not found at $PLATFORM_JAR" >&2; exit 1; }

AAPT2="$BUILD_TOOLS_DIR/aapt2"
D8="$BUILD_TOOLS_DIR/d8"
ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"

for tool in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
    [ -x "$tool" ] || { echo "ERROR: missing build tool: $tool" >&2; exit 1; }
done

BUILD="$SCRIPT_DIR/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/compiled-res" "$BUILD/classes" "$BUILD/dex"

# ---- Compile resources (none for now, but aapt2 requires the dir) ----
mkdir -p "$SCRIPT_DIR/res"
if find "$SCRIPT_DIR/res" -type f -print -quit | grep -q .; then
    "$AAPT2" compile --dir "$SCRIPT_DIR/res" -o "$BUILD/compiled-res"
fi

# ---- Link resources + manifest into base APK ----
LINK_ARGS=(
    --manifest "$SCRIPT_DIR/AndroidManifest.xml"
    -I "$PLATFORM_JAR"
    --java "$BUILD"
    --min-sdk-version 29
    --target-sdk-version 35
    --version-code 1
    --version-name 1.0.0
    -o "$BUILD/base.apk"
)
# Include any compiled res archives.
for rfile in "$BUILD"/compiled-res/*.flat; do
    [ -e "$rfile" ] && LINK_ARGS+=("$rfile")
done
"$AAPT2" link "${LINK_ARGS[@]}"

# ---- Compile Java ----
# Collect .java files (including generated R.java if resources exist).
JAVA_SRCS=()
while IFS= read -r -d '' f; do JAVA_SRCS+=("$f"); done < <(find "$SCRIPT_DIR/java" "$BUILD" -name '*.java' -print0)

javac -source 11 -target 11 \
    -classpath "$PLATFORM_JAR" \
    -d "$BUILD/classes" \
    "${JAVA_SRCS[@]}"

# ---- Dex ----
CLASS_FILES=()
while IFS= read -r -d '' f; do CLASS_FILES+=("$f"); done < <(find "$BUILD/classes" -name '*.class' -print0)
"$D8" --min-api 29 --output "$BUILD/dex" "${CLASS_FILES[@]}" --lib "$PLATFORM_JAR"

# ---- Add classes.dex into the APK ----
cp "$BUILD/base.apk" "$BUILD/unsigned.apk"
(cd "$BUILD/dex" && zip -q "$BUILD/unsigned.apk" classes.dex)

# ---- Align ----
"$ZIPALIGN" -f -p 4 "$BUILD/unsigned.apk" "$BUILD/aligned.apk"

# ---- Sign with debug key (auto-generated on first build) ----
KEYSTORE="$SCRIPT_DIR/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    echo "Generating debug keystore..."
    keytool -genkeypair -v \
        -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Focus Status Debug, OU=Dev, O=Dev, L=NA, ST=NA, C=NA" \
        >/dev/null 2>&1
fi
"$APKSIGNER" sign \
    --ks "$KEYSTORE" --ks-pass pass:android \
    --key-pass pass:android \
    --out "$BUILD/focus_status.apk" \
    "$BUILD/aligned.apk"

echo ""
echo "Built: $BUILD/focus_status.apk"
ls -l "$BUILD/focus_status.apk"
