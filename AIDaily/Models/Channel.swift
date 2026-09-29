import Foundation

/// A user-defined view of the news, described in plain language and compiled
/// into rules that are visible and editable. The prompt is the intent; the
/// rules are what actually runs.
struct Channel: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var prompt: String
    var rules: ChannelRules
    var compiler: CompilerKind
    var compiledAt: Date

    var isUsable: Bool { !rules.include.isEmpty }
}

/// Which compiler produced the rules, so the UI can be honest about it and
/// offer a re-compile when a better one becomes available.
enum CompilerKind: String, Codable, Hashable {
    case builtIn
    case local
    /// Retired: kept so channels saved by earlier versions still decode.
    case onDevice
    case claude

    var label: String {
        switch self {
        case .builtIn: "Built in"
        case .local: "Keyword rules"
        case .onDevice: "On-device model"
        case .claude: "Claude"
        }
    }

    var usesModel: Bool { self == .onDevice || self == .claude }
}

/// A term the user can see, reweight, or delete. Matching never reaches
/// outside this struct, so what's displayed is exactly what runs.
struct ChannelRules: Codable, Hashable {
    var include: [Term] = []
    var exclude: [Term] = []

    struct Term: Codable, Hashable, Identifiable {
        var text: String
        /// 3 = stated explicitly, 2 = derived from the prompt, 1 = expanded
        /// from the alias table. Weights only rank; they never gate.
        var weight: Int
        var id: String { text }
    }

    var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    /// Merges without duplicating, keeping the strongest weight for a term.
    static func merge(_ terms: [Term]) -> [Term] {
        var best: [String: Term] = [:]
        for term in terms {
            let key = term.text.lowercased()
            if let existing = best[key], existing.weight >= term.weight { continue }
            best[key] = Term(text: key, weight: term.weight)
        }
        return best.values.sorted {
            $0.weight == $1.weight ? $0.text < $1.text : $0.weight > $1.weight
        }
    }
}
