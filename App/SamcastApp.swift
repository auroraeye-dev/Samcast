import SwiftUI

@main
struct SamcastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
