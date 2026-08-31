import SwiftUI

/// Password login view for devices that require authentication.
struct LoginView: View {
    let device: KVMDevice
    let onAuthenticated: () -> Void

    @State private var password = ""
    @State private var savePassword = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let authService = AuthService()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Authentication Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the password for \(device.name)")
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { login() }

            Toggle("Save password securely", isOn: $savePassword)
                .frame(maxWidth: 300, alignment: .leading)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button(action: login) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isLoading)
        }
        .padding(40)
        .onAppear {
            if let savedPassword = KeychainPasswordStore.password(for: device) {
                password = savedPassword
                savePassword = true
            }
        }
    }

    private func login() {
        guard !password.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.login(device: device, password: password)
                if savePassword {
                    KeychainPasswordStore.save(password, for: device)
                } else {
                    KeychainPasswordStore.removePassword(for: device)
                }
                onAuthenticated()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
