import SwiftUI

struct ReaderView: View {
    let item: NewsItem?

    @Environment(NewsStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var loader = ArticleLoader()
    @AppStorage("readerTextScale") private var textScale = 1.0
    @AppStorage("readerShowSummary") private var showSummary = true

    private var bodySize: CGFloat { 17 * textScale }
    private let columnWidth: CGFloat = 680

    var body: some View {
        Group {
            if let item {
                article(for: item)
            } else {
                ContentUnavailableView(
                    "Select a story",
                    systemImage: "doc.richtext",
                    description: Text("Headlines open here, full text and all.")
                )
            }
        }
        .onChange(of: item) { _, newValue in
            if let newValue {
                loader.load(newValue)
            } else {
                loader.clear()
            }
        }
        .onAppear {
            if let item { loader.load(item) }
        }
    }

    private func article(for item: NewsItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(for: item)
                        .id("top")

                    switch loader.state {
                    case .idle, .loading:
                        loadingPlaceholder
                    case .loaded(let article):
                        if !article.keyPoints.isEmpty {
                            summaryCard(points: article.keyPoints)
                        }
                        ForEach(article.blocks) { block in
                            view(for: block)
                        }
                        footer(for: item)
                    case .unavailable(let reason):
                        fallback(reason: reason, item: item)
                    }
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .textSelection(.enabled)
            }
            .onChange(of: item.id) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    textScale = max(0.85, textScale - 0.1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text")
                .disabled(textScale <= 0.85)

                Button {
                    textScale = min(1.6, textScale + 0.1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Larger text")
                .disabled(textScale >= 1.6)

                Button {
                    openURL(item.link)
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open in browser")
            }
        }
    }

    // MARK: - Sections

    private func header(for item: NewsItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: bodySize * 1.85, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(item.sourceName).fontWeight(.medium)
                Text("·")
                Text(item.publishedAt.formatted(date: .abbreviated, time: .shortened))
                if case .loaded(let article) = loader.state {
                    Text("·")
                    Text("\(article.readingMinutes) min read")
                }
            }
            .font(.system(size: bodySize * 0.8))
            .foregroundStyle(.secondary)

            Divider().padding(.top, 4)
        }
    }

    private func summaryCard(points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("The gist")
                Spacer()
                Button {
                    showSummary.toggle()
                } label: {
                    Image(systemName: showSummary ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(showSummary ? "Hide summary" : "Show summary")
            }
            .font(.system(size: bodySize * 0.8, weight: .semibold))
            .foregroundStyle(.secondary)

            if showSummary {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: 5, height: 5)
                                .offset(y: -2)
                            Text(point)
                                .font(.system(size: bodySize * 0.92))
                                .lineSpacing(bodySize * 0.3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    @ViewBuilder
    private func view(for block: ArticleBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.system(size: bodySize * 1.35, weight: .bold, design: .serif))
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

        case .subheading(let text):
            Text(text)
                .font(.system(size: bodySize * 1.15, weight: .semibold, design: .serif))
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(text)
                .font(.system(size: bodySize, design: .serif))
                .lineSpacing(bodySize * 0.42)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: bodySize, design: .serif))
                    .italic()
                    .lineSpacing(bodySize * 0.42)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

        case .listItem(let text):
            HStack(alignment: .top, spacing: 10) {
                Text("•")
                    .font(.system(size: bodySize, design: .serif))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: bodySize, design: .serif))
                    .lineSpacing(bodySize * 0.35)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6)

        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: bodySize * 0.85, design: .monospaced))
                    .padding(12)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

        case .image(let url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if phase.error != nil {
                    EmptyView()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.3))
                        .frame(height: 180)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: bodySize * 0.9)
                    .frame(maxWidth: index % 3 == 2 ? 420 : .infinity)
            }
        }
        .padding(.top, 8)
        .redacted(reason: .placeholder)
    }

    private func fallback(reason: String, item: NewsItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: bodySize, design: .serif))
                    .lineSpacing(bodySize * 0.42)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                Text(reason)
            }
            .font(.system(size: bodySize * 0.85))
            .foregroundStyle(.secondary)

            Button {
                openURL(item.link)
            } label: {
                Label("Read on \(item.sourceName)", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private func footer(for item: NewsItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.top, 8)
            Button {
                openURL(item.link)
            } label: {
                Label("View original on \(item.sourceName)", systemImage: "safari")
            }
            .buttonStyle(.link)
            .font(.system(size: bodySize * 0.9))
        }
    }
}
