import Foundation

/// Recognises pages that would do real damage if handed over by accident.
///
/// The gesture is never perfectly reliable — a hand closing to pick up a mug
/// reads much like a deliberate fist. For an ordinary web page a misread
/// costs a reopened tab. For a **live meeting** it drops you out of the call
/// in front of everyone, and rejoining means new camera and microphone
/// prompts. Those are not the same mistake, so they should not carry the same
/// risk, and the app asks first.
///
/// Lives in the core, with no platform imports, so macOS, iOS and the Windows
/// build all agree on what counts as a meeting rather than each guessing.
public enum PageRisk: Equatable, Sendable {
    case ordinary
    case liveMeeting(MeetingMatch)

    /// Whether the user should be asked before this page is handed over.
    public var needsConfirmation: Bool {
        if case .liveMeeting = self { return true }
        return false
    }
}

public struct MeetingMatch: Equatable, Sendable {
    /// Display name, e.g. "Google Meet".
    public let service: String
    /// The meeting code where the URL exposes one, e.g. "abc-defg-hij".
    /// Shown in the prompt so the user can tell *which* call is at stake.
    public let code: String?

    public init(service: String, code: String? = nil) {
        self.service = service
        self.code = code
    }
}

public enum PageRiskDetector {

    /// Assess a URL string. Anything unparseable is treated as ordinary —
    /// this is a safety prompt, not a filter, and it must not block a handoff
    /// it merely failed to understand.
    public static func assess(_ urlString: String) -> PageRisk {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased()
        else { return .ordinary }
        return assess(host: host, path: url.path)
    }

    public static func assess(host rawHost: String, path rawPath: String) -> PageRisk {
        let host = normalise(rawHost)
        let path = rawPath.lowercased()

        // --- Google Meet ---------------------------------------------------
        // Only a real room counts. `meet.google.com` on its own is the landing
        // page, and prompting there would train the user to dismiss prompts
        // without reading them — which would defeat the whole feature.
        if matches(host, "meet.google.com") {
            if let code = meetCode(in: path) {
                return .liveMeeting(MeetingMatch(service: "Google Meet", code: code))
            }
            if path.hasPrefix("/lookup/"), path.count > "/lookup/".count {
                return .liveMeeting(MeetingMatch(service: "Google Meet", code: nil))
            }
            return .ordinary
        }

        // --- Zoom -----------------------------------------------------------
        if matches(host, "zoom.us") || matches(host, "zoomgov.com") {
            for marker in ["/j/", "/s/", "/wc/", "/my/"] where path.contains(marker) {
                return .liveMeeting(MeetingMatch(service: "Zoom", code: segment(after: marker, in: path)))
            }
            return .ordinary
        }

        // --- Microsoft Teams ------------------------------------------------
        if matches(host, "teams.microsoft.com") || matches(host, "teams.live.com") {
            for marker in ["meetup-join", "/l/meeting", "/meet/", "/v2/?meetingjoin"] where path.contains(marker) {
                return .liveMeeting(MeetingMatch(service: "Microsoft Teams", code: nil))
            }
            return .ordinary
        }

        // --- Webex ------------------------------------------------------------
        if matches(host, "webex.com") {
            for marker in ["/meet/", "/join/", "/wbxmjs/", "/j.php"] where path.contains(marker) {
                return .liveMeeting(MeetingMatch(service: "Webex", code: nil))
            }
            return .ordinary
        }

        // --- Services where any room path is a call ---------------------------
        let roomServices: [(domain: String, name: String)] = [
            ("meet.jit.si", "Jitsi Meet"),
            ("whereby.com", "Whereby"),
            ("chime.aws", "Amazon Chime"),
            ("gather.town", "Gather"),
            ("around.co", "Around"),
            ("bluejeans.com", "BlueJeans"),
            ("gotomeeting.com", "GoToMeeting")
        ]
        for service in roomServices where matches(host, service.domain) {
            // A bare domain is marketing; a path is a room.
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty && !isMarketingPath(trimmed) {
                return .liveMeeting(MeetingMatch(service: service.name, code: nil))
            }
            return .ordinary
        }

        return .ordinary
    }

    // MARK: - Helpers

    /// `www.` is noise, and a match should cover subdomains — a Zoom link is
    /// usually `acme.zoom.us`, never the bare domain.
    private static func normalise(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Pages on a meeting domain that are plainly not a call.
    private static func isMarketingPath(_ path: String) -> Bool {
        let first = path.split(separator: "/").first.map(String.init) ?? path
        return ["pricing", "download", "about", "support", "signin", "login",
                "features", "blog", "contact", "terms", "privacy"].contains(first)
    }

    /// Google Meet room codes look like `abc-defg-hij` — three groups of
    /// letters, 3-4-3. Matched by shape rather than by regex so the rule is
    /// obvious and cheap.
    private static func meetCode(in path: String) -> String? {
        let candidate = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !candidate.isEmpty else { return nil }
        let groups = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 3,
              groups[0].count == 3, groups[1].count == 4, groups[2].count == 3,
              groups.allSatisfy({ $0.allSatisfy { $0.isLetter && $0.isASCII } })
        else { return nil }
        return candidate
    }

    /// The path segment immediately following a marker, e.g. the id in
    /// `/j/1234567890`.
    private static func segment(after marker: String, in path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        let value = rest.prefix(while: { $0 != "/" && $0 != "?" })
        return value.isEmpty ? nil : String(value)
    }
}
