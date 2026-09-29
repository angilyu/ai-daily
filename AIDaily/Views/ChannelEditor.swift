import SwiftUI

/// Creates or edits a channel. The prompt is the input, but the compiled rules
/// stay on screen and stay editable — the point is that nothing about why a
/// story appears is hidden from the reader.
struct ChannelEditor: View {
    @Environment(NewsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// `nil` when creating.
    let existing: Channel?

    @State private var name = ""
    @State private var prompt = ""
    @State private var rules = ChannelRules()
    @State private var compiler: CompilerKind = .local
    @State private var isCompiling = false
    @State private var modelNote: String?
    @State private var nameEdited = false
    @State private var autoSuggestedName = ""
    @State private var compileTask: Task<Void, Never>?

    private var matches: [NewsItem] {
        ChannelMatcher.rank(store.items, by: rules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promptSection
                    if !rules.isEmpty { rulesSection }
                    previewSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: load)
        .onDisappear { compileTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Text(existing == nil ? "New Channel" : "Edit Channel")
                .font(.headline)
            Spacer()
            if isCompiling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading your prompt…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the news you want")
                .font(.subheadline.weight(.semibold))

            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 76)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("e.g. running open models locally on apple silicon, not funding rounds")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: prompt) { _, _ in scheduleCompile() }

            HStack(spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Channel name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, newValue in
                        if newValue != autoSuggestedName { nameEdited = true }
                    }
            }

            HStack(spacing: 5) {
                Image(systemName: compiler.usesModel ? "sparkles" : "text.magnifyingglass")
                    .imageScale(.small)
                Text(modelNote ?? "Matched with keyword rules.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !rules.include.isEmpty {
                ruleGroup(
                    title: "Looking for",
                    caption: "Darker terms count for more. Remove any that don't belong.",
                    terms: rules.include,
                    tint: Color.accentColor
                ) { term in
                    rules.include.removeAll { $0.text == term.text }
                }
            }

            if !rules.exclude.isEmpty {
                ruleGroup(
                    title: "Skipping",
                    caption: nil,
                    terms: rules.exclude,
                    tint: .red
                ) { term in
                    rules.exclude.removeAll { $0.text == term.text }
                }
            }
        }
    }

    private func ruleGroup(
        title: String,
        caption: String?,
        terms: [ChannelRules.Term],
        tint: Color,
        remove: @escaping (ChannelRules.Term) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(terms) { term in
                    Button {
                        remove(term)
                    } label: {
                        HStack(spacing: 4) {
                            Text(term.text)
                            Image(systemName: "xmark")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(term.weight >= 3 ? 0.32 : term.weight == 2 ? 0.2 : 0.09), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Weight \(term.weight) — click to remove")
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matching now")
                .font(.subheadline.weight(.semibold))

            if rules.include.isEmpty {
                Text("Describe a topic above to see what it would pick up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if matches.isEmpty {
                // The likeliest cause by far: every source here is AI and
                // engineering news, so an off-topic prompt has nothing to hit.
                Label(
                    "No stories match yet. Your sources all cover AI and engineering, so a topic outside that won't find anything.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("\(matches.count) of \(store.items.count) stories")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(matches.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout)
                            .lineLimit(2)
                        Text(ChannelMatcher.match(item, against: rules).reasons.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let existing {
                Button("Delete", role: .destructive) {
                    store.deleteChannel(existing)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(rules.include.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        prompt = existing.prompt
        rules = existing.rules
        compiler = existing.compiler
        nameEdited = true
    }

    /// Compiles on a short delay so every keystroke doesn't start a model call.
    private func scheduleCompile() {
        compileTask?.cancel()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            rules = ChannelRules()
            modelNote = nil
            isCompiling = false
            return
        }

        // Opening a saved channel assigns its prompt, which lands here too.
        // Recompiling would bill a request and overwrite any hand-edited rules.
        if let existing, text == existing.prompt, rules == existing.rules {
            return
        }

        // The keyword pass is instant, so show its result immediately rather
        // than leaving the sheet blank while the model thinks.
        rules = PromptCompiler.compile(text)
        compiler = .local
        suggestName(from: nil)

        guard let client = AISettings.shared.client(for: .channels) else {
            isCompiling = false
            modelNote = AISettings.shared.hasKey
                ? "Matched with keyword rules. Claude is turned off for channels in Settings."
                : "Matched with keyword rules. Add an Anthropic API key in Settings for smarter channels."
            return
        }

        isCompiling = true
        compileTask = Task {
            // Long enough that typing doesn't fire a request per word.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            do {
                let (result, usage) = try await ClaudeChannelCompiler.compile(text, client: client)
                AISettings.shared.record(usage)
                guard !Task.isCancelled else { return }

                if result.rules.include.isEmpty {
                    modelNote = "Claude found nothing to match on. Using keyword rules."
                } else {
                    rules = result.rules
                    compiler = .claude
                    modelNote = "Rules written by \(client.model.label). Remove any term that doesn't belong."
                    suggestName(from: result.name)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let reason = (error as? ClaudeClient.Failure)?.message ?? error.localizedDescription
                compiler = .local
                modelNote = "\(reason) Using keyword rules instead."
            }
            isCompiling = false
        }
    }

    /// Only ever fills a name the user hasn't touched. Tracked by comparing
    /// against the last value we wrote, because `onChange` can't distinguish
    /// a user's keystroke from a programmatic assignment.
    private func suggestName(from suggestion: String?) {
        guard !nameEdited else { return }
        let candidate = suggestion ?? rules.include
            .filter { $0.weight >= 2 }
            .prefix(2)
            .map(\.text)
            .joined(separator: " & ")

        let cleaned = candidate.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }

        let titled = Self.titleCase(cleaned)
        autoSuggestedName = titled
        name = titled
    }

    /// `.capitalized` turns "gpu" into "Gpu"; technical names need their
    /// acronyms left alone.
    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if acronyms.contains(lower) { return lower.uppercased() }
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
    }

    private static let acronyms: Set<String> = [
        "ai", "llm", "llms", "gpu", "gpus", "cpu", "npu", "tpu", "api", "apis",
        "ml", "nlp", "rag", "sdk", "hpc", "eu", "us", "uk", "ide", "cli", "os"
    ]

    private func save() {
        var channel = existing ?? Channel(
            name: "",
            prompt: "",
            rules: ChannelRules(),
            compiler: .local,
            compiledAt: .now
        )
        channel.name = name.trimmingCharacters(in: .whitespaces)
        channel.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        channel.rules = rules
        channel.compiler = compiler
        channel.compiledAt = .now
        store.save(channel)
        store.selectedChannelID = channel.id
        dismiss()
    }
}

/// Wraps chips onto as many lines as they need. `HStack` would clip them and
/// `LazyVGrid` would force a fixed column width, which looks wrong for terms
/// of very different lengths.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
