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

struct TokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// Per-model pricing in USD per token — mirrors Anthropic public API pricing.
struct ModelPricing {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheWritePerToken: Double
    let cacheReadPerToken: Double

    static let table: [String: ModelPricing] = [
        "claude-sonnet-4-6":        .init(input: 3.0,   output: 15.0,  cacheWrite: 3.75,  cacheRead: 0.30),
        "claude-sonnet-4-5":        .init(input: 3.0,   output: 15.0,  cacheWrite: 3.75,  cacheRead: 0.30),
        "claude-haiku-4-5":         .init(input: 0.80,  output: 4.0,   cacheWrite: 1.0,   cacheRead: 0.08),
        "claude-haiku-4-5-20251001":.init(input: 0.80,  output: 4.0,   cacheWrite: 1.0,   cacheRead: 0.08),
        "claude-opus-4-7":          .init(input: 15.0,  output: 75.0,  cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-4-6":          .init(input: 15.0,  output: 75.0,  cacheWrite: 18.75, cacheRead: 1.50),
    ]

    // Sonnet pricing as conservative fallback for unrecognised models
    static let fallback = ModelPricing.init(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30)

    // Convenience init — rates in USD per 1M tokens
    private init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        inputPerToken      = input      / 1_000_000
        outputPerToken     = output     / 1_000_000
        cacheWritePerToken = cacheWrite / 1_000_000
        cacheReadPerToken  = cacheRead  / 1_000_000
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
        return Double(inputTokens ?? 0)               * p.inputPerToken
             + Double(outputTokens ?? 0)              * p.outputPerToken
             + Double(cacheCreationInputTokens ?? 0)  * p.cacheWritePerToken
             + Double(cacheReadInputTokens ?? 0)      * p.cacheReadPerToken
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
