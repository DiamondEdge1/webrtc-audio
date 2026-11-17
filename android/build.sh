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
VERSION=${WEBRTC_AUDIO_VERSION:-155.0.0-audio1}
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
  rm -rf "$out"
  mkdir -p "$out"
  # build_aar.py's own GN args (release, no tests) plus protobuf off, as on iOS. Word-split on purpose.
  # shellcheck disable=SC2086
  python3 tools_webrtc/android/build_aar.py \
    --build-dir "$out/build" \
    --output "$aar" \
    --arch $ARCHS \
    --extra-gn-args 'rtc_enable_protobuf=false' 'rtc_include_tests=false' 'treat_warnings_as_errors=false'
  # Licenses travel inside the AAR, as they do inside the iOS zip: WebRTC's own, and the third-party
  # notices build_aar.py generates beside its output for exactly what was linked.
  zip -j -q "$aar" LICENSE PATENTS "$out/LICENSE.md"

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
  if unzip -l "$tmp/classes.jar" | grep -q -E 'org/webrtc/(Camera|ScreenCapturer|SurfaceViewRenderer|Default.*VideoEncoderFactory)'; then
    echo "video classes found in classes.jar" >&2
    exit 1
  fi
  rm -rf "$tmp"
}

case "$PHASE" in
  sync) sync ;;
  build) build ;;
  all) sync && build ;;
  *) echo "usage: $0 [sync|build|all]" >&2; exit 2 ;;
esac
