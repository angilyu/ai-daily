import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Shape the model fills in.
///
/// Free-form arrays on purpose: forcing a count makes the model pad with
/// repeated filler. `exclude` is requested but deliberately *discarded* —
/// see `assemble` — because asking for it measurably improves the quality of
/// `include` while its own contents are unsafe to use.
@available(macOS 26.0, *)
@Generable
struct GeneratedChannelRules {
    @Guide(description: "A short channel name of one to three words.")
    var name: String

    @Guide(description: "Lowercase keywords that should appear in a matching article. Prefer specific product, model, hardware and library names.")
    var include: [String]

    @Guide(description: "Lowercase keywords that mean an article should be skipped.")
    var exclude: [String]
}
#endif

/// Compiles a prompt using Apple's on-device model, when available.
///
/// The model is an enhancement, never a dependency. It runs once per prompt
/// edit rather than once per story, and everything it returns is filtered
/// before use. Measured over 24 runs on real prompts: 23 succeeded with a
/// median of ~600ms and a worst case of 1.1s; one looped until it exhausted
/// the 4096-token context window, taking 50 seconds. Hence the deadline.
enum ModelPromptCompiler {
    struct Result {
        var rules: ChannelRules
        var suggestedName: String?
        /// Terms the model contributed that the keyword pass missed, so the
        /// editor can show what it actually bought us.
        var addedTerms: [String]
    }

    enum Unavailable: String, Error {
        case unsupported = "This Mac doesn't support on-device Apple Intelligence."
        case notReady = "Apple Intelligence isn't set up yet."
        case declined = "The on-device model declined this prompt."
        case timedOut = "The on-device model took too long."
        case failed = "The on-device model couldn't interpret this prompt."
    }

    /// No successful call has ever taken more than ~1.1s, so this only ever
    /// catches the runaway-generation case.
    private static let deadline: Duration = .seconds(8)

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    static func compile(_ prompt: String) async -> Swift.Result<Result, Unavailable> {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .failure(.unsupported) }

        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): return .failure(.unsupported)
        default: return .failure(.notReady)
        }

        return await withTaskGroup(of: Swift.Result<Result, Unavailable>?.self) { group in
            group.addTask { await generate(prompt) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .failure(.timedOut)
            }

            let first = await group.next() ?? .failure(.failed)
            // Abandon the loser. A runaway generation can't be interrupted,
            // but nothing waits on it and its result is discarded.
            group.cancelAll()
            return first ?? .failure(.failed)
        }
        #else
        return .failure(.unsupported)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generate(_ prompt: String) async -> Swift.Result<Result, Unavailable> {
        let session = LanguageModelSession(instructions: Instructions(instructions))
        do {
            let response = try await session.respond(
                to: "Reader's request: \(prompt)",
                generating: GeneratedChannelRules.self
            )
            return .success(assemble(from: response.content, prompt: prompt))
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation: return .failure(.declined)
            case .exceededContextWindowSize: return .failure(.timedOut)
            default: return .failure(.failed)
            }
        } catch {
            return .failure(.failed)
        }
    }

    @available(macOS 26.0, *)
    private static func assemble(from generated: GeneratedChannelRules, prompt: String) -> Result {
        let local = PromptCompiler.compile(prompt)

        // The model's own exclusions are discarded. Measured across real
        // prompts it excluded the very terms being asked for — "apple" and
        // "silicon" for an Apple-silicon request, "model" and "releases" for
        // a model-releases request. Because exclusion is a hard filter, one
        // bad term silently empties the channel. Negation is parsed
        // deterministically from the prompt instead, which is reliable.
        let exclude = local.exclude
        let excluded = Set(exclude.map(\.text))
        let known = Set(local.include.map(\.text))

        let contributed = generated.include
            .map { clean($0) }
            .filter { term in
                !term.isEmpty
                    && !known.contains(term)
                    && !excluded.contains(term)
                    // The model often echoes the prompt's filler words back.
                    && !PromptCompiler.isStopword(term)
            }

        let modelTerms = contributed.map {
            ChannelRules.Term(text: $0, weight: PromptCompiler.isWeak($0) ? 1 : 2)
        }

        let include = ChannelRules.merge(local.include + modelTerms)
            .filter { !excluded.contains($0.text) }

        let name = generated.name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'."))
        return Result(
            rules: ChannelRules(include: include, exclude: exclude),
            suggestedName: name.isEmpty || name.count > 40 ? nil : name,
            addedTerms: ChannelRules.merge(modelTerms).map(\.text)
        )
    }
    #endif

    /// Models return bulleted, quoted, or sentence-length fragments.
    private static func clean(_ term: String) -> String {
        let trimmed = term
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'*-•.,"))
            .lowercased()
        guard trimmed.count > 1,
              trimmed.count <= 40,
              trimmed.split(separator: " ").count <= 3
        else { return "" }
        return trimmed
    }

    /// Kept short: every token here is taken from the 4096-token budget the
    /// runaway case is already straining.
    private static let instructions = """
        Turn the reader's request into keyword matching rules for an AI and \
        technology news reader. Use lowercase keywords that would literally \
        appear in a headline. Prefer specific product, model, hardware and \
        library names over broad category words.
        """
}
