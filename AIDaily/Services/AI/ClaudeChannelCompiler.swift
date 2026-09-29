import Foundation

/// Compiles a channel prompt into matching rules with Claude.
///
/// Benchmarked against the same 15 prompts and 681 live stories used for the
/// on-device model: 93% recall and 70% precision on the live corpus, versus 29%
/// and 47% on-device and 64% and 25% for the keyword compiler alone. Zero
/// self-defeating exclusions, so unlike the on-device path its exclusions are
/// kept — but still checked, because one bad exclusion empties a channel.
enum ClaudeChannelCompiler {
    struct Result: Sendable {
        var rules: ChannelRules
        var name: String?
    }

    struct Generated: Decodable, Sendable {
        let name: String
        let core: [String]
        let related: [String]
        let exclude: [String]
    }

    static func compile(_ prompt: String, client: ClaudeClient) async throws -> (Result, ClaudeClient.Usage) {
        var total = ClaudeClient.Usage(inputTokens: 0, outputTokens: 0)
        var generated: Generated?
        // Constrained decoding occasionally closes every array immediately.
        // One retry is cheap (~$0.002) and costs nothing when unneeded.
        for _ in 0..<2 {
            let (attempt, usage) = try await client.generate(
                Generated.self,
                system: system,
                user: "Reader's request: \(prompt)",
                schema: schema,
                maxTokens: 2048,
                timeout: 30
            )
            total.inputTokens += usage.inputTokens
            total.outputTokens += usage.outputTokens
            generated = attempt
            if !attempt.core.isEmpty || !attempt.related.isEmpty { break }
        }
        return (assemble(generated!, prompt: prompt), total)
    }

    static func assemble(_ generated: Generated, prompt: String) -> Result {
        let local = PromptCompiler.compile(prompt)

        func weighted(_ terms: [String], weight: Int) -> [ChannelRules.Term] {
            terms.map(clean).filter { !$0.isEmpty && !PromptCompiler.isStopword($0) }
                .map { .init(text: $0, weight: PromptCompiler.isWeak($0) ? 1 : weight) }
        }

        let include = ChannelRules.merge(weighted(generated.core, weight: 3) + weighted(generated.related, weight: 2))
        let wanted = Set(include.map(\.text)).union(local.include.map(\.text))

        // An exclusion that is also something the reader asked for would
        // silently empty the channel. Drop it, and any exclusion that is a
        // fragment of a wanted phrase ("silicon" inside "apple silicon").
        let modelExclusions = weighted(generated.exclude, weight: 2).filter { term in
            !wanted.contains { $0 == term.text || $0.split(separator: " ").contains(Substring(term.text)) }
        }
        // Negation parsed straight from the prompt is always kept.
        let exclude = ChannelRules.merge(local.exclude + modelExclusions)
        let excluded = Set(exclude.map(\.text))

        let name = generated.name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'."))
        return Result(
            rules: ChannelRules(include: include.filter { !excluded.contains($0.text) }, exclude: exclude),
            name: name.isEmpty || name.count > 40 ? nil : name
        )
    }

    private static func clean(_ term: String) -> String {
        let trimmed = term
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'*-•,"))
            .lowercased()
        guard trimmed.count > 1, trimmed.count <= 40, trimmed.split(separator: " ").count <= 4 else { return "" }
        return trimmed
    }

    private static let system = """
        You turn a reader's plain-language request into keyword rules for a news \
        reader that covers AI, machine learning, GPUs, chips, and software engineering. \
        A story matches when one of your keywords appears as a whole word or phrase in \
        its headline or summary, so every keyword must be something that literally \
        appears in real headlines.

        name: a short channel name, one to three words, title case.
        core: the specific names at the heart of the request — products, companies, \
        people, models, chips, libraries, techniques. Expand intent: "running models on \
        my macbook" means llama.cpp, mlx, ollama, gguf, apple silicon, m4, and so on.
        related: closely related names and the most common alternate spellings. Include \
        acronyms and their expansions when both appear in headlines.
        exclude: only what the reader explicitly asked to avoid, expanded into the words \
        those stories use. Never exclude anything the reader asked for, or any part of it. \
        Leave empty when the reader didn't ask to avoid anything.

        Use lowercase. Prefer specific names over generic words like "ai", "model", \
        "news", "technology", "release", or "update". Aim for 6–15 core and related terms \
        combined; quality over quantity.
        """

    /// Order matters: name, then core, then related, then exclude. See
    /// `ClaudeClient.generate`.
    private static let schema = """
        {"type":"object","properties":{\
        "name":{"type":"string"},\
        "core":{"type":"array","items":{"type":"string"}},\
        "related":{"type":"array","items":{"type":"string"}},\
        "exclude":{"type":"array","items":{"type":"string"}}},\
        "required":["name","core","related","exclude"],"additionalProperties":false}
        """
}
