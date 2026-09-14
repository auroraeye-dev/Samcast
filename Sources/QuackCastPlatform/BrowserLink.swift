#if os(macOS)
import Foundation
import AppKit

/// Reads (and can close) the current tab of the frontmost browser, so a page
/// can be *handed over* to another machine rather than streamed as pixels.
///
/// This is what makes "the link closed here and opened there" possible: only a
/// URL travels, so it arrives instantly, at perfect fidelity, and opens
/// natively in the other person's own browser without disturbing their tabs.
///
/// Uses AppleScript, which requires Automation permission for each browser the
/// first time (macOS prompts), plus the apple-events entitlement.
public enum BrowserLink {

    public struct Page {
        public let url: URL
        public let title: String
        public let browserName: String
    }

    /// Browsers we can talk to, and the AppleScript dialect each one needs.
    private struct Browser {
        let bundleID: String
        let appName: String
        /// Chromium and Safari use different vocabulary for the same idea.
        let isChromium: Bool
    }

    private static let known: [Browser] = [
        Browser(bundleID: "com.apple.Safari", appName: "Safari", isChromium: false),
        Browser(bundleID: "com.google.Chrome", appName: "Google Chrome", isChromium: true),
        Browser(bundleID: "com.microsoft.edgemac", appName: "Microsoft Edge", isChromium: true),
        Browser(bundleID: "com.brave.Browser", appName: "Brave Browser", isChromium: true),
        Browser(bundleID: "company.thebrowser.Browser", appName: "Arc", isChromium: true),
        Browser(bundleID: "com.vivaldi.Vivaldi", appName: "Vivaldi", isChromium: true)
    ]

    /// Why a page could not be grabbed. Surfaced to the user rather than
    /// silently falling back, so failures are diagnosable.
    public enum LinkError: LocalizedError {
        case frontAppNotABrowser(String)
        case scriptFailed(String)
        case noUsableURL(String)

        public var errorDescription: String? {
            switch self {
            case .frontAppNotABrowser(let app):
                return "front app is \(app), not a supported browser"
            case .scriptFailed(let message):
                return message
            case .noUsableURL(let detail):
                return detail
            }
        }
    }

    /// The page open in the frontmost browser.
    public static func frontmostPage() throws -> Page {
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let front = frontApp?.bundleIdentifier,
              let browser = known.first(where: { $0.bundleID == front }) else {
            throw LinkError.frontAppNotABrowser(frontApp?.localizedName ?? "unknown")
        }

        let script: String
        if browser.isChromium {
            script = """
            tell application "\(browser.appName)"
                if (count of windows) is 0 then return ""
                set theTab to active tab of front window
                set theURL to URL of theTab
                if theURL is missing value then return ""
                return (theURL as text) & linefeed & (title of theTab as text)
            end tell
            """
        } else {
            script = """
            tell application "\(browser.appName)"
                if (count of windows) is 0 then return ""
                set theTab to current tab of front window
                set theURL to URL of theTab
                if theURL is missing value then return ""
                return (theURL as text) & linefeed & (name of theTab as text)
            end tell
            """
        }

        let result = try run(script)
        // Split on any line ending: AppleScript may return CR, LF or CRLF
        // depending on the app and OS version.
        let parts = result
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let raw = parts.first, !raw.isEmpty, raw != "missing value" else {
            throw LinkError.noUsableURL("the browser reported no open page")
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            throw LinkError.noUsableURL("couldn't read an address (got “\(raw.prefix(60))”)")
        }
        guard scheme == "http" || scheme == "https" else {
            // e.g. a local file, a PDF blob, or the Start Page.
            throw LinkError.noUsableURL("that page is \(scheme):, which can't be opened on another device")
        }
        let title = parts.count > 1 ? parts[1] : (url.host ?? raw)
        return Page(url: url, title: title, browserName: browser.appName)
    }

    /// Closes the frontmost browser tab — the "it left my screen" half of a
    /// handoff. Returns false if it could not be closed.
    @discardableResult
    public static func closeFrontmostTab() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = known.first(where: { $0.bundleID == front }) else { return false }

        let script: String
        if browser.isChromium {
            script = """
            tell application "\(browser.appName)" to close active tab of front window
            """
        } else {
            script = """
            tell application "\(browser.appName)" to close current tab of front window
            """
        }
        return (try? run(script)) != nil
    }

    /// Opens a handed-over URL in this machine's default browser.
    public static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw LinkError.scriptFailed("could not compile the AppleScript")
        }
        let output = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple events", i.e. the
            // Automation permission was denied or never granted.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            if code == -1743 {
                throw LinkError.scriptFailed("QuackCast isn't allowed to control your browser. Enable it under System Settings ▸ Privacy & Security ▸ Automation.")
            }
            throw LinkError.scriptFailed("AppleScript error \(code): \(message)")
        }
        return output.stringValue ?? ""
    }
}
#endif
