# webrtc-audio

Audio-only builds of Google's [WebRTC](https://webrtc.googlesource.com/src/) for Diamond Tabletop's voice
chat: peer connections, audio and data channels, with no camera capture, video codecs or video rendering.
Each release carries the iOS framework and, from the Android phase on, the Android library, both built
from the same WebRTC commit and patches.

| Release | WebRTC | Contents |
| --- | --- | --- |
| `155.0.0-audio1` | M155, `branch-heads/8059` @ `5bd86a2f17a3` | `WebRTC-155.0.0-audio1.xcframework.zip` (iOS arm64 device + arm64 simulator) |

## Why

A stock WebRTC build ships a camera capturer, VP8/VP9/AV1/H.264 codecs and Metal rendering. An app that
only talks pays for them twice:

- **App Store processing.** The camera capturer references `AVCaptureDevice`, and Apple rejects any binary
  that references a protected API without a purpose string (ITMS-90683), whether or not it is ever called.
- **Size.** The iOS framework drops from 12.4 MB (stasel/WebRTC M155) to 7.0 MB for arm64.

No GN argument does this. `sdk/BUILD.gn`'s `framework_objc` depends unconditionally on the camera,
video-codec, VideoToolbox and Metal targets, and `RTCPeerConnectionFactory`'s default `init` (and the
builder's `defaultBuilder`) hard-wire the H.264 factories. `rtc_include_video` and `rtc_build_openh264` do
not exist, `rtc_use_h264` is already false on iOS, and `rtc_build_libvpx=false` means "supplied
externally". So `ios/audio-only.patch` removes those dependencies and leaves the factories' video codecs
unset; the video-track classes stay, with no codecs to offer, so the public API is unchanged.

## Building iOS

On a Mac with Xcode:

```sh
ios/build.sh sync    # once: depot_tools + the WebRTC checkout (~28 GB in ~/projects/webrtc-build)
ios/build.sh build   # patch, build arm64 device + simulator, zip, print the SHA-256
```

`WEBRTC_WORK` moves the checkout. The build mirrors stasel/WebRTC's `scripts/build.sh` at the same commit,
minus the video-only GN args.

## Releasing

Publish the zip as a release asset tagged with its version, and update the consuming app's fetch script
with the new URL, version and SHA-256. Check first that the binary has no `AVCapture` references
(`nm -u`, `strings`) and record its size.

## Bumping WebRTC

1. Take the branch and commit stasel/WebRTC built the milestone from (their release notes name both) and set
   `BRANCH`, `COMMIT` and `VERSION` in the build script.
2. `sync`, then `build`. If the patch no longer applies, rebase it, keeping it to removals.
3. Verify and release as above.

Security fixes arrive the same way, so keeping current is this repo's job.

## Licence

The binaries are WebRTC, under its BSD licence and patent grant; each release zip includes WebRTC's
`LICENSE` and `PATENTS`.
