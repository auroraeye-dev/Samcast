# Samcast — website copy

The text for samcast's site, kept here so the claims on the page and the
claims in the code can be checked against each other. Every figure below
comes from a measurement or a test, not an estimate.

**Before editing, re-check these against reality:**

| Claim on the page | Where it comes from |
|---|---|
| 93 checks | `swift run CoreCheck` |
| 21 landmarks | `HandJoint` in SamcastCore |
| 15 fps · 1600 px | `capture size` / `stream` lines in `~/Library/Logs/Samcast.log` |
| 20–130 KB/s, 1–9 KB frames | Same log, measured to a real iPad |
| 31 meeting cases | `docs/meeting-vectors.json` |
| Current version | `gh release view --json tagName` |

---

## Hero

**Mac → iPad → iPhone → Mac. Working today.**

### A tab closes here. It opens there.

Close your hand at your Mac and the page you're on lands on the other device
as a real link — full resolution, their browser, their accounts. Nothing is
streamed and nothing is screenshotted.

Any other window travels too, mirrored live as a view they can watch but not
touch.

*macOS 13 or later · Free · Both devices on the same Wi-Fi · No accounts, no
server*

---

## 01 — Three gestures

**Your camera is already pointed at you. Use it.**

Samcast counts how many fingers are extended — the one thing hand tracking
reports reliably. The thumb is left out, because its position tells you how
the hand is rotated rather than whether it is open. The count runs to four.

- **✊ Close your hand — hand it over.** In a browser, the tab closes here and
  waits to be caught, returning after 20 seconds if nobody does. Any other
  window starts mirroring instead.
- **🖐️ Open your hand — catch it.** At the device you want it on. Catching is
  always deliberate; nobody can push a screen onto you.
- **✌️ Peace sign — screenshot,** saved to your Desktop. Needs Screen
  Recording; links work without it.

While a page is held, gestures are ignored — you are walking to another
device, and stray hands on the way used to cancel the handoff.

---

## 02 — The handoff

You close your hand. The tab closes here immediately and goes up for grabs.
They open theirs. A direct, encrypted link forms, with no server in the path.
It opens on theirs — a real link in their browser, which comes to the front.

**Send the page, not a picture of the page.** When the front-most app is a
browser, Samcast hands over the link. Safari, Chrome, Edge, Brave, Arc,
Vivaldi.

**Any app can travel, not just a link.** Figma, Xcode, a spreadsheet, a
terminal — mirrored as a live view. They watch, they cannot touch. It is
mirroring, not remote access. 15 fps at 1600 px, 20–130 KB/s, 1–9 KB per
H.264 frame.

---

## 03 — Devices

| | |
|---|---|
| **Mac** | Sends and receives · links verified both ways |
| **iPad** | Receives links and live windows · sends links back |
| **iPhone** | Receives links · verified on an iPhone 17 and 17 Pro |
| **Windows** | Finds and connects to a Mac · handoff still untested |

---

## 04 — Status

What is verified, what is measured, what is guesswork. Nothing rounded up.

| Claim | Status | Measured |
|---|---|---|
| Mac → Mac, link handoff both directions | Verified | — |
| Mac → iPad, browser tab moves as a link | Verified | — |
| Mac → iPad, any window mirrored live | Verified | 15 fps · 1600 px |
| Bandwidth while mirroring | Measured | 20–130 KB/s |
| Frame size, H.264 | Measured | 1–9 KB |
| iPad → Mac, links via clipboard | Verified | — |
| iPhone receives links | Verified | iPhone 17, 17 Pro |
| Windows finds and connects to a Mac | Verified | on a real PC |
| Hand landmarks read on-device | True | 21 |
| Servers in the path | True | 0 |
| Core test suite | Passing | 93 checks |
| Mac → Mac, live window | Untested | — |
| Windows link handoff | Untested | — |
| Windows camera and gestures | Untested | — |

---

## 05 — Guardrails

**A gesture is a fast way to do something. So it has to be a hard way to do
it by accident.**

- **It asks before handing over a live call.** Google Meet, Zoom, Teams or
  Webex. In a panel over your browser, not buried in the app. Doing nothing
  means no. 31 tested cases, including the ones that must *not* prompt — a
  prompt people learn to dismiss unread protects nobody.
- **Trust is a decision you can change.** A new device asks once. Allow it
  and you are never asked again; decline and it is blocked, reversibly. Every
  device you have decided about is listed with a button to change your mind.
- **Nothing gets lost.** An uncaught handoff returns after 20 seconds, and
  Samcast refuses to grab at all with no device nearby to send to.

---

## 06 — Why it is built this way

- **Bonjour, not the cloud.** The same mechanism AirDrop and printers use. No
  internet, no accounts, no server. Both devices must share a Wi-Fi network.
  There is no Bluetooth in this app, despite what the gesture suggests.
- **Your device name stays yours.** Each install invents its own permanent
  name — `vivid-vole-4997` — and announces that instead.
- **A tested core, not a demo.** A pure Swift core with no platform
  dependencies, covered by 93 passing checks.

---

## 07 — Security

- **The camera feed never leaves your Mac.** Frames are analysed in memory and
  discarded. What travels is the outcome: "a hand with four fingers extended
  was seen."
- **It goes to one device, after two deliberate acts** — a gesture to offer, a
  gesture to catch, on a device you approved beforehand.
- **Traffic between Apple devices is encrypted;** macOS refuses an unencrypted
  session. **The Windows bridge is not** — a lab tool, not a private channel.
- **No accounts, no telemetry, no analytics, no cookies.**

Permissions: **Camera** (required), **Screen Recording** (optional — only
mirroring and screenshots), **Local Network**, **Automation** (per browser,
to read and close the front tab).

Link handoff needs Apple Events, so the app runs outside the App Sandbox.
That is a real trade-off with no way around it. The build is signed but not
notarized, so macOS warns on first open. The source is public so none of this
has to be taken on trust.

---

## 08 — Get it

**The Mac is a download. iPad and iPhone are not** — Apple provides no way to
install an iOS app from a website. That is the platform, not a gap in the
work.

- **Mac** — a `.dmg`; right-click ▸ Open ▸ Open on first launch.
- **iPad and iPhone** — build with Xcode (free account: expires after seven
  days) or TestFlight (needs the $99/yr Developer Program, which also removes
  the Gatekeeper warning).
- **Windows** — experimental. Run `python doctor.py` first.

---

## 09 — The honest bit

Built for fun, on coffee, in a handful of hours. No company, no roadmap
meeting, no paid tier waiting in the wings. Free, and it stays free.

If it saved you a cable or a "can you see my screen?", you can buy me a
coffee. Entirely optional, genuinely appreciated.

---

## 10 — Terms, such as they are

**It is free and MIT licensed.** Do what you like with it — use it, fork it,
sell a t-shirt with a duck on it. Keep my name in the licence file and we are
square.

**It comes with no warranty whatsoever.** That is not me being cagey, it is
literally what MIT says, in capital letters. If Samcast closes a tab you
wanted, mirrors your screen to your flatmate mid-argument, or waves at your
cat and hands your dissertation to a printer, that is between you and
physics. I will feel bad about it. I will not be liable for it.

**Things I would rather you did not do, but cannot stop:** running it on a
network you do not control, using the Windows bridge for anything private
(it is not encrypted and I have now said so four times), or pointing the
camera at something you would not want a hand-detection model looking at. It
does not record anything. It still has a camera.

**Things I genuinely cannot help with:** Apple's Gatekeeper warning, the
seven-day expiry on free iOS builds, and Windows Firewall. Three different
companies' decisions, over which I have exactly as much influence as you do.

**No data, no accounts, no analytics, no cookies, nothing to delete.** There
is no privacy policy because there is no privacy to have a policy about. The
app never phones home. This site does not know you were here.

**If something breaks,** open an issue. I will probably fix it, because I use
this thing every day and it annoys me too.
