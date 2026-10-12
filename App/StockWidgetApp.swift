import SwiftUI
import WidgetKit

@main
struct StockWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Minimal host app: point the widget at your aggregation backend.
struct SettingsView: View {
    @State private var endpoint = BackendConfiguration.endpoint?.absoluteString ?? ""
    @State private var token = ""
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://api.example.com/v1/portfolio", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(CredentialStore.shared.readToken() == nil ? "API token" : "API token (saved)", text: $token)
                } header: {
                    Text("Aggregation backend")
                } footer: {
                    Text("Leave the endpoint empty to show sample data. The token is stored in the Keychain and shared only with the widget.")
                }

                Section {
                    Button("Save & Refresh Widgets", action: save)
                    Button("Remove Token", role: .destructive) {
                        CredentialStore.shared.deleteToken()
                        reload("Token removed.")
                    }
                }

                if let status {
                    Section { Text(status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Portfolio Widget")
        }
    }

    private func save() {
        do {
            try BackendConfiguration.setEndpoint(endpoint)
            if !token.isEmpty {
                try CredentialStore.shared.saveToken(token)
                token = ""
            }
            reload("Saved. Widgets will refresh shortly.")
        } catch {
            status = PortfolioError.message(for: error)
        }
    }

    private func reload(_ message: String) {
        PortfolioCache().clear()
        WidgetCenter.shared.reloadAllTimelines()
        status = message
    }
}
