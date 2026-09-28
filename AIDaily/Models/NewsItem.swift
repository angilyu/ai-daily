import Foundation

struct NewsItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let link: URL
    let sourceName: String
    let publishedAt: Date
    let summary: String
    /// Full article markup when the feed supplies it, so the reader can skip a fetch.
    var contentHTML: String?
    /// Assigned by the store so filtering doesn't reclassify on every render.
    var topics: [Topic] = []

    init(
        title: String,
        link: URL,
        sourceName: String,
        publishedAt: Date,
        summary: String,
        contentHTML: String? = nil
    ) {
        self.id = link.absoluteString
        self.title = title
        self.link = link
        self.sourceName = sourceName
        self.publishedAt = publishedAt
        self.summary = summary
        self.contentHTML = contentHTML
    }
}

extension NewsItem {
    var relativeAge: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: publishedAt, relativeTo: .now)
    }
}
