import SwiftUI

@main
struct AgentApp: App {
    var body: some Scene {
        WindowGroup {
            BridgeView()
                .preferredColorScheme(.dark)
        }
    }
}
