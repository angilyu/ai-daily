import SwiftUI

struct SettingsView: View {
    @Environment(NewsStore.self) private var store

    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        TabView {
            sourcesTab
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.up.forward") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 520)
    }

    private var sourcesTab: some View {
        @Bindable var store = store

        return Form {
            Section("Sources") {
                ForEach($store.feeds) { $feed in
                    HStack {
                        Toggle(feed.name, isOn: $feed.isEnabled)
                        Spacer()
                        if !feed.isBuiltIn {
                            Button(role: .destructive) {
                                store.feeds.removeAll { $0.id == feed.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Add a Feed") {
                TextField("Name", text: $newName)
                TextField("RSS or Atom URL", text: $newURL)
                if let addError {
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Add Feed", action: addFeed)
                    .disabled(newName.trimmed.isEmpty || newURL.trimmed.isEmpty)
            }

            Section {
                LabeledContent("Last refreshed") {
                    Text(store.lastRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                Text("AI Daily checks your sources about once an hour, and again whenever your Mac wakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFeed() {
        guard let url = URL(string: newURL.trimmed), url.scheme?.hasPrefix("http") == true else {
            addError = "Enter a valid http or https URL."
            return
        }
        guard !store.feeds.contains(where: { $0.url == url }) else {
            addError = "That feed is already in your list."
            return
        }
        store.feeds.append(Feed(name: newName.trimmed, url: url))
        newName = ""
        newURL = ""
        addError = nil
    }
}

private struct AISettingsView: View {
    @State private var settings = AISettings.shared
    @State private var keyInput = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, passed
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                if settings.hasKey {
                    LabeledContent("API key") {
                        HStack(spacing: 8) {
                            Text("••••••••\(settings.keyHint ?? "")")
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) {
                                settings.removeKey()
                                testState = .idle
                            }
                        }
                    }
                    HStack {
                        Button("Test Connection") { runTest() }
                            .disabled(testState == .testing)
                        testLabel
                    }
                } else {
                    SecureField("Anthropic API key", text: $keyInput, prompt: Text("sk-ant-…"))
                    HStack {
                        Button("Save Key") {
                            settings.saveKey(keyInput)
                            keyInput = ""
                            runTest()
                        }
                        .disabled(keyInput.trimmed.isEmpty)
                        Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Stored in your Mac's Keychain. Requests go directly from this Mac to Anthropic and are billed to your account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                Text(settings.model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.channelsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write channel rules")
                        Text("Turns your channel prompt into specific names and terms. About $0.005 per edit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.summariesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Summarize articles")
                        Text("A one-line TL;DR, key points, and why it matters. About $0.01–0.02 per article, cached so each is paid for once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Use Claude to")
            } footer: {
                Text("Without a key, or with these off, AI Daily uses keyword rules and extractive summaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Usage on this Mac") {
                LabeledContent("Requests", value: settings.requestCount.formatted())
                LabeledContent("Estimated cost") {
                    Text(settings.estimatedCost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                }
                Button("Reset Counter") { settings.resetUsage() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var testLabel: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .passed:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            switch await settings.testKey() {
            case .success: testState = .passed
            case .failure(let failure): testState = .failed(failure.message)
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
