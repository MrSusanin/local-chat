import SwiftUI

@main
struct LocalChatApp: App {
    @StateObject private var appState = AppSessionStore()

    var body: some Scene {
        WindowGroup {
            if appState.isAuthenticated {
                ContentView()
                    .preferredColorScheme(.dark)
            } else {
                LoginView(appState: appState)
                    .preferredColorScheme(.dark)
            }
        }
    }
}
