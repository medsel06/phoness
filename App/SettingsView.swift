import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var control = Control.shared
    @State private var auth = ClaudeAuth.shared
    @AppStorage("provider") private var provider = Providers.all[0].id
    @AppStorage("model") private var model = Providers.all[0].models[0].id
    @AppStorage("custom.url") private var customURL = ""
    // one keychain item per provider, named by its id. anthropic's was always "anthropic"
    @State private var key = Keychain.get(Providers.current.id) ?? ""
    @State private var loginCode = ""
    @State private var loginError: String?
    @State private var keyError: String?

    private var p: Provider { Providers.find(provider) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(Providers.all) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                    if !p.models.isEmpty {
                        Picker("Model", selection: $model) {
                            ForEach(p.models, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    TextField("model id", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Model ID")
                } header: {
                    Text("Model")
                }

                if p.api == .anthropic { claudeLogin }

                if p.id == "custom" {
                    Section("Server") {
                        TextField("https://example.com/v1", text: $customURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Base URL")
                    }
                }

                Section {
                    SecureField(p.hint, text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: key) {
                            do {
                                try Keychain.set(provider, key.trimmingCharacters(in: .whitespacesAndNewlines))
                                keyError = nil
                            } catch {
                                keyError = error.localizedDescription
                            }
                        }
                    if let keyError {
                        Text(keyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("\(p.name) API key")
                } footer: {
                    Text(p.api == .anthropic
                        ? "kept in the keychain on this \(Device.name). used when signed out of claude."
                        : "kept in the keychain on this \(Device.name).")
                }

                Section("Agent") {
                    NavigationLink {
                        ControlView()
                    } label: {
                        LabeledContent {
                            Text(control.phase.label)
                        } label: {
                            Label("\(Device.name) Control", systemImage: "hand.tap")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // each provider keeps its own model and key
            .onChange(of: provider) { old, new in
                UserDefaults.standard.set(model, forKey: "model.\(old)")
                model = Providers.remembered(Providers.find(new))
                key = Keychain.get(new) ?? ""
                keyError = nil
            }
        }
    }

    private var claudeLogin: some View {
        Section {
            if auth.isSignedIn {
                Text("signed in")
                Button("sign out", role: .destructive) {
                    do {
                        try auth.signOut()
                        loginCode = ""
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("claude.signOut")
            } else if auth.pendingLogin {
                Text("finish signing in in your browser, then paste the code here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("authorization code", text: $loginCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(auth.isExchanging)
                    .accessibilityIdentifier("claude.code")
                Button {
                    loginError = nil
                    Task {
                        do {
                            try await auth.finishSignIn(loginCode)
                            loginCode = ""
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Text(auth.isExchanging ? "signing in…" : "finish sign in")
                        if auth.isExchanging { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(auth.isExchanging || loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("claude.finish")
                if let url = auth.authorizationURL {
                    Button("reopen browser") { openLogin(url) }
                        .disabled(auth.isExchanging)
                }
                Button("cancel sign in", role: .cancel) {
                    do {
                        try auth.cancelSignIn()
                        loginCode = ""
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
                .disabled(auth.isExchanging)
                .accessibilityIdentifier("claude.cancel")
            } else {
                Button("sign in with claude") {
                    do {
                        loginError = nil
                        openLogin(try auth.beginSignIn())
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("claude.signIn")
            }
            if let loginError {
                Text(loginError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("claude login")
        } footer: {
            Text("experimental. anthropic may reject subscription access from this app, even after sign in.")
        }
    }

    private func openLogin(_ url: URL) {
        openURL(url) { accepted in
            if !accepted {
                loginError = "couldn't open the browser. tap reopen browser to try again."
            }
        }
    }
}

struct ControlView: View {
    @State private var control = Control.shared
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if control.phase == .starting { ProgressView().controlSize(.small) }
                        Text(control.phase.label)
                    }
                }
                if !control.message.isEmpty {
                    Text(control.message)
                        .font(.footnote)
                        .foregroundStyle(control.phase == .failed ? .red : .secondary)
                }
                switch control.phase {
                case .off, .failed:
                    Button("Turn On") { control.start() }
                        .disabled(!ready)
                case .starting:
                    // elle kapatınca köprü bekçisi Runner'ı yeniden açmasın
                    Button("Cancel", role: .cancel) { Task { await BridgeKeeper.shared.end() }; control.stop() }
                case .on:
                    Button("Turn Off", role: .destructive) { Task { await BridgeKeeper.shared.end() }; control.stop() }
                }
            } footer: {
                Text("Starts a UI test runner on this \(Device.name) through a local VPN, so the agent can see the screen and tap anywhere. iOS asks for your passcode each time it starts.")
            }

            Section {
                LabeledContent("Pairing file") {
                    Text(control.hasPairing ? "Ready" : "Missing")
                }
                Button(control.hasPairing ? "Replace Pairing File" : "Import Pairing File") { importing = true }
                LabeledContent("Developer disk image") {
                    Text(Control.ddiDir == nil ? "Missing" : "Included")
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("scripts/setup.sh puts the pairing file here. Import one only if you made it some other way.")
            }

        }
        .navigationTitle("\(Device.name) Control")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
            if case .success(let url) = result { control.importPairing(from: url) }
        }
        .task {
            // setup.sh may have dropped a pairing file in while the app was running
            Control.securePairing()
            control.hasPairing = Control.pairingURL != nil
            // pick up a runner started from xcode
            if control.phase == .off, await Runner.alive() { _ = await control.ensureOn() }
        }
    }

    private var ready: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        control.hasPairing && Control.ddiDir != nil
        #endif
    }
}

extension Control.Phase {
    var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .on: "On"
        case .failed: "Failed"
        }
    }
}
