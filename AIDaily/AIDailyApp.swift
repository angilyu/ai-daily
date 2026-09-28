import SwiftUI

@main
struct AIDailyApp: App {
    static let mainWindowID = "main"

    @State private var store = NewsStore()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            NewsListView()
                .environment(store)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Mark All as Read") { store.markAllRead() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Image(systemName: store.unreadCount > 0 ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
