import Foundation

let appVersion = "1.1.5"

func localized(_ english: String, _ korean: String) -> String {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
    return language.hasPrefix("ko") ? korean : english
}

struct UsageWindow: Codable {
    let slot: String
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditInfo: Codable {
    let availableCount: Int?
    let earliestExpiresAt: Int?
}

struct ResetCredit: Codable, Equatable {
    let id: String
    let expiresAt: Date
}

struct UsagePayload: Codable {
    let bucketLabel: String?
    let windows: [UsageWindow]
    let credits: CreditInfo
    var resetCredits: [ResetCredit] = []
    var isCoreCodex: Bool = false
    // Diagnostics remain sanitized; identifiers are internal to the worker.
    enum CodingKeys: String, CodingKey { case bucketLabel, windows, credits }

}
