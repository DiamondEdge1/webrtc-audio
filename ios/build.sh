#!/usr/bin/env bash
# Build an audio-only WebRTC.xcframework for iOS (README.md).
#
# Mirrors stasel/WebRTC's scripts/build.sh — the build this replaces — at the same WebRTC commit, with
# three differences: audio-only.patch is applied, the video-only GN args are dropped, and only the two iOS
# slices this app links are built (arm64 device, arm64 simulator).
#
# Usage: ios/build.sh [sync|build|all]   (default: all)
#   sync   depot_tools + the WebRTC checkout at $WEBRTC_COMMIT (~28 GB in $WEBRTC_WORK, slow once)
#   build  patch, compile both slices, assemble and zip the xcframework, print its SHA-256
set -euo pipefail

# stasel's 155.0.0 was built from this branch and commit; keep them together when bumping.
BRANCH=${WEBRTC_BRANCH:-branch-heads/8059}
COMMIT=${WEBRTC_COMMIT:-5bd86a2f17a35dfc986b87d058f511e45805bd1d}
VERSION=${WEBRTC_AUDIO_VERSION:-155.0.0-audio1}
WORK=${WEBRTC_WORK:-$HOME/projects/webrtc-build}
HERE=$(cd "$(dirname "$0")" && pwd)
PHASE=${1:-all}

sync() {
  mkdir -p "$WORK"
  cd "$WORK"
  if [ ! -d depot_tools ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
  fi
  export PATH="$WORK/depot_tools:$PATH"
  ensure_bootstrap
  if [ ! -d src ]; then
    fetch --nohooks webrtc_ios
  fi
  git -C src fetch origin "+refs/$BRANCH:refs/remotes/origin/$BRANCH"
  # Anything a previous build patched goes back first, so the checkout and sync see clean sources.
  git -C src checkout -f "$COMMIT"
  gclient sync -D --with_branch_heads --with_tags
}

build() {
  export PATH="$WORK/depot_tools:$PATH"
  cd "$WORK/src"
  git checkout -f "$COMMIT" -- sdk
  git apply "$HERE/audio-only.patch"

  local out="$WORK/out"
  rm -rf "$out"
  # stasel's COMMON_GN_ARGS minus the video ones (VP9, OpenGL rendering, H.265, system OpenH264), plus
  # protobuf off; SCTP stays, because voice opens an RTCDataChannel.
  local common="is_debug=false is_component_build=false rtc_include_tests=false rtc_enable_protobuf=false \
rtc_enable_objc_symbol_export=true enable_stripping=true enable_dsyms=true use_lld=true \
target_os=\"ios\" ios_deployment_target=\"17.0\" ios_enable_code_signing=false"
  for slice in device simulator; do
    gn gen "$out/ios-arm64-$slice" --args="$common target_cpu=\"arm64\" target_environment=\"$slice\""
    ninja -C "$out/ios-arm64-$slice" framework_objc
  done

  xcodebuild -create-xcframework \
    -framework "$out/ios-arm64-device/WebRTC.framework" \
    -framework "$out/ios-arm64-simulator/WebRTC.framework" \
    -output "$out/WebRTC.xcframework"
  cp LICENSE PATENTS "$out/WebRTC.xcframework/"
  (cd "$out" && zip --symlinks -rq "WebRTC-$VERSION.xcframework.zip" WebRTC.xcframework)
  echo "built $out/WebRTC-$VERSION.xcframework.zip"
  shasum -a 256 "$out/WebRTC-$VERSION.xcframework.zip"
}

case "$PHASE" in
  sync) sync ;;
  build) build ;;
  all) sync && build ;;
  *) echo "usage: $0 [sync|build|all]" >&2; exit 2 ;;
esac
