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

    /// The page in the frontmost browser, or nil if the front app isn't a
    /// browser we can read.
    public static func frontmostPage() -> Page? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = known.first(where: { $0.bundleID == front }) else { return nil }

        let script: String
        if browser.isChromium {
            script = """
            tell application "\(browser.appName)"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & "\\n" & theTitle
            end tell
            """
        } else {
            script = """
            tell application "\(browser.appName)"
                set theURL to URL of current tab of front window
                set theTitle to name of current tab of front window
                return theURL & "\\n" & theTitle
            end tell
            """
        }

        guard let result = run(script) else { return nil }
        let parts = result.components(separatedBy: "\n")
        guard let first = parts.first, let url = URL(string: first.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        let title = parts.count > 1 ? parts[1] : url.host ?? first
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
        return run(script) != nil
    }

    /// Opens a handed-over URL in this machine's default browser.
    public static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return output.stringValue ?? ""
    }
}
#endif
