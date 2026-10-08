import DashboardCore
import SwiftUI

struct SettingsView: View {
    @Environment(DashboardStore.self) private var store
    @State private var newToken = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LabeledContent("Status", value: tokenStatus)
                SecureField("Personal access token", text: $newToken)
                HStack {
                    Button("Save to Keychain") {
                        let value = newToken
                        newToken = ""
                        Task { await store.saveToken(value) }
                    }
                    .disabled(newToken.isEmpty)
                    if store.hasStoredToken {
                        Button("Remove", role: .destructive) { Task { await store.removeToken() } }
                    }
                }
            } header: {
                Text("GitHub token")
            } footer: {
                Text("A fine-grained token with read-only access to pull requests and contents is enough.")
            }

            Section {
                TextField("Organizations", text: $store.orgs, prompt: Text("all repositories"))
                TextField("Ignored logins", text: $store.ignoredLogins, prompt: Text("none"))
                Button("Apply") { Task { await store.refresh() } }
            } header: {
                Text("Scope")
            } footer: {
                Text("Comma separated. Leave organizations empty to include every repository.")
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
        }
        .formStyle(.grouped)
    }

    private var tokenStatus: String {
        if let dashboard = store.dashboard, !store.needsToken {
            return "@\(dashboard.viewer) via \(dashboard.tokenSource.rawValue)"
        }
        return store.needsToken ? "Not connected" : "Checking…"
    }
}
