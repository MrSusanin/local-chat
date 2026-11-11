import SwiftUI

struct LoginView: View {
    @ObservedObject var appState: AppSessionStore
    @State private var username = ""
    @State private var password = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text("Local AI")
                    .font(.title.bold())

                Text("Войдите, чтобы продолжить")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Логин")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Введите логин", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Text("Пароль")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("Введите пароль", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if showError {
                Text("Логин и пароль должны быть заполнены корректно")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                let success = appState.login(username: username, password: password)
                showError = !success
            } label: {
                Text("Войти")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button(role: .cancel) {
                username = "demo"
                password = "1234"
                _ = appState.login(username: username, password: password)
            } label: {
                Text("Войти как demo")
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}
