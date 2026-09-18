import Foundation

/// Optional billing fields supplied by OpenRouter, never estimated from text.
public struct OpenRouterUsage: Codable, Equatable, Sendable {
    public let cost: Double?
    public let seconds: Double?
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cost, seconds
        case totalTokens = "total_tokens", inputTokens = "input_tokens", outputTokens = "output_tokens"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func amount(_ key: CodingKeys) -> Double? {
            guard let value = try? values.decode(Double.self, forKey: key), value.isFinite,
                  value >= 0, value <= 1e12 else { return nil }
            return value
        }
        func tokens(_ key: CodingKeys) -> Int? {
            guard let value = try? values.decode(Int.self, forKey: key), value >= 0, value <= 1_000_000_000_000 else { return nil }
            return value
        }
        cost = amount(.cost)
        seconds = amount(.seconds)
        let input = tokens(.inputTokens)
        let output = tokens(.outputTokens)
        inputTokens = input
        outputTokens = output
        totalTokens = tokens(.totalTokens) ?? input.flatMap { input in output.map { input + $0 } }
    }
}

/// Totals belong to committed sections of one transcript generation. Missing
/// fields remain visibly unknown; they must not masquerade as zero-cost usage.
public struct CloudUsageTotals: Codable, Equatable, Sendable {
    public private(set) var sections: Int
    public private(set) var costSections = 0
    public private(set) var tokenSections = 0
    public private(set) var inputTokenSections = 0
    public private(set) var outputTokenSections = 0
    public private(set) var costUSD = 0.0
    public private(set) var totalTokens = 0
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var lastSectionCostPerAudioHour: Double?

    public init(unreportedSections: Int = 0) {
        sections = unreportedSections
    }

    public func adding(_ usage: OpenRouterUsage?) -> Self {
        var next = self
        next.sections += 1
        if let value = usage?.cost {
            next.costUSD += value; next.costSections += 1
        }
        if let value = usage?.totalTokens {
            next.totalTokens += value; next.tokenSections += 1
        }
        if let value = usage?.inputTokens {
            next.inputTokens += value; next.inputTokenSections += 1
        }
        if let value = usage?.outputTokens {
            next.outputTokens += value; next.outputTokenSections += 1
        }
        if let cost = usage?.cost, let seconds = usage?.seconds, seconds > 0 {
            let rate = cost / seconds * 3600
            next.lastSectionCostPerAudioHour = rate.isFinite ? rate : nil
        } else {
            next.lastSectionCostPerAudioHour = nil
        }
        return next
    }
}
