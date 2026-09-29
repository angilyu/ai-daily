import Foundation

/// A minimal client for the Anthropic Messages API, limited to what the app
/// needs: one request in, one schema-constrained JSON object out.
///
/// Structured outputs (`output_config.format`) constrain decoding to the
/// schema, so a response either parses or the API reports why it didn't —
/// there is no "the model wrote prose around the JSON" failure to recover from.
struct ClaudeClient: Sendable {
    let apiKey: String
    let model: ClaudeModel
    /// Overridable so the client can be exercised against a local mock.
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum Failure: Error, Equatable {
        case invalidKey
        case rateLimited
        case overloaded
        case refused
        case truncated
        case offline
        case timedOut
        case badResponse(String)

        var message: String {
            switch self {
            case .invalidKey: "Your Anthropic API key was rejected."
            case .rateLimited: "Anthropic rate limit reached. Try again shortly."
            case .overloaded: "Claude is overloaded right now."
            case .refused: "Claude declined this request."
            case .truncated: "Claude's answer was cut off."
            case .offline: "You appear to be offline."
            case .timedOut: "Claude took too long to respond."
            case .badResponse(let detail): "Unexpected response from Claude (\(detail))."
            }
        }
    }

    struct Usage: Sendable {
        var inputTokens: Int
        var outputTokens: Int
    }

    /// Sends one request and decodes the model's JSON into `T`.
    ///
    /// `schema` is JSON *text*, not a dictionary, on purpose. The model fills
    /// fields in schema order, and Swift dictionaries serialize in random
    /// order. Measured: with `related` ahead of `core` and `name`, the model
    /// returned an entirely empty object in 6 of 10 calls; in the intended
    /// order, 0 of 10.
    func generate<T: Decodable & Sendable>(
        _ type: T.Type,
        system: String,
        user: String,
        schema: String,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 45
    ) async throws -> (value: T, usage: Usage) {
        let placeholder = "__SCHEMA__"
        var outputConfig: [String: Any] = [
            "format": ["type": "json_schema", "schema": placeholder]
        ]
        // These are extraction tasks, not reasoning problems; low effort keeps
        // latency and thinking tokens down. Older models reject the field.
        if model.supportsEffort {
            outputConfig["effort"] = "low"
        }

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": outputConfig,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        request.httpBody = Data(encoded.replacingOccurrences(of: "\"\(placeholder)\"", with: schema).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw Failure.timedOut
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                throw Failure.offline
            default: throw Failure.badResponse(error.localizedDescription)
            }
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw Failure.invalidKey
        case 429: throw Failure.rateLimited
        case 529, 503: throw Failure.overloaded
        default: throw Failure.badResponse("HTTP \(status): \(Self.errorMessage(in: data))")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw Failure.badResponse("unreadable envelope")
        }

        switch envelope.stopReason {
        case "refusal": throw Failure.refused
        case "max_tokens": throw Failure.truncated
        default: break
        }

        // Adaptive thinking can prepend thinking blocks; the answer is the text.
        guard let text = envelope.content.last(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8)
        else { throw Failure.badResponse("no text block") }

        do {
            let value = try JSONDecoder().decode(T.self, from: json)
            let usage = Usage(
                inputTokens: envelope.usage?.inputTokens ?? 0,
                outputTokens: envelope.usage?.outputTokens ?? 0
            )
            return (value, usage)
        } catch {
            throw Failure.badResponse("JSON didn't match schema")
        }
    }

    private static func errorMessage(in data: Data) -> String {
        struct APIError: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.error.message ?? "no detail"
    }

    private struct Envelope: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct TokenUsage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
        let content: [Block]
        let stopReason: String?
        let usage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case usage
        }
    }
}

enum ClaudeModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-4-5-20251001"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 4.5"
        case .opus: "Claude Opus 5.5"
        }
    }

    var detail: String {
        switch self {
        case .sonnet: "Fast and sharp. Recommended."
        case .haiku: "Fastest and cheapest. Older knowledge cutoff."
        case .opus: "Most capable, slower, 2× the cost of Sonnet."
        }
    }

    var supportsEffort: Bool { self != .haiku }

    /// USD per million tokens (input, output), for the running cost estimate.
    var pricing: (input: Double, output: Double) {
        switch self {
        case .sonnet: (2, 10)
        case .haiku: (1, 5)
        case .opus: (4, 20)
        }
    }
}
