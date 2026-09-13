# GestureCast

Control screen-sharing between your nearby devices with **hand gestures** — no
clicking, no menus.

- ✊ **Close your hand** at your Mac's camera → it captures your screen and
  offers it to nearby devices ("arm as source").
- 🖐️ **Open your hand** at another device's camera → your screen is cast to
  *that* device.
- 🫰 **Snap** → take a screenshot of the current page. *(best-effort; see notes)*

Devices find each other automatically over Bluetooth + peer-to-peer Wi-Fi — only
devices that also run GestureCast appear, which is exactly the "my nearby
devices that have the app" behaviour the product is going for.

> **Scope note — mirroring, not a true extended display.** The cast screen
> appears *inside the GestureCast window* on the target device (like a shared
> screen). Becoming a real macOS extended desktop (à la Sidecar) is only
> possible for Apple / low-level display drivers, not third-party apps, so that
> is explicitly out of scope for v1.

## Platforms

| Platform | Status | Stack |
|---|---|---|
| macOS | 🚧 in progress | SwiftUI · Vision · AVFoundation · ScreenCaptureKit · MultipeerConnectivity |
| iOS (iPhone/iPad as receivers) | planned | shares `GestureCastCore` |
| Windows | planned, **separate native build** | reimplements the `Ports` protocols |

The Mac and Windows apps are built and shipped separately (two downloads on the
site) — this repo currently holds the macOS app plus the shared core.

## Architecture

Hexagonal / ports-and-adapters so the "brain" stays portable:

```
GestureCastCore  (pure Swift, Foundation-only — no Apple UI/media frameworks)
├── Gesture/     HandLandmarks, GestureClassifier (geometry), GestureDebouncer
├── Session/     SessionCoordinator — the state machine (idle→armed→casting/receiving)
└── Ports/       HandTracker · ScreenSource · PeerTransport protocols

Platform adapters (macOS app, added next):
    VisionHandTracker · ScreenCaptureKitSource · MultipeerTransport · CameraController
```

`GestureCastCore` has **zero platform imports**, is fully unit-tested, and is
what a future Windows port reuses — that port only reimplements the three
`Ports` protocols.

## Building & testing

The portable core builds and its logic runs on any Swift toolchain — **you do
not need full Xcode** for this part:

```bash
swift run CoreCheck   # dependency-free smoke test (works with Command Line Tools)
swift test            # full XCTest suite (requires Xcode)
```

The macOS **app** requires **full Xcode** (from the App Store) — Command Line
Tools alone cannot build a signed app bundle with camera/screen entitlements.

## Notes

- **Snap detection** from hand pose alone is unreliable (a snap is a fast
  transient, better sensed via audio). The pinch/snap heuristics are marked
  best-effort; an audio-based detector is a likely follow-up.
