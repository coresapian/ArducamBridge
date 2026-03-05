import SwiftUI

@main
struct ArducamBridgeViewerApp: App {
    var body: some Scene {
        WindowGroup("Arducam Bridge") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 820)
    }
}
