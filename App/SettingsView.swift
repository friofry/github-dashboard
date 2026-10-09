import DashboardCore
import SwiftUI

struct SettingsView: View {
    @Environment(DashboardStore.self) private var store
    @Environment(ReviewCoordinator.self) private var coordinator: ReviewCoordinator?
    @Environment(\.buildCommit) private var buildCommit
    @State private var newToken = ""
    @State private var newOwner = ""

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
                ForEach(store.availableOwners, id: \.self) { owner in
                    Toggle(isOn: Binding(
                        get: { store.isSelected(owner) },
                        set: { store.setOwner(owner, selected: $0) }
                    )) {
                        Text(owner == store.dashboard?.viewer ? "Personal (@\(owner))" : owner)
                    }
                }
                HStack {
                    TextField("Other organization or user", text: $newOwner, prompt: Text("e.g. apple"))
                        .onSubmit(addOwner)
                    Button("Add", action: addOwner).disabled(newOwner.isEmpty)
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("Nothing selected means every repository you can see.")
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .onChange(of: store.orgs) { Task { await store.refresh() } }

            if let coordinator { ClaudeSettingsSection(coordinator: coordinator) }

            Section {
                TextField("Ignored logins", text: $store.ignoredLogins, prompt: Text("none"))
            } header: {
                Text("Updates")
            } footer: {
                Text("Comma separated. Activity from these accounts is hidden; bots always are.")
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            if !buildCommit.isEmpty {
                Section {
                    LabeledContent("Built from", value: buildCommit)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addOwner() {
        store.setOwner(newOwner, selected: true)
        newOwner = ""
    }

    private var tokenStatus: String {
        if let dashboard = store.dashboard, !store.needsToken {
            return "@\(dashboard.viewer) via \(dashboard.tokenSource.rawValue)"
        }
        return store.needsToken ? "Not connected" : "Checking…"
    }
}
