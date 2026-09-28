import SwiftUI

struct NewsListView: View {
    @Environment(NewsStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var scope: Scope = .today
    @State private var searchText = ""
    @State private var isCreatingChannel = false
    @State private var editingChannel: Channel?

    enum Scope: String, CaseIterable, Identifiable {
        case today = "Today"
        case unread = "Unread"
        case all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            sidebar(selection: $store.selectedItemID)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            ReaderView(item: store.selectedItem)
        }
        .navigationTitle("AI Daily")
    }

    private func sidebar(selection: Binding<String?>) -> some View {
        VStack(spacing: 0) {
            if let error = store.lastError {
                banner(error)
            }

            if !store.items.isEmpty {
                // Always visible: a channel that matches nothing must not hide
                // the only control that gets you back out of it.
                topicBar
            }

            if visibleItems.isEmpty {
                emptyState
            } else {
                List(visibleItems, selection: selection) { item in
                    NewsRow(
                        item: item,
                        isUnread: store.isUnread(item),
                        matchReasons: store.matchReasons(for: item)
                    )
                        .tag(item.id)
                        .contextMenu {
                            Button("Open in Browser") { openURL(item.link) }
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.link.absoluteString, forType: .string)
                            }
                        }
                }
                .listStyle(.inset)
                .onChange(of: selection.wrappedValue) { _, newValue in
                    guard let newValue,
                          let item = store.items.first(where: { $0.id == newValue })
                    else { return }
                    store.markRead(item)
                }
            }
        }
        .sheet(isPresented: $isCreatingChannel) {
            ChannelEditor(existing: nil)
        }
        .sheet(item: $editingChannel) { channel in
            ChannelEditor(existing: channel)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search headlines")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    store.refresh()
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .help("Refresh now")
            }
        }
    }

    private var visibleItems: [NewsItem] {
        let base: [NewsItem]
        switch scope {
        case .today: base = store.todaysItems
        case .unread: base = store.items.filter { store.isUnread($0) }
        case .all: base = store.items
        }

        // A channel searches everything rather than just today's stories —
        // a narrow prompt would otherwise usually show an empty list.
        let source = store.selectedChannel == nil ? base : store.items
        let scoped = store.applyFilter(to: source)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.sourceName.localizedCaseInsensitiveContains(query)
        }
    }

    private var topicBar: some View {
        @Bindable var store = store

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", isOn: store.selectedTopic == nil && store.selectedChannelID == nil) {
                    store.selectedTopic = nil
                    store.selectedChannelID = nil
                }

                ForEach(store.channels) { channel in
                    chip(
                        title: channel.name,
                        symbol: channel.compiler == .onDevice ? "sparkles" : "line.3.horizontal.decrease",
                        isOn: store.selectedChannelID == channel.id
                    ) {
                        store.selectedChannelID = store.selectedChannelID == channel.id ? nil : channel.id
                    }
                    .contextMenu {
                        Button("Edit…") { editingChannel = channel }
                        Button("Delete", role: .destructive) { store.deleteChannel(channel) }
                    }
                }

                chip(title: "New Channel", symbol: "plus", isOn: false) {
                    isCreatingChannel = true
                }

                if !store.availableTopics.isEmpty {
                    Divider().frame(height: 16).padding(.horizontal, 2)
                }

                ForEach(store.availableTopics) { topic in
                    chip(
                        title: topic.shortName,
                        symbol: topic.symbol,
                        isOn: store.selectedTopic == topic
                    ) {
                        store.selectedTopic = store.selectedTopic == topic ? nil : topic
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func chip(
        title: String,
        symbol: String? = nil,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title)
            }
            .font(.caption.weight(isOn ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyTitle,
                systemImage: store.selectedChannel == nil ? "sparkles.rectangle.stack" : "line.3.horizontal.decrease"
            )
        } description: {
            Text(emptyMessage)
        } actions: {
            if let channel = store.selectedChannel {
                Button("Edit Channel") { editingChannel = channel }
                    .buttonStyle(.borderedProminent)
                Button("Show Everything") { store.selectedChannelID = nil }
            } else if !store.isRefreshing {
                Button("Refresh") { store.refresh() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if store.selectedChannel != nil { return "Nothing in this channel" }
        return store.isRefreshing ? "Fetching headlines…" : "Nothing here yet"
    }

    private var emptyMessage: String {
        if let channel = store.selectedChannel {
            return "No stories match “\(channel.prompt)” right now. Loosen the rules, or wait for the next refresh."
        }
        return store.isRefreshing
            ? "Pulling the latest AI news from your feeds."
            : "Pull the latest AI news to get started."
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.quaternary)
    }
}
