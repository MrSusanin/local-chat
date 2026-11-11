import Foundation
import SwiftUI

@MainActor
final class AppSessionStore: ObservableObject {
    @Published var isAuthenticated: Bool {
        didSet { UserDefaults.standard.set(isAuthenticated, forKey: "isAuthenticated") }
    }

    @Published var selectedProvider: AIProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider")
            do {
                apiKey = try KeychainStore.read(account: selectedProvider.rawValue) ?? ""
                credentialError = nil
            } catch {
                apiKey = ""
                credentialError = "Не удалось прочитать ключ из Keychain."
            }
        }
    }

    @Published var apiKey: String {
        didSet {
            do {
                try KeychainStore.write(apiKey, account: selectedProvider.rawValue)
                credentialError = nil
            } catch {
                credentialError = "Не удалось сохранить API-ключ в Keychain."
            }
        }
    }

    @Published var selectedModelName: String {
        didSet { UserDefaults.standard.set(selectedModelName, forKey: "selectedModelName") }
    }

    @Published private(set) var credentialError: String?

    init() {
        let defaults = UserDefaults.standard
        let providerRaw = defaults.string(forKey: "selectedProvider") ?? AIProvider.local.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .local
        let modelName = defaults.string(forKey: "selectedModelName") ?? provider.defaultModelName

        self.isAuthenticated = defaults.bool(forKey: "isAuthenticated")
        self.selectedProvider = provider
        self.selectedModelName = modelName

        let legacyKey = defaults.string(forKey: "providerApiKey")
        let storedKey: String?
        do {
            storedKey = try KeychainStore.read(account: provider.rawValue)
        } catch {
            storedKey = nil
            self.credentialError = "Не удалось прочитать ключ из Keychain."
        }
        self.apiKey = storedKey ?? legacyKey ?? ""

        if storedKey == nil, let legacyKey, !legacyKey.isEmpty {
            do {
                try KeychainStore.write(legacyKey, account: provider.rawValue)
                defaults.removeObject(forKey: "providerApiKey")
            } catch {
                self.credentialError = "Не удалось перенести API-ключ в Keychain."
            }
        }
    }

    var currentProfile: AIModelProfile {
        AIModelProfile(
            provider: selectedProvider,
            modelName: selectedModelName.isEmpty ? selectedProvider.defaultModelName : selectedModelName,
            capabilities: selectedProvider.supportedCapabilities
        )
    }

    /// Local UI gate only; this does not authenticate against a server or create an account.
    func login(username: String, password: String) -> Bool {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.count >= 2, pass.count >= 4 else { return false }
        isAuthenticated = true
        return true
    }

    func logout() {
        isAuthenticated = false
    }
}
