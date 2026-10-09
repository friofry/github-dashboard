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

            AutoRestartSection()

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

/// Jenkins sign-in and limits for restarting failed jobs of my pull requests.
struct AutoRestartSection: View {
    @Environment(AutoRestarter.self) private var restarter
    @State private var newToken = ""

    var body: some View {
        @Bindable var restarter = restarter
        Section {
            TextField("Jenkins address", text: $restarter.server, prompt: Text("https://ci.example.com"))
            TextField("Jenkins user", text: $restarter.user, prompt: Text("your Jenkins login"))
            LabeledContent("API token", value: restarter.hasToken ? "Saved in Keychain" : "Not set")
            SecureField("New API token", text: $newToken)
            HStack {
                Button("Save to Keychain") {
                    let value = newToken
                    newToken = ""
                    Task { await restarter.saveToken(value) }
                }
                .disabled(newToken.isEmpty)
                if restarter.hasToken {
                    Button("Remove", role: .destructive) { restarter.removeToken() }
                }
            }
            Toggle("All my pull requests", isOn: $restarter.restartAll)
            TextField("Only these checks", text: $restarter.checks, prompt: Text("every Jenkins check"))
            Stepper("Up to \(restarter.limit) restart\(restarter.limit == 1 ? "" : "s") per check per commit",
                    value: $restarter.limit, in: 1...5)
            if let error = restarter.lastError {
                Text(error).foregroundStyle(.red)
            }
            ForEach(restarter.log.prefix(5)) { entry in
                LabeledContent("\(entry.pullRequest) · \(entry.check)") {
                    Text(entry.error == nil ? entry.date.formatted(.relative(presentation: .named)) : "failed")
                        .foregroundStyle(entry.error == nil ? Color.secondary : .red)
                }
                .help(entry.error ?? "")
            }
        } header: {
            Text("Auto-restart failed CI")
        } footer: {
            Text("""
            Switch it on per pull request with the ↻ button in My PRs, or here for all of them. Only failed checks \
            that link to this Jenkins are restarted; a new commit starts the count again. Make the API token in \
            Jenkins under your name → Security (or Configure) → API Token. Comma separate check names or prefixes, \
            e.g. jenkins/prs/linux.
            """)
        }
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .task { await restarter.checkToken() }
    }
}
