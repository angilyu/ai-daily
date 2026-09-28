import Foundation

/// Builds a short "key points" digest from an already-extracted article.
///
/// This is extractive, not generative: it ranks the article's own sentences and
/// keeps the few that carry the most weight. That keeps the app free of API
/// keys and network round-trips, and means every bullet is text the author
/// actually wrote rather than something invented.
enum Summarizer {
    /// Below this the article is already a quick read and a digest just repeats it.
    private static let minimumWordCount = 220
    private static let maximumPoints = 3

    static func keyPoints(for article: Article, title: String) -> [String] {
        guard article.wordCount >= minimumWordCount else { return [] }

        let sentences = candidateSentences(in: article)
        guard sentences.count >= 4 else { return [] }

        let weights = wordWeights(in: sentences)
        let titleWords = contentWords(in: title)

        let ranked = sentences.enumerated()
            .map { position, sentence -> (index: Int, score: Double, sentence: Sentence) in
                (position, score(sentence, weights: weights, titleWords: titleWords, total: sentences.count), sentence)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        var chosen: [(index: Int, sentence: Sentence)] = []
        for candidate in ranked {
            guard chosen.count < maximumPoints else { break }
            // Two bullets making the same point is worse than one bullet fewer.
            let isRedundant = chosen.contains {
                overlap(candidate.sentence.words, $0.sentence.words) > 0.5
            }
            if !isRedundant {
                chosen.append((candidate.index, candidate.sentence))
            }
        }

        guard chosen.count >= 2 else { return [] }

        // Reading order beats score order: the points should track the article.
        return chosen
            .sorted { $0.index < $1.index }
            .map { tidy($0.sentence.text) }
    }

    // MARK: - Candidate selection

    private struct Sentence {
        let text: String
        let words: Set<String>
        let wordCount: Int
        /// Index of the block this came from, used for a lead-paragraph bonus.
        let blockIndex: Int
    }

    private static func candidateSentences(in article: Article) -> [Sentence] {
        var result: [Sentence] = []

        for (blockIndex, block) in article.blocks.enumerated() {
            // Headings are labels, code is not prose, and images have no text.
            switch block {
            case .paragraph, .quote, .listItem:
                break
            case .heading, .subheading, .code, .image:
                continue
            }

            for text in split(block.text) {
                let words = contentWords(in: text)
                let wordCount = text.split(whereSeparator: \.isWhitespace).count

                // Fragments carry no argument; very long sentences read worse
                // than the paragraph they came from.
                guard wordCount >= 9, wordCount <= 45, !words.isEmpty else { continue }
                guard !isBoilerplate(text) else { continue }
                // Captions, table cells, and headings-in-disguise lack terminal
                // punctuation and read as debris when lifted into a bullet.
                guard endsAsSentence(text) else { continue }

                result.append(
                    Sentence(text: text, words: words, wordCount: wordCount, blockIndex: blockIndex)
                )
            }
        }

        return result
    }

    /// Splits prose into sentences, holding back on abbreviations and decimals
    /// where a period is not a sentence end.
    private static func split(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else {
                index += 1
                continue
            }

            // Run past "?!" and ellipses so they close a single sentence.
            var end = index
            while end + 1 < characters.count,
                  characters[end + 1] == "." || characters[end + 1] == "!" || characters[end + 1] == "?" {
                end += 1
            }

            var next = end + 1
            // Closing quotes and brackets belong to the sentence that ends here.
            while next < characters.count, "\"')]”’".contains(characters[next]) {
                next += 1
            }

            guard next < characters.count else { break }
            guard characters[next].isWhitespace else {
                index = end + 1
                continue
            }

            let following = characters[(next + 1)...].first { !$0.isWhitespace }
            let startsNewSentence = following.map { $0.isUppercase || $0.isNumber || "\"“'([".contains($0) } ?? true

            // A lowercase word after the punctuation means the break was
            // internal — a quoted exclamation, or an abbreviation.
            if !startsNewSentence {
                index = end + 1
                continue
            }
            if character == ".", endsWithAbbreviation(characters, upTo: index) {
                index = end + 1
                continue
            }

            let piece = String(characters[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            start = next
            index = next
        }

        let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Titles, initials, and common abbreviations end in a period without
    /// ending the sentence — "Dr. Chen", "U.S. exports", "vs. Blackwell".
    private static func endsWithAbbreviation(_ characters: [Character], upTo index: Int) -> Bool {
        var cursor = index - 1
        var token = ""
        while cursor >= 0, !characters[cursor].isWhitespace {
            token.insert(characters[cursor], at: token.startIndex)
            cursor -= 1
        }

        // A lone initial: "J. Doe".
        if token.isEmpty { return true }
        // Dotted forms like "U.S." or "e.g." already carry an inner period.
        if token.hasSuffix(".") { return true }
        if token.count == 1 { return true }

        // The token is captured without the period that triggered the split,
        // so restore it before matching the abbreviation list.
        return abbreviations.contains("\(token.lowercased()).")
    }

    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.",
        "vs.", "etc.", "e.g.", "i.e.", "approx.", "est.", "fig.",
        "inc.", "corp.", "ltd.", "co.", "dept.", "gov.", "no.",
        "al.", "ca.", "cf.", "ed.", "vol.", "pp.", "min.", "max.",
        "jan.", "feb.", "mar.", "apr.", "jun.", "jul.", "aug.",
        "sep.", "sept.", "oct.", "nov.", "dec."
    ]

    /// Newsletters and publisher chrome surface as fluent sentences, so they
    /// score well unless they are filtered out explicitly.
    private static func isBoilerplate(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return boilerplateMarkers.contains { lowered.contains($0) }
    }

    /// True when the text closes like a real sentence, allowing for trailing
    /// quotes and brackets.
    private static func endsAsSentence(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !"\"')]”’ ".contains($0) }) else {
            return false
        }
        return last == "." || last == "!" || last == "?"
    }

    private static let boilerplateMarkers: [String] = [
        "subscribe", "sign up", "newsletter", "click here", "read more",
        "follow us", "all rights reserved", "advertisement", "cookie",
        "privacy policy", "terms of service", "sponsored", "you can support",
        "join us", "register now", "this post was", "originally appeared",
        "share this", "comments below", "email us", "free trial"
    ]

    // MARK: - Scoring

    private static func wordWeights(in sentences: [Sentence]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for sentence in sentences {
            // Counted once per sentence, so a word repeated in one paragraph
            // doesn't outrank a term used throughout the piece.
            for word in sentence.words { counts[word, default: 0] += 1 }
        }

        guard let peak = counts.values.max(), peak > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(peak) }
    }

    private static func score(
        _ sentence: Sentence,
        weights: [String: Double],
        titleWords: Set<String>,
        total: Int
    ) -> Double {
        let mass = sentence.words.reduce(0.0) { $0 + (weights[$1] ?? 0) }

        // Divide by a dampened length so long sentences don't win on bulk
        // alone, while still preferring substance over one-liners.
        var value = mass / pow(Double(sentence.words.count), 0.75)

        // News writing front-loads the point.
        if sentence.blockIndex <= 1 {
            value *= 1.35
        } else if Double(sentence.blockIndex) < Double(total) * 0.25 {
            value *= 1.15
        }

        // Sentences echoing the headline are usually on-topic.
        let titleHits = sentence.words.intersection(titleWords).count
        if titleHits > 0 {
            value *= 1 + min(0.3, Double(titleHits) * 0.08)
        }

        // Concrete numbers signal benchmarks, prices, and specs.
        if sentence.text.contains(where: \.isNumber) {
            value *= 1.12
        }

        // A sentence opening with a pronoun or connective depends on the one
        // before it and reads as a non sequitur once lifted out of context.
        // Transcripts are especially full of these.
        if startsWithDanglingReference(sentence.text) {
            value *= 0.4
        }

        // Rhetorical questions set a point up rather than making one.
        if sentence.text.hasSuffix("?") {
            value *= 0.45
        }

        if isConversational(sentence.text) {
            value *= 0.4
        }

        return value
    }

    private static func startsWithDanglingReference(_ text: String) -> Bool {
        let first = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init) ?? ""
        return danglingOpeners.contains(first)
    }

    private static let danglingOpeners: Set<String> = [
        "this", "that", "these", "those", "it", "they", "he", "she",
        "them", "but", "however", "instead", "also", "then",
        "meanwhile", "therefore", "thus", "so", "yet", "still", "here",
        "and", "or", "now", "well", "okay", "right", "plus", "besides",
        "anyway", "next", "finally", "first", "second", "third", "again",
        "indeed", "moreover", "furthermore", "otherwise", "likewise",
        // Subordinating conjunctions open a dependent clause, which reads as
        // half a thought when pulled out on its own.
        "because", "if", "when", "while", "although", "unless", "whereas"
    ]

    /// Spoken-word filler. Transcripts otherwise score well because their
    /// vocabulary matches the article, yet they summarize badly.
    private static func isConversational(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return conversationalMarkers.contains { lowered.contains($0) }
    }

    private static let conversationalMarkers: [String] = [
        "i mean", "you know", "let me", "as i mentioned", "as i said",
        "we're going to", "we are going to", "going to talk about",
        "in this video", "kind of like", "sort of like", "if you will",
        "let's say", "let us say", "so to speak", "and so on", "or whatever"
    ]

    // MARK: - Text helpers

    private static func contentWords(in text: String) -> Set<String> {
        let words = text
            .lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { $0.count > 2 && !stopwords.contains($0) }
        return Set(words)
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let shared = lhs.intersection(rhs).count
        return Double(shared) / Double(min(lhs.count, rhs.count))
    }

    private static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading list punctuation reads oddly once the sentence is a bullet.
        while let first = result.first, "•-–—*".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
        "boy", "did", "its", "let", "put", "say", "she", "too", "use", "that",
        "with", "have", "this", "will", "your", "from", "they", "know", "want",
        "been", "good", "much", "some", "time", "very", "when", "come", "here",
        "just", "like", "long", "make", "many", "over", "such", "take", "than",
        "them", "well", "were", "what", "into", "more", "only", "also", "back",
        "even", "most", "other", "their", "there", "these", "those", "would",
        "could", "should", "about", "after", "before", "because", "which",
        "while", "where", "being", "between", "through", "during", "under",
        "again", "further", "then", "once", "both", "each", "same", "does",
        "doing", "having", "said", "says", "using", "used", "made", "also",
        "however", "still", "already", "though", "since", "without", "within"
    ]
}
