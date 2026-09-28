import Foundation

struct Feed: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var isEnabled: Bool = true
    var isBuiltIn: Bool = false
}

extension Feed {
    private static func builtIn(_ name: String, _ url: String, enabled: Bool = true) -> Feed {
        Feed(name: name, url: URL(string: url)!, isEnabled: enabled, isBuiltIn: true)
    }

    /// Sources chosen for engineering depth: model releases, GPU and silicon
    /// coverage, inference and infrastructure work, and practitioner writing.
    /// Every entry here was checked for a live feed and for readability in the
    /// in-app reader; sources that only render in a browser were left out.
    static let builtIn: [Feed] = [
        // Model releases, straight from the labs
        builtIn("OpenAI", "https://openai.com/news/rss.xml"),
        builtIn("Google DeepMind", "https://deepmind.google/blog/rss.xml"),
        builtIn("Hugging Face", "https://huggingface.co/blog/feed.xml"),
        builtIn("Mistral", "https://mistral.ai/rss.xml"),
        builtIn("Qwen", "https://qwenlm.github.io/blog/index.xml"),
        builtIn("Allen AI", "https://allenai.org/rss.xml"),
        builtIn("The Decoder", "https://the-decoder.com/feed/"),

        // Silicon, GPUs, and datacenter hardware
        builtIn("NVIDIA Developer", "https://developer.nvidia.com/blog/feed/"),
        builtIn("SemiAnalysis", "https://semianalysis.com/feed/"),
        builtIn("Chips and Cheese", "https://chipsandcheese.com/feed"),
        builtIn("The Next Platform", "https://www.nextplatform.com/feed/"),
        builtIn("ServeTheHome", "https://www.servethehome.com/feed/"),
        builtIn("Phoronix", "https://www.phoronix.com/rss.php"),
        builtIn("HPCwire", "https://www.hpcwire.com/feed/"),
        // ~39 stories a day, much of it consumer gaming and deals.
        builtIn("Tom's Hardware", "https://www.tomshardware.com/feeds.xml", enabled: false),

        // Inference, training, and the tooling around them
        builtIn("PyTorch", "https://pytorch.org/blog/feed/"),
        builtIn("Ollama", "https://ollama.com/blog/rss.xml"),
        builtIn("Together AI", "https://www.together.ai/blog/rss.xml"),
        builtIn("Replicate", "https://replicate.com/blog/rss"),
        builtIn("Databricks", "https://www.databricks.com/feed"),

        // Platform and systems engineering
        builtIn("InfoQ AI", "https://feed.infoq.com/ai-ml-data-eng/"),
        builtIn("The Register AI", "https://api.theregister.com/api/v1/article?orderBy=published&site_id=2&remapper=rss&query=(tag:software+AND+tag:%22ai+and+ml%22)"),
        builtIn("Cloudflare", "https://blog.cloudflare.com/rss/"),
        builtIn("Meta Engineering", "https://engineering.fb.com/feed/"),
        builtIn("AWS Machine Learning", "https://aws.amazon.com/blogs/machine-learning/feed/"),
        builtIn("Netflix Tech", "https://netflixtechblog.com/feed"),
        builtIn("Fly.io", "https://fly.io/blog/feed.xml"),

        // Practitioners worth reading closely
        builtIn("Simon Willison", "https://simonwillison.net/atom/everything/"),
        builtIn("Sebastian Raschka", "https://magazine.sebastianraschka.com/feed"),
        builtIn("Latent Space", "https://www.latent.space/feed"),
        builtIn("Import AI", "https://importai.substack.com/feed"),
        builtIn("Chip Huyen", "https://huyenchip.com/feed.xml"),
        builtIn("Lilian Weng", "https://lilianweng.github.io/index.xml"),
        builtIn("Eugene Yan", "https://eugeneyan.com/rss/"),

        // Research
        builtIn("Google Research", "https://research.google/blog/rss/"),
        builtIn("Microsoft Research", "https://www.microsoft.com/en-us/research/feed/"),
        builtIn("Berkeley BAIR", "https://bair.berkeley.edu/blog/feed.xml"),
        // High volume: opt in from Settings when you want the firehose.
        builtIn("arXiv cs.LG", "https://export.arxiv.org/rss/cs.LG", enabled: false),
        builtIn("arXiv cs.CL", "https://export.arxiv.org/rss/cs.CL", enabled: false),

        // News and community
        builtIn("Hacker News", "https://hnrss.org/newest?q=AI+OR+LLM+OR+GPU+OR+CUDA+OR+inference&points=100"),
        builtIn("r/LocalLLaMA", "https://www.reddit.com/r/LocalLLaMA/top/.rss?t=day"),
        builtIn("TechCrunch AI", "https://techcrunch.com/category/artificial-intelligence/feed/"),
        builtIn("IEEE Spectrum AI", "https://spectrum.ieee.org/feeds/topic/artificial-intelligence.rss"),
        builtIn("MIT Tech Review", "https://www.technologyreview.com/topic/artificial-intelligence/feed"),
        // General programming rather than AI, and fairly chatty.
        builtIn("Lobsters", "https://lobste.rs/rss", enabled: false)
    ]
}
