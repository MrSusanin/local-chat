import Foundation
import SwiftUI

/// Сессия пользователя: простой локальный «вход» без сервера.
/// Настройки ИИ (провайдер, модель, API ключи) хранятся в ChatViewModel и связке ключей.
final class AppSessionStore: ObservableObject {
    @Published var isAuthenticated: Bool {
        didSet { UserDefaults.standard.set(isAuthenticated, forKey: "isAuthenticated") }
    }

    @Published private(set) var username: String

    init() {
        isAuthenticated = UserDefaults.standard.bool(forKey: "isAuthenticated")
        username = UserDefaults.standard.string(forKey: "username") ?? ""
    }

    /// Простая локальная проверка: логин от 2 символов, пароль от 4.
    /// Никуда не отправляется: данные остаются на устройстве.
    func login(username: String, password: String) -> Bool {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.count >= 2, pass.count >= 4 else { return false }
        self.username = user
        UserDefaults.standard.set(user, forKey: "username")
        isAuthenticated = true
        return true
    }

    func logout() {
        isAuthenticated = false
    }
}
