import Foundation

/// Scores a story against a channel's rules.
///
/// Scoring rather than hard filtering: a channel should degrade into "less
/// relevant first" rather than an empty list, which is what keyword filters
/// usually do to people. Exclusions are the one hard rule, because "not X"
/// is an explicit instruction.
enum ChannelMatcher {
    struct Match {
        var score: Int
        /// The terms that actually fired, shown in the row so the user can see
        /// why a story is here and fix the rule if it's wrong.
        var reasons: [String]

        var isMatch: Bool { score > 0 }
    }

    static func match(_ item: NewsItem, against rules: ChannelRules) -> Match {
        guard !rules.include.isEmpty else { return Match(score: 0, reasons: []) }

        let title = normalize(item.title)
        let body = normalize("\(item.summary) \(item.sourceName)")

        for term in rules.exclude where contains(term.text, in: title) || contains(term.text, in: body) {
            return Match(score: 0, reasons: [])
        }

        var score = 0
        var reasons: [String] = []

        for term in rules.include {
            let inTitle = contains(term.text, in: title)
            let inBody = contains(term.text, in: body)
            guard inTitle || inBody else { continue }

            // A headline hit is a much stronger signal than a passing mention
            // in the summary blurb.
            score += inTitle ? term.weight * 3 : term.weight
            reasons.append(term.text)
        }

        // Rank the explanation by weight so the chips show the strongest
        // reason first, not whichever term happened to be alphabetically low.
        let order = Dictionary(rules.include.map { ($0.text, $0.weight) }, uniquingKeysWith: max)
        reasons.sort { (order[$0] ?? 0) > (order[$1] ?? 0) }

        return Match(score: score, reasons: Array(reasons.prefix(3)))
    }

    /// Sorted best-first, with recency breaking ties so a channel still reads
    /// like a news feed rather than a static ranking.
    static func rank(_ items: [NewsItem], by rules: ChannelRules) -> [NewsItem] {
        var scored: [(item: NewsItem, score: Int, date: Date)] = []
        for item in items {
            let result = match(item, against: rules)
            if result.isMatch {
                scored.append((item, result.score, item.publishedAt))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.date > rhs.date : lhs.score > rhs.score
        }
        return scored.map(\.item)
    }

    /// Padded with spaces so `contains` is whole-word: "ram" must not fire on
    /// "program", and "ai" must not fire on "said".
    private static func normalize(_ text: String) -> String {
        let cleaned = text.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            // Keep the separators that appear inside real technical terms.
            if character == "-" || character == "." || character == "+" { return character }
            return " "
        }
        return " \(String(cleaned)) "
    }

    private static func contains(_ term: String, in normalized: String) -> Bool {
        guard !term.isEmpty else { return false }
        return normalized.contains(" \(term.lowercased()) ")
    }
}
