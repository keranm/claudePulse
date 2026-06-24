import Foundation

struct JSONLEntry: Decodable {
    let type: String?
    let timestamp: Date?
    let message: MessagePayload?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, message, requestId
    }
}

struct MessagePayload: Decodable {
    let role: String?
    let model: String?
    let usage: TokenUsage?
}

// TTL breakdown for cache writes — Claude Code uses 1h-TTL caches heavily,
// which cost 2×/token vs 5m-TTL at 1.25×/token.
private struct CacheCreation: Decodable {
    let ephemeral1hInputTokens: Int?
    let ephemeral5mInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
    }
}

struct TokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?   // total write tokens (backward compat)
    let cacheReadInputTokens: Int?
    private let cacheCreation: CacheCreation?   // TTL-split breakdown (newer logs)

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }

    // 5-minute cache writes (1.25× rate). Falls back to total write count when
    // TTL breakdown is absent (older JSONL format).
    var cache5mWriteTokens: Int {
        if let breakdown = cacheCreation {
            return breakdown.ephemeral5mInputTokens ?? 0
        }
        return cacheCreationInputTokens ?? 0
    }

    // 1-hour cache writes (2× rate). Zero for older JSONL without the breakdown.
    var cache1hWriteTokens: Int {
        cacheCreation?.ephemeral1hInputTokens ?? 0
    }
}

// Per-model pricing in USD per token — mirrors Anthropic public API pricing.
struct ModelPricing {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheWrite5mPerToken: Double   // 1.25× input rate (5-minute TTL)
    let cacheWrite1hPerToken: Double   // 2.0× input rate (1-hour TTL)
    let cacheReadPerToken: Double

    static let table: [String: ModelPricing] = [
        // Fable 5 / Mythos 5 — $10/$50 per 1M
        "claude-fable-5":           .init(input: 10.0, output: 50.0,  cacheWrite5m: 12.50, cacheWrite1h: 20.0, cacheRead: 1.00),
        "claude-mythos-5":          .init(input: 10.0, output: 50.0,  cacheWrite5m: 12.50, cacheWrite1h: 20.0, cacheRead: 1.00),
        // Opus 4.x — $5/$25 per 1M (was incorrectly $15/$75)
        "claude-opus-4-8":          .init(input: 5.0,  output: 25.0,  cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-7":          .init(input: 5.0,  output: 25.0,  cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-6":          .init(input: 5.0,  output: 25.0,  cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
        // Sonnet 4.x — $3/$15 per 1M
        "claude-sonnet-4-6":        .init(input: 3.0,  output: 15.0,  cacheWrite5m: 3.75,  cacheWrite1h: 6.0,  cacheRead: 0.30),
        "claude-sonnet-4-5":        .init(input: 3.0,  output: 15.0,  cacheWrite5m: 3.75,  cacheWrite1h: 6.0,  cacheRead: 0.30),
        // Haiku 4.x — $1/$5 per 1M (was incorrectly $0.80/$4.0)
        "claude-haiku-4-5":         .init(input: 1.0,  output: 5.0,   cacheWrite5m: 1.25,  cacheWrite1h: 2.0,  cacheRead: 0.10),
        "claude-haiku-4-5-20251001":.init(input: 1.0,  output: 5.0,   cacheWrite5m: 1.25,  cacheWrite1h: 2.0,  cacheRead: 0.10),
    ]

    // Sonnet pricing as conservative fallback for unrecognised models
    static let fallback = ModelPricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30)

    // Convenience init — rates in USD per 1M tokens
    private init(input: Double, output: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double) {
        inputPerToken        = input        / 1_000_000
        outputPerToken       = output       / 1_000_000
        cacheWrite5mPerToken = cacheWrite5m / 1_000_000
        cacheWrite1hPerToken = cacheWrite1h / 1_000_000
        cacheReadPerToken    = cacheRead    / 1_000_000
    }

    static func forModel(_ model: String?) -> ModelPricing {
        guard let model else { return fallback }
        if let exact = table[model] { return exact }
        for (key, pricing) in table where model.hasPrefix(key) || key.hasPrefix(model) {
            return pricing
        }
        return fallback
    }
}

extension TokenUsage {
    func cost(for model: String?) -> Double {
        let p = ModelPricing.forModel(model)
        return Double(inputTokens ?? 0)          * p.inputPerToken
             + Double(outputTokens ?? 0)         * p.outputPerToken
             + Double(cache5mWriteTokens)         * p.cacheWrite5mPerToken
             + Double(cache1hWriteTokens)         * p.cacheWrite1hPerToken
             + Double(cacheReadInputTokens ?? 0)  * p.cacheReadPerToken
    }
}

final class JSONLParser {
    // Both formatters are constants — no per-line allocation
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = JSONLParser.isoWithFraction.date(from: str) { return date }
            if let date = JSONLParser.isoPlain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Cannot parse date: \(str)")
        }
        return d
    }()

    func parse(fileURL: URL) -> [JSONLEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var results: [JSONLEntry] = []
        results.reserveCapacity(64)
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(JSONLEntry.self, from: data) else { continue }
            results.append(entry)
        }
        return results
    }
}
