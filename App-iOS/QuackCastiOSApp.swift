import SwiftUI

@main
struct QuackCastiOSApp: App {
    @StateObject private var model = ReceiverModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    model.start()
                    model.didBecomeActive()
                }
                // A link can be handed in directly (Shortcut or share action)
                // instead of going via the clipboard.
                .onOpenURL { model.handleIncoming($0) }
        }
        .onChange(of: scenePhase) { phase in
            // iOS suspends this app in the background, so coming forward is
            // the moment to re-check what can be sent.
            if phase == .active { model.didBecomeActive() }
        }
    }
}
