import Foundation
import Observation

@MainActor
@Observable
final class ArticleLoader {
    enum State {
        case idle
        case loading
        case loaded(Article)
        /// Extraction produced too little to read; the reader shows a fallback.
        case unavailable(String)
    }

    enum SummaryStatus: Equatable {
        case idle
        case generating
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var summaryStatus: SummaryStatus = .idle
    private var cache: [String: Article] = [:]
    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var currentItem: NewsItem?

    /// Below this there's nothing worth compressing; the reader sees it all
    /// on one screen anyway.
    private let minimumWordsForClaude = 150

    private let browserUserAgent = """
        Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
        AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15
        """

    func load(_ item: NewsItem) {
        task?.cancel()
        summaryTask?.cancel()
        summaryStatus = .idle
        currentItem = item

        if let cached = cache[item.id] {
            state = cached.isPartial
                ? .unavailable("This site doesn't share the full article.")
                : .loaded(cached)
            if !cached.isPartial { enhanceSummary(cached, item: item) }
            return
        }

        state = .loading
        let userAgent = browserUserAgent

        task = Task { [weak self] in
            let article = await Self.buildArticle(for: item, userAgent: userAgent)
            guard !Task.isCancelled, let self else { return }

            self.cache[item.id] = article
            self.state = article.isPartial
                ? .unavailable("This site doesn't share the full article.")
                : .loaded(article)
            if !article.isPartial { self.enhanceSummary(article, item: item) }
        }
    }

    func clear() {
        task?.cancel()
        summaryTask?.cancel()
        currentItem = nil
        summaryStatus = .idle
        state = .idle
    }

    func retrySummary() {
        guard let item = currentItem, let article = cache[item.id] else { return }
        enhanceSummary(article, item: item)
    }

    // MARK: - Claude summary

    /// The article renders immediately with the extractive digest; Claude's
    /// summary replaces it in place when it arrives. Reading never waits on
    /// the network.
    private func enhanceSummary(_ article: Article, item: NewsItem) {
        guard article.summarySource != .claude,
              article.wordCount >= minimumWordsForClaude,
              let client = AISettings.shared.client(for: .summaries)
        else { return }

        summaryStatus = .generating
        summaryTask = Task { [weak self] in
            if let cached = await SummaryCache.shared.summary(for: item.id) {
                self?.install(cached, on: article, item: item)
                return
            }
            do {
                let (summary, usage) = try await ClaudeSummarizer.summarize(
                    title: item.title,
                    source: item.sourceName,
                    article: article,
                    client: client
                )
                AISettings.shared.record(usage)
                await SummaryCache.shared.store(summary, for: item.id, model: client.model.rawValue)
                guard !Task.isCancelled else { return }
                self?.install(summary, on: article, item: item)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.currentItem?.id == item.id else { return }
                let failure = (error as? ClaudeClient.Failure)?.message ?? error.localizedDescription
                self.summaryStatus = .failed(failure)
            }
        }
    }

    private func install(_ summary: ClaudeSummarizer.Generated, on article: Article, item: NewsItem) {
        var updated = article
        updated.apply(summary)
        cache[item.id] = updated
        guard currentItem?.id == item.id else { return }
        state = .loaded(updated)
        summaryStatus = .idle
    }

    // MARK: - Extraction

    /// Extracts from both the feed payload and the live page, keeping whichever
    /// reads better. Feeds often carry only a teaser; some pages are JS-only.
    private nonisolated static func buildArticle(
        for item: NewsItem,
        userAgent: String
    ) async -> Article {
        var best: Article?

        /// Raw word count is a poor judge on its own: a page that collapses into
        /// one undifferentiated blob can out-count properly separated prose and
        /// then render as a wall of text. Reward paragraph structure so a
        /// slightly shorter but readable extraction wins.
        func score(_ article: Article) -> Double {
            guard article.wordCount > 0 else { return 0 }
            let wordsPerBlock = Double(article.wordCount) / Double(max(1, article.blocks.count))
            let structurePenalty = wordsPerBlock > 250 ? 0.5 : 1.0
            return Double(article.wordCount) * structurePenalty
        }

        func consider(_ html: String, baseURL: URL) {
            let article = ArticleExtractor.extract(
                html: html,
                baseURL: baseURL,
                itemID: item.id,
                title: item.title
            )
            if score(article) > score(best ?? Article(itemID: item.id, blocks: [], isPartial: true)) {
                best = article
            }
        }

        if let feedHTML = item.contentHTML {
            consider(feedHTML, baseURL: item.link)
        }

        // Skip the fetch when the feed already gave us a complete article.
        if (best?.wordCount ?? 0) < 700, let html = await fetchHTML(item.link, userAgent: userAgent) {
            consider(html, baseURL: item.link)
        }

        guard var article = best else {
            return Article(itemID: item.id, blocks: [], isPartial: true)
        }

        // Summarizing here keeps the work off the main thread and out of view
        // bodies, and the loader's cache means it runs once per article.
        article.keyPoints = Summarizer.keyPoints(for: article, title: item.title)
        return article
    }

    private nonisolated static func fetchHTML(_ url: URL, userAgent: String) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }

        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}
