import SwiftUI

@main
struct LocalChatApp: App {
    @StateObject private var appState = AppSessionStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.isAuthenticated {
                    LoginView(appState: appState)
                } else if appState.selectedProvider == .local {
                    ContentView()
                } else {
                    RemoteProviderChatView(appState: appState)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
