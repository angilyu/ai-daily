import Foundation

/// Turns article HTML into ordered, readable blocks using a readability-style
/// pass: strip chrome, then keep only the subtree that holds the real prose.
enum ArticleExtractor {

    static func extract(html: String, baseURL: URL, itemID: String, title: String) -> Article {
        var parser = Parser(html: html, baseURL: baseURL)
        parser.run()
        let blocks = select(from: parser.blocks, depths: parser.depths, title: title)

        // Some sources ship bare text with <br> separators, or plain-text feed
        // payloads with no markup at all. Fall back to loose text for those.
        if wordCount(of: blocks) < 120 {
            let loose = looseBlocks(from: html, title: title)
            if wordCount(of: loose) > wordCount(of: blocks) {
                let images = blocks.filter { if case .image = $0 { return true }; return false }
                let merged = images + loose
                return Article(itemID: itemID, blocks: merged, isPartial: wordCount(of: loose) < 60)
            }
        }

        return Article(itemID: itemID, blocks: blocks, isPartial: wordCount(of: blocks) < 120)
    }

    private static func wordCount(of blocks: [ArticleBlock]) -> Int {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    // MARK: - Loose text fallback

    private static let breakTags = try? NSRegularExpression(
        pattern: "<br[^>]*>|</p>|</div>|</li>|</h[1-6]>|</tr>",
        options: [.caseInsensitive]
    )

    private static let strippedSections = try? NSRegularExpression(
        pattern: "<(script|style|noscript|svg|nav|header|footer|aside|form|template)\\b[^>]*>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Splits visible text into paragraph-sized chunks when no block elements exist.
    private static func looseBlocks(from html: String, title: String) -> [ArticleBlock] {
        var working = html
        if let strippedSections {
            working = strippedSections.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: " "
            )
        }
        if let breakTags {
            working = breakTags.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: "\n"
            )
        }

        let text = HTMLText.decodeEntities(in: HTMLText.stripTags(from: working))
        var blocks: [ArticleBlock] = []
        var seen = Set<String>()

        for line in text.components(separatedBy: "\n") {
            let chunk = line.collapsingWhitespace()
            guard chunk.count >= 80, isProse(chunk) else { continue }
            if HTMLText.isRestatement(chunk, of: title) { continue }
            guard seen.insert(chunk.lowercased()).inserted else { continue }
            blocks.append(.paragraph(chunk))
        }
        return blocks
    }

    /// Distinguishes sentences from nav menus and tag lists, which the loose
    /// pass would otherwise sweep up alongside the real body text.
    private static func isProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 12 else { return false }

        // Real paragraphs end sentences; menus and breadcrumbs don't.
        guard text.contains(". ") || text.hasSuffix(".")
                || text.contains("? ") || text.contains("! ") else { return false }

        let capitalized = words.count { $0.first?.isUppercase == true }
        return Double(capitalized) / Double(words.count) < 0.5
    }

    // MARK: - Choosing the content subtree

    private static func select(
        from candidates: [Candidate],
        depths: [Int: Int],
        title: String
    ) -> [ArticleBlock] {
        guard !candidates.isEmpty else { return [] }

        // Score every ancestor by the prose it contains.
        var scores: [Int: Int] = [:]
        for candidate in candidates where candidate.kind == .paragraph {
            let weight = candidate.text.count
            guard weight >= 25 else { continue }
            for ancestor in candidate.ancestors {
                scores[ancestor, default: 0] += weight
            }
        }

        let best = scores.values.max() ?? 0
        var chosen: Int?
        if best > 0 {
            let threshold = Int(Double(best) * 0.65)
            // The deepest container still holding most of the prose is the article body.
            chosen = scores
                .filter { $0.value >= threshold }
                .max { lhs, rhs in
                    let lhsDepth = depths[lhs.key] ?? 0
                    let rhsDepth = depths[rhs.key] ?? 0
                    return lhsDepth == rhsDepth ? lhs.value < rhs.value : lhsDepth < rhsDepth
                }?.key
        }

        let kept: [Candidate]
        if let chosen {
            kept = candidates.filter { $0.ancestors.contains(chosen) }
        } else {
            kept = candidates
        }

        return clean(kept, title: title)
    }

    // MARK: - Post-filtering

    private static let boilerplate = [
        "sign up", "subscribe", "newsletter", "share this", "read more",
        "advertisement", "related stories", "follow us", "cookie",
        "all rights reserved", "terms of service", "privacy policy"
    ]

    private static func clean(_ candidates: [Candidate], title: String) -> [ArticleBlock] {
        var blocks: [ArticleBlock] = []
        var seenText = Set<String>()
        var seenImages = Set<String>()

        for candidate in candidates {
            if case .image = candidate.kind {
                guard let url = candidate.imageURL, seenImages.insert(url.absoluteString).inserted else { continue }
                blocks.append(.image(url))
                continue
            }

            let text = candidate.text
            guard text.count >= 2 else { continue }

            // Nav menus masquerade as lists; real list items are sentences.
            if candidate.kind == .listItem && text.count < 45 { continue }

            let lowered = text.lowercased()
            if text.count < 90, boilerplate.contains(where: { lowered.contains($0) }) { continue }

            // The title is rendered separately in the reader header.
            if HTMLText.isRestatement(text, of: title) { continue }

            guard seenText.insert(lowered).inserted else { continue }

            switch candidate.kind {
            case .heading: blocks.append(.heading(text))
            case .subheading: blocks.append(.subheading(text))
            case .paragraph: blocks.append(.paragraph(text))
            case .quote: blocks.append(.quote(text))
            case .listItem: blocks.append(.listItem(text))
            case .code: blocks.append(.code(text))
            case .image: break
            }
        }

        // Trailing headings with no prose under them are section chrome.
        while let last = blocks.last, case .subheading = last { blocks.removeLast() }
        while let last = blocks.last, case .heading = last { blocks.removeLast() }

        return blocks
    }

    // MARK: - Candidates

    fileprivate enum BlockKind {
        case heading, subheading, paragraph, quote, listItem, code, image
    }

    fileprivate struct Candidate {
        let kind: BlockKind
        let text: String
        let ancestors: [Int]
        let imageURL: URL?
    }

    // MARK: - Parser

    fileprivate struct Parser {
        private let bytes: [UInt8]
        private let baseURL: URL
        var blocks: [Candidate] = []
        var depths: [Int: Int] = [:]

        private var stack: [(name: String, id: Int, skipped: Bool)] = []
        private var nextID = 0
        private var skipCount = 0
        private var buffer: [UInt8] = []
        private var openBlock: (kind: BlockKind, ancestors: [Int])?
        /// Set after a `<br>`; a second one before any text splits the block.
        private var pendingBreak = false

        init(html: String, baseURL: URL) {
            self.bytes = Array(html.utf8)
            self.baseURL = baseURL
        }

        private static let skipTags: Set<String> = [
            "script", "style", "noscript", "svg", "nav", "header", "footer",
            "aside", "form", "iframe", "button", "select", "textarea",
            "template", "figcaption", "video", "audio", "canvas",
            "label", "object", "embed", "map", "dialog"
        ]

        /// Never treated as chrome, whatever classes they carry.
        private static let structuralTags: Set<String> = [
            "html", "body", "main", "article"
        ]

        private static let rawTextTags: Set<String> = [
            "script", "style", "noscript", "textarea", "title", "template", "svg"
        ]

        private static let voidTags: Set<String> = [
            "br", "img", "hr", "meta", "link", "input", "source", "col",
            "area", "base", "embed", "param", "track", "wbr"
        ]

        private static let junkAttributes = [
            "share", "related", "newsletter", "promo", "advert", "subscribe",
            "comment", "sidebar", "menu", "breadcrumb", "cookie",
            "social", "recirc", "teaser", "byline", "caption",
            "toolbar", "banner", "popup", "modal", "navigation"
        ]

        mutating func run() {
            var index = 0
            let count = bytes.count

            while index < count {
                if bytes[index] == UInt8(ascii: "<") {
                    if isCommentStart(at: index) {
                        index = endOfComment(from: index)
                        continue
                    }
                    guard let close = indexOfGreaterThan(from: index + 1) else { break }
                    let raw = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                    if let rawTextTag = handle(tag: raw) {
                        // Script/style bodies are raw text: their contents routinely
                        // contain `<` and `>` that must not be parsed as markup.
                        index = endOfRawText(tag: rawTextTag, from: close + 1)
                        continue
                    }
                    index = close + 1
                } else {
                    if openBlock != nil, skipCount == 0 {
                        let byte = bytes[index]
                        if byte > UInt8(ascii: " ") { pendingBreak = false }
                        buffer.append(byte)
                    }
                    index += 1
                }
            }

            flush()
        }

        // MARK: Scanning helpers

        private func isCommentStart(at index: Int) -> Bool {
            index + 3 < bytes.count
                && bytes[index + 1] == UInt8(ascii: "!")
                && bytes[index + 2] == UInt8(ascii: "-")
                && bytes[index + 3] == UInt8(ascii: "-")
        }

        private func endOfComment(from index: Int) -> Int {
            var cursor = index + 4
            while cursor + 2 < bytes.count {
                if bytes[cursor] == UInt8(ascii: "-")
                    && bytes[cursor + 1] == UInt8(ascii: "-")
                    && bytes[cursor + 2] == UInt8(ascii: ">") {
                    return cursor + 3
                }
                cursor += 1
            }
            return bytes.count
        }

        private func indexOfGreaterThan(from index: Int) -> Int? {
            var cursor = index
            while cursor < bytes.count {
                if bytes[cursor] == UInt8(ascii: ">") { return cursor }
                cursor += 1
            }
            return nil
        }

        // MARK: Tag handling

        /// Returns the tag name when the element's body must be skipped as raw text.
        private mutating func handle(tag raw: String) -> String? {
            guard !raw.isEmpty, !raw.hasPrefix("!"), !raw.hasPrefix("?") else { return nil }

            let isClosing = raw.hasPrefix("/")
            let body = isClosing ? String(raw.dropFirst()) : raw
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            guard !name.isEmpty else { return nil }

            if isClosing {
                close(name)
                return nil
            }

            let selfClosing = body.hasSuffix("/") || Self.voidTags.contains(name)

            if name == "img" {
                captureImage(from: body)
                return nil
            }
            if name == "br", let open = openBlock {
                // Newsletter markup often wraps a whole article in one <p> and
                // separates paragraphs with <br><br>. A single break is a line
                // break; a double break starts a new block, otherwise the piece
                // renders as one unreadable wall of text.
                if pendingBreak {
                    flush()
                    openBlock = open
                    pendingBreak = false
                } else {
                    buffer.append(UInt8(ascii: " "))
                    pendingBreak = true
                }
                return nil
            }
            if selfClosing { return nil }
            if Self.rawTextTags.contains(name) { return name }

            let kind = blockKind(for: name)
            // Junk-class filtering applies to non-structural containers only:
            // publishers put classes like "paywall" on real body paragraphs, and
            // site-wide chrome classes routinely land on <body> itself.
            let isChrome = kind == nil
                && !Self.structuralTags.contains(name)
                && hasJunkAttribute(body)
            let skipped = Self.skipTags.contains(name) || isChrome
            nextID += 1
            let id = nextID
            depths[id] = stack.count
            stack.append((name: name, id: id, skipped: skipped))
            if skipped { skipCount += 1 }

            guard skipCount == 0, let kind else { return nil }
            flush()
            openBlock = (kind: kind, ancestors: stack.map(\.id))
            return nil
        }

        /// Scans to just past the matching close tag of a raw-text element.
        private func endOfRawText(tag: String, from index: Int) -> Int {
            let needle = Array("</\(tag)".utf8)
            var cursor = index

            while cursor + needle.count <= bytes.count {
                if bytes[cursor] == UInt8(ascii: "<"), matchesNeedle(needle, at: cursor) {
                    return indexOfGreaterThan(from: cursor).map { $0 + 1 } ?? bytes.count
                }
                cursor += 1
            }
            return bytes.count
        }

        private func matchesNeedle(_ needle: [UInt8], at start: Int) -> Bool {
            for offset in 0..<needle.count {
                if lowercased(bytes[start + offset]) != needle[offset] { return false }
            }
            // Guard against `</scriptish>` matching `</script`.
            let next = start + needle.count
            guard next < bytes.count else { return true }
            let following = bytes[next]
            return following == UInt8(ascii: ">")
                || following == UInt8(ascii: "/")
                || following == UInt8(ascii: " ")
        }

        private func lowercased(_ byte: UInt8) -> UInt8 {
            (byte >= 65 && byte <= 90) ? byte + 32 : byte
        }

        private mutating func close(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.name == name }) else { return }

            if blockKind(for: name) != nil { flush() }

            for entry in stack[position...] where entry.skipped {
                skipCount -= 1
            }
            stack.removeSubrange(position...)
        }

        private func blockKind(for name: String) -> BlockKind? {
            switch name {
            case "p": .paragraph
            case "h1", "h2": .heading
            case "h3", "h4": .subheading
            case "blockquote": .quote
            case "li": .listItem
            case "pre": .code
            default: nil
            }
        }

        private mutating func flush() {
            defer { buffer.removeAll(keepingCapacity: true); openBlock = nil }
            guard let openBlock else { return }
            let text = HTMLText
                .decodeEntities(in: String(decoding: buffer, as: UTF8.self))
                .collapsingWhitespace()
            guard !text.isEmpty else { return }
            blocks.append(
                Candidate(kind: openBlock.kind, text: text, ancestors: openBlock.ancestors, imageURL: nil)
            )
        }

        private mutating func captureImage(from body: String) {
            guard skipCount == 0 else { return }
            let source = attribute("src", in: body)
                ?? attribute("data-src", in: body)
                ?? attribute("data-original", in: body)
            guard let source, let url = resolvedImageURL(source) else { return }

            // Skip tracking pixels, logos, and other chrome.
            let lowered = url.absoluteString.lowercased()
            let junk = ["pixel", "logo", "icon", "avatar", "badge", "spacer",
                        "1x1", "track", "beacon", "sprite", "placeholder", "emoji"]
            if junk.contains(where: { lowered.contains($0) }) { return }
            if lowered.hasSuffix(".svg") || lowered.hasPrefix("data:") { return }
            if let width = Int(attribute("width", in: body) ?? ""), width < 200 { return }

            blocks.append(
                Candidate(kind: .image, text: "", ancestors: stack.map(\.id), imageURL: url)
            )
        }

        private func resolvedImageURL(_ source: String) -> URL? {
            // srcset-style values list several candidates; take the first.
            let first = source
                .split(separator: ",")
                .first?
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? source
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }

        private func hasJunkAttribute(_ body: String) -> Bool {
            let classes = (attribute("class", in: body) ?? "").lowercased()
            let identifier = (attribute("id", in: body) ?? "").lowercased()
            guard !classes.isEmpty || !identifier.isEmpty else { return false }
            let combined = classes + " " + identifier
            return Self.junkAttributes.contains { combined.contains($0) }
        }

        private func attribute(_ name: String, in body: String) -> String? {
            guard let range = body.range(of: "\(name)=", options: [.caseInsensitive]) else { return nil }

            // Make sure we matched a whole attribute name, not a suffix of one.
            if range.lowerBound > body.startIndex {
                let previous = body[body.index(before: range.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "-" { return nil }
            }

            var cursor = range.upperBound
            guard cursor < body.endIndex else { return nil }

            let quote = body[cursor]
            if quote == "\"" || quote == "'" {
                cursor = body.index(after: cursor)
                guard let end = body[cursor...].firstIndex(of: quote) else { return nil }
                return String(body[cursor..<end])
            }
            let end = body[cursor...].firstIndex { $0.isWhitespace } ?? body.endIndex
            return String(body[cursor..<end])
        }
    }
}
