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

/// Enter broker keys (stored in the shared Keychain) and test them.
/// Fields are write-only: saved values are never read back into the UI.
struct SettingsView: View {
    @State private var growwAPIKey = ""
    @State private var growwTOTPSecret = ""
    @State private var ibkrToken = ""
    @State private var ibkrQueryID = ""
    @State private var saved: Set<CredentialKey> = []
    @State private var status: String?
    @State private var isRefreshing = false

    private let keychain = Keychain.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    credentialField("TOTP token (API key)", text: $growwAPIKey, key: .growwAPIKey)
                    credentialField("TOTP secret", text: $growwTOTPSecret, key: .growwTOTPSecret)
                } header: {
                    Text("Groww")
                } footer: {
                    Text("groww.in → Trade API → Generate API key → Generate TOTP token. Codes are generated on this device, so the token renews itself every day.")
                }

                Section {
                    credentialField("Flex Web Service token", text: $ibkrToken, key: .ibkrFlexToken)
                    credentialField("Flex Query ID", text: $ibkrQueryID, key: .ibkrFlexQueryID)
                } header: {
                    Text("Interactive Brokers")
                } footer: {
                    Text("Client Portal → Performance & Reports → Flex Queries. Create an Activity query (XML) with Open Positions, Cash Report and Account Information, then enable the Flex Web Service to get a token.")
                }

                Section {
                    Button("Save", action: save)
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Text("Refresh now")
                            if isRefreshing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isRefreshing)
                    Button("Remove all keys", role: .destructive, action: removeAll)
                }

                if let status {
                    Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            .navigationTitle("Portfolio Widget")
            .onAppear(perform: loadSavedState)
        }
    }

    private func credentialField(_ title: String, text: Binding<String>, key: CredentialKey) -> some View {
        SecureField(saved.contains(key) ? "\(title) — saved" : title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func loadSavedState() {
        saved = Set(CredentialKey.allCases.filter { keychain.string($0) != nil })
    }

    private func save() {
        let entries: [(CredentialKey, String)] = [
            (.growwAPIKey, growwAPIKey), (.growwTOTPSecret, growwTOTPSecret),
            (.ibkrFlexToken, ibkrToken), (.ibkrFlexQueryID, ibkrQueryID),
        ]
        if !growwTOTPSecret.isEmpty, TOTP.base32Decode(growwTOTPSecret) == nil {
            status = "That TOTP secret isn't valid base32."
            return
        }
        do {
            for (key, value) in entries where !value.isEmpty {
                try keychain.set(value, for: key)
                if key == .growwAPIKey || key == .growwTOTPSecret { try keychain.set(nil, for: .growwAccessToken) }
                if key == .ibkrFlexToken || key == .ibkrFlexQueryID { StatementCache().clear() }
            }
            growwAPIKey = ""; growwTOTPSecret = ""; ibkrToken = ""; ibkrQueryID = ""
            loadSavedState()
            Task { await refresh() }
        } catch {
            status = PortfolioError.message(for: error)
        }
    }

    private func removeAll() {
        for key in CredentialKey.allCases { try? keychain.set(nil, for: key) }
        PortfolioCache().clear()
        StatementCache().clear()
        HistoryStore().clear()
        loadSavedState()
        WidgetCenter.shared.reloadAllTimelines()
        status = "All keys and cached data removed."
    }

    /// The app has far more time than a widget reload, so it does the slow part
    /// (regenerating the IBKR Flex statement) and leaves a fresh cache for the widget.
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let load = try await PortfolioRepository.shared.load(force: true)
            WidgetCenter.shared.reloadAllTimelines()
            let model = PortfolioDisplayModel(summary: load.summary, baseCurrency: .inr)
            let lines = load.summary.brokers.map { broker in
                let value = MoneyFormat.full(broker.totalValue(using: load.summary.fx), broker.currency)
                let problem = broker.syncStatus == .ok ? "" : " — \(broker.syncStatus.rawValue): \(broker.syncMessage ?? "unknown error")"
                return "\(broker.shortName): \(value)\(problem)"
            }
            status = (["Total: \(MoneyFormat.full(model.totalValue, .inr))"] + lines).joined(separator: "\n")
        } catch {
            status = PortfolioError.message(for: error)
        }
    }
}
