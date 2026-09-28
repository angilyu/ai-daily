import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class NewsStore {
    private(set) var items: [NewsItem] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?
    /// Shared between the window list and the menu bar so both drive the reader.
    var selectedItemID: String?
    /// `nil` means every topic.
    var selectedTopic: Topic? {
        didSet {
            // Topics and channels are alternative lenses on the same list;
            // showing both at once would read as an unexplained empty feed.
            if selectedTopic != nil, selectedChannelID != nil { selectedChannelID = nil }
        }
    }
    /// User-defined channels, compiled from a plain-language prompt.
    var channels: [Channel] = [] {
        didSet { persist() }
    }
    var selectedChannelID: UUID? {
        didSet {
            if selectedChannelID != nil, selectedTopic != nil { selectedTopic = nil }
        }
    }
    var feeds: [Feed] = Feed.builtIn {
        didSet { persist() }
    }
    private var readIDs: Set<String> = []

    /// Items older than this are dropped on every refresh.
    private let retention: TimeInterval = 14 * 24 * 60 * 60
    /// Headroom over the ~400 stories the enabled sources produce in a
    /// fortnight, so a busy news cycle doesn't silently evict the tail.
    private let maxItems = 700
    /// How old the newest fetch may get before the scheduler pulls again.
    private let refreshInterval: TimeInterval = 60 * 60
    /// Floor between attempts, so a failed fetch can't turn the scheduler into
    /// a retry loop while the machine is offline.
    private let retryInterval: TimeInterval = 10 * 60
    private var lastAttempt: Date?
    private var refreshTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var isRestoring = false

    init() {
        restore()
        startScheduler()
        observeWake()
    }

    deinit {
        // No teardown here: `deinit` is nonisolated and can't touch main-actor
        // state. The store lives for the life of the process, and the wake
        // observer captures `self` weakly, so it turns into a no-op either way.
    }

    /// Checks every few minutes and refreshes once the feed data is an hour old.
    private func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            self?.refreshIfStale()
            while !Task.isCancelled {
                // Polling well under the refresh interval keeps the schedule
                // honest after the timer drifts, which it does whenever the
                // machine sleeps through a tick.
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                self.refreshIfStale()
            }
        }
    }

    /// `Task.sleep` stops counting while the machine is asleep, so a lid closed
    /// overnight would otherwise leave stale news sitting there until the next
    /// tick happens to land.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfStale()
            }
        }
    }

    // MARK: - Derived state

    var unreadCount: Int {
        items.filter { !readIDs.contains($0.id) }.count
    }

    func isUnread(_ item: NewsItem) -> Bool {
        !readIDs.contains(item.id)
    }

    var selectedItem: NewsItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    /// Opens a story in the reader and marks it read.
    func select(_ item: NewsItem) {
        selectedItemID = item.id
        markRead(item)
    }

    /// Items published since the start of today, falling back to the newest
    /// items so the list is never empty on a slow news day.
    var todaysItems: [NewsItem] {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let today = items.filter { $0.publishedAt >= startOfDay }
        return today.count >= 5 ? today : Array(items.prefix(25))
    }

    /// Topics present in the current items, ordered by the canonical topic order.
    var availableTopics: [Topic] {
        let present = Set(items.flatMap(\.topics))
        return Topic.allCases.filter(present.contains)
    }

    func matchesSelectedTopic(_ item: NewsItem) -> Bool {
        guard let selectedTopic else { return true }
        return item.topics.contains(selectedTopic)
    }

    // MARK: - Channels

    var selectedChannel: Channel? {
        guard let selectedChannelID else { return nil }
        return channels.first { $0.id == selectedChannelID }
    }

    /// Applies whichever lens is active. A channel ranks by relevance; a topic
    /// filters but preserves the existing reverse-chronological order.
    func applyFilter(to items: [NewsItem]) -> [NewsItem] {
        if let channel = selectedChannel {
            return ChannelMatcher.rank(items, by: channel.rules)
        }
        return items.filter(matchesSelectedTopic)
    }

    /// Why a story matched the active channel, for display in the row.
    func matchReasons(for item: NewsItem) -> [String] {
        guard let channel = selectedChannel else { return [] }
        return ChannelMatcher.match(item, against: channel.rules).reasons
    }

    /// How many stories a set of rules would surface right now, used by the
    /// editor to preview a prompt before it is saved.
    func previewCount(for rules: ChannelRules) -> Int {
        ChannelMatcher.rank(items, by: rules).count
    }

    func save(_ channel: Channel) {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index] = channel
        } else {
            channels.append(channel)
        }
    }

    func deleteChannel(_ channel: Channel) {
        channels.removeAll { $0.id == channel.id }
        if selectedChannelID == channel.id { selectedChannelID = nil }
    }

    // MARK: - Actions

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    func markRead(_ item: NewsItem) {
        guard readIDs.insert(item.id).inserted else { return }
        persist()
    }

    func markAllRead() {
        readIDs.formUnion(items.map(\.id))
        persist()
    }

    /// Refreshes when the newest data is older than the refresh interval.
    /// Manual refreshes bypass this entirely.
    func refreshIfStale() {
        if shouldRefresh(at: .now) { refresh() }
    }

    /// Pure decision so the scheduling rules can be tested without networking.
    func shouldRefresh(at now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryInterval {
            return false
        }

        guard let lastRefresh else { return true }

        // A clock change or a restored future timestamp would otherwise park
        // the app in a state where it never refreshes again.
        let age = now.timeIntervalSince(lastRefresh)
        return age >= refreshInterval || age < 0
    }

    // MARK: - Networking

    private func performRefresh() async {
        isRefreshing = true
        lastAttempt = .now
        defer { isRefreshing = false }

        let enabled = feeds.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            lastError = "No feeds are enabled."
            return
        }

        var fetched: [NewsItem] = []
        var failures: [String] = []

        await withTaskGroup(of: Result<[NewsItem], FeedError>.self) { group in
            for feed in enabled {
                group.addTask {
                    do {
                        var request = URLRequest(url: feed.url)
                        request.timeoutInterval = 20
                        request.setValue("AIDaily/1.0", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            return .failure(FeedError(feedName: feed.name))
                        }
                        return .success(FeedParser.parse(data: data, sourceName: feed.name))
                    } catch {
                        return .failure(FeedError(feedName: feed.name))
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let parsed): fetched.append(contentsOf: parsed)
                case .failure(let error): failures.append(error.feedName)
                }
            }
        }

        merge(fetched)

        if fetched.isEmpty && !failures.isEmpty {
            lastError = "Couldn't reach \(failures.joined(separator: ", "))."
        } else {
            lastError = failures.isEmpty ? nil : "Skipped \(failures.joined(separator: ", "))."
            lastRefresh = .now
        }
        persist()
    }

    private func merge(_ incoming: [NewsItem]) {
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        for item in incoming where byID[item.id] == nil {
            var classified = item
            classified.topics = TopicClassifier.topics(for: item)
            byID[item.id] = classified
        }
        let cutoff = Date.now.addingTimeInterval(-retention)
        items = byID.values
            .filter { $0.publishedAt >= cutoff }
            .sorted { $0.publishedAt > $1.publishedAt }
            .prefix(maxItems)
            .map(\.self)
        readIDs.formIntersection(items.map(\.id))
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var feeds: [Feed]
        var items: [NewsItem]
        var readIDs: [String]
        var lastRefresh: Date?
        /// Optional so snapshots written before channels existed still decode.
        var channels: [Channel]?
    }

    private static var storeURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("AIDaily", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.json")
    }

    private func persist() {
        guard !isRestoring, let url = Self.storeURL else { return }
        let snapshot = Snapshot(
            feeds: feeds,
            items: items,
            readIDs: Array(readIDs),
            lastRefresh: lastRefresh,
            channels: channels
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        guard let url = Self.storeURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }

        // Rebuild from the current built-in set so retired sources drop away,
        // preserving the user's enable/disable choices and any custom feeds.
        let previous = Dictionary(
            snapshot.feeds.map { ($0.url, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var merged = Feed.builtIn.map { builtIn -> Feed in
            var feed = builtIn
            if let saved = previous[builtIn.url] {
                feed.isEnabled = saved.isEnabled
            }
            return feed
        }
        merged.append(contentsOf: snapshot.feeds.filter { !$0.isBuiltIn })
        feeds = merged
        channels = snapshot.channels ?? []

        let retainedSources = Set(merged.map(\.name))
        items = snapshot.items
            .filter { retainedSources.contains($0.sourceName) }
            .map { item in
                guard item.topics.isEmpty else { return item }
                var classified = item
                classified.topics = TopicClassifier.topics(for: item)
                return classified
            }
            .sorted { $0.publishedAt > $1.publishedAt }
        readIDs = Set(snapshot.readIDs)
        lastRefresh = snapshot.lastRefresh
    }
}

private struct FeedError: Error {
    let feedName: String
}
