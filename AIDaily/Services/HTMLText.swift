import Foundation

/// Shared helpers for turning raw feed/article markup into display text.
enum HTMLText {
    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&nbsp;": " ", "&hellip;": "…",
        "&mdash;": "—", "&ndash;": "–", "&rsquo;": "'", "&lsquo;": "'",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&middot;": "·",
        "&bull;": "•", "&trade;": "™", "&copy;": "©", "&reg;": "®",
        "&deg;": "°", "&euro;": "€", "&pound;": "£", "&times;": "×"
    ]

    private static let numericEntity = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
    private static let tag = try? NSRegularExpression(pattern: "<[^>]+>")
    private static let whitespace = try? NSRegularExpression(pattern: "\\s+")

    /// Strips markup, decodes entities, and collapses whitespace.
    static func plainText(from markup: String) -> String {
        decodeEntities(in: stripTags(from: markup)).collapsingWhitespace()
    }

    /// Decodes entities and collapses whitespace without removing markup.
    static func decodeEntities(in text: String) -> String {
        var output = decodeNumericEntities(in: text)
        for (entity, replacement) in namedEntities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    static func stripTags(from markup: String) -> String {
        guard let tag else { return markup }
        return tag.stringByReplacingMatches(
            in: markup,
            range: NSRange(markup.startIndex..., in: markup),
            withTemplate: " "
        )
    }

    /// Expands `&#8230;` and `&#x2026;` style character references.
    private static func decodeNumericEntities(in text: String) -> String {
        guard text.contains("&#"), let numericEntity else { return text }

        var output = text
        let matches = numericEntity.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let flagRange = Range(match.range(at: 1), in: text),
                  let digitsRange = Range(match.range(at: 2), in: text)
            else { continue }

            let isHex = !text[flagRange].isEmpty
            guard let value = UInt32(text[digitsRange], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value)
            else { continue }

            output.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return output
    }

    /// True when the body is just the headline restated. Requires comparable
    /// lengths so that a paragraph merely *opening* with the headline survives.
    static func isRestatement(_ body: String, of title: String) -> Bool {
        let normalize: (String) -> String = { text in
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let normalizedBody = normalize(body)
        let normalizedTitle = normalize(title)

        guard !normalizedBody.isEmpty else { return true }
        guard normalizedTitle.count >= 12 else { return false }

        let longer = max(normalizedBody.count, normalizedTitle.count)
        let shorter = min(normalizedBody.count, normalizedTitle.count)
        guard Double(shorter) >= Double(longer) * 0.8 else { return false }

        return normalizedBody.hasPrefix(normalizedTitle)
            || normalizedTitle.hasPrefix(normalizedBody)
    }

    fileprivate static func collapse(_ text: String) -> String {
        guard let whitespace else { return text }
        let collapsed = whitespace.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    func collapsingWhitespace() -> String {
        HTMLText.collapse(self)
    }
}
