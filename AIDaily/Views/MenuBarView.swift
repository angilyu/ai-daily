import SwiftUI

struct MenuBarView: View {
    @Environment(NewsStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.todaysItems.isEmpty {
                Text(store.isRefreshing ? "Fetching headlines…" : "No stories yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.todaysItems.prefix(15)) { item in
                            Button {
                                open(item)
                            } label: {
                                NewsRow(item: item, isUnread: store.isUnread(item))
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open in Browser") { openURL(item.link) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 420)
            }

            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("AI Daily")
                .font(.headline)
            if store.unreadCount > 0 {
                Text("\(store.unreadCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Mark All Read") { store.markAllRead() }
                .buttonStyle(.borderless)
                .disabled(store.unreadCount == 0)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(12)
    }

    /// Reads the story in the app rather than handing it off to a browser.
    private func open(_ item: NewsItem) {
        store.select(item)
        openWindow(id: AIDailyApp.mainWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
