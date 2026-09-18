import SwiftUI

struct CloudUsageStatsView: View {
    let usage: CloudUsageTotals?
    let modelID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Reported cost: \(cost) · Tokens: \(tokens)")
                .monospacedDigit()
            if let usage, usage.inputTokenSections > 0 || usage.outputTokenSections > 0 {
                Text("Input tokens: \(count(usage.inputTokens, reported: usage.inputTokenSections, sections: usage.sections)) · Output tokens: \(count(usage.outputTokens, reported: usage.outputTokenSections, sections: usage.sections))")
                    .monospacedDigit()
            }
            if let rate = usage?.lastSectionCostPerAudioHour {
                Text("Last section rate: \(usd(rate)) / audio hour")
                    .monospacedDigit()
            }
            Link("Current model pricing", destination: URL(string: "https://openrouter.ai/\(modelID)")!)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("OpenRouter usage for saved sections, updated after each response. Partial means some sections did not report usage. Failed or cancelled requests may add charges not shown here. The last section rate is observed cost, not a quote for future requests.")
    }

    private var cost: String {
        guard let usage, usage.sections > 0 else { return "Waiting for first section" }
        guard usage.costSections > 0 else { return "Not reported" }
        return usd(usage.costUSD) + (usage.costSections < usage.sections ? " (partial)" : "")
    }

    private var tokens: String {
        guard let usage, usage.sections > 0 else { return "Waiting for first section" }
        return count(usage.totalTokens, reported: usage.tokenSections, sections: usage.sections)
    }

    private func count(_ value: Int, reported: Int, sections: Int) -> String {
        guard reported > 0 else { return "Not reported" }
        return value.formatted() + (reported < sections ? " (partial)" : "")
    }

    private func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2 ... 6))) + " USD"
    }
}
