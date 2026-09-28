import Foundation

/// Turns a plain-language prompt into visible matching rules.
///
/// This path is deterministic, instant, and offline. It is also the floor:
/// when the on-device model is unavailable or declines a prompt, this is what
/// runs, so a channel always compiles to *something* the user can edit.
enum PromptCompiler {
    static func compile(_ prompt: String) -> ChannelRules {
        var include: [ChannelRules.Term] = []
        var exclude: [ChannelRules.Term] = []

        var working = prompt.lowercased()

        // Quoted phrases are an explicit request; pull them out before
        // tokenising so they survive intact and outrank everything else.
        for phrase in quotedPhrases(in: &working) {
            include.append(.init(text: phrase, weight: 3))
        }

        for segment in clauses(in: working) {
            let (wanted, unwanted) = split(segment)
            include.append(contentsOf: significantTerms(in: wanted).map {
                .init(text: $0, weight: isWeak($0) ? 1 : 2)
            })
            exclude.append(contentsOf: significantTerms(in: unwanted).map { .init(text: $0, weight: 2) })
        }

        // Expand only what the user actually asked for. Expansions are weight
        // 1 so a story matching only aliases ranks below a direct hit.
        let stated = Set(include.map(\.text))
        for term in stated {
            for alias in aliases[term] ?? [] where !stated.contains(alias) {
                include.append(.init(text: alias, weight: 1))
            }
        }

        let excluded = Set(exclude.map(\.text))
        return ChannelRules(
            include: ChannelRules.merge(include).filter { !excluded.contains($0.text) },
            exclude: ChannelRules.merge(exclude)
        )
    }

    /// Strips quoted runs out of the prompt, returning them.
    private static func quotedPhrases(in text: inout String) -> [String] {
        var found: [String] = []
        var result = ""
        var buffer = ""
        var inQuote = false

        for character in text {
            if character == "\"" || character == "\u{201C}" || character == "\u{201D}" {
                if inQuote {
                    let phrase = buffer.trimmingCharacters(in: .whitespaces)
                    if phrase.count > 1 { found.append(phrase) }
                    buffer = ""
                }
                inQuote.toggle()
                continue
            }
            if inQuote { buffer.append(character) } else { result.append(character) }
        }

        // An unbalanced quote shouldn't silently swallow the rest of the prompt.
        if inQuote { result.append(buffer) }
        text = result
        return found
    }

    /// Negation scopes to its clause, so "gpus, but not gaming" excludes only
    /// gaming rather than poisoning the whole prompt.
    private static func clauses(in text: String) -> [String] {
        var segments = [text]
        for separator in [",", ";", ".", "\n", " but ", " however "] {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        return segments.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static let negations = [
        "not ", "no ", "none ", "skip ", "except ", "excluding ", "exclude ",
        "without ", "avoid ", "ignore ", "don't ", "dont ", "nothing "
    ]

    /// Splits one clause at its negation marker.
    private static func split(_ clause: String) -> (wanted: String, unwanted: String) {
        let padded = " \(clause) "
        for negation in negations {
            guard let range = padded.range(of: " \(negation)") else { continue }
            return (String(padded[padded.startIndex..<range.lowerBound]),
                    String(padded[range.upperBound...]))
        }
        return (clause, "")
    }

    private static func significantTerms(in text: String) -> [String] {
        let words = text
            .split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }

        var terms: [String] = []
        for (index, word) in words.enumerated() {
            guard isSignificant(word) else { continue }
            terms.append(word)

            // Only pair words that were genuinely adjacent in the prompt.
            // Pairing across a removed stopword invents phrases the reader
            // never wrote — "local llm inference on apple silicon" must not
            // yield "inference apple".
            let next = index + 1
            if next < words.count, isSignificant(words[next]) {
                terms.append("\(word) \(words[next])")
            }
        }
        return terms
    }

    private static func isSignificant(_ word: String) -> Bool {
        word.count > 1 && !stopwords.contains(word)
    }

    /// Exposed so the model compiler can discard filler the model echoes back.
    static func isStopword(_ term: String) -> Bool {
        term.split(separator: " ").allSatisfy { stopwords.contains(String($0)) }
    }

    /// Words that are true of almost every story in this corpus. Matching on
    /// them is near-meaningless here, so they rank but never drive.
    static func isWeak(_ term: String) -> Bool {
        weakTerms.contains(term)
    }

    private static let weakTerms: Set<String> = [
        "ai", "a.i.", "artificial", "intelligence", "artificial intelligence",
        "tech", "technology", "software", "computer", "computing", "digital",
        "internet", "web", "online", "app", "apps", "platform", "startup"
    ]

    /// Filler that carries no topical signal. Deliberately includes the
    /// request scaffolding people wrap prompts in ("show me the latest…").
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "for", "to", "with",
        "from", "by", "at", "as", "is", "are", "was", "were", "be", "been",
        "it", "its", "this", "that", "these", "those", "there", "here",
        "i", "me", "my", "we", "us", "our", "you", "your", "they", "them",
        "own", "mine", "myself", "ourselves",
        "want", "wants", "wanted", "like", "likes", "liked", "love", "need",
        "show", "showing", "give", "get", "getting", "find", "finding", "see",
        "read", "reading", "follow", "following", "interested", "interest",
        "about", "around", "regarding", "related", "anything", "everything",
        "something", "stuff", "things", "thing", "please", "would", "could",
        "should", "can", "will", "just", "only", "also", "more", "most",
        "news", "story", "stories", "article", "articles", "post", "posts",
        "update", "updates", "headline", "headlines", "coverage", "feed",
        "latest", "new", "newest", "recent", "recently", "today", "daily",
        "all", "any", "some", "good", "great", "best", "top", "big", "really",
        "very", "much", "many", "how", "what", "when", "where", "who", "why"
    ]

    /// Domain expansions: the vocabulary a reader means but doesn't type.
    /// Kept deliberately tight — loose synonyms make every channel match
    /// everything, which is worse than matching too little.
    private static let aliases: [String: [String]] = [
        "gpu": ["cuda", "nvidia", "blackwell", "hopper", "h100", "h200", "b200", "vram", "accelerator"],
        "gpus": ["cuda", "nvidia", "blackwell", "hopper", "h100", "b200", "vram", "accelerator"],
        "nvidia": ["cuda", "blackwell", "hopper", "h100", "b200", "gb200", "nvlink"],
        "amd": ["rocm", "instinct", "mi300", "mi350", "radeon"],
        "chip": ["silicon", "semiconductor", "wafer", "tsmc", "fab", "foundry", "asic"],
        "chips": ["silicon", "semiconductor", "wafer", "tsmc", "fab", "foundry", "asic"],
        "silicon": ["semiconductor", "wafer", "tsmc", "fab", "foundry", "node"],

        "llm": ["language model", "gpt", "claude", "gemini", "llama", "qwen", "mistral", "transformer"],
        "llms": ["language model", "gpt", "claude", "gemini", "llama", "qwen", "mistral", "transformer"],
        "model": ["llm", "checkpoint", "weights", "frontier"],
        "models": ["llm", "checkpoint", "weights", "frontier"],
        "openai": ["gpt", "chatgpt", "sora", "o1", "o3"],
        "anthropic": ["claude", "opus", "sonnet", "haiku"],
        "google": ["gemini", "deepmind", "tpu"],
        "meta": ["llama", "pytorch"],
        "opensource": ["open-weight", "open weights", "apache", "mit license"],
        "open-source": ["open-weight", "open weights", "huggingface", "github"],

        "inference": ["serving", "latency", "throughput", "vllm", "tokens per second", "kv cache"],
        "training": ["pretraining", "fine-tuning", "rlhf", "checkpoint", "cluster"],
        "finetuning": ["fine-tune", "lora", "peft", "adapter"],
        "fine-tuning": ["lora", "peft", "adapter", "sft"],
        "quantization": ["quantized", "gguf", "int4", "int8", "fp8", "awq", "gptq"],
        "local": ["on-device", "llama.cpp", "ollama", "gguf", "self-hosted"],
        "agent": ["agentic", "tool use", "mcp", "function calling"],
        "agents": ["agentic", "tool use", "mcp", "function calling"],
        "rag": ["retrieval", "embedding", "vector database", "reranking"],
        "robotics": ["robot", "manipulation", "embodied", "humanoid"],
        "security": ["vulnerability", "exploit", "cve", "jailbreak", "prompt injection"],
        "benchmark": ["eval", "evals", "leaderboard", "sota", "mmlu"],
        "benchmarks": ["eval", "evals", "leaderboard", "sota", "mmlu"],
        "paper": ["arxiv", "preprint", "ablation"],
        "papers": ["arxiv", "preprint", "ablation"],
        "research": ["arxiv", "paper", "preprint", "study"],

        "kubernetes": ["k8s", "container", "orchestration", "helm"],
        "database": ["postgres", "sql", "query", "index"],
        "rust": ["cargo", "crate", "borrow checker"],
        "python": ["pypi", "numpy", "asyncio"],
        "datacenter": ["data center", "megawatt", "gigawatt", "cooling", "rack"],
        "energy": ["power", "megawatt", "gigawatt", "grid", "nuclear"],

        "funding": ["raised", "valuation", "series a", "series b", "venture"],
        "startup": ["founder", "seed", "yc", "funding"],
        "regulation": ["policy", "eu ai act", "compliance", "antitrust"]
    ]
}
