import Foundation

/// A single renderable piece of an extracted article.
enum ArticleBlock: Identifiable, Hashable, Codable {
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case quote(String)
    case listItem(String)
    case code(String)
    case image(URL)

    var id: String {
        switch self {
        case .heading(let text): "h|\(text)"
        case .subheading(let text): "s|\(text)"
        case .paragraph(let text): "p|\(text)"
        case .quote(let text): "q|\(text)"
        case .listItem(let text): "l|\(text)"
        case .code(let text): "c|\(text)"
        case .image(let url): "i|\(url.absoluteString)"
        }
    }

    var text: String {
        switch self {
        case .heading(let text), .subheading(let text), .paragraph(let text),
             .quote(let text), .listItem(let text), .code(let text):
            text
        case .image:
            ""
        }
    }
}

struct Article: Codable, Hashable {
    let itemID: String
    var blocks: [ArticleBlock]
    /// True when extraction produced too little text to be worth reading in-app.
    var isPartial: Bool
    /// Short digest shown above the article. Empty when the piece is already
    /// brief enough that a summary would just repeat it.
    var keyPoints: [String] = []
    /// One-line takeaway. Only Claude writes these; extraction can't compress.
    var tldr: String?
    var whyItMatters: String?
    var summarySource: SummarySource = .extractive

    enum SummarySource: String, Codable, Hashable {
        /// Sentences lifted from the article by `Summarizer`.
        case extractive
        case claude
    }

    var hasSummary: Bool { tldr != nil || !keyPoints.isEmpty }

    mutating func apply(_ summary: ClaudeSummarizer.Generated) {
        tldr = summary.tldr.isEmpty ? nil : summary.tldr
        keyPoints = summary.keyPoints
        whyItMatters = summary.whyItMatters.isEmpty ? nil : summary.whyItMatters
        summarySource = .claude
    }

    var wordCount: Int {
        blocks.reduce(0) { total, block in
            total + block.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    var readingMinutes: Int {
        max(1, Int((Double(wordCount) / 225.0).rounded()))
    }
}
