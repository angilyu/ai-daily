import Foundation
import Observation

/// The single switchboard for Claude features: the key, the model, which jobs
/// use it, and what it has cost so far. Every feature asks `client(for:)` and
/// falls back to its deterministic path on `nil`, so the app stays fully usable
/// with no key at all.
@MainActor
@Observable
final class AISettings {
    static let shared = AISettings()

    enum Feature {
        case channels
        case summaries
    }

    private(set) var hasKey: Bool
    /// Last four characters, so Settings can confirm which key is stored
    /// without ever displaying it.
    private(set) var keyHint: String?

    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }
    var channelsEnabled: Bool {
        didSet { defaults.set(channelsEnabled, forKey: Keys.channels) }
    }
    var summariesEnabled: Bool {
        didSet { defaults.set(summariesEnabled, forKey: Keys.summaries) }
    }

    private(set) var requestCount: Int
    private(set) var estimatedCost: Double

    private let defaults = UserDefaults.standard
    private var apiKey: String?

    private enum Keys {
        static let model = "ai.model"
        static let channels = "ai.channels"
        static let summaries = "ai.summaries"
        static let requests = "ai.requestCount"
        static let cost = "ai.estimatedCost"
    }

    private init() {
        let key = Keychain.read()
        apiKey = key
        hasKey = key != nil
        keyHint = key.map { String($0.suffix(4)) }
        model = defaults.string(forKey: Keys.model).flatMap(ClaudeModel.init) ?? .sonnet
        channelsEnabled = defaults.object(forKey: Keys.channels) as? Bool ?? true
        summariesEnabled = defaults.object(forKey: Keys.summaries) as? Bool ?? true
        requestCount = defaults.integer(forKey: Keys.requests)
        estimatedCost = defaults.double(forKey: Keys.cost)
    }

    func client(for feature: Feature) -> ClaudeClient? {
        guard let apiKey else { return nil }
        switch feature {
        case .channels where !channelsEnabled: return nil
        case .summaries where !summariesEnabled: return nil
        default: return ClaudeClient(apiKey: apiKey, model: model)
        }
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.write(trimmed) else { return }
        apiKey = trimmed
        hasKey = true
        keyHint = String(trimmed.suffix(4))
    }

    func removeKey() {
        Keychain.delete()
        apiKey = nil
        hasKey = false
        keyHint = nil
    }

    /// Makes one tiny real request so a bad key fails here, in Settings,
    /// rather than silently later inside a channel or summary.
    func testKey() async -> Result<Void, ClaudeClient.Failure> {
        guard let apiKey else { return .failure(.invalidKey) }
        struct Pong: Decodable, Sendable { let ok: Bool }
        let client = ClaudeClient(apiKey: apiKey, model: model)
        do {
            let result = try await client.generate(
                Pong.self,
                system: "Reply with the requested JSON.",
                user: "Set ok to true.",
                schema: #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#,
                maxTokens: 256,
                timeout: 30
            )
            record(result.usage)
            return .success(())
        } catch let failure as ClaudeClient.Failure {
            return .failure(failure)
        } catch {
            return .failure(.badResponse(error.localizedDescription))
        }
    }

    func record(_ usage: ClaudeClient.Usage) {
        let price = model.pricing
        requestCount += 1
        estimatedCost += Double(usage.inputTokens) / 1_000_000 * price.input
            + Double(usage.outputTokens) / 1_000_000 * price.output
        defaults.set(requestCount, forKey: Keys.requests)
        defaults.set(estimatedCost, forKey: Keys.cost)
    }

    func resetUsage() {
        requestCount = 0
        estimatedCost = 0
        defaults.set(0, forKey: Keys.requests)
        defaults.set(0.0, forKey: Keys.cost)
    }
}
