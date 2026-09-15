import Foundation
import SwiftUI
import CoreImage
import CoreVideo
import AppKit
import SamcastCore
import SamcastPlatform

/// The app-level integration layer: it owns the platform adapters and the
/// portable `SessionCoordinator`, feeds gestures + peer messages into the
/// coordinator, and carries out the `SessionEffect`s it returns by calling the
/// real frameworks. All published state is read by SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    // Portable brain.
    private var coordinator = SessionCoordinator()
    private let classifier = GestureClassifier()
    private var debouncer = GestureDebouncer(holdDuration: 0.3)

    // Platform adapters.
    let handTracker = VisionHandTracker()
    private let transport = MultipeerTransport(kind: .mac)
    private let screenSource = ScreenCaptureKitSource()
    private let ciContext = CIContext()

    /// Tracks macOS privacy permissions so the UI can guide setup.
    let permissions = Permissions()

    private let trust = TrustStore()
    /// Plays the glow over the whole screen, since the app window is usually
    /// behind whatever you are grabbing from.
    private let glowOverlay = GlowOverlay()
    /// This device's persistent Samcast name — how other devices see it.
    let identity = DeviceIdentity.loadOrCreate(kind: .mac)

    // Where captured frames are currently being streamed (if casting).
    private var streamingTarget: Peer?
    /// Ignore open/close gestures until this time, just after a screenshot, so
    /// hands returning to rest can't accidentally arm a cast.
    private var gestureSuppressUntil = Date.distantPast
    /// When the current grab was made. A second fist cancels a grab, but hand
    /// tracking flickers closed→none→closed, and that re-fire would cancel the
    /// grab a moment after making it — putting the page straight back on this
    /// machine. Cancelling is therefore only allowed after a deliberate pause.
    private var armedAt = Date.distantPast
    private let cancelGuard: TimeInterval = 5

    // MARK: Gesture timing
    /// When a hand was last seen, used to keep the indicator steady across
    /// dropped tracking frames.
    private var lastHandSeen = Date.distantPast
    /// Screenshots are rate limited so one held gesture fires once.
    private var lastScreenshotAt = Date.distantPast
    private let screenshotCooldown: TimeInterval = 1.0

    // MARK: Published UI state
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var currentGesture: HandGesture = .none
    /// Live: is the camera seeing a real hand right now? Shown in the UI so the
    /// gating is visible rather than a black box.
    @Published private(set) var handDetected: Bool = false
    /// Live readout of which fingers the camera sees extended, so gesture
    /// recognition is observable instead of a black box.
    @Published private(set) var fingerReadout: String = "—" 
    @Published private(set) var receivedImage: NSImage?
    @Published private(set) var lastScreenshot: URL?
    @Published private(set) var statusLine: String = "Starting…"
    /// What is currently being cast, e.g. "Safari — Example Page".
    @Published private(set) var castTarget: String = ""
    /// Devices already accepted from; their offers are taken automatically.
    @Published private(set) var trustedNames: [String] = []
    /// Bumped to play the glow; direction says whether something left or
    /// arrived, so the animation reads correctly without any text.
    @Published private(set) var glowTrigger = 0
    @Published private(set) var glowDirection: GlowDirection = .outward

    /// A page grabbed by the fist gesture, waiting to be dropped on another
    /// device. When set, arming hands this over instead of streaming pixels.
    private var pendingHandoff: BrowserLink.Page?

    /// Asks before handing over something that would hurt to lose — a live
    /// meeting, above all. Shown over whatever app is in front, because that
    /// is where the user is looking when they make the gesture.
    private let confirmOverlay = ConfirmOverlay()

    /// Important messages (why a handoff failed, where a screenshot went) must
    /// survive the routine status refresh that follows every effect, otherwise
    /// they are overwritten before they can be read.
    private var statusHoldUntil = Date.distantPast
    private var reannounceTask: Task<Void, Never>?
    /// Only the newest grab may be undone by a timeout. Previously each grab
    /// left its own timer running, so an old timer could fire and put back a
    /// page grabbed much later — seconds after grabbing it, rather than the
    /// two minutes intended.
    private var recoveryTask: Task<Void, Never>?

    func start() {
        QCLog.write("=== Samcast started as \(identity.name) ===")
        transport.delegate = self
        transport.start()

        handTracker.onHands = { [weak self] hands, time in
            guard let self else { return }
            // A low-quality detection must not drive a gesture: at launch a
            // phantom "fist" armed a handoff with no input from the user.
            let hand = hands.first
            let raw = self.isRealHand(hand) ? (hand.map { self.classifier.classify($0) } ?? .none) : .none
            let fingers = hands.first.map { self.classifier.extendedFingers($0) }
            Task { @MainActor in
                self.updateFingerReadout(fingers)
                self.handleFrame(hands, raw: raw, at: time)
            }
        }
        do { try handTracker.start() } catch { statusLine = "Camera error: \(error)" }


        screenSource.onCaptureTarget = { [weak self] label in
            // Which window was chosen is the first thing you need when a
            // stream produces nothing, and it was only ever shown in the UI.
            QCLog.write("capture target: \(label)")
            self?.castTarget = label
        }

        screenSource.onCaptureSize = { width, height in
            QCLog.write("capture size: \(width)×\(height) px")
        }

        screenSource.onCaptureError = { [weak self] message, isPermissionIssue in
            guard let self else { return }
            QCLog.write("CAPTURE ERROR\(isPermissionIssue ? " (permission)" : ""): \(message)")
            self.setStatus(message, hold: 12)
            // Only a genuine permission failure should send the user to
            // System Settings. "Nothing to cast" is not a permission problem,
            // and saying it is wastes their time on the wrong fix.
            if isPermissionIssue {
                self.permissions.screenRecordingFailed = true
                self.permissions.refresh()
            }
        }

        // Network faults used to print to stdout, which is nowhere for an
        // app launched from Finder. Send them to the log the user can tail.
        MultipeerTransport.log = { QCLog.write($0) }

        encoder.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            let packet = VideoPacket.h264(frame.data, isKeyframe: frame.isKeyframe,
                                          sps: frame.sps, pps: frame.pps)
            Task { @MainActor in
                guard let target = self.streamingTarget else { return }
                self.deliver(packet, bytes: packet.count, to: target)
            }
        }
        encoder.onError = { message in QCLog.write("h264: \(message)") }

        screenSource.onFrame = { [weak self] frame, _ in
            guard let self else { return }
            // `frame` is an opaque CVPixelBuffer (a CoreFoundation type, so a
            // plain `as?` always "succeeds" — check the CF type id instead).
            guard CFGetTypeID(frame as CFTypeRef) == CVPixelBufferGetTypeID() else { return }
            self.forwardFrame(frame as! CVPixelBuffer)
        }

        trustedNames = Array(trust.trusted.values).sorted()
        updateStatus()
    }

    // MARK: Gesture pipeline

    /// A detection only counts as a real hand if it's confident, has most of
    /// its 21 joints, and is big enough in frame — this filters out the
    /// low-quality phantom detections that were letting plain sounds through.
    /// Forgiving on purpose — hand tracking drops frames, and treating every
    /// miss as "no hand" makes the indicator flicker and resets gesture timing.
    private func isRealHand(_ hand: HandLandmarks?) -> Bool {
        guard let hand else { return false }
        guard hand.confidence >= 0.5 else { return false }
        guard hand.points.count >= 10 else { return false }
        guard let span = hand.palmSpan, span >= 0.03 else { return false }
        return true
    }

    private func handleFrame(_ hands: [HandLandmarks], raw: HandGesture, at time: TimeInterval) {
        // Is a real hand on camera right now?
        if isRealHand(hands.first) { lastHandSeen = Date() }
        // Bridge dropped frames so the badge is steady rather than strobing.
        let present = Date().timeIntervalSince(lastHandSeen) < 0.5
        if handDetected != present { handDetected = present }

        // Briefly after a screenshot, ignore open/close so a hand returning to
        // rest can't arm a cast.
        if Date() < gestureSuppressUntil {
            debouncer.reset()
            return
        }
        if let confirmed = debouncer.update(raw, at: time) {
            QCLog.write("gesture \(confirmed.rawValue) | state=\(coordinator.state) | pending=\(pendingHandoff?.url.absoluteString ?? "none")")
            currentGesture = confirmed

            // Once a page is grabbed and waiting to be dropped, this camera
            // stops deciding anything. You are walking to another device and
            // gesturing at *that* one; hands this camera happens to catch on
            // the way were cancelling the grab before it could be delivered.
            if pendingHandoff != nil {
                QCLog.write("ignored \(confirmed.rawValue): holding a grabbed page")
                return
            }
            // A question is already on screen. Answer it with the buttons —
            // waving again must not stack a second prompt behind the first.
            if confirmOverlay.isAsking {
                QCLog.write("ignored \(confirmed.rawValue): awaiting confirmation")
                return
            }
            if confirmed == .peace {
                fireScreenshot()
                return
            }
            // Don't let a flickering fist cancel the grab it just made.
            if confirmed == .closedHand, coordinator.state == .armedSource,
               Date().timeIntervalSince(armedAt) < cancelGuard {
                QCLog.write("ignored repeat fist within cancel guard")
                return
            }
            // Nowhere to send it. Grabbing would close the tab and hold it
            // with nobody to hand it to, which looks exactly like the page
            // simply vanished — the worst failure this app can have.
            if confirmed == .closedHand, coordinator.state == .idle,
               transport.connectedPeers.isEmpty {
                QCLog.write("refused grab: no devices nearby")
                setStatus("No devices nearby — open Samcast on the other device first", hold: 5)
                return
            }
            let wasIdle = coordinator.state == .idle
            apply(coordinator.reduce(.localGesture(confirmed)))
            if wasIdle, coordinator.state == .armedSource { armedAt = Date() }
        }
    }

    /// Readable summary of the extended fingers, e.g. "index+middle (2)".
    private func updateFingerReadout(_ fingers: GestureClassifier.ExtendedFingers?) {
        guard let f = fingers else {
            if fingerReadout != "—" { fingerReadout = "—" }
            return
        }
        var names: [String] = []
        if f.index { names.append("index") }
        if f.middle { names.append("middle") }
        if f.ring { names.append("ring") }
        if f.little { names.append("little") }
        let text = names.isEmpty ? "none (0)" : "\(names.joined(separator: "+")) (\(f.count))"
        if fingerReadout != text { fingerReadout = text }
    }

    /// The peace sign was held: take a screenshot.
    private func fireScreenshot() {
        let now = Date()
        guard now.timeIntervalSince(lastScreenshotAt) > screenshotCooldown else { return }
        lastScreenshotAt = now
        // Ignore open/close for 2s so hands returning to rest can't arm a cast.
        gestureSuppressUntil = now.addingTimeInterval(2.0)
        debouncer.reset()
        currentGesture = .peace
        apply(coordinator.reduce(.localGesture(.peace)))
        NSSound(named: "Tink")?.play() // audible confirmation
    }

    /// Re-announce a held page every couple of seconds.
    ///
    /// The offer is otherwise sent once, so any device that reconnects (or
    /// whose session was still settling) never learns there is something to
    /// take, and opening your hand at it does nothing.
    private func startReannouncing() {
        reannounceTask?.cancel()
        reannounceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.pendingHandoff != nil else { return }
                self.broadcast(.sourceAvailable)
            }
        }
    }

    /// Restore a grabbed page if it is never dropped anywhere.
    private func scheduleHandoffRecovery(for page: BrowserLink.Page) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            // 20 seconds. Long enough to turn and raise a hand at the other
            // device; short enough that a handoff nobody catches reads as
            // "that didn't work" rather than "my page is gone".
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingHandoff,
                  pending.url == page.url else { return }
            self.reannounceTask?.cancel()
            QCLog.write("PUT BACK (timeout) \(pending.url.absoluteString)")
            BrowserLink.open(pending.url)
            self.pendingHandoff = nil
            // Leave the armed state too, so a later request doesn't find an
            // armed source with nothing behind it.
            if case .armedSource = self.coordinator.state {
                self.apply(self.coordinator.reduce(.localGesture(.closedHand)))
            }
            self.setStatus("Nobody took “\(pending.title)” — put it back")
            self.pulseGlow(.inward, message: "Put back — nobody took it")
        }
    }

    // MARK: Effect execution

    private func apply(_ effects: [SessionEffect]) {
        if !effects.isEmpty {
            QCLog.write("effects \(effects) | state before=\(coordinator.state)")
        }
        for effect in effects { perform(effect) }
        state = coordinator.state
        updateStatus()
    }

    /// Commit to the handoff: close the tab here, advertise it, and start the
    /// clock that puts it back if nobody takes it.
    ///
    /// Separated out so the confirmation prompt has something to call, and so
    /// there is exactly one place where a page actually gets closed.
    private func beginHandoff(_ page: BrowserLink.Page) {
        pendingHandoff = page
        startReannouncing()
        BrowserLink.closeFrontmostTab()
        // If no device takes it, put the page back rather than leaving the
        // user with a closed tab and nothing to show for it.
        scheduleHandoffRecovery(for: page)
        castTarget = "\(page.browserName) — \(page.title)"
        setStatus("Grabbed “\(page.title)” — now open your hand at the device you want it on")
        pulseGlow(.outward, message: "Grabbed — open your hand at another device")
    }

    /// A live meeting is on screen. Ask first.
    ///
    /// Handing a meeting over is a perfectly reasonable thing to want — it
    /// moves the call to another device — so this must not block it. It only
    /// insists the user meant it, because the cost of being wrong is being
    /// dropped from a call in front of other people.
    private func askBeforeHandingOver(_ page: BrowserLink.Page, meeting: MeetingMatch) {
        let named = meeting.code.map { "\(meeting.service) · \($0)" } ?? meeting.service
        setStatus("Waiting — confirm the \(meeting.service) handoff on screen")
        confirmOverlay.ask(
            title: "Move this \(meeting.service) to another device?",
            detail: "\(named) will close on this Mac, and you'll leave the call here. "
                  + "Open your hand at the other device to pick it up.",
            confirmTitle: "Move the call"
        ) { [weak self] confirmed in
            guard let self else { return }
            if confirmed {
                QCLog.write("CONFIRMED meeting handoff \(page.url.absoluteString)")
                self.beginHandoff(page)
            } else {
                // Nothing was closed, so there is nothing to undo — just go
                // back to idle and leave the user exactly where they were.
                QCLog.write("DECLINED meeting handoff — nothing was closed")
                self.setStatus("Left your \(meeting.service) alone", hold: 4)
                self.apply(self.coordinator.reduce(.localGesture(.closedHand)))
            }
        }
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .startScreenCapture:
            // Prefer handing the *content* over to streaming a picture of it.
            // A page travels as a URL: instant, pixel-perfect, and it opens in
            // the other person's own browser without touching their tabs.
            // Belt and braces: the gesture path already refuses this, but
            // nothing should ever close a tab with no peer to receive it.
            guard !transport.connectedPeers.isEmpty else {
                QCLog.write("refused grab in effect: no devices nearby")
                setStatus("No devices nearby — open Samcast on the other device first", hold: 5)
                DispatchQueue.main.async { [weak self] in
                    guard let self, case .armedSource = self.coordinator.state else { return }
                    self.apply(self.coordinator.reduce(.localGesture(.closedHand)))
                }
                return
            }
            do {
                let page = try BrowserLink.frontmostPage()
                QCLog.write("GRABBED \(page.url.absoluteString)")

                // Some pages cost far more than a reopened tab if the gesture
                // was misread. Ask before touching anything — nothing is
                // closed, advertised or timed until the question is answered.
                let risk = PageRiskDetector.assess(page.url.absoluteString)
                if case .liveMeeting(let meeting) = risk {
                    QCLog.write("CONFIRM needed: \(meeting.service)")
                    askBeforeHandingOver(page, meeting: meeting)
                    return
                }

                beginHandoff(page)
                return
            } catch BrowserLink.LinkError.frontAppNotABrowser(let app) {
                // Not a failure — this is the whole point of window sharing.
                // It used to report "front app is Freeform, not a supported
                // browser", which reads as a refusal for every app the
                // feature exists to handle. Only a browser can have its page
                // *moved*; everything else gets mirrored, and that is normal.
                QCLog.write("sharing window of \(app) (not a browser, so not a link)")
                setStatus("Sharing your \(app) window — open your hand at the device you want it on")
            } catch {
                // A real failure: the front app *is* a browser, so a link was
                // expected and something went wrong reading it. Worth saying,
                // because mirroring a browser instead is a worse outcome the
                // user did not ask for.
                QCLog.write("link handoff failed, mirroring instead: \(error.localizedDescription)")
                setStatus("Couldn't read the page (\(error.localizedDescription)) — sharing the window instead", hold: 12)
            }
            pendingHandoff = nil
            do {
                try screenSource.startCapture()
            } catch {
                statusLine = "Enable Screen Recording for Samcast in System Settings ▸ Privacy & Security, then relaunch."
            }
        case .stopScreenCapture:
            // Cancelled before dropping it — put the page back where it was.
            if let page = pendingHandoff {
                reannounceTask?.cancel()
                recoveryTask?.cancel()
                QCLog.write("PUT BACK (cancelled) \(page.url.absoluteString)")
                BrowserLink.open(page.url)
                setStatus("Put “\(page.title)” back")
                pulseGlow(.inward, message: "Put back — nothing took it")
                pendingHandoff = nil
            }
            screenSource.stopCapture()
        case .advertiseSourceAvailable:
            broadcast(.sourceAvailable)
        case .withdrawSourceAvailable:
            broadcast(.sourceWithdrawn)
        case .requestCastFromPeer(let peer):
            trust.trust(peer.id, name: peer.displayName)
            trustedNames = Array(trust.trusted.values).sorted()
            transport.send(.requestCast, to: peer)
        case .startStreaming(let peer):
            if let page = pendingHandoff {
                reannounceTask?.cancel()
                recoveryTask?.cancel()
                QCLog.write("-> handoff \(page.url.absoluteString) to \(peer.displayName)")
                transport.send(.handoff, payload: page.url.absoluteString, to: peer)
                setStatus("✅ Handed “\(page.title)” to \(peer.displayName)")
                pulseGlow(.outward, message: "Sent to \(peer.displayName)")
                pendingHandoff = nil
                streamingTarget = nil
                // A handoff completes instantly — nothing is being streamed —
                // so the session must not stay in "casting". It previously
                // did, and every later request was then ignored, so a second
                // handoff silently did nothing.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.apply(self.coordinator.reduce(.remoteEndedCast(peer)))
                    QCLog.write("handoff complete, back to \(self.coordinator.state)")
                }
                return
            }
            // No held page: stream instead. Capture may not be running (the
            // handoff path skips it), so make sure it is started.
            streamingTarget = peer
            // Whoever just asked has never seen a keyframe, and cannot decode
            // anything until they do.
            encoder.requestKeyframe()
            do {
                try screenSource.startCapture()
                setStatus("Streaming to \(peer.displayName)")
                // A stream that starts and then produces nothing looks
                // identical to one that was never asked for. Say so.
                framesThisStream = 0
                resetEncoding()
                streamWatchdog?.cancel()
                streamWatchdog = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, !Task.isCancelled, self.streamingTarget != nil,
                          self.framesThisStream == 0 else { return }
                    QCLog.write("STREAM STALLED: 3s after start, no frame has been captured")
                    self.setStatus("Nothing captured — bring the window you want to share to the front, then try again", hold: 10)
                }

                // Answer immediately with the last frame we already have,
                // rather than waiting for the shared window to change.
                if let cached = lastCapturedFrame {
                    QCLog.write("priming stream with the last captured frame")
                    encoder.encode(cached, at: 0)
                }
                startKeyframeHeartbeat()
            } catch {
                setStatus("Couldn't start streaming: \(error.localizedDescription)")
            }
        case .stopStreaming:
            streamingTarget = nil
            encoder.invalidate()
            keyframeHeartbeat?.cancel()
            keyframeHeartbeat = nil
            streamWatchdog?.cancel()
            streamWatchdog = nil
        case .showRemoteScreen:
            receivedImage = nil // frames will populate it
            pulseGlow(.inward)
        case .hideRemoteScreen:
            receivedImage = nil
        case .notifyEndedCast(let peer):
            transport.send(.endCast, to: peer)
        case .takeScreenshot:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await self.screenSource.captureStill()
                    self.lastScreenshot = url
                    self.permissions.screenRecordingFailed = false
                    self.setStatus("📸 Screenshot saved to Desktop: \(url.lastPathComponent)")
                } catch {
                    // Show the real underlying error so failures are diagnosable
                    // rather than always blamed on permissions.
                    self.statusLine = "✌️ Peace sign seen — screenshot failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func broadcast(_ message: ControlMessage) {
        let recipients = transport.connectedPeers
        QCLog.write("-> broadcast \(message.rawValue) to \(recipients.map(\.displayName))")
        for peer in recipients { transport.send(message, to: peer) }
    }

    // MARK: Streaming

    // MARK: Adaptive encoding
    //
    // A fixed quality cannot work: the same settings that give a 90 KB frame
    // for a Keynote slide give 357 KB for a text-heavy window, and at 10 fps
    // that is 3.2 MB/s — far past what MultipeerConnectivity will carry to an
    // iPad. Reliable delivery makes overshooting worse, not better: nothing is
    // dropped, so it queues, latency grows, and the session collapses.
    //
    // So aim at a byte budget instead, and let quality and scale float to
    // meet it. A softer picture that arrives beats a sharp one that kills the
    // stream.

    /// Roughly 10 Mbit/s.
    ///
    /// The first value was a guess on the cautious side, and the measurements
    /// showed why that costs something: the stream died at 3.2 MB/s but sat
    /// rock-steady at 0.8, pinned to its worst picture with the budget fully
    /// spent. The true ceiling is somewhere between, so this reaches for it.
    /// Overshooting is safe now in a way it was not before — frames past the
    /// budget are skipped rather than queued, and the receiver keeps only the
    /// newest — so the cost of aiming too high is a dropped frame, not a dead
    /// session.
    private let targetBytesPerSecond = 1200 * 1024

    private var jpegQuality: CGFloat = 0.75
    private var encodeScale: CGFloat = 1.0

    /// Resolution is defended harder than compression. For text, a
    /// full-size frame with JPEG artefacts stays readable, while a crisply
    /// encoded shrunken one does not — the strokes are simply gone. So
    /// quality is spent down to 0.40 before scale gives up anything, and
    /// scale never falls below 80% (1280px of the 1600 captured).
    private let minQuality: CGFloat = 0.40
    private let maxQuality: CGFloat = 0.85
    private let minScale: CGFloat = 0.80
    private var budgetBytes = 0
    private var budgetStart = Date()
    private var framesSkipped = 0

    private var framesSent = 0
    private var bytesSent = 0
    private var loggedIdleCapture = false

    /// Hardware H.264. JPEG stays as the fallback for when a session cannot
    /// be created, but it is genuinely a fallback now: it re-sends the whole
    /// picture every frame, which is why sharpness and smoothness had to be
    /// traded against each other at all.
    private let encoder = H264Encoder()
    private var usingH264 = true

    /// The most recent frame captured, kept even when nobody is watching.
    ///
    /// ScreenCaptureKit only delivers a frame when the screen actually
    /// changes — unchanged ones are marked idle and skipped, which is what
    /// makes a still window nearly free. But it also means that when someone
    /// finally opens their hand, there may be nothing to send: capture began
    /// at the fist, its first frame was discarded because no one had asked
    /// yet, and a static window produces nothing after that. The receiver
    /// then waits, sometimes ten seconds, for the sender to happen to move
    /// something. Holding the last frame lets the answer be immediate.
    private var lastCapturedFrame: CVPixelBuffer?

    /// When the last frame actually went out, and the timer that notices if
    /// that was too long ago.
    ///
    /// A receiver cannot decode anything until it has a keyframe, and the
    /// idle-frame skipping means a window nobody is touching produces no
    /// frames at all — so if the first keyframe is missed, or the viewer
    /// joins between two of them, there is nothing on the way to recover
    /// with and the screen simply stays empty. Re-sending the frame we
    /// already hold, as a keyframe, gives them a way back every couple of
    /// seconds for almost no bandwidth.
    private var lastFrameSentAt = Date.distantPast
    private var keyframeHeartbeat: Task<Void, Never>?
    /// Frames sent since this stream began. Distinct from `framesSent`, which
    /// is a per-second rate window and resets constantly — reading that for
    /// "has anything been sent?" made STREAM START repeat every second and
    /// the stall watchdog fire in the middle of a healthy stream.
    private var framesThisStream = 0
    private var streamWatchdog: Task<Void, Never>?
    private var rateWindowStart = Date()

    private func forwardFrame(_ pixelBuffer: CVPixelBuffer) {
        // Kept before the guard below, precisely so there is something to
        // send the instant a receiver appears.
        lastCapturedFrame = pixelBuffer

        guard let target = streamingTarget else {
            // Capture is running but nobody has asked for it yet. Worth
            // saying once, because "capturing" and "sending" look identical
            // from outside and this is where the two diverge.
            if !loggedIdleCapture {
                loggedIdleCapture = true
                QCLog.write("capture running, no stream target yet")
            }
            return
        }
        loggedIdleCapture = false

        // Shed load rather than queue it. Skipping a frame costs one stale
        // picture; queueing past the link's capacity costs the whole session.
        let now = Date()
        if now.timeIntervalSince(budgetStart) >= 1 {
            budgetBytes = 0
            budgetStart = now
        }
        guard budgetBytes < targetBytesPerSecond else {
            framesSkipped += 1
            return
        }

        // H.264 encodes the difference between frames and manages its own
        // bitrate, so the quality ladder below applies to JPEG only.
        if usingH264 {
            encoder.encode(pixelBuffer, at: 0)
            return                        // the send happens in onEncodedFrame
        }

        guard let data = jpeg(from: pixelBuffer, quality: jpegQuality, scale: encodeScale) else {
            QCLog.write("frame dropped: JPEG encode failed")
            return
        }
        budgetBytes += data.count
        adaptEncoding(lastFrameBytes: data.count)
        deliver(VideoPacket.jpeg(data), bytes: data.count, to: target)
    }

    /// Put an encoded frame on the wire and keep the running statistics.
    /// Shared by both codecs so the numbers mean the same thing either way.
    private func deliver(_ packet: Data, bytes: Int, to target: Peer) {
        lastFrameSentAt = Date()
        if framesThisStream == 0 {
            QCLog.write("STREAM START -> \(target.displayName), first frame \(bytes / 1024) KB"
                        + " (\(usingH264 ? "H.264" : "JPEG"))")
        }
        framesThisStream += 1
        transport.sendFrameData(packet, to: target)

        framesSent += 1
        bytesSent += bytes
        let elapsed = Date().timeIntervalSince(rateWindowStart)
        if elapsed >= 1 {
            let codec = usingH264
                ? "H.264"
                : String(format: "q%.2f scale %.0f%%", jpegQuality, encodeScale * 100)
            QCLog.write(String(format: "stream %.1f fps, %.0f KB/s, avg frame %.0f KB, %@, %d skipped",
                               Double(framesSent) / elapsed,
                               Double(bytesSent) / 1024 / elapsed,
                               Double(bytesSent) / 1024 / Double(max(framesSent, 1)),
                               codec, framesSkipped))
            framesSent = 0; bytesSent = 0; framesSkipped = 0; rateWindowStart = Date()
        }
    }

    /// While a stream is running, make sure a decodable keyframe goes out at
    /// least every couple of seconds even if nothing on screen has changed.
    ///
    /// This is what turns "it worked, then it didn't, then it did" into
    /// something reliable: any receiver that missed a keyframe recovers on
    /// the next beat instead of waiting for the sender to happen to move a
    /// window. A still frame costs a few KB, so the floor is negligible.
    private func startKeyframeHeartbeat() {
        keyframeHeartbeat?.cancel()
        keyframeHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.streamingTarget != nil else { return }
                guard Date().timeIntervalSince(self.lastFrameSentAt) >= 1.5,
                      let cached = self.lastCapturedFrame else { continue }
                QCLog.write("keyframe heartbeat — nothing sent for 1.5s")
                self.encoder.requestKeyframe()
                self.encoder.encode(cached, at: 0)
            }
        }
    }

    /// Steer quality and scale toward the byte budget.
    ///
    /// Quality is spent first and scale only once quality bottoms out, because
    /// a slightly soft full-size window stays readable while a shrunken one
    /// does not. Recovery is deliberately slower than backing off — climbing
    /// as eagerly as we retreat just oscillates.
    private func adaptEncoding(lastFrameBytes: Int) {
        let targetFrame = targetBytesPerSecond / max(screenSource.framesPerSecond, 1)
        if lastFrameBytes > targetFrame * 6 / 5 {
            if jpegQuality > minQuality {
                jpegQuality -= 0.05
            } else if encodeScale > minScale {
                encodeScale -= 0.05
            }
        } else if lastFrameBytes < targetFrame * 3 / 5 {
            if encodeScale < 1.0 {
                encodeScale = min(1.0, encodeScale + 0.05)
            } else if jpegQuality < maxQuality {
                jpegQuality += 0.02
            }
        }
    }

    private func resetEncoding() {
        jpegQuality = 0.75
        encodeScale = 1.0
        budgetBytes = 0
        budgetStart = Date()
        framesSkipped = 0
    }

    private func jpeg(from pixelBuffer: CVPixelBuffer, quality: CGFloat, scale: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if scale < 0.999 {
            // Lanczos rather than an affine transform: downscaling text with
            // a cheap filter is what makes a shrunken window unreadable.
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(scale, forKey: kCIInputScaleKey)
            filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let output = filter?.outputImage { image = output }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    /// Put a grabbed page back, from the UI. Gestures deliberately cannot do
    /// this while a page is held, so there has to be an explicit way.
    func cancelGrab() {
        guard pendingHandoff != nil else { return }
        apply(coordinator.reduce(.localGesture(.closedHand)))
    }

    /// True while a page is grabbed and waiting for a device to take it.
    var isHoldingPage: Bool { pendingHandoff != nil }

    /// Play the glow for something leaving or arriving.
    private func pulseGlow(_ direction: GlowDirection, message: String? = nil) {
        glowDirection = direction
        glowTrigger &+= 1
        glowOverlay.flash(direction, message: message)
    }

    /// Show a message and protect it from being overwritten for a moment.
    private func setStatus(_ text: String, hold: TimeInterval = 6) {
        statusLine = text
        statusHoldUntil = Date().addingTimeInterval(hold)
    }

    private func updateStatus() {
        guard Date() >= statusHoldUntil else { return }
        switch state {
        case .idle:
            statusLine = peers.isEmpty ? "Waiting for nearby devices…" : "Ready — close your hand to share this screen"
        case .armedSource:
            statusLine = "Screen armed — open your hand at another device to cast"
        case .casting(let p):
            statusLine = "Casting to \(p.displayName)"
        case .receiving(let p):
            statusLine = "Receiving from \(p.displayName)"
        }
    }
}

// MARK: - PeerTransportDelegate

extension AppModel: PeerTransportDelegate {
    nonisolated func transport(_ transport: PeerTransport, didUpdate peers: [Peer]) {
        Task { @MainActor in
            QCLog.write("peers now: \(peers.map(\.displayName))")
            self.peers = peers
            // Keep newly-joined peers informed if we are currently a source.
            if case .armedSource = self.state { self.broadcast(.sourceAvailable) }
            self.updateStatus()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            QCLog.write("<- \(message.rawValue) from \(peer.displayName)\(payload.map { " payload=\($0)" } ?? "")")
            // A handed-over page opens natively here; there is no session state
            // to advance, the thing has simply arrived.
            if message == .handoff {
                guard let payload, let url = URL(string: payload) else {
                    QCLog.write("HANDOFF REFUSED — unreadable address: \(payload ?? "nil")")
                    self.setStatus("Something arrived from \(peer.displayName) that wasn't a web address", hold: 8)
                    return
                }
                // Say whether macOS actually opened it. Silently dropping this
                // made "the page never arrived" and "the page arrived and the
                // browser refused it" look identical.
                let opened = BrowserLink.open(url)
                QCLog.write(opened
                    ? "OPENED \(url.absoluteString)"
                    : "HANDOFF ARRIVED BUT macOS REFUSED TO OPEN IT: \(url.absoluteString)")
                if !opened {
                    self.setStatus("Couldn't open the page from \(peer.displayName) — no default browser?", hold: 10)
                }
                self.setStatus("📬 Opened a page from \(peer.displayName)")
                self.pulseGlow(.inward, message: "Received from \(peer.displayName)")
                self.apply(self.coordinator.reduce(.remoteEndedCast(peer)))
                return
            }
            let input: SessionInput
            switch message {
            case .sourceAvailable: input = .remoteSourceBecameAvailable(peer)
            case .sourceWithdrawn: input = .remoteSourceWithdrawn(peer)
            case .requestCast:     input = .remoteRequestedCast(peer)
            case .endCast:         input = .remoteEndedCast(peer)
            case .handoff:         return
            }
            self.apply(self.coordinator.reduce(input))
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceiveFrame frame: Any, from peer: Peer) {
        guard let data = frame as? Data else { return }
        Task { @MainActor in
            if case .receiving(let source) = self.state, source == peer {
                self.receivedImage = NSImage(data: data)
            }
        }
    }
}
