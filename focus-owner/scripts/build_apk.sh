#!/bin/bash

# ============================================================================
# Lean, split release build of focus-owner (com.kuhy.focus_owner, the Device
# Owner on the Pixel 6a). Same scheme as kuhyx/tutor scripts/build_apk.sh.
#
# Why not `flutter build apk --release`: it is one ~2-4 minute action, and
# kuhy's agent sessions cap every action at 60 s. This runs the same Gradle
# build Flutter would, as five steps that each finish well under the cap and
# reuse each other's outputs (Gradle up-to-date checks + Flutter's assemble
# cache), and makes it leaner on the way:
#   * arm64 only (the Pixel 6a): one AOT snapshot instead of three, no fat APK;
#   * lintVital* skipped (minutes of lint on every release, nothing it checks
#     is acted on here);
#   * the Gradle JVM sized to fit capped.sh's 4 GiB scope. ~/.gradle/
#     gradle.properties (daemon=false, -Xmx5120m) wins over the project file,
#     so the heap has to be set on the command line.
# R8 stays on: the Flutter Gradle plugin forces minify for release unless
# -Pshrink=false, so every installed DO build so far went through it
# (despite the "deliberately no minify" note in app/build.gradle.kts).
# A warm Gradle daemon is not possible under capped.sh -- its scope (and so
# the daemon) is killed when the step's 60 s RuntimeMaxSec ends.
#
# Usage (one step per invocation, in order; each prints the next):
#   scripts/build_apk.sh prep --phone SERIAL     # pub get, Gradle config, versionCode
#   scripts/build_apk.sh dart                    # Dart kernel + arm64 AOT
#   scripts/build_apk.sh jvm                     # Kotlin/Java, resources, native libs
#   scripts/build_apk.sh r8                      # shrink + dex
#   scripts/build_apk.sh apk                     # package, sign, verify signer + policy
# Locally wrap each in: CAP_MEM=4G CAP_CPU_PCT=20 ~/.claude/scripts/capped.sh
#
# versionCode: one above the installed build (--phone is required: pubspec
# says +1 and the phone is far past it), through the ceiling-gated rule
# ~/.claude/scripts/phone_deploy.sh uses, floored at the commit count.
# Release only: a device owner refuses a debuggable build, and NEVER
# uninstall / pm clear it -- `adb install -r` only (README).
# Output: focus-owner/build/app/outputs/flutter-apk/app-release.apk
# ============================================================================

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_DIR
REPO_DIR="$(git -C "$APP_DIR" rev-parse --show-toplevel)"
readonly REPO_DIR
readonly ANDROID_DIR="$APP_DIR/android"
readonly APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
readonly TARGET_PLATFORM="android-arm64"
readonly STEPS=(prep dart jvm r8 apk)
# The shared kuhy release key (CN=kuhy); anything else must not ship.
readonly CANONICAL_SHA256="9dcc2e6c053c44bb0507903b9dd351015ea7d4315b6ee6c853dd8d807b98f846"
readonly POLICY_ASSET="assets/flutter_assets/assets/policy.json"
readonly PHONE_VERSION_LIB="$HOME/.claude/scripts/lib/phone_deploy_version.sh"

die() { printf 'build_apk: %s\n' "$2" >&2; exit "$1"; }

usage() {
    sed -n '/^# Usage/,/^# Output/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# The SDK .fvmrc pins, without fvm's own startup cost; CI puts its pinned
# flutter on PATH instead.
flutter_bin() {
    if [[ -n ${FLUTTER:-} ]]; then printf '%s' "$FLUTTER"; return; fi
    local ver="" rc
    for rc in "$APP_DIR/.fvmrc" "$REPO_DIR/.fvmrc"; do
        if [[ -r $rc ]]; then ver=$(jq -r '.flutter // empty' "$rc"); break; fi
    done
    local pinned="$HOME/sdk/fvm/versions/$ver/bin/flutter"
    if [[ -n $ver && -x $pinned ]]; then printf '%s' "$pinned"; return; fi
    command -v flutter || die 2 "no flutter on PATH (set FLUTTER=...)"
}

local_prop() {
    grep -m1 "^$1=" "$ANDROID_DIR/local.properties" | cut -d= -f2- ||
        die 2 "$1 missing from android/local.properties: run the prep step first"
}

pubspec_version() {
    local raw
    raw=$(grep -m1 -E '^version:' "$APP_DIR/pubspec.yaml" | sed -E 's/^version:[[:space:]]*//')
    printf '%s' "${raw%%+*}"
}

# Commit count + offset is what release-apk.yml mints. With a phone, one
# above the installed build, gated by phone_deploy's ceiling (exit 37).
build_number() {
    local serial="$1" offset=0 base
    [[ -r $REPO_DIR/.versioncode-offset ]] && read -r offset < "$REPO_DIR/.versioncode-offset"
    base=$(( $(git -C "$REPO_DIR" rev-list --count HEAD) + offset ))
    [[ -n $serial ]] || die 2 "prep needs --phone SERIAL (versionCode = installed + 1)"
    [[ -r $PHONE_VERSION_LIB ]] || die 2 "--phone needs $PHONE_VERSION_LIB"
    # Names the sourced library expects from its entry script.
    # shellcheck disable=SC2034
    SERIAL="$serial" LOCAL_BUILD_HEADROOM=50
    # shellcheck source=/dev/null
    source "$PHONE_VERSION_LIB"
    local next
    next=$(next_build_number "$(app_id)" "$APP_DIR")
    (( next > base )) || next=$base
    printf '%s' "$next"
}

app_id() {
    grep -m1 -oE 'applicationId = "[^"]+"' "$ANDROID_DIR/app/build.gradle.kts" | cut -d'"' -f2
}

step_prep() {
    local serial="$1" flutter number name
    flutter=$(flutter_bin)
    number=$(build_number "$serial")
    name=$(pubspec_version)
    echo "versionCode $number, versionName $name"
    (cd "$APP_DIR" && "$flutter" pub get)
    # Writes gradlew and local.properties (sdk paths, versionCode/Name)
    # exactly as a real `flutter build` would, without building.
    (cd "$APP_DIR" && "$flutter" build apk --config-only --release \
        --target-platform "$TARGET_PLATFORM" \
        --build-number="$number" --build-name="$name")
}

# The -P set `flutter build apk` hands Gradle, derived (not copied) so a
# Flutter bump cannot leave stale defines that re-run the Dart compile.
gradle_args() {
    local flutter json sdk
    flutter=$(flutter_bin)
    json=$("$flutter" --version --machine 2>/dev/null)
    sdk=$(local_prop sdk.dir)
    local -a defines=(
        "FLUTTER_BUILD_NAME=$(local_prop flutter.versionName)"
        "FLUTTER_BUILD_NUMBER=$(local_prop flutter.versionCode)"
        "FLUTTER_VERSION=$(jq -r .frameworkVersion <<<"$json")"
        "FLUTTER_CHANNEL=$(jq -r .channel <<<"$json")"
        "FLUTTER_GIT_URL=$(jq -r .repositoryUrl <<<"$json")"
        "FLUTTER_FRAMEWORK_REVISION=$(jq -r '.frameworkRevision[:10]' <<<"$json")"
        "FLUTTER_ENGINE_REVISION=$(jq -r '.engineRevision[:10]' <<<"$json")"
        "FLUTTER_DART_VERSION=$(jq -r .dartSdkVersion <<<"$json")"
    )
    local encoded="" d ndks
    for d in "${defines[@]}"; do encoded+="${encoded:+,}$(printf '%s' "$d" | base64 -w0)"; done
    ndks=$(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | paste -sd, -)
    GRADLE_ARGS=(
        --console=plain --build-cache
        "-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g -XX:+UseParallelGC -Dfile.encoding=UTF-8"
        "-Ptarget-platform=$TARGET_PLATFORM" -Ptarget=lib/main.dart
        -Pbase-application-name=android.app.Application
        "-Pdart-defines=$encoded" -Pdart-obfuscation=false
        -Ptrack-widget-creation=true -Ptree-shake-icons=true
        "-Pflutter.androidSdkRoot=$sdk"
        "-Pflutter.installedNdkVersions=$ndks"
        "-Pflutter.sdkManagerPath=$sdk/cmdline-tools/latest/bin/sdkmanager"
    )
}

run_gradle() {
    [[ -x $ANDROID_DIR/gradlew ]] || die 2 "android/gradlew missing: run the prep step first"
    gradle_args
    (cd "$ANDROID_DIR" && ./gradlew "${GRADLE_ARGS[@]}" "$@")
}

apk_sha256() {
    local sdk signer
    sdk=$(local_prop sdk.dir)
    signer=$(find "$sdk/build-tools" -name apksigner -type f | sort -V | tail -1)
    [[ -n $signer ]] || die 2 "apksigner not found under $sdk/build-tools"
    "$signer" verify --print-certs "$APK" |
        sed -nE 's/.*certificate SHA-256 digest: ([0-9a-f]+).*/\1/p' | head -1
}

step_apk() {
    local started sha
    printf -v started '%(%s)T' -1
    # Removed first so that only this step's output can pass the checks below.
    rm -f "$APK"
    run_gradle :app:assembleRelease \
        -x lintVitalAnalyzeRelease -x lintVitalReportRelease -x lintVitalRelease
    # A killed step leaves the previous APK in place; never pass that on.
    if [[ ! -f $APK ]] || (( $(stat -c %Y "$APK") < started )); then
        die 4 "$APK was not rebuilt by this step"
    fi
    sha=$(apk_sha256)
    [[ $sha == "$CANONICAL_SHA256" ]] ||
        die 5 "APK signer SHA-256 $sha is not the kuhy release key (key.properties missing?)"
    # The whole point of most rebuilds: the bundled whitelist.
    unzip -p "$APK" "$POLICY_ASSET" | jq -e '.allowed_packages | length > 0' >/dev/null ||
        die 6 "$POLICY_ASSET missing or without allowed_packages in the APK"
    echo "OK $APK ($(du -h "$APK" | cut -f1), signer kuhy, versionCode $(local_prop flutter.versionCode))"
}

main() {
    local step="${1:-}" serial=""
    [[ -n $step ]] || usage 2
    shift
    while (( $# > 0 )); do
        case "$1" in
            --phone) serial="${2:?--phone needs a serial}"; shift ;;
            -h|--help) usage 0 ;;
            *) die 2 "unknown option: $1" ;;
        esac
        shift
    done
    if [[ -z ${JAVA_HOME:-} && -d /usr/lib/jvm/java-21-openjdk ]]; then
        export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
    fi
    case "$step" in
        prep) step_prep "$serial" ;;
        dart) run_gradle :app:compileFlutterBuildRelease ;;
        jvm) run_gradle :app:compileReleaseJavaWithJavac :app:processReleaseResources \
                :app:mergeReleaseNativeLibs :app:mergeReleaseAssets :app:mergeReleaseJavaResource ;;
        r8) run_gradle :app:minifyReleaseWithR8 ;;
        apk) step_apk ;;
        -h|--help) usage 0 ;;
        *) die 2 "unknown step: $step (one of: ${STEPS[*]})" ;;
    esac
    local i
    for i in "${!STEPS[@]}"; do
        if [[ ${STEPS[i]} == "$step" && -n ${STEPS[i + 1]:-} ]]; then
            echo "step '$step' done in ${SECONDS}s; next: scripts/build_apk.sh ${STEPS[i + 1]}"
            return 0
        fi
    done
    echo "step '$step' done in ${SECONDS}s"
}

main "$@"
