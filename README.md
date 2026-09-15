<div align="center">

# 🦆 QuackCast

### Move what you're working on to another device — with a wave of your hand.

<img src="docs/hero.svg" width="840" alt="A page is grabbed from a Mac with a closed hand, travels, and lands on an iPad with an open hand">

![Platform](https://img.shields.io/badge/macOS-13%2B-1f6feb?style=flat-square&logo=apple&logoColor=white)
![Platform](https://img.shields.io/badge/iPadOS-16%2B-1f6feb?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-f05138?style=flat-square&logo=swift&logoColor=white)
![Tests](https://img.shields.io/badge/core%20tests-75%20passing-2da44e?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-8250df?style=flat-square)

</div>

---

## The gestures

| | Gesture | What happens |
|:--:|---|---|
| ✊ | **Close your hand** | Grabs the page — or window — you're looking at |
| 🖐️ | **Open your hand** *at another device* | It lands **there** |
| ✌️ | **Peace sign** | Screenshot, saved to your Desktop |

No clicking, no menus, no picking a device from a list. **The device you walk
up to is the one that receives it** — because it's the one that can see your hand.

### Except when it would cost you something

Hand tracking is never perfect — a hand closing around a mug looks a lot like
a deliberate fist. On an ordinary page a misread costs you a reopened tab. On
a **live Google Meet, Zoom, Teams or Webex call** it drops you out of the
meeting in front of everyone.

So those get asked about first, in a prompt over whatever app you're actually
looking at:

> **Move this Google Meet to another device?**
> Google Meet · abc-defg-hij will close on this Mac, and you'll leave the call here.
> `Stay here` `Move the call`

Nothing is closed, announced or timed until you answer — and **doing nothing
means no**, because someone who didn't mean to make that gesture won't reach
for a button. Moving a call to another device is a perfectly good thing to
want, so it's never blocked; it just has to be meant.

The rule lives in `QuackCastCore` and is shared by the Mac, iOS and Windows
builds, with `docs/meeting-vectors.json` pinning all three to the same answer
— including the negative cases. A prompt people learn to dismiss unread
protects nobody, so `meet.google.com` on its own, Zoom's pricing page and the
like must stay silent, and there are tests for each.

---

## A link doesn't get streamed. It *moves*.

This is the part that makes QuackCast different from screen sharing:

```mermaid
sequenceDiagram
    participant M as 💻 Mac
    participant P as 📱 iPad
    M->>M: ✊ the tab closes here
    M-->>P: offers the page
    Note over P: 🖐️ open your hand
    P->>M: I'll take it
    M->>P: the URL itself — a few bytes
    Note over P: the real page opens,<br/>fully usable, other tabs untouched
```

Grab a web page and **the tab closes on your Mac**. Open your hand at your
iPad and the *actual page* opens in its browser — instantly, at full fidelity,
scrollable and clickable, leaving its other tabs alone.

**Apps can't move like that.** A running process can't leave its machine, so a
non-browser window is sent as a **live picture** instead, while the app keeps
running on the original device. QuackCast picks the right mechanism for you.

---

## Get it

| Platform | How | State |
|---|---|---|
| **macOS 13+** | [Download the `.dmg`](https://github.com/auroraeye-dev/QuackCast/releases/latest) | Sends and receives |
| **iPadOS / iOS 16+** | Build from source — **Apple allows no download** | Receives; sends links |
| **Windows 10+** | [Source zip](https://github.com/auroraeye-dev/QuackCast/releases/latest) | Experimental, never run on Windows |

### macOS

Open the `.dmg` and drag QuackCast to Applications. It is signed but **not
notarized** — that needs a paid Apple Developer membership — so macOS warns
on first open: **right-click ▸ Open ▸ Open**.

Building from source skips the warning entirely, because macOS only
quarantines apps that were downloaded:

```bash
git clone https://github.com/auroraeye-dev/QuackCast.git
cd QuackCast
brew install xcodegen           # one-time
./scripts/package.sh --run      # build, install to /Applications, launch
```

Requires Xcode from the App Store.

### iPad and iPhone

**There is no download, and there cannot be one.** Apple provides no way to
install an iOS app from a website or a release page — an `.ipa` file here
would be inert. The only routes are the App Store or TestFlight, both of
which require the paid Apple Developer Program, or building it yourself:

```bash
brew install xcodegen && xcodegen generate
open QuackCast.xcodeproj        # QuackCastiOS scheme, pick your device
```

With a free Apple account the app stops working after 7 days and has to be
rebuilt. The build is universal, so the same one runs on iPhone and iPad.

### Windows

Experimental, and the honest state is in
[the bridge repo](../QuackCast-Bridge): the protocol underneath is tested,
but the Windows-only parts have only ever been compiled, never run on
Windows. It also cannot talk to the macOS **app** — only to the headless
`BridgeCLI`, because the app speaks Apple-only MultipeerConnectivity.

### First run

QuackCast asks for **Camera** (to read gestures) and **Screen Recording** (to
grab windows and take screenshots). Its setup screen links straight to the
right System Settings pane, and offers a relaunch — macOS requires one after
granting Screen Recording.

## Devices and trust

Every install picks a permanent, friendly name like `swift-heron-3172` and is
discovered by that, rather than an OS device name that can change or collide.

> **Trust decides *whether* a device may hand you things. Your hand decides
> *where* they go.** A device is approved once, with a button, the first time
> it offers you something. After that it's remembered and your open hand is
> enough — but taking something *always* needs the gesture at the destination.

Devices find each other over Apple's peer-to-peer Wi-Fi — the same mechanism
AirDrop uses, with Bluetooth assisting discovery. No network setup, no pairing,
no internet, and nothing leaves your local network.

---

## Platforms

| Platform | Status | Notes |
|---|---|---|
| **macOS 13+** | ✅ Sends and receives | Grabs the page you're in, or streams the focused window |
| **iPadOS / iOS 16+** | ✅ Receives · ⚠️ sends deliberately | See below |
| **Windows** | 🔭 Planned, separate build | MultipeerConnectivity is Apple-only |

<details>
<summary><b>⚠️ Why the iPad is a better receiver than a sender</b></summary>

<br>

Two iOS rules shape this, and neither can be engineered around:

- **No background operation.** iOS suspends a backgrounded app's camera and
  networking, so QuackCast must be open and in front on the iPad to take part
  at all. macOS has no such rule, which is why a Mac can sit idle and still
  participate. The app holds the iPad awake while it's in front, so auto-lock
  can't quietly end a session.
- **No reading another app's content.** There's no AppleScript on iOS, so the
  app can't read Safari's open tab. A link leaves an iPad via the clipboard
  (copy it, then make a fist) or handed in through `quackcast://send?url=…`,
  which a Shortcut or share action can use.

No iOS app can launch itself on unlock or boot. The nearest equivalent is a
Shortcuts personal automation — *when joining your home Wi-Fi → open
QuackCast* — which on iPadOS 17+ can run without a prompt.

</details>

---

## Architecture

Ports and adapters, so the decision-making stays portable and testable:

```
QuackCastCore ······ pure Swift, Foundation only, zero platform imports
├── Gesture/ ······· HandLandmarks · GestureClassifier · GestureDebouncer
├── Session/ ······· SessionCoordinator · DeviceIdentity · TrustStore
└── Ports/ ········· HandTracker · ScreenSource · PeerTransport

Adapters ·········· VisionHandTracker · ScreenCaptureKitSource (macOS)
                    MultipeerTransport · BrowserLink (macOS)
```

`QuackCastCore` holds the gesture maths and the session state machine with no
Apple frameworks attached, so it runs on any Swift toolchain — and a future
Windows port would reimplement only the three `Ports` protocols.

## Building & testing

```bash
swift run CoreCheck   # smoke test — works with Command Line Tools alone
swift test            # full XCTest suite (needs Xcode)
swift run CastPeer    # a second peer, so casting is testable on one Mac
```

`CastPeer` is worth knowing about: it joins the same service as the app, shows
the incoming window live, and reports the frame rate and bandwidth actually
achieved. It's how the connection-flapping bug was found.

Pushing a `vX.Y.Z` tag runs [`release.yml`](.github/workflows/release.yml),
which builds a universal app and attaches the DMG and zip to a GitHub Release.

<details>
<summary><b>Design notes — the non-obvious decisions</b></summary>

<br>

- **Gestures are separated by extended-finger count**, the most reliable thing
  hand tracking reports: fist (0) grabs, peace (2) screenshots, open palm (4)
  receives. Earlier designs using a finger snap and a two-handed "T" were
  dropped — any sharp noise imitated a snap, and hand tracking degrades badly
  when two hands overlap.
- **The app is not sandboxed.** Reading the frontmost browser tab needs Apple
  Events, which the sandbox blocks for directly distributed apps. macOS still
  gates Camera, Screen Recording and Automation individually. Hardened Runtime
  *additionally* requires `com.apple.security.automation.apple-events` —
  without it Apple Events fail silently, with no permission prompt at all.
- **A stable signing identity is pinned in `project.yml`.** macOS ties privacy
  permissions to an app's signature, so an ad-hoc signed app (whose signature
  changes every build) forces users to re-grant Screen Recording after every
  update.
- **Streaming is mirroring, not an extended display** — a third-party app
  cannot become a real external display. Frames are JPEG at 1600px/10fps,
  and ScreenCaptureKit's `.idle` frames are skipped, so a window nobody is
  touching costs ~20 KB/s instead of 1.5 MB/s. That saving is what pays for
  the resolution. H.264 remains the main outstanding work: roughly 10× less
  bandwidth again, and sharper text while moving.

</details>

---

<div align="center">
<sub>MIT licensed · built with Swift, Vision, ScreenCaptureKit and MultipeerConnectivity</sub>
</div>
