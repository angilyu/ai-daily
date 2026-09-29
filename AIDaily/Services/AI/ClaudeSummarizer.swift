import Foundation

/// Writes an engineer-oriented digest of an article with Claude.
///
/// The extractive `Summarizer` can only lift sentences the author wrote; it
/// can't compress a 2,000-word post into one line or say why it matters. This
/// can, and it is told to stay strictly inside the article's own claims.
enum ClaudeSummarizer {
    struct Generated: Codable, Sendable {
        let tldr: String
        let keyPoints: [String]
        let whyItMatters: String

        enum CodingKeys: String, CodingKey {
            case tldr
            case keyPoints = "key_points"
            case whyItMatters = "why_it_matters"
        }
    }

    /// ~6k tokens. Long enough for nearly every news post; for long papers the
    /// opening carries the claims that matter for a digest anyway.
    private static let characterBudget = 24_000

    static func summarize(title: String, source: String, article: Article, client: ClaudeClient) async throws -> (Generated, ClaudeClient.Usage) {
        let (generated, usage) = try await client.generate(
            Generated.self,
            system: system,
            user: """
                Title: \(title)
                Source: \(source)

                \(text(of: article))
                """,
            schema: schema,
            maxTokens: 2048,
            timeout: 60
        )
        let cleaned = Generated(
            tldr: generated.tldr.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: generated.keyPoints
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n-•*")) }
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { $0 },
            whyItMatters: generated.whyItMatters.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (cleaned, usage)
    }

    static func text(of article: Article) -> String {
        var out = ""
        for block in article.blocks {
            let line: String
            switch block {
            case .heading(let t), .subheading(let t): line = "## \(t)"
            case .paragraph(let t): line = t
            case .quote(let t): line = "> \(t)"
            case .listItem(let t): line = "- \(t)"
            case .code(let t): line = "```\n\(t.prefix(600))\n```"
            case .image: continue
            }
            if out.count + line.count > characterBudget { break }
            out += line + "\n\n"
        }
        return out
    }

    private static let system = """
        You summarize technology news for software and ML engineers. Use only facts \
        stated in the article; never add outside knowledge, speculation, or numbers \
        that aren't in the text.

        tldr: one plain sentence, at most 30 words, saying what actually happened.
        key_points: 2 to 4 short bullets, each under 25 words, with the concrete \
        specifics an engineer would want — model names, parameter counts, benchmark \
        results, hardware, prices, versions, dates, APIs, licenses. No bullet should \
        repeat the tldr. Use fewer bullets for a short or thin article.
        why_it_matters: one sentence on the practical consequence for engineers who \
        build with AI or run it in production. If the article gives no basis for one, \
        return an empty string.

        No markdown, no leading dashes, no "The article says".
        """

    /// Order matters: the headline first, then the detail, then the takeaway.
    private static let schema = """
        {"type":"object","properties":{\
        "tldr":{"type":"string"},\
        "key_points":{"type":"array","items":{"type":"string"}},\
        "why_it_matters":{"type":"string"}},\
        "required":["tldr","key_points","why_it_matters"],"additionalProperties":false}
        """
}

/// Persists Claude summaries so reopening a story — or relaunching the app —
/// never pays for the same summary twice.
actor SummaryCache {
    static let shared = SummaryCache()

    struct Entry: Codable {
        let summary: ClaudeSummarizer.Generated
        let model: String
        let createdAt: Date
    }

    private var entries: [String: Entry]?
    private let maxEntries = 1_500

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIDaily", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("summaries.json")
    }

    func summary(for itemID: String) -> ClaudeSummarizer.Generated? {
        load()[itemID]?.summary
    }

    func store(_ summary: ClaudeSummarizer.Generated, for itemID: String, model: String) {
        var all = load()
        all[itemID] = Entry(summary: summary, model: model, createdAt: .now)
        if all.count > maxEntries {
            let oldest = all.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(all.count - maxEntries)
            for (key, _) in oldest { all.removeValue(forKey: key) }
        }
        entries = all
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }
}
