import SwiftUI

@main
struct ScreenOverIPApp: App {

    @StateObject private var coordinator = StreamCoordinator()

    var body: some Scene {
        WindowGroup("Screen Over IP") {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 480, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { } // No "New Window"
        }
    }
}
