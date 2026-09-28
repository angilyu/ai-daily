import Foundation

/// Engineering-relevant buckets used for filtering and row badges.
enum Topic: String, Codable, CaseIterable, Identifiable, Hashable {
    case models = "Models"
    case hardware = "GPUs & Hardware"
    case research = "Research"
    case tools = "Tools & Code"
    case infra = "Infra & Systems"
    case industry = "Industry"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .models: "Models"
        case .hardware: "Hardware"
        case .research: "Research"
        case .tools: "Tools"
        case .infra: "Infra"
        case .industry: "Industry"
        }
    }

    var symbol: String {
        switch self {
        case .models: "brain"
        case .hardware: "cpu"
        case .research: "function"
        case .tools: "hammer"
        case .infra: "server.rack"
        case .industry: "building.2"
        }
    }
}

enum TopicClassifier {
    /// Keyword signals per topic. Matching is whole-word over lowercased text,
    /// so "ram" doesn't fire on "program".
    private static let signals: [(Topic, [String])] = [
        (.models, [
            "gpt", "gpt-4", "gpt-5", "gpt-6", "claude", "gemini", "llama", "mistral",
            "qwen", "deepseek", "grok", "opus", "sonnet", "haiku", "o1", "o3",
            "llm", "llms", "slm", "model", "models", "multimodal", "diffusion",
            "frontier", "pretraining", "post-training", "inference-time",
            "transformer", "transformers", "moe", "context window", "tokenizer",
            "fine-tune", "fine-tuning", "finetuning", "distillation", "quantization",
            "quantized", "checkpoint", "weights", "open-weight", "benchmark",
            "benchmarks", "eval", "evals", "reasoning", "embedding", "embeddings"
        ]),
        (.hardware, [
            "gpu", "gpus", "cuda", "nvidia", "blackwell", "hopper", "h100", "h200",
            "b200", "gb200", "amd", "rocm", "instinct", "mi300", "mi350", "tpu",
            "tpus", "trainium", "inferentia", "asic", "accelerator", "accelerators",
            "chip", "chips", "silicon", "semiconductor", "wafer", "tsmc", "hbm",
            "nvlink", "interconnect", "fab", "foundry", "arm", "risc-v", "npu",
            "vram", "die", "node", "3nm", "2nm", "datacenter", "data center",
            "hardware", "server", "servers", "rack", "workstation", "bandwidth",
            "memory", "throughput", "ddr", "pcie", "cxl", "ethernet", "infiniband"
        ]),
        (.research, [
            "arxiv", "paper", "papers", "preprint", "research", "study",
            "ablation", "sota", "state-of-the-art", "novel", "theorem", "proof",
            "empirical", "architecture", "scaling law", "scaling laws",
            "interpretability", "alignment", "rlhf", "rl", "reinforcement"
        ]),
        (.tools, [
            "sdk", "api", "apis", "library", "framework", "open source",
            "open-source", "github", "repo", "release", "released", "cli",
            "pytorch", "tensorflow", "jax", "triton", "vllm", "ollama",
            "langchain", "hugging face", "huggingface", "transformers.js",
            "agent", "agents", "agentic", "mcp", "copilot", "cursor", "ide",
            "developer", "developers", "code", "coding", "python", "rust",
            "typescript", "docker", "kubernetes", "compiler"
        ]),
        (.infra, [
            "inference", "training", "serving", "throughput", "latency",
            "cluster", "clusters", "supercomputer", "cloud", "aws", "azure",
            "gcp", "kubernetes", "orchestration", "scaling", "distributed",
            "pipeline", "deployment", "deploy", "cache", "caching", "batch",
            "megawatt", "gigawatt", "power", "cooling", "networking", "storage"
        ]),
        (.industry, [
            "funding", "raise", "raised", "valuation", "series a", "series b",
            "series c", "series d", "series e", "ipo", "acquisition", "acquires",
            "acquired", "startup", "revenue", "partnership", "lawsuit",
            "regulation", "policy", "antitrust", "hiring", "layoffs", "ceo"
        ])
    ]

    /// Sources whose output is overwhelmingly one topic; used as a tiebreaker.
    private static let sourceBias: [String: Topic] = [
        "arXiv": .research,
        "Google Research": .research,
        "Hugging Face": .tools,
        "Simon Willison": .tools,
        "NVIDIA Developer": .hardware,
        "SemiAnalysis": .hardware,
        "Phoronix": .hardware,
        "ServeTheHome": .infra,
        "InfoQ AI": .infra,
        "OpenAI": .models,
        "Google DeepMind": .models,
        "The Decoder": .models,
        "Sebastian Raschka": .research,
        "Import AI": .research,
        "Latent Space": .tools
    ]

    static func topics(for item: NewsItem) -> [Topic] {
        let haystack = tokens(from: "\(item.title) \(item.summary)")
        var scores: [Topic: Int] = [:]

        for (topic, keywords) in signals {
            for keyword in keywords where haystack.contains(keyword) {
                // Longer, more specific phrases are stronger evidence.
                scores[topic, default: 0] += keyword.contains(" ") ? 3 : 2
            }
        }

        let bias = sourceBias.first { item.sourceName.hasPrefix($0.key) }?.value

        // A source only reinforces a topic the headline already suggests.
        // Left unguarded it invents topics — a Canonical revenue story from
        // Phoronix is not a hardware story.
        if let bias, scores[bias, default: 0] > 0 {
            scores[bias, default: 0] += 3
        }

        guard let best = scores.max(by: { lhs, rhs in
            lhs.value == rhs.value
                ? Topic.allCases.firstIndex(of: lhs.key)! > Topic.allCases.firstIndex(of: rhs.key)!
                : lhs.value < rhs.value
        }), best.value > 0 else {
            return [bias ?? .industry]
        }

        // The winner always stands, even on a single keyword. A second topic
        // has to be both close to the winner and independently well evidenced,
        // otherwise near-miss hits make every story look cross-cutting.
        var matched = [best.key]
        if let runnerUp = scores
            .filter({ $0.key != best.key && $0.value >= 4 && Double($0.value) >= Double(best.value) * 0.75 })
            .max(by: { $0.value < $1.value }) {
            matched.append(runnerUp.key)
        }

        return matched
    }

    /// Lowercased word and bigram set, so multi-word signals can match too.
    private static func tokens(from text: String) -> Set<String> {
        let words = text
            .lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }

        var result = Set(words)
        for index in words.indices.dropLast() {
            result.insert("\(words[index]) \(words[index + 1])")
        }
        return result
    }
}
