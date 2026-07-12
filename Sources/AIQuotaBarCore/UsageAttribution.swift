import Foundation

public struct QuotaReading: Equatable, Sendable {
    public let timestamp: Date
    public let remainingPercent: Int
    public let sessionID: String?

    public init(timestamp: Date, remainingPercent: Int, sessionID: String?) {
        self.timestamp = timestamp
        self.remainingPercent = remainingPercent
        self.sessionID = sessionID
    }
}

public enum UsageAttribution {
    /// Returns an observed quota drop only when both readings belong to the same task.
    /// Ambiguous task switches are intentionally left unattributed.
    public static func quotaDrop(
        for sessionID: String,
        from previous: QuotaReading,
        to current: QuotaReading,
        maximumInterval: TimeInterval = 3 * 60
    ) -> Double? {
        guard previous.sessionID == sessionID,
              current.sessionID == sessionID,
              current.timestamp >= previous.timestamp,
              current.timestamp.timeIntervalSince(previous.timestamp) <= maximumInterval
        else { return nil }

        let drop = previous.remainingPercent - current.remainingPercent
        guard drop > 0 else { return nil }
        return Double(drop)
    }
}

public enum CodexBarCLI {
    public static func executablePath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        var candidates: [String] = []
        if let override = environment["AI_QUOTA_BAR_CODEXBAR_CLI"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: [
            "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
            "/opt/homebrew/bin/codexbar",
            "/usr/local/bin/codexbar"
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
