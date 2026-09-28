import SwiftUI

struct NewsRow: View {
    let item: NewsItem
    let isUnread: Bool
    /// Terms that put this story in the active channel. Empty when no channel
    /// is selected.
    var matchReasons: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unread")
                }
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if !matchReasons.isEmpty {
                    // Shown instead of the topic badge: when you're inside a
                    // channel, why this story matched is the more useful fact.
                    Label(matchReasons.joined(separator: " · "), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                } else if let topic = item.topics.first {
                    Label(topic.shortName, systemImage: topic.symbol)
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(item.sourceName)
                Text("·")
                Text(item.relativeAge)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
