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

public struct CodexUsageWindow: Equatable, Sendable {
    public let id: String
    public let title: String
    public let remainingPercent: Int
    public let usedPercent: Int
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let isSpark: Bool

    public init(
        id: String,
        title: String,
        remainingPercent: Int,
        usedPercent: Int,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        isSpark: Bool
    ) {
        self.id = id
        self.title = title
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.isSpark = isSpark
    }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let primary: CodexUsageWindow?
    public let secondary: CodexUsageWindow?
    public let extraWindows: [CodexUsageWindow]
    public let availableResetCount: Int
    public let earliestResetExpiry: Date?
    public let dataConfidence: String?
    public let updatedAt: Date?

    public init(
        primary: CodexUsageWindow?,
        secondary: CodexUsageWindow?,
        extraWindows: [CodexUsageWindow],
        availableResetCount: Int,
        earliestResetExpiry: Date?,
        dataConfidence: String?,
        updatedAt: Date?
    ) {
        self.primary = primary
        self.secondary = secondary
        self.extraWindows = extraWindows
        self.availableResetCount = availableResetCount
        self.earliestResetExpiry = earliestResetExpiry
        self.dataConfidence = dataConfidence
        self.updatedAt = updatedAt
    }

    public var allWindows: [CodexUsageWindow] {
        [primary, secondary].compactMap { $0 } + extraWindows
    }

    public var sparkWindow: CodexUsageWindow? {
        extraWindows.first(where: \.isSpark)
    }

    public func trackedWindow(for model: String?) -> CodexUsageWindow? {
        if model?.localizedCaseInsensitiveContains("spark") == true,
           let sparkWindow
        {
            return sparkWindow
        }
        return primary ?? secondary
    }
}

public enum CodexUsageParser {
    private struct ProviderPayload: Decodable {
        let provider: String
        let usage: UsagePayload?
    }

    private struct UsagePayload: Decodable {
        let primary: WindowPayload?
        let secondary: WindowPayload?
        let extraRateWindows: [ExtraWindowPayload]?
        let codexResetCredits: ResetCreditsPayload?
        let dataConfidence: String?
        let updatedAt: Date?
    }

    private struct ExtraWindowPayload: Decodable {
        let id: String
        let title: String
        let window: WindowPayload
    }

    private struct WindowPayload: Decodable {
        let resetDescription: String?
        let resetsAt: Date?
        let usedPercent: Int?
        let windowMinutes: Int?
    }

    private struct ResetCreditsPayload: Decodable {
        let availableCount: Int?
        let credits: [ResetCreditPayload]?
    }

    private struct ResetCreditPayload: Decodable {
        let status: String?
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
        }
    }

    public static func parse(_ output: String, now: Date = Date()) -> CodexUsageSnapshot? {
        guard let data = output.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payloads = try? decoder.decode([ProviderPayload].self, from: data),
              let usage = payloads.first(where: { $0.provider.lowercased() == "codex" })?.usage
        else { return nil }

        let primary = usage.primary.flatMap {
            window(from: $0, id: "codex-primary", title: title(for: $0, fallback: "Codex额度"), isSpark: false)
        }
        let secondary = usage.secondary.flatMap {
            window(from: $0, id: "codex-weekly", title: "Codex一周", isSpark: false)
        }
        let extras = (usage.extraRateWindows ?? []).compactMap { extra in
            window(
                from: extra.window,
                id: extra.id,
                title: normalizedExtraTitle(extra.title, id: extra.id),
                isSpark: extra.id.localizedCaseInsensitiveContains("spark")
                    || extra.title.localizedCaseInsensitiveContains("spark"))
        }

        let credits = usage.codexResetCredits?.credits ?? []
        let availableCredits = credits.filter {
            $0.status == "available" && ($0.expiresAt ?? .distantFuture) > now
        }
        let availableCount = usage.codexResetCredits?.availableCount ?? availableCredits.count
        let earliestExpiry = availableCredits.compactMap(\.expiresAt).min()

        guard primary != nil || secondary != nil || !extras.isEmpty || availableCount > 0 else {
            return nil
        }
        return CodexUsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraWindows: extras,
            availableResetCount: availableCount,
            earliestResetExpiry: earliestExpiry,
            dataConfidence: usage.dataConfidence,
            updatedAt: usage.updatedAt)
    }

    private static func window(
        from payload: WindowPayload,
        id: String,
        title: String,
        isSpark: Bool
    ) -> CodexUsageWindow? {
        guard let usedPercent = payload.usedPercent else { return nil }
        let boundedUsed = max(0, min(100, usedPercent))
        return CodexUsageWindow(
            id: id,
            title: title,
            remainingPercent: 100 - boundedUsed,
            usedPercent: boundedUsed,
            windowMinutes: payload.windowMinutes,
            resetsAt: payload.resetsAt,
            resetDescription: payload.resetDescription,
            isSpark: isSpark)
    }

    private static func title(for payload: WindowPayload, fallback: String) -> String {
        switch payload.windowMinutes {
        case 300: return "5小时"
        case 10_080: return "Codex一周"
        case let minutes?: return "\(minutes)分钟"
        case nil: return fallback
        }
    }

    private static func normalizedExtraTitle(_ title: String, id: String) -> String {
        if id.localizedCaseInsensitiveContains("spark")
            || title.localizedCaseInsensitiveContains("spark")
        {
            return "Spark一周"
        }
        return title
    }
}
