# QuackCast

Move what you're working on to another device with a **hand gesture**.

- ✊ **Close your hand** → grab the page (or window) you're in
- 🖐️ **Open your hand at another device** → it lands there
- ✌️ **Peace sign** → screenshot to your Desktop

**A link doesn't get streamed, it moves.** Grab a web page and the tab closes
on your Mac; open your hand at your iPad and the *real page* opens in its
browser — instantly, at full fidelity, fully usable, leaving their other tabs
alone. Anything that isn't a web page falls back to live-streaming that one
window.

Devices find each other automatically over Apple's peer-to-peer Wi-Fi (the same
mechanism AirDrop uses), with Bluetooth assisting discovery. Only devices also
running QuackCast appear. No network setup, no pairing, no internet, nothing
leaves your local network.

### Devices and trust
Each install picks a permanent friendly name such as `swift-heron-3172` and is
discovered by that, rather than by an OS device name that can change or
collide. The first time you accept something from a device it becomes trusted,
and after that its offers are taken automatically — unknown devices always
require a deliberate gesture.

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

| Platform | Status | Notes |
|---|---|---|
| macOS | working | Grabs the page you're in, or streams the focused window |
| iOS / iPadOS | working | Receives anything; sends links via the clipboard |
| Windows | planned, **separate build** | Would reimplement the `Ports` protocols |

**iOS can send too, but only via the clipboard.** There is no AppleScript on
iOS, so an app cannot read Safari's open tab the way it can on macOS — copy the
link, then make a fist. A Share Extension would remove that step.

**Windows can't join this network.** MultipeerConnectivity is Apple-only, so a
Windows build would be its own island unless the transport is replaced with
something cross-platform (mDNS + WebRTC/QUIC).

## Architecture

Hexagonal / ports-and-adapters so the "brain" stays portable:

```
QuackCastCore  (pure Swift, Foundation-only — no Apple UI/media frameworks)
├── Gesture/     HandLandmarks, GestureClassifier (geometry), GestureDebouncer
├── Session/     SessionCoordinator (state machine), DeviceIdentity, TrustStore
└── Ports/       HandTracker · ScreenSource · PeerTransport protocols

Platform adapters:
    VisionHandTracker · ScreenCaptureKitSource (macOS) · MultipeerTransport
    BrowserLink (reads/closes the frontmost browser tab, macOS)
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
  hand tracking reports: fist (0) grabs, peace sign (2) screenshots, open palm
  (4) receives. Earlier designs using a finger snap (audio) and a two-handed
  "T" were dropped — any sharp noise imitated a snap, and hand tracking
  degrades badly when two hands overlap.
- **The app is not sandboxed.** Reading the frontmost browser tab needs Apple
  Events, which the sandbox blocks for directly-distributed apps. macOS still
  gates Camera, Screen Recording and Automation individually. Hardened Runtime
  additionally requires `com.apple.security.automation.apple-events`, without
  which Apple Events fail silently with no permission prompt at all.
- **Streaming is mirroring, not an extended display**, and still sends JPEG
  frames (~100 KB each). H.264 is the main outstanding work: roughly 10× less
  bandwidth and sharper text.
- **Testing without a second device:** `swift run CastPeer` opens a viewer
  window that joins as a separate peer on the same Mac.
