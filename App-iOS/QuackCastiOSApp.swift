import SwiftUI

@main
struct QuackCastiOSApp: App {
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
    }
}
