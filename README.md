# QuackCast

Control screen-sharing between your nearby devices with **hand gestures** — no
clicking, no menus.

- ✊ **Close your hand** at your Mac's camera → it captures your screen and
  offers it to nearby devices ("arm as source").
- 🖐️ **Open your hand** at another device's camera → your screen is cast to
  *that* device.
- ✌️ **Peace sign** → take a screenshot (saved to ~/Pictures).

Devices find each other automatically over Apple's peer-to-peer Wi-Fi (the same
mechanism AirDrop uses), with Bluetooth assisting discovery. Only devices also
running QuackCast appear. No network setup, no pairing, no internet.

## Install

### Build from source (recommended, no warnings)
macOS only attaches its quarantine flag to *downloaded* files, so an app you
build yourself opens with **no Gatekeeper warning at all**:

```bash
git clone https://github.com/auroraeye-dev/QuackCast.git
cd QuackCast
brew install xcodegen          # one-time
./scripts/package.sh --run     # builds, installs to /Applications, launches
```
Requires Xcode (from the App Store).

### Or download a release
Grab **QuackCast.dmg** from the
[Releases page](https://github.com/auroraeye-dev/QuackCast/releases), open it and
drag QuackCast to Applications.

> Downloaded builds are **not notarized**, so macOS will warn the first time.
> Either **right-click the app ▸ Open ▸ Open**, or clear the quarantine flag:
> ```bash
> xattr -dr com.apple.quarantine /Applications/QuackCast.app
> ```
> Notarization (which removes the warning entirely) requires a paid Apple
> Developer Program membership; see *Signing* below.

### First run
QuackCast asks for **Camera** (to read gestures) and **Screen Recording** (to
share the screen and take screenshots). The app's setup screen links straight to
the right System Settings pane. macOS requires a relaunch after granting Screen
Recording — there's a button for it.

## Signing

| Goal | Identity | Cost |
|---|---|---|
| Run locally, permissions persist across rebuilds | Apple Development (free Apple ID) | Free |
| Downloads open with no Gatekeeper warning | Developer ID + notarization | $99/yr |

The project pins a stable signing identity in `project.yml`. This matters more
than it sounds: macOS ties privacy permissions to an app's signature, so an
ad-hoc signed app (whose signature changes every build) makes users re-grant
Screen Recording after every update.

To produce a notarized build once you have a Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=quackcast ./scripts/package.sh
```


## Platforms

| Platform | Status | Stack |
|---|---|---|
| macOS | 🚧 in progress | SwiftUI · Vision · AVFoundation · ScreenCaptureKit · MultipeerConnectivity |
| iOS (iPhone/iPad as receivers) | planned | shares `QuackCastCore` |
| Windows | planned, **separate native build** | reimplements the `Ports` protocols |

The Mac and Windows apps are built and shipped separately (two downloads on the
site) — this repo currently holds the macOS app plus the shared core.

## Architecture

Hexagonal / ports-and-adapters so the "brain" stays portable:

```
QuackCastCore  (pure Swift, Foundation-only — no Apple UI/media frameworks)
├── Gesture/     HandLandmarks, GestureClassifier (geometry), GestureDebouncer
├── Session/     SessionCoordinator — the state machine (idle→armed→casting/receiving)
└── Ports/       HandTracker · ScreenSource · PeerTransport protocols

Platform adapters (macOS):
    VisionHandTracker · ScreenCaptureKitSource · MultipeerTransport
```

`QuackCastCore` has **zero platform imports**, is fully unit-tested, and is
what a future Windows port reuses — that port only reimplements the three
`Ports` protocols.

## Building & testing

The portable core builds and its logic runs on any Swift toolchain — **you do
not need full Xcode** for this part:

```bash
swift run CoreCheck   # dependency-free smoke test (works with Command Line Tools)
swift test            # full XCTest suite (requires Xcode)
swift run CastPeer    # headless receiver: test casting without a second device
```

The macOS **app** requires **full Xcode** (from the App Store) — Command Line
Tools alone cannot build a signed app bundle with camera/screen entitlements.

`CastPeer` is worth knowing about: it joins the same Multipeer service as the
app and reports the frame rate and bandwidth actually achieved, so the cast
pipeline can be tested and measured on one machine. It is how the connection
flapping bug was found.

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds and
attaches the DMG/zip to a GitHub Release automatically.

## Notes

- **Gestures** are separated by extended-finger count, the most reliable thing
  hand tracking reports: fist (0) shares, peace sign (2) screenshots, open palm
  (4) casts. Earlier designs using a finger snap (audio) and a two-handed "T"
  were dropped — any sharp noise imitated a snap, and hand tracking degrades
  badly when two hands overlap.
- **Casting is mirroring, not an extended display**, and currently sends JPEG
  frames (~100 KB each). Moving to H.264 is the main outstanding work: it would
  cut bandwidth roughly 10× and sharpen text.
