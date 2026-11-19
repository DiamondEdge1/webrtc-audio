#!/usr/bin/env bash
# Build an audio-only libwebrtc AAR for Android (README.md).
#
# The same WebRTC commit as ios/build.sh, so both platforms ship one milestone, built with WebRTC's own
# tools_webrtc/android/build_aar.py after android/audio-only.patch removes the video codecs, capturers
# and renderers from the AAR's two targets. **Linux only**: WebRTC's Android toolchain (the NDK and the
# Java build) is fetched for a Linux host, so on a Mac this runs in CI (.github/workflows/android.yml).
#
# Usage: android/build.sh [sync|build|all]   (default: all)
#   sync   depot_tools + the WebRTC Android checkout at $WEBRTC_COMMIT (~30 GB in $WEBRTC_WORK, slow once)
#   build  patch, compile every ABI, assemble the AAR, print its SHA-256
set -euo pipefail

# Keep these three equal to ios/build.sh's: one release carries both platforms' binaries.
BRANCH=${WEBRTC_BRANCH:-branch-heads/8059}
COMMIT=${WEBRTC_COMMIT:-5bd86a2f17a35dfc986b87d058f511e45805bd1d}
VERSION=${WEBRTC_AUDIO_VERSION:-155.0.0-audio2}
# The ABIs io.github.webrtc-sdk:android ships, which is what the app linked before this build.
ARCHS=${WEBRTC_ARCHS:-armeabi-v7a arm64-v8a x86 x86_64}
WORK=${WEBRTC_WORK:-$HOME/webrtc-android}
HERE=$(cd "$(dirname "$0")" && pwd)
PHASE=${1:-all}

sync() {
  mkdir -p "$WORK"
  cd "$WORK"
  if [ ! -d depot_tools ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
  fi
  export PATH="$WORK/depot_tools:$PATH"
  if [ ! -d src ]; then
    fetch --nohooks webrtc_android
  fi
  git -C src fetch origin "+refs/$BRANCH:refs/remotes/origin/$BRANCH"
  # Anything a previous build patched goes back first, so the checkout and sync see clean sources.
  git -C src checkout -f "$COMMIT"
  gclient sync -D --with_branch_heads --with_tags
  # The apt packages the Android build needs (a JDK, the 32-bit libs for armeabi-v7a/x86 tooling).
  if [ "${WEBRTC_INSTALL_DEPS:-0}" = 1 ]; then
    sudo src/build/install-build-deps.sh --android --no-prompt --no-chromeos-fonts
  fi
}

build() {
  export PATH="$WORK/depot_tools:$PATH"
  cd "$WORK/src"
  git checkout -f "$COMMIT" -- sdk
  git apply "$HERE/audio-only.patch"

  local out="$WORK/out"
  local aar="$out/webrtc-audio-android-$VERSION.aar"
  # build_aar.py refuses a build directory outside the checkout ("--build-dir must be under …/src"), so the
  # ninja tree lives under src/out while the AAR and its LICENSE.md land in $out, where CI collects them.
  local build_dir="$WORK/src/out/audio-aar"
  rm -rf "$out" "$build_dir"
  mkdir -p "$out"
  # build_aar.py's own GN args (release, no tests) plus protobuf off, as on iOS. Word-split on purpose.
  # shellcheck disable=SC2086
  python3 tools_webrtc/android/build_aar.py \
    --build-dir "$build_dir" \
    --output "$aar" \
    --arch $ARCHS \
    --extra-gn-args 'rtc_enable_protobuf=false' 'rtc_include_tests=false' 'treat_warnings_as_errors=false'
  # Consumer keep rules, which build_aar.py doesn't write: jni_zero's own (native methods, @CalledByNative, the
  # J.N hashes native code checks at load), and every org.webrtc name, which JNI_OnLoad looks up as it registers.
  # An app that shrinks its release build would otherwise rename them and abort the first time voice starts.
  { cat third_party/jni_zero/proguard.flags; echo '-keep class org.webrtc.** { *; }'; } > "$out/proguard.txt"
  # Licenses travel inside the AAR, as they do inside the iOS zip: WebRTC's own, and the third-party
  # notices build_aar.py generates beside its output for exactly what was linked.
  zip -j -q "$aar" LICENSE PATENTS "$out/LICENSE.md" "$out/proguard.txt"

  verify "$aar"
  echo "built $aar"
  sha256sum "$aar"
}

# The binary must carry none of the codecs the patch removes; a dependency that crept back in through
# another target would otherwise ship silently.
verify() {
  local aar=$1 tmp
  tmp=$(mktemp -d)
  unzip -q "$aar" -d "$tmp"
  local so
  # Each codec library embeds its own name string ("WebM Project VP8 Encoder", "AOMedia Project AV1
  # Encoder", "dav1d … VideoLAN"), which survives stripping where its hidden symbol names do not.
  for so in "$tmp"/jni/*/libjingle_peerconnection_so.so; do
    if strings "$so" | grep -q -E 'WebM Project|AOMedia Project|VideoLAN'; then
      echo "video codec symbols found in $so" >&2
      exit 1
    fi
    echo "$(basename "$(dirname "$so")"): $(du -k "$so" | cut -f1) KB"
  done
  local classes
  classes=$(unzip -Z1 "$tmp/classes.jar")
  if echo "$classes" | grep -q -E 'org/webrtc/(Camera|ScreenCapturer|SurfaceViewRenderer|Default.*VideoEncoderFactory)'; then
    echo "video classes found in classes.jar" >&2
    exit 1
  fi
  # And it must carry the Java side of its native calls, which jni_zero generates apart from the classes
  # themselves and 155.0.0-audio1 shipped without: every org.webrtc class with a Natives interface needs its
  # *Jni proxy, and the proxies need the registration they call through (J.N, or GEN_JNI without
  # multiplexing). jni_zero's own two are left out: nothing in WebRTC calls them.
  local natives missing=0
  for natives in $(echo "$classes" | grep '^org/webrtc/.*\$Natives\.class$'); do
    if ! echo "$classes" | grep -qxF "${natives%\$Natives.class}Jni.class"; then
      echo "no JNI proxy for ${natives%.class}" >&2
      missing=1
    fi
  done
  if ! echo "$classes" | grep -q -x -E 'J/N\.class|org/jni_zero/GEN_JNI\.class'; then
    echo "no JNI registration class (J.N or GEN_JNI) in classes.jar" >&2
    missing=1
  fi
  [ "$missing" = 0 ] || exit 1
  unzip -l "$aar" proguard.txt > /dev/null || { echo "no proguard.txt in the AAR" >&2; exit 1; }
  echo "classes.jar: $(echo "$classes" | grep -c 'Jni\.class$') JNI proxies and their registration"
  rm -rf "$tmp"
}

case "$PHASE" in
  sync) sync ;;
  build) build ;;
  all) sync && build ;;
  *) echo "usage: $0 [sync|build|all]" >&2; exit 2 ;;
esac
