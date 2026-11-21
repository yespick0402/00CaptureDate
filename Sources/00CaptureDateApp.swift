import SwiftUI

@main
struct CaptureDateApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("00CaptureDate") {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
