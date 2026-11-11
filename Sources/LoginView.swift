import SwiftUI

/// Экран входа: локальная «учётная запись» без сервера.
struct LoginView: View {
    @ObservedObject var appState: AppSessionStore
    @State private var username = ""
    @State private var password = ""
    @State private var showAuthError = false
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 52))
                            .foregroundStyle(.orange)
                        Text("Local AI")
                            .font(.title.bold())
                        Text("Войдите, чтобы продолжить")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Логин")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Введите логин", text: $username)
                            .focused($focusedField, equals: .username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(white: 0.12))
                            )
                            .foregroundStyle(.white)

                        Text("Пароль")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Введите пароль", text: $password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(tryLogin)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(white: 0.12))
                            )
                            .foregroundStyle(.white)
                    }

                    if showAuthError {
                        Text("Логин — от 2 символов, пароль — от 4")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button(action: tryLogin) {
                        Text("Войти")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Color.orange,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .foregroundColor(.black)
                    }

                    Button {
                        username = "demo"
                        password = "1234"
                        showAuthError = !appState.login(username: username, password: password)
                    } label: {
                        Text("Войти как demo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
    }

    private func tryLogin() {
        showAuthError = !appState.login(username: username, password: password)
    }
}
