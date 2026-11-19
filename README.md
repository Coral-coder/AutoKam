# AutoKam

One app, two jobs:

- **iPhone — the camera.** Records takes and streams each one to the Mac *while it's recording*
  (no AirDrop, no huge files to move afterwards).
- **Mac — the receiver.** Saves every take straight into a folder, shows a live view of the
  camera, and can start/stop/keep takes remotely.

Bundle ID `com.lightwave.autokam` (one universal app: iOS + macOS).

## Hand gestures (show it for a moment; Settings → Gestures → Speed)

| Gesture | Not recording | Recording |
|---|---|---|
| ✋ open hand | start (counts in) | goofed — toss this take, count in the same segment again |
| ✊ fist | start the next segment (counts in) | **cut** — keep this take, count in the next segment |
| 👍 thumbs up | keep the last take | stop and **keep** this take |
| ✌️ peace sign | — | stop (not kept) |

The phone pops up the gesture it recognised and what it did. Retakes and cuts always count in
(at least 2 s, with beeps) so there's time to drop the hand. Kept takes are copied to
**Good Takes** with the gesture cut off the end; files are named `Seg 02 - Take 03`.

## On the phone screen

- **Mic chip** — which mic is recording (green = external), mono/stereo. Stereo mics record stereo.
- **VU meter** (right edge) — L/R levels with peak hold.
- **Sound warnings** — a small yellow note if the external mic isn't connected, or if a take
  has had no sound for 4 s. Tap to hide for 2 minutes.
- **Focus target** — follows autofocus: green on a face, white on the centre/tapped point,
  yellow while adjusting. Tap to focus somewhere; long‑press to go back to automatic.
- **?** — the walkthrough (also on the Mac: toolbar → How it works).

## Where takes go on the Mac

```
~/Movies/AutoKam/<Session>/All Takes/Take 001.mov     every take
~/Movies/AutoKam/<Session>/Good Takes/Take 001.mov    👍 takes only
```

Change the folder or start a new session from the Mac window. Files are regular `.mov`
(HEVC or H.264, no re‑encode on the Mac).

## How it works

- The Mac advertises itself over Bonjour (`_autokam._tcp`); the iPhone finds it on its own —
  same Wi‑Fi or direct peer‑to‑peer Wi‑Fi.
- The iPhone encodes fragmented MP4 in 1‑second segments and sends each segment as soon as it
  exists. A local copy is kept until the Mac confirms it saved the take, so if Wi‑Fi drops the
  rest is sent when the Mac is back.
- The Mac rewraps the stream into a normal `.mov` (passthrough) and files it.
- Gestures use Vision hand‑pose detection on the camera frames (~10 checks/s).

## Building

```sh
brew install xcodegen
xcodegen generate
open AutoKam.xcodeproj
```

Pick an iPhone to run the camera, or "My Mac" to run the receiver. Code is in `AutoKam/`
(`Shared/`, `iOS/`, `macOS/`).

## TestFlight

`.github/workflows/ios-testflight.yml` archives and uploads. Put `*u` in a commit
subject on `main` to upload, `*b` to archive only, or run it by hand from Actions. Signing uses
Xcode cloud signing and never revokes certificates. The iOS build uploads first, then the macOS
build of the same version. For the Mac build, the app record in App Store Connect needs the
**macOS platform** added once (the app → Add Platform → macOS).

`.github/workflows/build-check.yml` compiles both platforms (unsigned) on every branch push.
