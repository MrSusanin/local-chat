import Foundation
import SwiftUI

final class AppSessionStore: ObservableObject {
    @Published var isAuthenticated: Bool {
        didSet { UserDefaults.standard.set(isAuthenticated, forKey: "isAuthenticated") }
    }

    @Published var selectedProvider: AIProvider {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "providerApiKey") }
    }

    @Published var selectedModelName: String {
        didSet { UserDefaults.standard.set(selectedModelName, forKey: "selectedModelName") }
    }

    init() {
        let storedLoggedIn = UserDefaults.standard.bool(forKey: "isAuthenticated")
        let providerValue = UserDefaults.standard.string(forKey: "selectedProvider") ?? AIProvider.local.rawValue
        let provider = AIProvider(rawValue: providerValue) ?? .local
        let storedModel = UserDefaults.standard.string(forKey: "selectedModelName") ?? provider.defaultModelName

        self.isAuthenticated = storedLoggedIn
        self.selectedProvider = provider
        self.apiKey = UserDefaults.standard.string(forKey: "providerApiKey") ?? ""
        self.selectedModelName = storedModel
    }

    var currentProfile: AIModelProfile {
        AIModelProfile(
            provider: selectedProvider,
            modelName: selectedModelName.isEmpty ? selectedProvider.defaultModelName : selectedModelName,
            capabilities: selectedProvider.supportedCapabilities
        )
    }

    func login(username: String, password: String) -> Bool {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)

        let valid = !trimmedUser.isEmpty && trimmedUser.count >= 2 && !trimmedPass.isEmpty && trimmedPass.count >= 4
        if valid {
            isAuthenticated = true
            return true
        }
        return false
    }

    func logout() {
        isAuthenticated = false
    }
}
