import UIKit
import SafariServices

/// Presents a handed-over page in an in-app browser.
///
/// Done imperatively rather than with SwiftUI's `fullScreenCover`: a
/// representable wrapping SFSafariViewController cannot change its URL once
/// created (there is nothing meaningful to do in updateUIViewController), so
/// SwiftUI reusing the existing controller silently re-showed the *previous*
/// page when a second handoff arrived. Presenting directly guarantees each
/// page gets its own controller.
///
/// The page stays inside QuackCast so the app is never backgrounded — iOS
/// suspends a backgrounded app's networking and camera, which would stop the
/// device receiving anything further.
@MainActor
enum PagePresenter {
    static func show(_ url: URL) {
        guard let root = keyRootViewController() else { return }
        let browser = SFSafariViewController(url: url)
        browser.modalPresentationStyle = .fullScreen

        if let presented = root.presentedViewController {
            // Replace whatever is already showing.
            presented.dismiss(animated: false) {
                root.present(browser, animated: true)
            }
        } else {
            root.present(browser, animated: true)
        }
    }

    private static func keyRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
