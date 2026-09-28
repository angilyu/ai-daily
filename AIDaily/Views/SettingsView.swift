import SwiftUI

struct SettingsView: View {
    @Environment(NewsStore.self) private var store

    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        @Bindable var store = store

        Form {
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
        .frame(width: 460, height: 460)
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
