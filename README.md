# AI Daily

A macOS news reader for engineers who follow AI, GPUs, and systems work.

It pulls from 45 RSS feeds, extracts the full article text so you can read it
without leaving the app, generates a short summary at the top of each piece, and
lets you define your own channels by describing what you want in plain English.

Written in SwiftUI. About 4,400 lines of Swift, no third-party dependencies, and
no server. The two jobs that need real language understanding — turning a
channel prompt into rules, and summarizing articles — use **Claude** through your
own Anthropic API key. Without a key, every feature still works with
deterministic fallbacks.

---

## Contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [The readability extractor](#the-readability-extractor)
- [Claude integration](#claude-integration)
- [The summarizers](#the-summarizers)
- [Prompt-defined channels](#prompt-defined-channels)
- [Topic classification](#topic-classification)
- [Refresh scheduling](#refresh-scheduling)
- [Sources](#sources)
- [Building](#building)
- [Known limitations](#known-limitations)

---

## What it does

**Reads articles in-app.** RSS feeds usually ship a truncated teaser. The app
fetches the linked page and runs a hand-written readability extractor over the
raw HTML to recover the actual prose, then renders it as native SwiftUI text.

**Summarizes before you commit to reading.** Every article gets a card at the
top with a one-line TL;DR, two to four key points with the concrete specifics
(model names, parameter counts, benchmarks, prices), and a line on why it
matters to engineers. Claude writes it; without a key, an extractive fallback
lifts the article's own best sentences instead.

**Filters by topic.** Each story is classified into one of six engineering
buckets, shown as a badge and usable as a filter.

**Channels you define by prompt.** Describe the news you want and the app
compiles it — with Claude — into visible, editable keyword rules. See
[Prompt-defined channels](#prompt-defined-channels).

**Lives in the menu bar too.** A `MenuBarExtra` shows recent headlines, and both
it and the main window drive the same reader.

---

## Architecture

```
Feed (URL)
   │
   ├─ FeedParser ──────────── RSS 2.0 / Atom → [NewsItem]
   │                            title, link, summary, publishedAt, contentHTML
   │
   ├─ TopicClassifier ─────── keyword scoring → [Topic]
   │
   └─ NewsStore ───────────── dedupe, merge, retention, persistence
        │
        ├─ ArticleLoader ──── fetch page → ArticleExtractor → Article
        │                        ├─ Summarizer (extractive, instant)
        │                        └─ ClaudeSummarizer (async, replaces it) ─┐
        │                                                                  │
        └─ ChannelMatcher ─── score items against ChannelRules             │
                                  ▲                                        │
             ChannelEditor ── PromptCompiler (instant)                     │
                          └── ClaudeChannelCompiler (debounced) ───────────┤
                                                                           ▼
                             AISettings ── Keychain key ── ClaudeClient ── api.anthropic.com
```

Layering is strict: `Models` hold data, `Services` do work and own all the
non-trivial logic, `Views` only display. Every service is a pure enum namespace
or a plain struct with no UI dependency, which is what makes them testable by
compiling them into standalone Swift harnesses (see [Testing](#testing)).

`NewsStore` is the single `@MainActor @Observable` source of truth, injected
through the SwiftUI environment. It persists to a JSON snapshot in the sandbox
container. Parsing, extraction, and summarization all happen off the main
thread.

### Data model

| Type | Role |
| --- | --- |
| `Feed` | A source. Name, URL, enabled flag, built-in flag. |
| `NewsItem` | One story. Stable ID derived from its link, plus topics. |
| `Article` | Extracted full text as `[ArticleBlock]`, plus `tldr`, `keyPoints`, `whyItMatters`, and which summarizer wrote them. |
| `Topic` | Six-case enum used for badges and filtering. |
| `Channel` | A user prompt plus the `ChannelRules` it compiled into. |

### Storage

A single JSON file under the app's sandbox container holds feeds, items, read
IDs, channels, and the last refresh timestamp. Items are pruned on every refresh
to a 14-day window, capped at 700 (the 41 enabled sources produce roughly 430 in
a fortnight, so the cap is headroom rather than a limit).

The snapshot's `channels` field is optional so that stores written before the
channel feature still decode. Feed migration rebuilds the list from the current
built-in set on every launch, which drops retired sources while preserving the
user's enable/disable choices and any feeds they added themselves.

---

## The readability extractor

`ArticleExtractor.swift` is the largest and most-debugged file in the project
(~500 lines). It takes raw HTML and returns ordered blocks of prose. It is a
scoring extractor in the Readability tradition, written from scratch — no
`WKWebView`, no JavaScript, no dependencies.

The approach: tokenize HTML into a tag stream, build a shallow tree, score
candidate containers by text density and paragraph count, pick a winner, then
clean it.

`ArticleLoader` tries both the extracted page and any `content:encoded` from the
feed, then picks whichever scores better. The score penalizes blobs with more
than 250 words per block by half, because raw word count alone lets one
unstructured wall of text beat properly structured prose.

Getting from "works on my test page" to "works on 30 of 32 live articles" took a
sequence of fixes against real, specific failures:

| Problem | Fix |
| --- | --- |
| `<script>` bodies containing JSON corrupted the tag stack | Treat script/style as raw text with a dedicated scanner |
| One site puts a junk class on `<body>`, skipping the whole document | Never apply junk-class filtering to structural tags |
| Another marks real paragraphs `class="paywall"` | Only apply junk-class filtering to containers, never text blocks |
| Restatement detection was deleting real prose | Require a title of 12+ normalized characters and lengths within 80% |
| Pages using `<br>` instead of `<p>` produced nothing | Fall back to loose block detection gated on a prose heuristic |
| A newsletter rendered 1,287 words as a single block | Treat a double `<br>` as a paragraph break |

That prose heuristic — 12+ words, sentence punctuation, and under 50%
capitalized words — is what keeps navigation menus and link lists out of the
article body. The capitalization rule does most of the work.

One source was removed permanently rather than fixed: Google News RSS links
resolve to a redirect page and never reach the article.

---

## Claude integration

Claude is used for exactly two jobs — the ones where the deterministic versions
measurably fell short — and nowhere else. Topic badges, matching, ranking,
extraction, and refresh stay deterministic: they run per story, so they need to
be instant, free, and predictable.

| Job | Runs | Without a key |
| --- | --- | --- |
| Channel prompt → rules | Once per prompt edit, debounced 900ms | Keyword compiler |
| Article summary | Once per article, cached to disk | Extractive summarizer |

**Setup.** Settings → AI → paste an Anthropic API key. It's stored in the macOS
Keychain, never in `UserDefaults` or the JSON store. *Test Connection* makes one
tiny real request so a bad key fails in Settings rather than silently inside a
channel. Each job has its own toggle, and a running counter estimates spend.

**Model.** Claude Sonnet 5.5 by default; Haiku 4.5 and Opus 5.5 are selectable.
Requests use `effort: low` (these are extraction tasks, not reasoning problems)
and are omitted for Haiku, which doesn't support it.

**Client** (`ClaudeClient.swift`, ~200 lines, no SDK). One method: send a system
prompt, a user message, and a JSON schema; get back a decoded `Decodable`.
[Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
(`output_config.format`) constrain decoding to the schema, so there's no "the
model wrapped the JSON in prose" failure mode. Every failure maps to a typed
case — invalid key, rate limit, overloaded, refusal, truncation, offline,
timeout — each with a readable message, and every caller falls back rather than
surfacing a dead end.

**The schema-order bug.** Schemas are passed as JSON *text*, not Swift
dictionaries. The model fills fields in schema order, and `[String: Any]`
serializes in random order. When `related` happened to come before `core` and
`name`, the model returned `{"core":[],"exclude":[],"name":"","related":[]}` in
**6 of 10** calls; in the intended order, **0 of 10**. This showed up in
benchmarking as 5 of 15 prompts compiling to nothing, and was invisible from the
Python client used for comparison because Python dicts preserve insertion order.
There's also a single retry if a response still comes back empty.

**Cost, measured.** $0.0026 per channel compile and $0.009 per article summary on
Sonnet 5.5. Summaries are cached in `summaries.json` (capped at 1,500 entries),
so reopening an article — or relaunching — never pays twice.

**Privacy.** With a key set, article text and channel prompts are sent to
Anthropic. Nothing else is: not your read history, feed list, or other channels.

---

## The summarizers

### Claude (`ClaudeSummarizer.swift`)

The article opens immediately with the extractive digest; Claude's summary
replaces it in place when it arrives (p50 3.6s), with a *"Claude is
summarizing…"* indicator in between. Reading never waits on the network. Up to
24,000 characters of article text are sent — nearly every news post in full.
Images are skipped and code blocks truncated.

The prompt restricts Claude to facts stated in the article. Checked on eight
live articles from eight different sources: **every one of the 58 numbers**
Claude wrote into a summary appears verbatim in the source text. The old
extractive digest, by comparison, often led with a side remark — for a
LocalLLaMA benchmark post, its first point was about the comment section.

### Extractive fallback (`Summarizer.swift`)

Ranks the article's own sentences and returns the best three.
Extractive, not generative, so a summary can never contain a claim the article
doesn't make.

Sentences are scored on term frequency against the article's own vocabulary,
position, title-word overlap, and length. Thresholds: at least 220 words before
summarizing at all, at most 3 points, sentences between 9 and 45 words.

The interesting part is sentence splitting, which is where almost all the bugs
were:

- **Abbreviations.** The token has to be captured *with* its trailing period,
  otherwise `"Sept."` never matches the abbreviation list and a summary starts
  mid-date.
- **Quotations.** A lowercase-follower check has to apply to `!` and `?`, not
  just `.`, or `"This is great!" she said.` splits inside the quote.
- **Captions.** Text without terminal punctuation was becoming bullets.
- **Transcripts.** Rhetorical questions and conversational filler scored well
  and had to be explicitly down-weighted.

The splitter has 14 unit tests, all passing (it started at 8 of 14).
Performance: 4,000 paragraphs in 537ms. Summaries are computed off the main
thread and cached with the article.

---

## Prompt-defined channels

Describe what you want to read. The app compiles that description into keyword
rules, shows you the rules, and lets you edit them. Stories matching a channel
display the specific terms that matched instead of a topic badge.

The design principle: **the prompt compiles into visible, editable rules.** No
black box, and no situation where you cannot tell why something appeared.

### Three layers

**1. Keyword compiler** (`PromptCompiler.swift`) — always runs, instant,
offline, deterministic.

Parses quoted phrases, splits on clause boundaries so negation is scoped
(`"gpus, but not gaming"` excludes only gaming), strips filler, keeps adjacent
word pairs, and expands terms through a domain alias table — `gpu` brings in
`cuda`, `blackwell`, `h100`, `vram`.

Terms carry a weight: 3 if quoted, 2 if stated, 1 if expanded from an alias.
Weights rank but never gate. A separate weak-term list demotes words like `ai`
and `technology` to weight 1, since in a corpus where every story is about AI
they carry almost no signal.

**2. Scoring** (`ChannelMatcher.swift`) — ranks rather than hard-filters, so a
channel degrades into "less relevant last" instead of an empty list. A title hit
counts triple a summary hit. Matching is whole-word, so `ram` doesn't fire on
`program`. Exclusions are the one hard rule, because "not X" is explicit.

**3. Claude** (`ClaudeChannelCompiler.swift`) — replaces the keyword rules
when a key is set. The editor shows the keyword result instantly, then swaps in
Claude's rules about two seconds later.

Claude returns a name and three lists: `core` terms (weight 3), `related` terms
(weight 2), and `exclude`. The prompt pushes hard toward specific names that
literally appear in headlines — `"running models on my macbook"` becomes
`llama.cpp, mlx, ollama, gguf, apple silicon, m4`, not `local, models, laptop`.

Exclusions are kept, but guarded. Any exclusion that equals something the
reader asked for — or is a fragment of it, like `silicon` inside `apple
silicon` — is dropped, because exclusion is a hard filter and one bad term
silently empties the channel. Negation parsed deterministically from the prompt
is always kept.

The model runs **once per prompt edit**, never per story. Matching stays
instant and deterministic, and every term is visible and removable in the editor.

### Why Claude, measured

An earlier version used Apple's on-device `FoundationModels` model for this
layer. It was benchmarked on 15 prompts across 7 categories (literal, negation,
inference, jargon, multi-constraint, ambiguous, out-of-domain) and then replaced.
All numbers below come from the same prompts, scored with the same rubric, and
matched against the same live corpus of ~690 stories.

| | Keyword only | On-device model | **Claude Sonnet 5.5** |
| --- | --- | --- | --- |
| Calls completed | — | 83% (62/75) | **100% (45/45)** |
| Latency p50 / p95 | instant | 1.8s / 51s | **2.0s / 3.8s** |
| Semantic recall of expected terms | — | 28% | **79%** |
| Self-defeating exclusions | 0% | 35–40% | **0%** |
| Same prompt twice → same terms (Jaccard) | 100% | 29% | **71%** |
| Live corpus precision | 26% | 47% | **69%** |
| Live corpus recall | 64% | 29% | **81%** |
| Live corpus F1 | 28% | 23% | **68%** |
| Cost per compile | free | free | $0.0026 |

The on-device model scored *below the keyword compiler on F1*: it swung between
extremes — zero matches for `"running models on my macbook"`, 367 for `"gpu news
but not gaming"`. Its signature failure was generating exactly the right
vocabulary and then putting it in both the include and exclude lists. Claude
brings `"running models on my macbook"` to 96% precision and 86% recall.

Relevance for the corpus metrics is judged against an independent per-prompt
vocabulary, not either compiler's own terms. It's a proxy, and a strict one: for
`"the chip war between the us and china"` only one story in the corpus hit the
reference vocabulary, so every compiler's precision on that prompt looks near
zero.

---

## Topic classification

`TopicClassifier` scores each story against keyword sets for six topics: Models,
GPUs & Hardware, Research, Tools & Code, Infra & Systems, and Industry.
Multi-word phrases score higher than single words, since they're stronger
evidence.

Two bugs here are worth recording, because both produced plausible-looking
wrong output:

- **Source bias was inventing topics.** A story about a company's revenue,
  published by a hardware site, was tagged as hardware. Source bias now only
  *reinforces* a topic the headline already suggests; it can never introduce
  one.
- **A score floor was discarding valid matches.** Single-keyword matches fell
  through to a catch-all Industry bucket. The top-scoring topic now always
  stands. A second topic is only added if it scores at least 4 *and* at least
  75% of the winner.

Measured across 200 live items: 0 unclassified, with reasonable spread.

---

## Refresh scheduling

Refreshes hourly, plus whenever the Mac wakes.

The scheduler compares the *age* of the data against a one-hour interval rather
than counting down, because `Task.sleep` stops advancing while the machine
sleeps. An `NSWorkspace.didWakeNotification` observer triggers a staleness check
on wake.

One bug worth noting: on a total fetch failure the last-refresh timestamp never
updated, so the five-minute poll would retry forever while offline. A separate
`lastAttempt` timestamp with a 10-minute floor fixes it. The logic also handles
a clock jumping forward, where age computes as negative.

The decision function `shouldRefresh(at:)` is pure and separated from the timer
for exactly this reason. 11 scheduling tests, all passing.

---

## Sources

45 feeds, 41 enabled by default, grouped by what they cover:

- **Model releases** — OpenAI, Google DeepMind, Hugging Face, Mistral, Qwen,
  Allen AI, The Decoder
- **Silicon and hardware** — NVIDIA Developer, SemiAnalysis, Chips and Cheese,
  The Next Platform, ServeTheHome, Phoronix, HPCwire
- **Inference and tooling** — PyTorch, Ollama, Together AI, Replicate,
  Databricks
- **Platform engineering** — InfoQ, The Register, Cloudflare, Meta Engineering,
  AWS ML, Netflix Tech, Fly.io
- **Practitioners** — Simon Willison, Sebastian Raschka, Latent Space, Import
  AI, Chip Huyen, Lilian Weng, Eugene Yan
- **Research** — Google Research, Microsoft Research, Berkeley BAIR, arXiv
- **News and community** — Hacker News, r/LocalLLaMA, TechCrunch, IEEE Spectrum,
  MIT Technology Review

Four ship disabled because of volume or fit: Tom's Hardware (~39 stories a day,
much of it consumer gaming), Lobsters (general programming), and two arXiv
categories. Toggle any of them in Settings, or add your own feed URL.

Every source was verified to have a live feed *and* to render correctly in the
in-app reader. Candidates that parsed but produced only terse changelogs or
teaser text were rejected rather than shipped.

---

## Building

Requires Xcode 26 or later and macOS 14 or later.

```bash
git clone https://github.com/angilyu/ai-daily.git
cd ai-daily
open AIDaily.xcodeproj
```

Then build and run (`⌘R`). Or from the command line:

```bash
xcodebuild -scheme AIDaily -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual build

open build/Build/Products/Debug/AIDaily.app
```

The project targets macOS 14.0. To enable the Claude features, open
**Settings → AI** and paste an Anthropic API key from
[console.anthropic.com](https://console.anthropic.com/settings/keys). The app is
fully usable without one.

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (object version 77),
so files added to the `AIDaily` directory are picked up automatically without
editing the project file.

### Testing

The services are deliberately free of UI dependencies, so they can be compiled
into standalone Swift executables and run against real data — live feeds, real
HTML, and the app's own persisted store. That's how the extractor, summarizer,
classifier, scheduler, prompt compilers, and Claude summarizer were all validated: not against
fixtures, but against the actual pages and headlines they'd see in production.

---

## Known limitations

- **Bundle identifier is still `com.example.AIDaily`.** Change it before
  distributing.
- **No app icon.** The asset catalog slot is empty.
- **Not on the App Store.** Shipping requires a paid Apple Developer Program
  membership and a real signing identity.
- **Two live articles in 32 aren't extractable** — JavaScript-rendered or
  paywalled pages. These fall back to the feed summary with a link out.
- **Slow blogs can go invisible.** Sources that post less than once a fortnight
  fall outside the retention window entirely. Keeping each source's most recent
  post regardless of age would fix this.
- **Transcripts summarize poorly without a key.** Extractive ranking assumes
  expository prose; Claude handles them fine.
- **Claude features need network access and a paid API key.** Without either,
  the app falls back silently to keyword rules and extractive summaries.
- **A channel can only match what's already in your sources.** A prompt about a
  topic none of the feeds cover compiles fine and matches nothing. The editor
  says so explicitly rather than showing a blank list.

---

## License

MIT
