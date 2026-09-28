import Foundation

/// Parses RSS 2.0 and Atom feeds into `NewsItem` values.
enum FeedParser {
    static func parse(data: Data, sourceName: String) -> [NewsItem] {
        let delegate = ParserDelegate(sourceName: sourceName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return [] }
        return delegate.items
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private let sourceName: String
    private(set) var items: [NewsItem] = []

    private var currentElement = ""
    private var insideItem = false
    private var title = ""
    private var link = ""
    private var summary = ""
    private var content = ""
    private var dateText = ""

    init(sourceName: String) {
        self.sourceName = sourceName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        if elementName == "item" || elementName == "entry" {
            insideItem = true
            title = ""
            link = ""
            summary = ""
            content = ""
            dateText = ""
            return
        }

        // Atom links carry the URL in an attribute rather than in character data.
        if insideItem, elementName == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate", link.isEmpty {
                link = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title": title += string
        case "link": link += string
        case "description", "summary": summary += string
        case "content", "content:encoded": content += string
        case "pubDate", "published", "updated", "date": dateText += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard insideItem, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        switch currentElement {
        case "title": title += string
        case "description", "summary": summary += string
        case "content", "content:encoded": content += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { currentElement = "" }
        guard elementName == "item" || elementName == "entry" else { return }
        insideItem = false

        let cleanTitle = HTMLText.plainText(from: title)
        guard !cleanTitle.isEmpty,
              let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else { return }

        // Keep whatever markup the feed gave us; the reader compares it against
        // the fetched page and renders whichever is richer.
        let richest = [content, summary].max(by: { $0.count < $1.count }) ?? ""
        let hasBody = HTMLText.plainText(from: richest).count >= 200

        // Some aggregators echo the headline back as the description; drop it.
        let preview = summary.isEmpty ? content : summary
        var cleanSummary = HTMLText.plainText(from: preview)
        if HTMLText.isRestatement(cleanSummary, of: cleanTitle) {
            cleanSummary = ""
        }

        items.append(
            NewsItem(
                title: cleanTitle,
                link: url,
                sourceName: sourceName,
                publishedAt: DateParsing.date(from: dateText) ?? .now,
                summary: String(cleanSummary.prefix(400)),
                contentHTML: hasBody ? richest : nil
            )
        )
    }
}

private enum DateParsing {
    private static let rfc822: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"]
            .map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                return formatter
            }
    }()

    private static let iso8601: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in iso8601 {
            if let date = formatter.date(from: trimmed) { return date }
        }
        for formatter in rfc822 {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
