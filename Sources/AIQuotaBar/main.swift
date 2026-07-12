import AppKit
import AIQuotaBarCore
import Darwin
import Foundation
import SQLite3

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var lastOutput = "Loading..."
    private var lastGoodTitle: String?
    private var lastGoodAttributedTitle: NSAttributedString?
    private var lastRefreshDate: Date?
    private let claudeIconPath = "/Applications/Claude.app"
    private var codexIconPath: String {
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        return candidates.first(where: FileManager.default.fileExists(atPath:)) ?? candidates[0]
    }
    private let claudeHistoryPath = "\(NSHomeDirectory())/Library/Application Support/com.steipete.codexbar/history/claude.json"
    private let codexHistoryPath = "\(NSHomeDirectory())/Library/Application Support/com.steipete.codexbar/history/codex.json"
    private let codexHomePath = "\(NSHomeDirectory())/.codex"
    private let historyResetMaxAge: TimeInterval = 15 * 60
    private let showClaudeSection = false

    private struct QuotaInfo {
        let session: Int
        let weekly: Int
        let sessionReset: String?
        let weeklyReset: String?

        func usingResets(from other: QuotaInfo?) -> QuotaInfo {
            QuotaInfo(
                session: session,
                weekly: weekly,
                sessionReset: sessionReset ?? other?.sessionReset,
                weeklyReset: weeklyReset ?? other?.weeklyReset)
        }
    }

    private struct HistoryFile: Decodable {
        let accounts: [String: [HistoryWindow]]?
        let preferredAccountKey: String?
        let unscoped: [HistoryWindow]?
    }

    private struct HistoryWindow: Decodable {
        let entries: [HistoryEntry]
        let name: String
    }

    private struct HistoryEntry: Decodable {
        let capturedAt: Date?
        let resetsAt: Date?
        let usedPercent: Int?
    }

    private struct ProviderPayload: Decodable {
        let provider: String
        let usage: ProviderUsage?
    }

    private struct ProviderUsage: Decodable {
        let primary: RateWindow?
        let secondary: RateWindow?
    }

    private struct RateWindow: Decodable {
        let resetDescription: String?
        let resetsAt: Date?
        let usedPercent: Int?
        let windowMinutes: Int?
    }

    private struct CodexTaskUsage {
        let title: String
        let updatedAt: Date
        let primaryDelta: Double?
        let tokenTotal: Int?
    }

    private struct CodexQuotaReading: Codable {
        let timestamp: Date
        let primaryRemaining: Int
        let weeklyRemaining: Int
        let trackedWindowID: String?
        let trackedWindowTitle: String?
        let sessionId: String?
        let sessionTitle: String?
        let sessionTotalTokens: Int?
        let sessionModel: String?
    }

    private struct CodexSessionInfo {
        let id: String
        let title: String
        let lastActivity: Date
        let totalTokens: Int
        let model: String?
    }

    private struct CodexThreadInfo {
        let id: String
        let title: String
        let lastActivity: Date
        let totalTokens: Int
        let cwd: String?
        let rolloutPath: String?
    }

    private enum CodexTurnState {
        case running
        case stopped
        case unknown
    }

    private struct CodexTurnSnapshot {
        let state: CodexTurnState
        let progressText: String?
    }

    private struct CodexReportTask {
        let id: String
        let title: String
        let model: String
        let tokenDelta: Int?
        let tokenTotal: Int?
        let quotaDelta: Double?
        let quotaWindowID: String?
        let quotaWindowTitle: String
        let firstSeen: Date
        let lastSeen: Date
        let sessionFile: URL?
    }

    private struct TaskRadarSnapshot {
        let runningCount: Int
        let doneCount: Int
        let recentCount: Int
        let sleepingCount: Int
        let within2HoursCount: Int
        let within24HoursCount: Int
        let within72HoursCount: Int
        let otherCount: Int
        let totalCount: Int
        let hiddenCount: Int
        let groups: [TaskRadarGroup]
        let items: [TaskRadarItem]

        var attentionCount: Int {
            runningCount + doneCount
        }

        var menuSummary: String {
            "跑\(runningCount) · 2h \(within2HoursCount) · 24h \(within24HoursCount)"
        }

        var titleSuffix: String? {
            guard totalCount > 0 else { return nil }
            let timeSummary = "2h\(within2HoursCount) 24h\(within24HoursCount)"
            guard runningCount > 0 else { return timeSummary }
            return "跑\(runningCount) \(timeSummary)"
        }
    }

    private struct TaskRadarGroup {
        let title: String
        let totalCount: Int
        let items: [TaskRadarItem]

        var hiddenCount: Int {
            max(0, totalCount - items.count)
        }
    }

    private struct TaskRadarItem {
        let id: String
        let title: String
        let updatedAt: Date
        let status: TaskRadarStatus
        let tokenTotal: Int
        let cwd: String?
        let progressText: String?
    }

    private enum TaskRadarStatus {
        case running
        case done
        case recent
        case sleeping

        var label: String {
            switch self {
            case .running: return "跑"
            case .done: return "完"
            case .recent: return "近"
            case .sleeping: return "沉"
            }
        }

        var color: NSColor {
            switch self {
            case .running: return .systemGreen
            case .done: return .systemBlue
            case .recent: return .secondaryLabelColor
            case .sleeping: return .systemOrange
            }
        }
    }

    private struct ClaudeQuotaReading: Codable {
        let timestamp: Date
        let primaryRemaining: Int
        let weeklyRemaining: Int
        let sessionId: String?
        let sessionTitle: String?
        let sessionTotalTokens: Int?
        let sessionModel: String?
        let sessionHasThinking: Bool?
    }

    private struct ClaudeSessionInfo {
        let id: String
        let title: String
        let lastActivity: Date
        let totalTokens: Int
        let model: String?
        let hasThinking: Bool
    }

    private var claudeLedger: [ClaudeQuotaReading] = []
    private var codexLedger: [CodexQuotaReading] = []
    private var lastClaudeTasks: [CodexTaskUsage] = []
    private var lastCodexTasks: [CodexTaskUsage] = []
    private var lastTaskRadarSnapshot = TaskRadarSnapshot(
        runningCount: 0,
        doneCount: 0,
        recentCount: 0,
        sleepingCount: 0,
        within2HoursCount: 0,
        within24HoursCount: 0,
        within72HoursCount: 0,
        otherCount: 0,
        totalCount: 0,
        hiddenCount: 0,
        groups: [],
        items: [])
    private let claudeLedgerPath = NSHomeDirectory() + "/Library/Application Support/AI Quota Bar/claude-task-usage.json"
    // v3 records which server-provided window is being tracked. This prevents
    // five-hour and weekly percentages from being compared after rule changes.
    private let codexLedgerPath = NSHomeDirectory() + "/Library/Application Support/AI Quota Bar/codex-task-usage-v3.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        if let button = statusItem.button {
            button.title = "AI ..."
            button.toolTip = showClaudeSection ? "Claude / Codex quota" : "Codex quota"
        }
        menu.autoenablesItems = false
        statusItem.menu = menu
        loadClaudeLedger()
        loadCodexLedger()
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let output = self.fetchUsage()
            let activeSession = self.showClaudeSection ? self.activeClaudeSession() : nil
            let recentSessions = self.showClaudeSection ? self.fetchRecentClaudeSessions(limit: 5) : []
            let activeCodexSession = self.activeCodexSession()
            let recentCodexSessions = self.fetchRecentCodexSessions(limit: 5)
            DispatchQueue.main.async {
                self.lastOutput = output
                self.lastRefreshDate = Date()
                let quotas = self.quotaInfoByProvider(fromJSON: output)
                let codexUsage = CodexUsageParser.parse(output)
                if self.showClaudeSection, let claude = quotas["claude"] {
                    self.updateClaudeLedger(claude: claude, activeSession: activeSession)
                }
                if let codexUsage {
                    self.updateCodexLedger(codex: codexUsage, activeSession: activeCodexSession)
                }
                self.lastClaudeTasks = self.showClaudeSection ? self.mergeClaudeTaskUsages(sessions: recentSessions) : []
                self.lastCodexTasks = self.mergeCodexTaskUsages(sessions: recentCodexSessions)
                self.updateTitle(from: output, isManualRefresh: false)
                self.rebuildMenu()
            }
            let taskRadarSnapshot = self.taskRadarSnapshot()
            DispatchQueue.main.async {
                self.lastTaskRadarSnapshot = taskRadarSnapshot
                self.updateTitle(from: self.lastOutput, isManualRefresh: false)
                self.rebuildMenu()
            }
        }
    }

    private func fetchUsage() -> String {
        guard let cliPath = CodexBarCLI.executablePath() else {
            return "未找到 CodexBarCLI，请先安装 CodexBar"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["usage", "--provider", showClaudeSection ? "both" : "codex", "--format", "json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            if !process.waitUntilExit(timeout: 25) {
                process.terminate()
                return "Refresh timed out"
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "No output"
        } catch {
            return "Refresh failed: \(error.localizedDescription)"
        }
    }

    private func updateTitle(from output: String, isManualRefresh: Bool) {
        let jsonQuotas = quotaInfoByProvider(fromJSON: output)
        let codex = CodexUsageParser.parse(output)
        let claude = showClaudeSection
            ? (jsonQuotas["claude"] ?? quotaInfo(for: "Claude", in: output))?.usingResets(from: historyInfo(at: claudeHistoryPath))
            : nil

        let title: String?
        switch (claude, codex) {
        case let (.some(claude), .some(codex)):
            title = "Cl \(claude.session)/\(claude.weekly) Cx \(codexTitleSummary(codex))"
            setIconTitle(claude: claude, codex: codex)
        case let (.some(claude), .none):
            title = "Cl \(claude.session)/\(claude.weekly)"
            setPlainTitle("Cl \(claude.session)/\(claude.weekly)")
        case let (.none, .some(codex)):
            title = "Cx \(codexTitleSummary(codex))"
            setCodexIconTitle(codex: codex)
        default:
            title = nil
        }

        if let title {
            lastGoodTitle = title
            statusItem.button?.toolTip = showClaudeSection ? "Click for Claude / Codex quota details" : "Click for Codex quota details"
        } else if let lastGoodAttributedTitle {
            statusItem.button?.attributedTitle = lastGoodAttributedTitle
            statusItem.button?.toolTip = "Last refresh failed. Click for details."
        } else if let lastGoodTitle {
            setPlainTitle(lastGoodTitle)
            statusItem.button?.toolTip = "Last refresh failed. Click for details."
        } else if isManualRefresh {
            setPlainTitle("AI ...")
            statusItem.button?.toolTip = showClaudeSection ? "Refreshing Claude / Codex quota..." : "Refreshing Codex quota..."
        } else {
            setPlainTitle("AI ...")
            statusItem.button?.toolTip = showClaudeSection ? "Waiting for Claude / Codex quota data..." : "Waiting for Codex quota data..."
        }
    }

    private func setPlainTitle(_ title: String) {
        statusItem.button?.attributedTitle = NSAttributedString(string: title)
    }

    private func setIconTitle(claude: QuotaInfo, codex: CodexUsageSnapshot) {
        let result = NSMutableAttributedString()
        appendIcon(from: claudeIconPath, to: result)
        result.append(NSAttributedString(string: " ", attributes: titleAttributes))
        appendQuotaBlock(claude, to: result)
        result.append(NSAttributedString(string: "   ", attributes: titleAttributes))
        appendIcon(from: codexIconPath, to: result)
        result.append(NSAttributedString(string: " ", attributes: titleAttributes))
        appendCodexUsageTitle(codex, to: result)
        lastGoodAttributedTitle = result
        statusItem.button?.attributedTitle = result
    }

    private func setCodexIconTitle(codex: CodexUsageSnapshot) {
        let result = NSMutableAttributedString()
        appendIcon(from: codexIconPath, to: result)
        result.append(NSAttributedString(string: " ", attributes: titleAttributes))
        appendCodexUsageTitle(codex, to: result)
        if let suffix = lastTaskRadarSnapshot.titleSuffix {
            result.append(NSAttributedString(string: "  ", attributes: titleAttributes))
            appendRadarTitleSuffix(suffix, to: result)
        }
        lastGoodAttributedTitle = result
        statusItem.button?.attributedTitle = result
    }

    private func appendRadarTitleSuffix(_ suffix: String, to text: NSMutableAttributedString) {
        let parts = suffix.split(separator: " ", maxSplits: 1).map(String.init)
        if let first = parts.first {
            text.append(NSAttributedString(
                string: first,
                attributes: radarTitleAttributes(color: first == "●0" ? .tertiaryLabelColor : .systemBlue)))
        }
        if parts.count > 1 {
            text.append(NSAttributedString(string: " \(parts[1])", attributes: titleAttributes))
        }
    }

    private func appendQuotaBlock(_ quota: QuotaInfo, to text: NSMutableAttributedString) {
        text.append(NSAttributedString(
            string: "\(quota.session)",
            attributes: quotaAttributes(percent: quota.session)))
        text.append(NSAttributedString(
            string: titleSessionReset(quota.sessionReset),
            attributes: footnoteAttributes(position: .lower)))
        text.append(NSAttributedString(string: " ", attributes: titleAttributes))
        text.append(NSAttributedString(
            string: "\(quota.weekly)",
            attributes: quotaAttributes(percent: quota.weekly)))
        text.append(NSAttributedString(
            string: titleWeeklyReset(quota.weeklyReset),
            attributes: footnoteAttributes(position: .superscript)))
    }

    private func codexTitleWindows(_ usage: CodexUsageSnapshot) -> [CodexUsageWindow] {
        if usage.primary != nil {
            return [usage.primary, usage.secondary].compactMap { $0 }
        }
        return [usage.secondary, usage.sparkWindow].compactMap { $0 }
    }

    private func codexTitleSummary(_ usage: CodexUsageSnapshot) -> String {
        codexTitleWindows(usage).map { window in
            window.isSpark ? "S\(window.remainingPercent)" : "\(window.remainingPercent)"
        }.joined(separator: "/")
    }

    private func appendCodexUsageTitle(_ usage: CodexUsageSnapshot, to text: NSMutableAttributedString) {
        let windows = codexTitleWindows(usage)
        for (index, window) in windows.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: " ", attributes: titleAttributes))
            }
            if window.isSpark {
                text.append(NSAttributedString(string: "S", attributes: titleAttributes))
            }
            text.append(NSAttributedString(
                string: "\(window.remainingPercent)",
                attributes: quotaAttributes(percent: window.remainingPercent)))
            let reset = resetString(for: window)
            let isShortWindow = (window.windowMinutes ?? 0) <= 24 * 60
            text.append(NSAttributedString(
                string: isShortWindow ? titleSessionReset(reset) : titleWeeklyReset(reset),
                attributes: footnoteAttributes(position: isShortWindow ? .lower : .superscript)))
        }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private func radarTitleAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color
        ]
    }

    private enum FootnotePosition {
        case lower
        case superscript
    }

    private func quotaAttributes(percent: Int) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: quotaColor(percent: percent)
        ]
    }

    private func footnoteAttributes(position: FootnotePosition) -> [NSAttributedString.Key: Any] {
        _ = position
        return [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.white
        ]
    }

    private func quotaColor(percent: Int) -> NSColor {
        if percent < 20 {
            return .systemRed
        }
        if percent <= 50 {
            return .systemBlue
        }
        return .systemGreen
    }

    private func appendIcon(from appPath: String, to text: NSMutableAttributedString) {
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: 16, height: 16)

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
        text.append(NSAttributedString(attachment: attachment))
    }

    private func quotaInfo(for provider: String, in output: String) -> QuotaInfo? {
        let lines = output.components(separatedBy: .newlines)
        var inSection = false
        var session: Int?
        var weekly: Int?
        var sessionReset: String?
        var weeklyReset: String?
        var resetTarget: String?

        for line in lines {
            if line.hasPrefix("== ") {
                inSection = line.localizedCaseInsensitiveContains(provider)
                continue
            }

            guard inSection else { continue }
            if line.hasPrefix("== ") { break }

            if line.hasPrefix("Session:") {
                session = percentValue(in: line)
                resetTarget = "session"
            } else if line.hasPrefix("Weekly:") {
                weekly = percentValue(in: line)
                resetTarget = "weekly"
            } else if line.hasPrefix("Resets") {
                let reset = resetValue(in: line)
                if resetTarget == "session" {
                    sessionReset = reset
                } else if resetTarget == "weekly" {
                    weeklyReset = reset
                }
                resetTarget = nil
            }
        }

        guard let session, let weekly else { return nil }
        return QuotaInfo(
            session: session,
            weekly: weekly,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset)
    }

    private func percentValue(in line: String) -> Int? {
        let pattern = #"\b([0-9]+)%\s+left"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return Int(line[range])
    }

    private func resetValue(in line: String) -> String? {
        if line.hasPrefix("Resets in ") {
            return compactRelativeReset(String(line.dropFirst("Resets in ".count)))
        }

        if line.hasPrefix("Resets ") {
            let timeText = String(line.dropFirst("Resets ".count))
            return compactAbsoluteReset(timeText)
        }

        return nil
    }

    private func compactRelativeReset(_ value: String) -> String {
        let dayPattern = #"([0-9]+)d"#
        let hourPattern = #"([0-9]+)h"#
        let minutePattern = #"([0-9]+)m"#

        let days = Int(firstMatch(in: value, pattern: dayPattern) ?? "0") ?? 0
        let hours = Int(firstMatch(in: value, pattern: hourPattern) ?? "0") ?? 0
        let minutes = Int(firstMatch(in: value, pattern: minutePattern) ?? "0") ?? 0

        if days > 0 || hours > 0 || minutes > 0 {
            return compactDuration(minutes: max(1, days * 1440 + hours * 60 + minutes))
        }
        return value.replacingOccurrences(of: " ", with: "")
    }

    private func compactAbsoluteReset(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"

        guard let resetTime = formatter.date(from: value) else { return value }

        let calendar = Calendar.current
        let now = Date()
        let parts = calendar.dateComponents([.hour, .minute], from: resetTime)
        guard let hour = parts.hour, let minute = parts.minute else { return value }

        var reset = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now) ?? now

        if reset <= now {
            reset = calendar.date(byAdding: .day, value: 1, to: reset) ?? reset
        }

        return compactResetDate(reset)
    }

    private func compactResetDate(_ date: Date) -> String {
        let minutesLeft = max(1, Int(ceil(date.timeIntervalSinceNow / 60)))
        return compactDuration(minutes: minutesLeft)
    }

    private func compactDuration(minutes totalMinutes: Int) -> String {
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h\(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    private func titleSessionReset(_ reset: String?) -> String {
        guard let duration = durationParts(from: reset) else { return "--" }
        let totalHours = duration.days * 24 + duration.hours
        return subscriptText("\(totalHours):\(String(format: "%02d", duration.minutes))")
    }

    private func titleWeeklyReset(_ reset: String?) -> String {
        guard let duration = durationParts(from: reset) else { return "--" }
        if duration.days > 0 {
            return superscriptText("\(duration.days)d\(duration.hours):\(String(format: "%02d", duration.minutes))")
        }
        if duration.hours > 0 {
            return superscriptText("\(duration.hours):\(String(format: "%02d", duration.minutes))")
        }
        return superscriptText("\(duration.minutes)m")
    }

    private func subscriptText(_ value: String) -> String {
        transform(value, using: [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉"
        ])
    }

    private func superscriptText(_ value: String) -> String {
        transform(value, using: [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "d": "ᵈ", "h": "ʰ", "m": "ᵐ"
        ])
    }

    private func transform(_ value: String, using replacements: [String: String]) -> String {
        value.map { character in
            replacements[String(character)] ?? String(character)
        }.joined()
    }

    private func durationParts(from reset: String?) -> (days: Int, hours: Int, minutes: Int)? {
        guard let reset, reset != "--" else { return nil }
        let days = Int(firstMatch(in: reset, pattern: #"([0-9]+)d"#) ?? "0") ?? 0
        let hours = Int(firstMatch(in: reset, pattern: #"([0-9]+)h"#) ?? "0") ?? 0
        let minutes = Int(firstMatch(in: reset, pattern: #"([0-9]+)m"#) ?? "0") ?? 0

        if days > 0 || hours > 0 || minutes > 0 {
            return (days, hours, minutes)
        }

        let clockPattern = #"^([0-9]+):([0-9]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: clockPattern),
              let match = regex.firstMatch(
                in: reset,
                range: NSRange(reset.startIndex..<reset.endIndex, in: reset)),
              let hourRange = Range(match.range(at: 1), in: reset),
              let minuteRange = Range(match.range(at: 2), in: reset),
              let parsedHours = Int(reset[hourRange]),
              let parsedMinutes = Int(reset[minuteRange])
        else { return nil }

        return (0, parsedHours, parsedMinutes)
    }

    private func quotaInfoByProvider(fromJSON output: String) -> [String: QuotaInfo] {
        guard let data = output.data(using: .utf8) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payloads = try? decoder.decode([ProviderPayload].self, from: data) else { return [:] }

        var result: [String: QuotaInfo] = [:]
        for payload in payloads {
            guard let usage = payload.usage,
                  let primary = usage.primary,
                  let secondary = usage.secondary,
                  let primaryUsed = primary.usedPercent,
                  let secondaryUsed = secondary.usedPercent
            else { continue }

            result[payload.provider.lowercased()] = QuotaInfo(
                session: max(0, 100 - primaryUsed),
                weekly: max(0, 100 - secondaryUsed),
                sessionReset: resetString(for: primary),
                weeklyReset: resetString(for: secondary))
        }
        return result
    }

    private func resetString(for window: RateWindow) -> String? {
        if let resetsAt = window.resetsAt, resetsAt > Date() {
            return compactResetDate(resetsAt)
        }

        if let resetDescription = window.resetDescription {
            let cleaned = resetDescription
                .replacingOccurrences(of: "Resets ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let absolute = compactAbsoluteReset(cleaned) {
                return absolute
            }
            return compactRelativeReset(cleaned)
        }

        return nil
    }

    private func resetString(for window: CodexUsageWindow) -> String? {
        if let resetsAt = window.resetsAt, resetsAt > Date() {
            return compactResetDate(resetsAt)
        }

        if let resetDescription = window.resetDescription {
            let cleaned = resetDescription
                .replacingOccurrences(of: "Resets ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let absolute = compactAbsoluteReset(cleaned) {
                return absolute
            }
            return compactRelativeReset(cleaned)
        }
        return nil
    }

    private func historyInfo(at path: String) -> QuotaInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let history = try? decoder.decode(HistoryFile.self, from: data) else { return nil }

        let windows: [HistoryWindow]
        if let preferredAccountKey = history.preferredAccountKey,
           let accountWindows = history.accounts?[preferredAccountKey] {
            windows = accountWindows
        } else if let accountWindows = history.accounts?.values.first {
            windows = accountWindows
        } else {
            windows = history.unscoped ?? []
        }

        let sessionWindow = windows.first { $0.name == "session" }
        let weeklyWindow = windows.first { $0.name == "weekly" }

        guard let sessionEntry = sessionWindow?.entries.last,
              let weeklyEntry = weeklyWindow?.entries.last,
              let sessionUsed = sessionEntry.usedPercent,
              let weeklyUsed = weeklyEntry.usedPercent
        else { return nil }

        return QuotaInfo(
            session: max(0, 100 - sessionUsed),
            weekly: max(0, 100 - weeklyUsed),
            sessionReset: futureResetString(sessionEntry.resetsAt, capturedAt: sessionEntry.capturedAt),
            weeklyReset: futureResetString(weeklyEntry.resetsAt, capturedAt: weeklyEntry.capturedAt))
    }

    private func futureResetString(_ date: Date?, capturedAt: Date?) -> String? {
        guard let date, date > Date(),
              let capturedAt,
              Date().timeIntervalSince(capturedAt) <= historyResetMaxAge
        else { return nil }
        return compactResetDate(date)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let quotas = quotaInfoByProvider(fromJSON: lastOutput)
        let codexUsage = CodexUsageParser.parse(lastOutput)
        if !quotas.isEmpty || codexUsage != nil {
            if showClaudeSection, let claude = quotas["claude"] {
                addQuotaSectionView(title: "Claude", iconPath: claudeIconPath, quota: claude, tasks: lastClaudeTasks)
            }
            if let codexUsage {
                if showClaudeSection, quotas["claude"] != nil {
                    menu.addItem(.separator())
                }
                addCodexUsageSectionView(codexUsage)
                addTaskRadarSectionView()
            }
            if let lastRefreshDate {
                menu.addItem(.separator())
                addFooterView("最后更新 \(menuTimeFormatter.string(from: lastRefreshDate))")
            }
        } else {
            for line in menuLines(from: lastOutput) {
                let cleaned = line.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty else { continue }
                guard !cleaned.hasPrefix("Account:"),
                      !cleaned.hasPrefix("Web session:")
                else { continue }
                addInfoItem(cleaned)
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshFromMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let reportItem = NSMenuItem(title: "生成用量报告", action: #selector(generateReport), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        let openCodexBar = NSMenuItem(title: "打开 CodexBar", action: #selector(openCodexBarApp), keyEquivalent: "")
        openCodexBar.target = self
        menu.addItem(openCodexBar)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addQuotaSectionView(
        title: String,
        iconPath: String,
        quota: QuotaInfo,
        tasks: [CodexTaskUsage] = []) {
        let item = NSMenuItem()
        item.view = quotaSectionView(title: title, iconPath: iconPath, quota: quota, tasks: tasks)
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addCodexUsageSectionView(_ usage: CodexUsageSnapshot) {
        let item = NSMenuItem()
        item.view = codexQuotaSectionView(usage: usage)
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addTaskRadarSectionView() {
        let snapshot = lastTaskRadarSnapshot
        guard !snapshot.items.isEmpty else { return }

        menu.addItem(.separator())
        let item = NSMenuItem()
        item.view = taskRadarHeaderView(snapshot: snapshot)
        item.isEnabled = false
        menu.addItem(item)

        for group in snapshot.groups where !group.items.isEmpty {
            addTaskGroupHeader(group)
            for task in group.items {
                addTaskMenuItem(task)
            }
        }

        if snapshot.hiddenCount > 0 {
            addInfoItem("还有 \(snapshot.hiddenCount) 个未展开任务，报告页可看完整清单", secondary: true)
        }
    }

    private func addInfoItem(_ title: String, secondary: Bool = false) {
        let item = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 14),
                .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
            ])
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addTaskGroupHeader(_ group: TaskRadarGroup) {
        let suffix = group.hiddenCount > 0 ? "，另 \(group.hiddenCount) 个" : ""
        let title = "\(group.title)  \(group.totalCount) 个\(suffix)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addTaskMenuItem(_ task: TaskRadarItem) {
        let item = NSMenuItem(title: taskMenuTitle(task), action: #selector(openCodexTaskFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = task
        item.attributedTitle = taskMenuAttributedTitle(task)
        item.isEnabled = true
        menu.addItem(item)
    }

    private func taskMenuTitle(_ task: TaskRadarItem) -> String {
        let progressSuffix = task.progressText.map { " · \($0)" } ?? ""
        return "\(task.status.label)  \(task.title)  \(ageText(since: task.updatedAt)) · \(compactTokenCount(task.tokenTotal))\(progressSuffix)"
    }

    private func taskMenuAttributedTitle(_ task: TaskRadarItem) -> NSAttributedString {
        let text = taskMenuTitle(task)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ])
        if let statusRange = text.range(of: task.status.label) {
            result.addAttributes(
                [
                    .font: NSFont.menuFont(ofSize: 13),
                    .foregroundColor: task.status.color
                ],
                range: NSRange(statusRange, in: text))
        }
        return result
    }

    @objc private func openCodexTaskFromMenu(_ sender: NSMenuItem) {
        guard let task = sender.representedObject as? TaskRadarItem else { return }
        openCodexThread(id: task.id, cwd: task.cwd)
    }

    private func openCodexThread(id: String, cwd: String?) {
        if let url = URL(string: "codex://threads/\(id)"),
           NSWorkspace.shared.open(url) {
            return
        }

        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [cwd]
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: codexIconPath),
                configuration: configuration)
            return
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: codexIconPath),
            configuration: NSWorkspace.OpenConfiguration())
    }

    private func addFooterView(_ text: String) {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 30))
        let label = label(text, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        label.frame = NSRect(x: 18, y: 7, width: 320, height: 16)
        view.addSubview(label)
        item.view = view
        item.isEnabled = true
        menu.addItem(item)
    }

    private func quotaSectionView(
        title: String,
        iconPath: String,
        quota: QuotaInfo,
        tasks: [CodexTaskUsage]) -> NSView {
        let taskAreaHeight = tasks.isEmpty ? 0 : CGFloat(36 + tasks.count * 20)
        let viewHeight = CGFloat(112) + taskAreaHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: viewHeight))
        let offset = taskAreaHeight

        let icon = NSImageView(frame: NSRect(x: 18, y: 78 + offset, width: 22, height: 22))
        icon.image = menuIcon(from: iconPath, size: 22)
        view.addSubview(icon)

        let titleLabel = label(title, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
        titleLabel.frame = NSRect(x: 48, y: 78 + offset, width: 330, height: 22)
        view.addSubview(titleLabel)

        addProgressRow(
            to: view,
            y: 43 + offset,
            name: "5小时",
            percent: quota.session,
            reset: chineseDuration(quota.sessionReset))
        addProgressRow(
            to: view,
            y: 12 + offset,
            name: "一周",
            percent: quota.weekly,
            reset: chineseDuration(quota.weeklyReset))

        if !tasks.isEmpty {
            addCodexTaskRows(tasks, to: view)
        }

        return view
    }

    private func codexQuotaSectionView(usage: CodexUsageSnapshot) -> NSView {
        let windows = usage.allWindows
        let creditsHeight: CGFloat = usage.availableResetCount > 0 ? 28 : 0
        let viewHeight = CGFloat(50 + windows.count * 31) + creditsHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: viewHeight))

        let icon = NSImageView(frame: NSRect(x: 18, y: viewHeight - 34, width: 22, height: 22))
        icon.image = menuIcon(from: codexIconPath, size: 22)
        view.addSubview(icon)

        let titleLabel = label("Codex", font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
        titleLabel.frame = NSRect(x: 48, y: viewHeight - 34, width: 230, height: 22)
        view.addSubview(titleLabel)

        if usage.dataConfidence == "exact" {
            let confidence = label("实时", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            confidence.alignment = .right
            confidence.frame = NSRect(x: 300, y: viewHeight - 31, width: 108, height: 16)
            view.addSubview(confidence)
        }

        var rowY = viewHeight - 71
        for window in windows {
            addCodexProgressRow(
                to: view,
                y: rowY,
                name: window.title,
                percent: window.remainingPercent,
                reset: chineseDuration(resetString(for: window)))
            rowY -= 31
        }

        if usage.availableResetCount > 0 {
            let resetTitle = label("完整重置", font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
            resetTitle.frame = NSRect(x: 18, y: 8, width: 72, height: 18)
            view.addSubview(resetTitle)

            let count = label("\(usage.availableResetCount)次可用", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .systemBlue)
            count.frame = NSRect(x: 96, y: 8, width: 78, height: 18)
            view.addSubview(count)

            if let expiry = usage.earliestResetExpiry {
                let expiryLabel = label("最早\(shortChineseDate(expiry))到期", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
                expiryLabel.alignment = .right
                expiryLabel.frame = NSRect(x: 205, y: 8, width: 203, height: 18)
                view.addSubview(expiryLabel)
            }
        }

        return view
    }

    private func addCodexProgressRow(
        to view: NSView,
        y: CGFloat,
        name: String,
        percent: Int,
        reset: String
    ) {
        let nameLabel = label(name, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
        nameLabel.frame = NSRect(x: 18, y: y + 10, width: 72, height: 18)
        view.addSubview(nameLabel)

        let percentLabel = label("\(percent)%", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: quotaColor(percent: percent))
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: 90, y: y + 10, width: 42, height: 18)
        view.addSubview(percentLabel)

        let resetLabel = label(reset, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        resetLabel.alignment = .right
        resetLabel.frame = NSRect(x: 292, y: y + 10, width: 116, height: 18)
        view.addSubview(resetLabel)

        view.addSubview(progressBar(percent: percent, frame: NSRect(x: 140, y: y + 16, width: 140, height: 5)))
    }

    private func shortChineseDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func taskRadarHeaderView(snapshot: TaskRadarSnapshot) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 38))

        let titleLabel = label("Codex 任务监控", font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        titleLabel.frame = NSRect(x: 18, y: 10, width: 140, height: 18)
        view.addSubview(titleLabel)

        let summaryLabel = label(snapshot.menuSummary, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        summaryLabel.alignment = .right
        summaryLabel.frame = NSRect(x: 178, y: 10, width: 232, height: 18)
        view.addSubview(summaryLabel)

        return view
    }

    private func taskRadarView(snapshot: TaskRadarSnapshot) -> NSView {
        let rowHeight: CGFloat = 21
        let groupHeaderHeight: CGFloat = 22
        let footerHeight: CGFloat = snapshot.hiddenCount > 0 ? 22 : 0
        let visibleGroups = snapshot.groups.filter { !$0.items.isEmpty }
        let rowCount = visibleGroups.reduce(0) { $0 + $1.items.count }
        let viewHeight = CGFloat(46)
            + CGFloat(visibleGroups.count) * groupHeaderHeight
            + CGFloat(rowCount) * rowHeight
            + footerHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: viewHeight))

        let titleLabel = label("Codex 任务监控", font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        titleLabel.frame = NSRect(x: 18, y: viewHeight - 28, width: 140, height: 18)
        view.addSubview(titleLabel)

        let summaryLabel = label(snapshot.menuSummary, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        summaryLabel.alignment = .right
        summaryLabel.frame = NSRect(x: 178, y: viewHeight - 28, width: 232, height: 18)
        view.addSubview(summaryLabel)

        var y = viewHeight - 54
        for group in visibleGroups {
            let groupLabel = label(group.title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
            groupLabel.frame = NSRect(x: 18, y: y, width: 180, height: 15)
            view.addSubview(groupLabel)

            let countText = group.hiddenCount > 0 ? "\(group.totalCount) 个，另 \(group.hiddenCount) 个" : "\(group.totalCount) 个"
            let countLabel = label(countText, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
            countLabel.alignment = .right
            countLabel.frame = NSRect(x: 260, y: y, width: 150, height: 15)
            view.addSubview(countLabel)

            y -= groupHeaderHeight

            for item in group.items {
                let badge = label(item.status.label, font: .systemFont(ofSize: 11, weight: .semibold), color: item.status.color)
                badge.alignment = .center
                badge.frame = NSRect(x: 18, y: y, width: 30, height: 16)
                badge.wantsLayer = true
                badge.layer?.backgroundColor = item.status.color.withAlphaComponent(0.12).cgColor
                badge.layer?.cornerRadius = 5
                view.addSubview(badge)

                let title = label(item.title, font: .systemFont(ofSize: 12), color: .labelColor)
                title.frame = NSRect(x: 58, y: y, width: 226, height: 17)
                view.addSubview(title)

                let meta = "\(ageText(since: item.updatedAt)) · \(compactTokenCount(item.tokenTotal))"
                let metaLabel = label(meta, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
                metaLabel.alignment = .right
                metaLabel.frame = NSRect(x: 292, y: y, width: 118, height: 17)
                view.addSubview(metaLabel)

                y -= rowHeight
            }
        }

        if snapshot.hiddenCount > 0 {
            let footer = label(
                "还有 \(snapshot.hiddenCount) 个未展开任务，报告页可看完整清单",
                font: .systemFont(ofSize: 11),
                color: .tertiaryLabelColor)
            footer.frame = NSRect(x: 18, y: 7, width: 392, height: 15)
            view.addSubview(footer)
        }

        return view
    }

    private func addProgressRow(to view: NSView, y: CGFloat, name: String, percent: Int, reset: String) {
        let nameLabel = label(name, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        nameLabel.frame = NSRect(x: 18, y: y + 10, width: 46, height: 18)
        view.addSubview(nameLabel)

        let percentLabel = label("\(percent)%", font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: quotaColor(percent: percent))
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: 68, y: y + 10, width: 42, height: 18)
        view.addSubview(percentLabel)

        let resetLabel = label(reset, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        resetLabel.alignment = .right
        resetLabel.frame = NSRect(x: 292, y: y + 10, width: 116, height: 18)
        view.addSubview(resetLabel)

        view.addSubview(progressBar(percent: percent, frame: NSRect(x: 118, y: y + 16, width: 156, height: 5)))
    }

    private func progressBar(percent: Int, frame: NSRect) -> NSView {
        let track = NSView(frame: frame)
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        track.layer?.cornerRadius = frame.height / 2

        let fillWidth = max(frame.height, frame.width * CGFloat(max(0, min(100, percent))) / 100)
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: fillWidth, height: frame.height))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = quotaColor(percent: percent).cgColor
        fill.layer?.cornerRadius = frame.height / 2
        track.addSubview(fill)

        return track
    }

    private func addCodexTaskRows(_ tasks: [CodexTaskUsage], to view: NSView) {
        let heading = label("任务消耗（估算）", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        let taskAreaHeight = CGFloat(36 + tasks.count * 20)
        heading.frame = NSRect(x: 18, y: taskAreaHeight - 24, width: 180, height: 18)
        view.addSubview(heading)

        for (index, task) in tasks.enumerated() {
            let y = taskAreaHeight - 48 - CGFloat(index * 20)
            let titleLabel = label(task.title, font: .systemFont(ofSize: 12), color: .labelColor)
            titleLabel.frame = NSRect(x: 18, y: y, width: 220, height: 17)
            view.addSubview(titleLabel)

            let value = taskUsageSummary(task)
            let valueLabel = label(
                value,
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                color: taskDeltaColor(task.primaryDelta))
            valueLabel.alignment = .right
            valueLabel.frame = NSRect(x: 238, y: y, width: 172, height: 17)
            view.addSubview(valueLabel)
        }
    }

    private func taskUsageSummary(_ task: CodexTaskUsage) -> String {
        let tokenText = task.tokenTotal.map { compactTokenCount($0) } ?? "token未知"
        if let delta = task.primaryDelta {
            return "\(tokenText) · 本平台约\(Int(round(delta)))%"
        }
        return "\(tokenText) · 额度未知"
    }

    private func compactTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let value = Double(tokens) / 1_000_000
            return String(format: value >= 10 ? "%.0fM tok" : "%.1fM tok", value)
        }
        if tokens >= 1_000 {
            let value = Double(tokens) / 1_000
            return String(format: value >= 10 ? "%.0fK tok" : "%.1fK tok", value)
        }
        return "\(tokens) tok"
    }

    private func taskDeltaColor(_ delta: Double?) -> NSColor {
        guard let delta else { return .secondaryLabelColor }
        if delta > 5 {
            return .systemRed
        }
        if delta >= 1 {
            return .systemBlue
        }
        return .systemGreen
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        return label
    }

    private func menuIcon(from appPath: String) -> NSImage {
        menuIcon(from: appPath, size: 18)
    }

    private func menuIcon(from appPath: String, size: CGFloat) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: size, height: size)
        return image
    }

    @objc private func noop() {}

    @objc private func refreshFromMenu() {
        if lastGoodTitle == nil {
            setPlainTitle("AI ...")
        }
        refresh()
    }

    private func menuLines(from output: String) -> [String] {
        let quotas = quotaInfoByProvider(fromJSON: output)
        if !quotas.isEmpty {
            var lines: [String] = []
            if showClaudeSection, let claude = quotas["claude"] {
                lines.append("Claude")
                lines.append("5小时   \(claude.session)%    \(chineseDuration(claude.sessionReset))")
                lines.append("一周    \(claude.weekly)%    \(chineseDuration(claude.weeklyReset))")
            }
            if let codex = quotas["codex"] {
                if !lines.isEmpty {
                    lines.append("")
                }
                lines.append("Codex")
                lines.append("5小时   \(codex.session)%    \(chineseDuration(codex.sessionReset))")
                lines.append("一周    \(codex.weekly)%    \(chineseDuration(codex.weeklyReset))")
            }
            if let lastRefreshDate {
                lines.append("")
                lines.append("最后更新 \(menuTimeFormatter.string(from: lastRefreshDate))")
            }
            return lines
        }

        return output.components(separatedBy: .newlines)
    }

    private var menuTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private func chineseDuration(_ reset: String?) -> String {
        guard let duration = durationParts(from: reset) else { return "--" }

        if duration.days > 0 {
            return "\(duration.days)天\(duration.hours)小时\(duration.minutes)分"
        }
        if duration.hours > 0 {
            return "\(duration.hours)小时\(duration.minutes)分"
        }
        return "\(duration.minutes)分"
    }

    // MARK: - Claude Task Ledger

    private func loadClaudeLedger() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeLedgerPath)),
              let readings = try? decoder.decode([ClaudeQuotaReading].self, from: data)
        else { return }
        claudeLedger = Array(readings.suffix(1000))
    }

    private func saveClaudeLedger() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let dir = NSHomeDirectory() + "/Library/Application Support/AI Quota Bar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(claudeLedger) else { return }
        try? data.write(to: URL(fileURLWithPath: claudeLedgerPath))
    }

    private func updateClaudeLedger(claude: QuotaInfo, activeSession: ClaudeSessionInfo?) {
        let reading = ClaudeQuotaReading(
            timestamp: Date(),
            primaryRemaining: claude.session,
            weeklyRemaining: claude.weekly,
            sessionId: activeSession?.id,
            sessionTitle: activeSession?.title,
            sessionTotalTokens: activeSession?.totalTokens,
            sessionModel: activeSession?.model,
            sessionHasThinking: activeSession?.hasThinking)
        claudeLedger.append(reading)
        if claudeLedger.count > 1000 {
            claudeLedger = Array(claudeLedger.suffix(1000))
        }
        saveClaudeLedger()
    }

    private func activeClaudeSession() -> ClaudeSessionInfo? {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }

        var candidates: [(path: String, date: Date)] = []
        for project in projects {
            let projectPath = projectsDir + "/" + project
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date {
                    candidates.append((filePath, modDate))
                }
            }
        }
        candidates.sort { $0.date > $1.date }

        for candidate in candidates.prefix(3) {
            if let info = claudeSessionInfo(from: candidate.path) {
                return info
            }
        }
        return nil
    }

    private func fetchRecentClaudeSessions(limit: Int) -> [ClaudeSessionInfo] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var candidates: [(path: String, date: Date)] = []
        for project in projects {
            let projectPath = projectsDir + "/" + project
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date {
                    candidates.append((filePath, modDate))
                }
            }
        }
        candidates.sort { $0.date > $1.date }

        var sessions: [ClaudeSessionInfo] = []
        var seenIds = Set<String>()
        for candidate in candidates {
            guard sessions.count < limit else { break }
            if let info = claudeSessionInfo(from: candidate.path), !seenIds.contains(info.id) {
                sessions.append(info)
                seenIds.insert(info.id)
            }
        }
        return sessions
    }

    private func claudeSessionInfo(from filePath: String) -> ClaudeSessionInfo? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)

        var sessionId: String?
        var title: String?
        var lastTimestamp: Date?
        var totalTokens = 0
        var maxCacheRead = 0
        var model: String?
        var hasThinking = false
        let isoFmt = ISO8601DateFormatter()

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if sessionId == nil, let sid = obj["sessionId"] as? String {
                sessionId = sid
            }
            if let type = obj["type"] as? String, type == "ai-title",
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                title = t
            }
            if let ts = obj["timestamp"] as? String {
                isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = isoFmt.date(from: ts) ?? {
                    isoFmt.formatOptions = [.withInternetDateTime]
                    return isoFmt.date(from: ts)
                }()
                if let date, lastTimestamp == nil || date > lastTimestamp! {
                    lastTimestamp = date
                }
            }
            if let type = obj["type"] as? String, type == "assistant",
               let msg = obj["message"] as? [String: Any] {
                if let msgModel = msg["model"] as? String, model == nil {
                    model = msgModel
                }
                if let usage = msg["usage"] as? [String: Any] {
                    totalTokens += (usage["input_tokens"] as? Int ?? 0)
                        + (usage["output_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    maxCacheRead = max(maxCacheRead, usage["cache_read_input_tokens"] as? Int ?? 0)
                }
                if !hasThinking,
                   let content = msg["content"] as? [[String: Any]] {
                    hasThinking = content.contains { $0["type"] as? String == "thinking" }
                }
            }
        }

        guard let sid = sessionId, let lastDate = lastTimestamp else { return nil }
        return ClaudeSessionInfo(
            id: sid,
            title: shortTaskTitle(title ?? "未命名任务"),
            lastActivity: lastDate,
            totalTokens: totalTokens + maxCacheRead,
            model: model,
            hasThinking: hasThinking)
    }

    private func mergeClaudeTaskUsages(sessions: [ClaudeSessionInfo]) -> [CodexTaskUsage] {
        var deltaBySession: [String: Double] = [:]

        if claudeLedger.count > 1 {
            for i in 1..<claudeLedger.count {
                let prev = claudeLedger[i - 1]
                let curr = claudeLedger[i]
                guard let sid = prev.sessionId else { continue }
                let drop = Double(prev.primaryRemaining - curr.primaryRemaining)
                if drop > 0 {
                    deltaBySession[sid, default: 0] += drop
                }
            }
        }

        return sessions.map { session in
            if let delta = deltaBySession[session.id] {
                return CodexTaskUsage(title: session.title, updatedAt: session.lastActivity, primaryDelta: delta, tokenTotal: session.totalTokens)
            }
            let ratio = calibratedTokensPerPercent(model: session.model, hasThinking: session.hasThinking)
            if let ratio, session.totalTokens > 0 {
                let estimated = Double(session.totalTokens) / ratio
                return CodexTaskUsage(title: session.title, updatedAt: session.lastActivity, primaryDelta: estimated, tokenTotal: session.totalTokens)
            }
            return CodexTaskUsage(title: session.title, updatedAt: session.lastActivity, primaryDelta: nil, tokenTotal: session.totalTokens)
        }
    }

    private func calibratedTokensPerPercent(model: String?, hasThinking: Bool) -> Double? {
        var ratios: [Double] = []
        if claudeLedger.count > 1 {
            for i in 1..<claudeLedger.count {
                let prev = claudeLedger[i - 1]
                let curr = claudeLedger[i]
                guard prev.sessionId == curr.sessionId,
                      prev.sessionModel == model,
                      (prev.sessionHasThinking ?? false) == hasThinking,
                      let prevTokens = prev.sessionTotalTokens,
                      let currTokens = curr.sessionTotalTokens,
                      currTokens > prevTokens
                else { continue }
                let quotaDrop = Double(prev.primaryRemaining - curr.primaryRemaining)
                guard quotaDrop > 0 else { continue }
                ratios.append(Double(currTokens - prevTokens) / quotaDrop)
            }
        }
        // 同分组不够时，fallback 到全量
        if ratios.count < 3 {
            ratios = []
            if claudeLedger.count > 1 {
                for i in 1..<claudeLedger.count {
                    let prev = claudeLedger[i - 1]
                    let curr = claudeLedger[i]
                    guard prev.sessionId == curr.sessionId,
                          let prevTokens = prev.sessionTotalTokens,
                          let currTokens = curr.sessionTotalTokens,
                          currTokens > prevTokens
                    else { continue }
                    let quotaDrop = Double(prev.primaryRemaining - curr.primaryRemaining)
                    guard quotaDrop > 0 else { continue }
                    ratios.append(Double(currTokens - prevTokens) / quotaDrop)
                }
            }
        }
        guard ratios.count >= 3 else { return nil }
        let sorted = ratios.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Codex Task Usages

    private func loadCodexLedger() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: codexLedgerPath)),
              let readings = try? decoder.decode([CodexQuotaReading].self, from: data)
        else { return }
        codexLedger = Array(readings.suffix(1000))
    }

    private func saveCodexLedger() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let dir = NSHomeDirectory() + "/Library/Application Support/AI Quota Bar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(codexLedger) else { return }
        try? data.write(to: URL(fileURLWithPath: codexLedgerPath))
    }

    private func updateCodexLedger(codex: CodexUsageSnapshot, activeSession: CodexSessionInfo?) {
        guard let trackedWindow = codex.trackedWindow(for: activeSession?.model) else { return }
        let reading = CodexQuotaReading(
            timestamp: Date(),
            primaryRemaining: trackedWindow.remainingPercent,
            weeklyRemaining: codex.secondary?.remainingPercent ?? trackedWindow.remainingPercent,
            trackedWindowID: trackedWindow.id,
            trackedWindowTitle: trackedWindow.title,
            sessionId: activeSession?.id,
            sessionTitle: activeSession?.title,
            sessionTotalTokens: activeSession?.totalTokens,
            sessionModel: activeSession?.model)
        codexLedger.append(reading)
        if codexLedger.count > 1000 {
            codexLedger = Array(codexLedger.suffix(1000))
        }
        saveCodexLedger()
    }

    private func activeCodexSession() -> CodexSessionInfo? {
        let threads = fetchCodexThreadInfos(limit: 30)
        let running = runningCodexThreads(in: threads)

        // Multiple live tasks make a quota drop ambiguous. It is safer to leave
        // that drop unattributed than to charge the most recently updated task.
        guard running.count == 1,
              let runningID = running.keys.first,
              let thread = threads.first(where: { $0.id == runningID })
        else { return nil }
        guard let file = thread.rolloutPath.map(URL.init(fileURLWithPath:)),
              let session = codexSessionInfo(from: file)
        else { return nil }
        return session
    }

    private func fetchRecentCodexSessions(limit: Int) -> [CodexSessionInfo] {
        var sessions: [CodexSessionInfo] = []
        var seenIDs = Set<String>()
        for file in recentCodexSessionFiles(limit: 30) {
            guard let info = codexSessionInfo(from: file),
                  !seenIDs.contains(info.id)
            else { continue }
            sessions.append(info)
            seenIDs.insert(info.id)
            if sessions.count >= limit {
                break
            }
        }
        return sessions
    }

    private func fetchOpenCodexSessions(limit: Int) -> [CodexSessionInfo] {
        var sessions: [CodexSessionInfo] = []
        var seenIDs = Set<String>()
        for file in openCodexSessionFiles(limit: 120) {
            guard let info = codexSessionInfo(from: file),
                  !seenIDs.contains(info.id)
            else { continue }
            sessions.append(info)
            seenIDs.insert(info.id)
            if sessions.count >= limit {
                break
            }
        }
        return sessions
    }

    private func taskRadarSnapshot() -> TaskRadarSnapshot {
        let threads = fetchCodexThreadInfos(limit: 120)
        let sessions = threads.isEmpty
            ? fetchOpenCodexSessions(limit: 120).map { session in
                CodexThreadInfo(
                    id: session.id,
                    title: session.title,
                    lastActivity: session.lastActivity,
                    totalTokens: session.totalTokens,
                    cwd: nil,
                    rolloutPath: codexSessionFile(id: session.id)?.path)
            }
            : threads
        let now = Date()
        let runningThreads = runningCodexThreads(in: sessions)

        let allItems = sessions.map { session in
            let age = now.timeIntervalSince(session.lastActivity)
            let status: TaskRadarStatus
            if runningThreads[session.id] != nil {
                status = .running
            } else if age < 2 * 60 * 60 {
                status = .done
            } else if age < 72 * 60 * 60 {
                status = .recent
            } else {
                status = .sleeping
            }
            return radarItem(
                from: session,
                status: status,
                progressText: runningThreads[session.id]?.progressText)
        }

        let running = allItems.filter { $0.status == .running }
        let done = allItems.filter { $0.status == .done }
        let recent = allItems.filter { $0.status == .recent }
        let sleeping = allItems.filter { $0.status == .sleeping }
        let groupData = taskRadarGroups(items: allItems, now: now)

        return TaskRadarSnapshot(
            runningCount: running.count,
            doneCount: done.count,
            recentCount: recent.count,
            sleepingCount: sleeping.count,
            within2HoursCount: groupData.within2HoursCount,
            within24HoursCount: groupData.within24HoursCount,
            within72HoursCount: groupData.within72HoursCount,
            otherCount: groupData.otherCount,
            totalCount: allItems.count,
            hiddenCount: groupData.hiddenCount,
            groups: groupData.groups,
            items: groupData.items)
    }

    private func taskRadarGroups(
        items: [TaskRadarItem],
        now: Date)
        -> (
            groups: [TaskRadarGroup],
            items: [TaskRadarItem],
            within2HoursCount: Int,
            within24HoursCount: Int,
            within72HoursCount: Int,
            otherCount: Int,
            hiddenCount: Int
        ) {
        let twoHours = sortedRadarItems(items.filter { now.timeIntervalSince($0.updatedAt) < 2 * 60 * 60 })
        let day = sortedRadarItems(items.filter {
            let age = now.timeIntervalSince($0.updatedAt)
            return age >= 2 * 60 * 60 && age < 24 * 60 * 60
        })
        let threeDays = sortedRadarItems(items.filter {
            let age = now.timeIntervalSince($0.updatedAt)
            return age >= 24 * 60 * 60 && age < 72 * 60 * 60
        })
        let other = sortedRadarItems(items.filter { now.timeIntervalSince($0.updatedAt) >= 72 * 60 * 60 })

        let groups = [
            TaskRadarGroup(title: "2小时内", totalCount: twoHours.count, items: Array(twoHours.prefix(6))),
            TaskRadarGroup(title: "24小时内", totalCount: day.count, items: Array(day.prefix(6))),
            TaskRadarGroup(title: "72小时内", totalCount: threeDays.count, items: Array(threeDays.prefix(4))),
            TaskRadarGroup(title: "其他", totalCount: other.count, items: Array(other.prefix(4)))
        ]
        let visibleItems = groups.flatMap(\.items)

        return (
            groups: groups,
            items: visibleItems,
            within2HoursCount: twoHours.count,
            within24HoursCount: twoHours.count + day.count,
            within72HoursCount: twoHours.count + day.count + threeDays.count,
            otherCount: other.count,
            hiddenCount: max(0, items.count - visibleItems.count)
        )
    }

    private func sortedRadarItems(_ items: [TaskRadarItem]) -> [TaskRadarItem] {
        items.sorted {
            if $0.status == .running, $1.status != .running { return true }
            if $0.status != .running, $1.status == .running { return false }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func radarItem(
        from session: CodexThreadInfo,
        status: TaskRadarStatus,
        progressText: String? = nil) -> TaskRadarItem {
        TaskRadarItem(
            id: session.id,
            title: session.title,
            updatedAt: session.lastActivity,
            status: status,
            tokenTotal: session.totalTokens,
            cwd: session.cwd,
            progressText: progressText)
    }

    private func fetchCodexThreadInfos(limit: Int) -> [CodexThreadInfo] {
        let databasePath = "\(codexHomePath)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        let indexedTitles = codexThreadTitles()

        let query = """
        select
          id,
          coalesce(nullif(trim(title), ''), nullif(trim(preview), ''), '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          coalesce(nullif(recency_at_ms, 0), nullif(updated_at_ms, 0), 0) as activity_ms,
          cwd,
          rollout_path
        from threads
        where archived = 0
        order by activity_ms desc
        limit ?;
        """

        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var result: [CodexThreadInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let titleText = sqlite3_column_text(statement, 1)
            else { continue }

            let id = String(cString: idText)
            let rawTitle = indexedTitles[id] ?? String(cString: titleText)
            let tokens = Int(sqlite3_column_int64(statement, 2))
            let activityMS = Double(sqlite3_column_int64(statement, 3))
            let cwd = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let rolloutPath = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let databaseActivityDate = activityMS > 0
                ? Date(timeIntervalSince1970: activityMS / 1000)
                : Date.distantPast
            let fileActivityDate = rolloutPath.flatMap { path -> Date? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return attributes?[.modificationDate] as? Date
            }
            let activityDate = max(databaseActivityDate, fileActivityDate ?? .distantPast)
            result.append(CodexThreadInfo(
                id: id,
                title: shortTaskTitle(rawTitle),
                lastActivity: activityDate,
                totalTokens: tokens,
                cwd: cwd,
                rolloutPath: rolloutPath))
        }

        return result
    }

    private func runningCodexThreads(in sessions: [CodexThreadInfo]) -> [String: CodexTurnSnapshot] {
        let now = Date()
        let liveProcessIDs = liveCodexProcessThreadIDs()
        var result: [String: CodexTurnSnapshot] = [:]

        for session in sessions {
            guard let path = session.rolloutPath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date
            else { continue }

            let fileIsFresh = max(0, now.timeIntervalSince(modifiedAt)) < 5 * 60
            let hasLiveProcess = liveProcessIDs.contains(session.id)
            guard fileIsFresh || hasLiveProcess else { continue }

            let snapshot = latestCodexTurnSnapshot(in: path)
            if snapshot.state == .running || (snapshot.state == .unknown && hasLiveProcess) {
                result[session.id] = snapshot
            }
        }
        return result
    }

    private func liveCodexProcessThreadIDs() -> Set<String> {
        let path = "\(codexHomePath)/process_manager/chat_processes.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var result = Set<String>()
        for row in rows {
            guard let conversationID = row["conversationId"] as? String,
                  let osPid = intValue(row["osPid"]),
                  osPid > 0,
                  let startedAtMS = doubleValue(row["startedAtMs"])
            else { continue }

            var processInfo = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let readSize = proc_pidinfo(
                pid_t(osPid),
                PROC_PIDTBSDINFO,
                0,
                &processInfo,
                expectedSize)
            guard readSize == expectedSize else { continue }

            let processStartedAtMS = Double(processInfo.pbi_start_tvsec) * 1000
                + Double(processInfo.pbi_start_tvusec) / 1000
            guard abs(processStartedAtMS - startedAtMS) < 5_000 else { continue }
            result.insert(conversationID)
        }
        return result
    }

    private func latestCodexTurnSnapshot(in path: String) -> CodexTurnSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return CodexTurnSnapshot(state: .unknown, progressText: nil)
        }
        defer { try? handle.close() }

        let maximumBytes: UInt64 = 32 * 1024 * 1024
        guard let fileSize = try? handle.seekToEnd() else {
            return CodexTurnSnapshot(state: .unknown, progressText: nil)
        }
        let startOffset = fileSize > maximumBytes ? fileSize - maximumBytes : 0
        try? handle.seek(toOffset: startOffset)
        guard let data = try? handle.readToEnd() else {
            return CodexTurnSnapshot(state: .unknown, progressText: nil)
        }

        var state: CodexTurnState = .unknown
        var toolCallCount = 0
        var modificationCount = 0
        var verificationCount = 0
        var operationalCount = 0
        var latestPhase = "分析中"
        var isWrappingUp = false
        var planCompleted: Int?
        var planTotal: Int?

        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let recordType = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if recordType == "event_msg", let eventType = payload["type"] as? String {
                if eventType == "task_started" {
                    state = .running
                    toolCallCount = 0
                    modificationCount = 0
                    verificationCount = 0
                    operationalCount = 0
                    latestPhase = "分析中"
                    isWrappingUp = false
                    planCompleted = nil
                    planTotal = nil
                } else if eventType == "task_complete" || eventType == "turn_aborted" {
                    state = .stopped
                } else if eventType == "patch_apply_end", state == .running {
                    modificationCount += 1
                    latestPhase = "执行中"
                    isWrappingUp = false
                } else if eventType == "agent_message",
                          state == .running,
                          let message = payload["message"] as? String,
                          ["最后一轮", "最后检查", "收尾", "准备结束", "全部检查通过"].contains(where: message.contains) {
                    isWrappingUp = true
                }
                continue
            }

            guard recordType == "response_item", state == .running else { continue }
            let itemType = payload["type"] as? String
            let toolName = (payload["name"] as? String) ?? ""

            if itemType == "function_call", toolName == "update_plan",
               let arguments = payload["arguments"] as? String,
               let argumentData = arguments.data(using: .utf8),
               let argumentObject = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
               let plan = argumentObject["plan"] as? [[String: Any]] {
                planTotal = plan.count
                planCompleted = plan.filter { $0["status"] as? String == "completed" }.count
                continue
            }

            let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
            if itemType == "custom_tool_call", toolName == "exec", input.contains("tools.update_plan({plan:[") {
                let statusPattern = try? NSRegularExpression(
                    pattern: #"[\"']?status[\"']?\s*:\s*[\"'](completed|in_progress|pending)[\"']"#)
                let matches = statusPattern?.matches(
                    in: input,
                    range: NSRange(input.startIndex..., in: input)) ?? []
                if !matches.isEmpty {
                    planTotal = matches.count
                    planCompleted = matches.filter { match in
                        guard match.numberOfRanges > 1,
                              let range = Range(match.range(at: 1), in: input)
                        else { return false }
                        return input[range] == "completed"
                    }.count
                }
                continue
            }

            guard itemType == "function_call" || itemType == "custom_tool_call" else { continue }
            toolCallCount += 1
            isWrappingUp = false
            let signal = "\(toolName) \(input)".lowercased()

            let modificationSignals = [
                "tools.apply_patch", "apply_patch(", "image_gen__imagegen",
                "write_file", "create_file", "update_file"
            ]
            let verificationSignals = [
                "swiftc ", "pytest", "npm test", "pnpm test", "yarn test",
                "xcodebuild", "playwright", "view_image", "screenshot",
                "verify", "typecheck", "lint", "check_"
            ]
            let operationSignals = [
                "osascript", "open -a", "ssh ", "scp ", "curl -x",
                "click", "navigate", "send_message", "write_stdin", "imagegen"
            ]

            if modificationSignals.contains(where: signal.contains) {
                modificationCount += 1
                latestPhase = "执行中"
            } else if verificationSignals.contains(where: signal.contains) {
                verificationCount += 1
                latestPhase = "验证中"
            } else if operationSignals.contains(where: signal.contains) {
                operationalCount += 1
                latestPhase = "执行中"
            }
        }

        guard state == .running else {
            return CodexTurnSnapshot(state: state, progressText: nil)
        }

        if let completed = planCompleted, let total = planTotal, total > 0 {
            let percent = Int((Double(completed) / Double(total) * 100).rounded())
            return CodexTurnSnapshot(
                state: state,
                progressText: "\(percent)%·\(completed)/\(total)步")
        }

        let rawPercent: Int
        if isWrappingUp {
            rawPercent = 95
            latestPhase = "收尾中"
        } else if latestPhase == "验证中" {
            rawPercent = min(90, 75 + verificationCount * 4)
        } else if latestPhase == "执行中" {
            rawPercent = min(70, 40 + modificationCount * 7 + operationalCount * 3)
        } else {
            rawPercent = min(35, 15 + toolCallCount * 3)
        }
        let roundedPercent = min(95, max(10, ((rawPercent + 2) / 5) * 5))
        return CodexTurnSnapshot(
            state: state,
            progressText: "约\(roundedPercent)%·\(latestPhase)")
    }

    private func mergeCodexTaskUsages(sessions: [CodexSessionInfo]) -> [CodexTaskUsage] {
        sessions.map { session in
            if let delta = deltaForCodexSession(session.id) {
                return CodexTaskUsage(title: session.title, updatedAt: session.lastActivity, primaryDelta: delta, tokenTotal: session.totalTokens)
            }
            if let file = codexSessionFile(id: session.id),
               let task = codexTaskUsage(from: file, titleByID: codexThreadTitles()) {
                return task
            }
            return CodexTaskUsage(title: session.title, updatedAt: session.lastActivity, primaryDelta: nil, tokenTotal: session.totalTokens)
        }
    }

    private func recentCodexTaskUsages(limit: Int) -> [CodexTaskUsage] {
        let titleByID = codexThreadTitles()
        let files = recentCodexSessionFiles(limit: 30)
        var tasks: [CodexTaskUsage] = []
        var seenIDs = Set<String>()

        for file in files {
            guard let task = codexTaskUsage(from: file, titleByID: titleByID),
                  !seenIDs.contains(task.title)
            else { continue }
            tasks.append(task)
            seenIDs.insert(task.title)
            if tasks.count >= limit {
                break
            }
        }

        return tasks
    }

    private func recentCodexSessionFiles(limit: Int) -> [URL] {
        let roots = [
            URL(fileURLWithPath: "\(codexHomePath)/sessions"),
            URL(fileURLWithPath: "\(codexHomePath)/archived_sessions")
        ]
        return codexSessionFiles(in: roots, limit: limit)
    }

    private func openCodexSessionFiles(limit: Int) -> [URL] {
        codexSessionFiles(in: [URL(fileURLWithPath: "\(codexHomePath)/sessions")], limit: limit)
    }

    private func codexSessionFiles(in roots: [URL], limit: Int) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files: [(url: URL, modified: Date)] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { continue }

            for case let file as URL in enumerator {
                guard file.pathExtension == "jsonl",
                      let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate
                else { continue }
                files.append((file, modified))
            }
        }

        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.url)
    }

    private func codexThreadTitles() -> [String: String] {
        let url = URL(fileURLWithPath: "\(codexHomePath)/session_index.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var result: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            result[id] = title
        }
        return result
    }

    private func codexSessionInfo(from file: URL) -> CodexSessionInfo? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let titleByID = codexThreadTitles()

        var sessionID = sessionIDFromFilename(file)
        var timestamps: [Date] = []
        var fallbackTitle: String?
        var totalTokens = 0
        var model: String?

        for rawLine in content.split(separator: "\n") {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let timestampText = object["timestamp"] as? String,
               let timestamp = isoDate(timestampText) {
                timestamps.append(timestamp)
            }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "session_meta",
               let payload,
               let id = payload["id"] as? String {
                sessionID = id
                if let providerModel = payload["model"] as? String, model == nil {
                    model = providerModel
                }
            }

            if type == "turn_context",
               let payload,
               let contextModel = payload["model"] as? String {
                model = contextModel
            }

            if fallbackTitle == nil,
               type == "response_item",
               let payload,
               payload["role"] as? String == "user",
               let contentItems = payload["content"] as? [[String: Any]] {
                fallbackTitle = firstUserText(from: contentItems)
            }

            if type == "event_msg",
               let payload,
               payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any] {
                if let total = info["total_token_usage"] as? [String: Any],
                   let tokens = intValue(total["total_tokens"]) {
                    totalTokens = max(totalTokens, tokens)
                }
                if let last = info["last_token_usage"] as? [String: Any],
                   let tokens = intValue(last["total_tokens"]),
                   totalTokens == 0 {
                    totalTokens += tokens
                }
            }
        }

        guard let sid = sessionID else { return nil }
        let title = shortTaskTitle(titleByID[sid] ?? fallbackTitle ?? "未命名任务")
        let updatedAt = timestamps.max() ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return CodexSessionInfo(
            id: sid,
            title: title,
            lastActivity: updatedAt,
            totalTokens: totalTokens,
            model: model)
    }

    private func codexSessionFile(id: String) -> URL? {
        recentCodexSessionFiles(limit: 200).first { sessionIDFromFilename($0) == id }
    }

    private func codexTaskUsage(from file: URL, titleByID: [String: String]) -> CodexTaskUsage? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var sessionID = sessionIDFromFilename(file)
        var timestamps: [Date] = []
        var usedPercents: [Double] = []
        var fallbackTitle: String?
        var totalTokens = 0

        for rawLine in content.split(separator: "\n") {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let timestampText = object["timestamp"] as? String,
               let timestamp = isoDate(timestampText) {
                timestamps.append(timestamp)
            }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "session_meta",
               let payload,
               let id = payload["id"] as? String {
                sessionID = id
            }

            if fallbackTitle == nil,
               type == "response_item",
               let payload,
               payload["role"] as? String == "user",
               let contentItems = payload["content"] as? [[String: Any]] {
                fallbackTitle = firstUserText(from: contentItems)
            }

            if type == "event_msg",
               let payload,
               payload["type"] as? String == "token_count" {
                if let info = payload["info"] as? [String: Any] {
                    if let total = info["total_token_usage"] as? [String: Any],
                       let tokens = intValue(total["total_tokens"]) {
                        totalTokens = max(totalTokens, tokens)
                    }
                    if let last = info["last_token_usage"] as? [String: Any],
                       let tokens = intValue(last["total_tokens"]),
                       totalTokens == 0 {
                        totalTokens += tokens
                    }
                }

                if let rateLimits = payload["rate_limits"] as? [String: Any],
                   let primary = rateLimits["primary"] as? [String: Any] {
                    if let used = primary["used_percent"] as? Double {
                        usedPercents.append(used)
                    } else if let used = primary["used_percent"] as? Int {
                        usedPercents.append(Double(used))
                    }
                }
            }
        }

        let title = shortTaskTitle(titleByID[sessionID ?? ""] ?? fallbackTitle ?? "未命名任务")
        let updatedAt = timestamps.max() ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return CodexTaskUsage(
            title: title,
            updatedAt: updatedAt,
            primaryDelta: currentWindowDeltaSum(usedPercents),
            tokenTotal: totalTokens > 0 ? totalTokens : nil)
    }

    private func currentWindowDeltaSum(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let normalized = values.map { max(0, min(100, $0)) }
        var startIndex = 0

        for index in 1..<normalized.count {
            if normalized[index] + 15 < normalized[index - 1] {
                startIndex = index
            }
        }

        var total = 0.0
        guard startIndex + 1 < normalized.count else { return nil }
        for index in (startIndex + 1)..<normalized.count {
            let diff = normalized[index] - normalized[index - 1]
            if diff > 0 {
                total += diff
            }
        }
        guard total > 0 else { return nil }
        return min(100, total)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let int64 = value as? Int64 {
            return Int(int64)
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let int64 = value as? Int64 {
            return Double(int64)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func sessionIDFromFilename(_ file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        let pattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              let range = Range(match.range(at: 1), in: name)
        else { return nil }
        return String(name[range])
    }

    private func firstUserText(from contentItems: [[String: Any]]) -> String? {
        for item in contentItems {
            if let text = item["text"] as? String {
                let cleaned = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func shortTaskTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 16 else { return cleaned }
        return String(cleaned.prefix(16)) + "..."
    }

    private func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func ageText(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 * 60 {
            return "\(max(1, Int(seconds / 60)))分前"
        }
        if seconds < 24 * 60 * 60 {
            return "\(Int(seconds / 3600))小时前"
        }
        return "\(Int(seconds / (24 * 3600)))天前"
    }

    @objc private func generateReport() {
        let html = buildReportHTML()
        let tmpDir = FileManager.default.temporaryDirectory
        let reportURL = tmpDir.appendingPathComponent("ai-usage-report.html")
        try? html.write(to: reportURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(reportURL)
    }

    private func buildReportHTML() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let generatedAt = dateFormatter.string(from: Date())
        let claudeSection = showClaudeSection ? buildClaudeReportSection(dateFormatter: dateFormatter) : ""
        let codexQuotaSection = CodexUsageParser.parse(lastOutput)
            .map { buildCurrentCodexUsageReportSection($0) } ?? ""
        let codexSection = buildCodexReportSection(dateFormatter: dateFormatter)
        let radarSection = buildTaskRadarReportSection(dateFormatter: dateFormatter)

        return """
        <!DOCTYPE html>
        <html lang="zh">
        <head>
        <meta charset="UTF-8">
        <title>AI 用量报告</title>
        <style>
            body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; color: #1a1a1a; background: #f8f8f8; }
            h1 { font-size: 26px; font-weight: 700; margin-bottom: 4px; }
            h2 { font-size: 20px; font-weight: 700; margin: 36px 0 12px; color: #1a1a1a; }
            h3 { font-size: 16px; font-weight: 600; margin: 0 0 16px; color: #333; }
            .subtitle { color: #666; font-size: 14px; margin-bottom: 28px; }
            .card { background: white; border-radius: 12px; padding: 24px; margin-bottom: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
            table { width: 100%; border-collapse: collapse; font-size: 14px; }
            th { text-align: left; padding: 8px 10px; border-bottom: 2px solid #eee; color: #666; font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
            td { padding: 9px 10px; border-bottom: 1px solid #f0f0f0; }
            tr:last-child td { border-bottom: none; }
            .stat { display: inline-block; margin-right: 32px; }
            .stat-value { font-size: 28px; font-weight: 700; color: #1a1a1a; }
            .stat-label { font-size: 12px; color: #999; margin-top: 2px; }
            .note { font-size: 13px; color: #666; margin: 0 0 16px; }
            .notice { background: #fffbf0; border: 1px solid #f0c040; border-radius: 8px; padding: 12px 16px; font-size: 13px; color: #7a5c00; margin: 28px 0 48px; }
            .mini-card { border: 1px solid #eee; border-radius: 8px; padding: 14px 16px; margin: 12px 0; background: #fcfcfc; }
            .mini-title { font-weight: 700; margin-bottom: 4px; }
            .mini-meta { font-size: 12px; color: #888; margin-bottom: 8px; }
            .mini-body { font-size: 13px; color: #333; line-height: 1.55; margin-top: 4px; }
            .copy-button { border: 1px solid #d0d7de; background: #fff; border-radius: 7px; padding: 6px 9px; color: #1f6feb; font-size: 12px; cursor: pointer; white-space: nowrap; }
            .copy-button:hover { background: #f6f8fa; }
            .copy-button.done { color: #1a7f37; border-color: #a6d9b8; background: #f0fff4; }
        </style>
        <script>
        function copyDeepPrompt(button) {
            var text = button.getAttribute('data-prompt') || '';
            function done() {
                button.textContent = '已复制';
                button.classList.add('done');
                setTimeout(function() {
                    button.textContent = '复制深度分析提示';
                    button.classList.remove('done');
                }, 2200);
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done).catch(function() {
                    fallbackCopy(text);
                    done();
                });
            } else {
                fallbackCopy(text);
                done();
            }
        }
        function fallbackCopy(text) {
            var area = document.createElement('textarea');
            area.value = text;
            document.body.appendChild(area);
            area.select();
            document.execCommand('copy');
            document.body.removeChild(area);
        }
        </script>
        </head>
        <body>
        <h1>AI 用量报告</h1>
        <div class="subtitle">生成时间：\(generatedAt)</div>
        \(codexQuotaSection)
        \(radarSection)
        \(claudeSection)
        \(codexSection)
        <div class="notice">额度窗口以 Codex 当前实际返回为准：缺少的窗口不会用旧缓存补齐。Codex、ChatGPT Work 等 Agent 功能可能共享同一用量池；Spark 使用独立、可能随需求调整的额度。Token 处理量来自本地 JSONL，不等于账单。实际套餐请以 <a href="https://developers.openai.com/codex/pricing">OpenAI 官方页面</a>为准。</div>
        </body>
        </html>
        """
    }

    private func buildCurrentCodexUsageReportSection(_ usage: CodexUsageSnapshot) -> String {
        let rows = usage.allWindows.map { window in
            let reset = chineseDuration(resetString(for: window))
            return """
            <tr>
                <td style="font-weight:600">\(escapeHTML(window.title))</td>
                <td style="text-align:right; color:\(window.remainingPercent < 20 ? "#e74c3c" : "#27ae60"); font-weight:700">\(window.remainingPercent)%</td>
                <td style="text-align:right; color:#666">\(escapeHTML(reset))</td>
            </tr>
            """
        }.joined()

        let resetText: String
        if usage.availableResetCount > 0 {
            let expiry = usage.earliestResetExpiry.map { "，最早\(shortChineseDate($0))到期" } ?? ""
            resetText = "\(usage.availableResetCount) 次可用\(expiry)"
        } else {
            resetText = "当前没有可用的完整重置"
        }

        return """
        <h2>当前 Codex 额度</h2>
        <div class="card">
            <table>
                <thead><tr><th>额度窗口</th><th style="text-align:right">剩余</th><th style="text-align:right">重置倒计时</th></tr></thead>
                <tbody>\(rows)</tbody>
            </table>
            <p class="note" style="margin-top:16px"><b>完整重置：</b>\(resetText)</p>
            <p class="note">页面只显示服务器本次实际返回的窗口；普通 Codex 和 Spark 的周额度彼此独立。</p>
        </div>
        """
    }

    private func buildTaskRadarReportSection(dateFormatter: DateFormatter) -> String {
        let threads = fetchCodexThreadInfos(limit: 80)
        let sessions = threads.isEmpty
            ? fetchOpenCodexSessions(limit: 80).map { session in
                CodexThreadInfo(
                    id: session.id,
                    title: session.title,
                    lastActivity: session.lastActivity,
                    totalTokens: session.totalTokens,
                    cwd: nil,
                    rolloutPath: codexSessionFile(id: session.id)?.path)
            }
            : threads
        let now = Date()
        let runningThreads = runningCodexThreads(in: sessions)
        let runningIDs = Set(runningThreads.keys)
        var rows = ""

        for session in sessions.prefix(30) {
            let age = now.timeIntervalSince(session.lastActivity)
            let status: TaskRadarStatus
            if runningIDs.contains(session.id) {
                status = .running
            } else if age < 24 * 60 * 60 {
                status = .done
            } else if age < 3 * 24 * 60 * 60 {
                status = .recent
            } else {
                status = .sleeping
            }
            let color: String
            switch status {
            case .running: color = "#27ae60"
            case .done: color = "#2980b9"
            case .recent: color = "#7f8c8d"
            case .sleeping: color = "#e67e22"
            }

            rows += """
            <tr>
                <td style="color:\(color); font-weight:700">\(status.label)</td>
                <td>\(escapeHTML(session.title))</td>
                <td style="text-align:right; color:#666">\(ageText(since: session.lastActivity))</td>
                <td style="text-align:right; color:#666">\(compactTokenCount(session.totalTokens))</td>
                <td style="text-align:right; font-size:12px; color:#999">\(dateFormatter.string(from: session.lastActivity))</td>
            </tr>
            """
        }

        if rows.isEmpty {
            rows = "<tr><td colspan='5' style='color:#999; text-align:center'>暂无可读取的 Codex 任务</td></tr>"
        }

        let runningCount = sessions.filter { runningIDs.contains($0.id) }.count
        let doneCount = sessions.filter {
            !runningIDs.contains($0.id) && now.timeIntervalSince($0.lastActivity) < 24 * 60 * 60
        }.count
        let recentCount = sessions.filter {
            let age = now.timeIntervalSince($0.lastActivity)
            return !runningIDs.contains($0.id) && age >= 24 * 60 * 60 && age < 3 * 24 * 60 * 60
        }.count
        let sleepingCount = sessions.filter {
            !runningIDs.contains($0.id) && now.timeIntervalSince($0.lastActivity) >= 3 * 24 * 60 * 60
        }.count

        return """
        <h2>Codex 任务监控</h2>

        <div class="card">
            <h3>当前任务状态</h3>
            <div class="stat"><div class="stat-value">\(runningCount)</div><div class="stat-label">正在跑</div></div>
            <div class="stat"><div class="stat-value">\(doneCount)</div><div class="stat-label">24小时内</div></div>
            <div class="stat"><div class="stat-value">\(recentCount)</div><div class="stat-label">3天内</div></div>
            <div class="stat"><div class="stat-value">\(sleepingCount)</div><div class="stat-label">更早</div></div>
            <p class="note" style="margin-top:16px">这里看的是 Codex 本地任务状态，方便你知道哪些任务还在跑、哪些刚做完。</p>
            <table>
                <thead><tr><th>状态</th><th>任务</th><th style="text-align:right">距今</th><th style="text-align:right">Tokens</th><th style="text-align:right">时间</th></tr></thead>
                <tbody>\(rows)</tbody>
            </table>
        </div>
        """
    }

    private func buildClaudeReportSection(dateFormatter: DateFormatter) -> String {
        var seenSessions: [String: ClaudeQuotaReading] = [:]
        for reading in claudeLedger.reversed() {
            if let sid = reading.sessionId, seenSessions[sid] == nil {
                seenSessions[sid] = reading
            }
        }
        let recentReadings = seenSessions.values.sorted { $0.timestamp > $1.timestamp }.prefix(20)
        var sessionRows = ""

        for reading in recentReadings {
            let title = escapeHTML(reading.sessionTitle ?? "未命名任务")
            let model = escapeHTML((reading.sessionModel ?? "未知").replacingOccurrences(of: "claude-", with: ""))
            let thinking = reading.sessionHasThinking == true ? "*" : "-"
            let tokens = reading.sessionTotalTokens.map { compactTokenCount($0) } ?? "-"
            let delta = deltaForSession(reading.sessionId ?? "")
            let deltaStr = delta.map { String(format: "约 %.1f%%", $0) } ?? "暂无数据"
            let deltaColor = usageColor(delta)
            let timeStr = dateFormatter.string(from: reading.timestamp)
            sessionRows += """
            <tr>
                <td>\(title)</td>
                <td style="font-size:12px; color:#666">\(model)</td>
                <td style="text-align:center">\(thinking)</td>
                <td style="text-align:right; color:#666">\(tokens)</td>
                <td style="text-align:right; color:\(deltaColor); font-weight:600">\(deltaStr)</td>
                <td style="text-align:right; font-size:12px; color:#999">\(timeStr)</td>
            </tr>
            """
        }
        if sessionRows.isEmpty {
            sessionRows = "<tr><td colspan='6' style='color:#999; text-align:center'>暂无 Claude session 记录，继续使用后自动积累</td></tr>"
        }

        return """
        <h2>Claude 用量报告</h2>
        <div class="card">
            <h3>最近 Session 用量（最多 20 条）</h3>
            <table>
                <thead><tr><th>任务标题</th><th>Model</th><th>Thinking</th><th style="text-align:right">Tokens</th><th style="text-align:right">消耗估算</th><th style="text-align:right">记录时间</th></tr></thead>
                <tbody>\(sessionRows)</tbody>
            </table>
        </div>
        """
    }

    private func buildCodexReportSection(dateFormatter: DateFormatter) -> String {
        let rankedTasks = Array(codexReportTasks().prefix(20))
        let topTasks = Array(rankedTasks.prefix(5))
        let totalReadings = codexLedger.count
        let oldestDate = codexLedger.first.map { dateFormatter.string(from: $0.timestamp) } ?? "-"
        let newestDate = codexLedger.last.map { dateFormatter.string(from: $0.timestamp) } ?? "-"
        let knownDeltas = rankedTasks.compactMap(\.quotaDelta)
        let totalKnownDelta = knownDeltas.reduce(0, +)

        var calibrationRows = ""
        var ratiosByGroup: [String: [Double]] = [:]
        var labelsByGroup: [String: (model: String, window: String)] = [:]
        if codexLedger.count > 1 {
            for i in 1..<codexLedger.count {
                let prev = codexLedger[i - 1]
                let curr = codexLedger[i]
                guard prev.sessionId == curr.sessionId,
                      let windowID = prev.trackedWindowID,
                      curr.trackedWindowID == windowID,
                      (prev.sessionModel ?? "未知") == (curr.sessionModel ?? "未知"),
                      let prevT = prev.sessionTotalTokens,
                      let currT = curr.sessionTotalTokens,
                      currT > prevT
                else { continue }
                let drop = Double(prev.primaryRemaining - curr.primaryRemaining)
                guard drop > 0 else { continue }
                let model = curr.sessionModel ?? "未知"
                let key = "\(model)\u{0}\(windowID)"
                ratiosByGroup[key, default: []].append(Double(currT - prevT) / drop)
                labelsByGroup[key] = (model, curr.trackedWindowTitle ?? "额度窗口")
            }
        }
        for key in ratiosByGroup.keys.sorted() {
            let ratios = ratiosByGroup[key] ?? []
            let labels = labelsByGroup[key] ?? ("未知", "额度窗口")
            let ratio = ratios.count >= 3 ? ratios.sorted()[ratios.count / 2] : nil
            let ratioStr = ratio.map { String(format: "%.0f tokens/1%%", $0) } ?? "数据不足（需更多配对）"
            let statusColor = ratio != nil ? "#27ae60" : "#e67e22"
            calibrationRows += """
            <tr>
                <td>\(escapeHTML(labels.model))</td>
                <td>\(escapeHTML(labels.window))</td>
                <td>\(ratios.count)</td>
                <td style="color:\(statusColor); font-weight:600">\(ratioStr)</td>
            </tr>
            """
        }
        if calibrationRows.isEmpty {
            calibrationRows = "<tr><td colspan='4' style='color:#999; text-align:center'>暂无校准数据，继续使用后自动积累</td></tr>"
        }

        var rankingRows = ""
        for (index, task) in rankedTasks.enumerated() {
            let delta = task.quotaDelta
            let deltaText = delta.map { String(format: "约 %.1f%%", $0) } ?? "暂无数据"
            let tokenText = tokenDisplayHTML(for: task)
            let prompt = htmlAttribute(deepAnalysisPrompt(for: task))
            rankingRows += """
            <tr>
                <td style="font-weight:700">\(index + 1)</td>
                <td>
                    <div style="font-weight:600">\(escapeHTML(task.title))</div>
                    <div style="font-size:12px; color:#999">\(dateFormatter.string(from: task.firstSeen)) -> \(dateFormatter.string(from: task.lastSeen))</div>
                </td>
                <td style="text-align:right; color:\(usageColor(delta)); font-weight:700">\(deltaText)<div style="font-size:11px; color:#999; font-weight:400">\(escapeHTML(task.quotaWindowTitle))</div></td>
                <td style="text-align:right; color:#666">\(tokenText)</td>
                <td>\(escapeHTML(roughUsageDiagnosis(for: task)))</td>
                <td>\(escapeHTML(usageAdvice(for: task)))</td>
                <td style="text-align:right"><button class="copy-button" data-prompt="\(prompt)" onclick="copyDeepPrompt(this)">复制深度分析提示</button></td>
            </tr>
            """
        }
        if rankingRows.isEmpty {
            rankingRows = "<tr><td colspan='7' style='color:#999; text-align:center'>暂无可排序的 Codex 任务记录</td></tr>"
        }

        var roughCards = ""
        for task in topTasks {
            let deltaText = task.quotaDelta.map { String(format: "约 %.1f%%", $0) } ?? "暂无数据"
            roughCards += """
            <div class="mini-card">
                <div class="mini-title">\(escapeHTML(task.title))</div>
                <div class="mini-meta">\(escapeHTML(task.quotaWindowTitle))：\(deltaText) · 新增 Tokens：\(task.tokenDelta.map { compactTokenCount($0) } ?? "-")\(cumulativeTokenText(for: task))</div>
                <div class="mini-body">\(escapeHTML(roughUsageDiagnosis(for: task)))</div>
                <div class="mini-body"><b>下次省法：</b>\(escapeHTML(usageAdvice(for: task)))</div>
            </div>
            """
        }
        if roughCards.isEmpty {
            roughCards = "<p class='note'>还没有足够数据做粗分析。继续用几天后，这里会自动变得更有参考价值。</p>"
        }

        return """
        <h2>Codex 用量报告</h2>

        <div class="card">
            <h3>数据概览</h3>
            <div class="stat"><div class="stat-value">\(totalReadings)</div><div class="stat-label">账本记录条数</div></div>
            <div class="stat"><div class="stat-value">\(rankedTasks.count)</div><div class="stat-label">已追踪任务数</div></div>
            <div class="stat"><div class="stat-value">\(String(format: "%.1f%%", totalKnownDelta))</div><div class="stat-label">已可靠归因额度</div></div>
            <div style="margin-top:16px; font-size:13px; color:#999">记录范围：\(oldestDate) -> \(newestDate)</div>
        </div>

        <div class="card">
            <h3>粗分析：最值得复盘的任务</h3>
            <p class="note">这部分只用本地记录和规则判断，不调用 AI，所以几乎不消耗额度。它的作用是先帮你抓重点。</p>
            \(roughCards)
        </div>

        <div class="card">
            <h3>额度消耗排行榜（由高到低）</h3>
            <p class="note">每条任务会注明归属的额度窗口。不同窗口彼此独立，百分比不能直接换算成相同 Token 数。新增 TOKENS 是模型处理量增量，不等于 API 账单。按钮只会复制提示词，不会自动调用 Codex。</p>
            <table>
                <thead><tr><th>#</th><th>任务</th><th style="text-align:right">额度</th><th style="text-align:right">新增 TOKENS</th><th>粗判断</th><th>省法</th><th style="text-align:right">细分析</th></tr></thead>
                <tbody>\(rankingRows)</tbody>
            </table>
        </div>

        <div class="card">
            <h3>校准状态（按 Model 和额度窗口分组）</h3>
            <p class="note">5 小时、普通周额度和 Spark 周额度分别校准，避免把不同规则混成一个换算比例。</p>
            <table>
                <thead><tr><th>Model</th><th>额度窗口</th><th>数据点</th><th>换算比率</th></tr></thead>
                <tbody>\(calibrationRows)</tbody>
            </table>
        </div>
        """
    }

    private func codexReportTasks() -> [CodexReportTask] {
        var grouped: [String: [CodexQuotaReading]] = [:]
        for reading in codexLedger {
            guard let sid = reading.sessionId else { continue }
            grouped[sid, default: []].append(reading)
        }

        let tasks = grouped.compactMap { sid, readings -> CodexReportTask? in
            let sorted = readings.sorted { $0.timestamp < $1.timestamp }
            guard let last = sorted.last,
                  let windowID = sorted.reversed().compactMap(\.trackedWindowID).first
            else { return nil }
            let windowReadings = sorted.filter { $0.trackedWindowID == windowID }
            guard let firstWindowReading = windowReadings.first,
                  let lastWindowReading = windowReadings.last
            else { return nil }
            let latestWithTitle = sorted.reversed().first { ($0.sessionTitle ?? "").isEmpty == false }
            let tokenValues = sorted.compactMap(\.sessionTotalTokens)
            let tokenTotal = tokenValues.last
            let tokenDelta: Int?
            if let firstToken = tokenValues.first, let lastToken = tokenValues.last {
                tokenDelta = max(0, lastToken - firstToken)
            } else {
                tokenDelta = nil
            }
            return CodexReportTask(
                id: sid,
                title: shortTaskTitle(latestWithTitle?.sessionTitle ?? last.sessionTitle ?? "未命名任务"),
                model: last.sessionModel ?? "未知",
                tokenDelta: tokenDelta,
                tokenTotal: tokenTotal,
                quotaDelta: deltaForCodexSession(sid, windowID: windowID),
                quotaWindowID: windowID,
                quotaWindowTitle: lastWindowReading.trackedWindowTitle ?? "额度窗口",
                firstSeen: firstWindowReading.timestamp,
                lastSeen: lastWindowReading.timestamp,
                sessionFile: codexSessionFile(id: sid))
        }

        return tasks.sorted { lhs, rhs in
            let leftDelta = lhs.quotaDelta ?? -1
            let rightDelta = rhs.quotaDelta ?? -1
            if abs(leftDelta - rightDelta) > 0.01 {
                return leftDelta > rightDelta
            }
            return (lhs.tokenDelta ?? 0) > (rhs.tokenDelta ?? 0)
        }
    }

    private func roughUsageDiagnosis(for task: CodexReportTask) -> String {
        let delta = task.quotaDelta ?? 0
        let tokens = task.tokenDelta ?? 0
        let minutes = max(1, Int(task.lastSeen.timeIntervalSince(task.firstSeen) / 60))
        var reasons: [String] = []

        let isWeekly = task.quotaWindowTitle.contains("一周")
        let highThreshold = isWeekly ? 3.0 : 15.0
        let mediumThreshold = isWeekly ? 1.0 : 5.0

        if delta >= highThreshold {
            reasons.append("额度掉得很明显，通常是大任务、反复验证、或者一次性看了很多材料。")
        } else if delta >= mediumThreshold {
            reasons.append("这是中高消耗任务，值得复盘一下中间有没有来回试错。")
        } else if delta > 0 {
            reasons.append("额度有消耗，但还不算离谱。")
        } else {
            reasons.append("目前只看到 token 或记录，还没有抓到明确的额度下降。")
        }

        if tokens >= 5_000_000 {
            reasons.append("本段新增 token 很高，常见原因是会话太长、上下文背得多，或者同一任务里混了多个主题。")
        } else if tokens >= 1_000_000 {
            reasons.append("本段新增 token 偏高，可能读了不少文件或跑了多轮检查。")
        }

        if let total = task.tokenTotal, let deltaTokens = task.tokenDelta, total > max(deltaTokens * 2, deltaTokens + 1_000_000) {
            reasons.append("这个会话以前已经累积了不少 token，所以累计数不能直接拿来和本次额度对比。")
        }

        if minutes >= 90 {
            reasons.append("这个会话持续时间较长，后半段每次对话都可能背着更厚的上下文。")
        }

        return reasons.prefix(2).joined(separator: " ")
    }

    private func usageAdvice(for task: CodexReportTask) -> String {
        let delta = task.quotaDelta ?? 0
        let tokens = task.tokenDelta ?? 0
        let highThreshold = task.quotaWindowTitle.contains("一周") ? 2.0 : 10.0
        if delta >= highThreshold {
            return "下次先让它只列方案和相关文件，确认后再动手；大任务拆成两三个小任务。"
        }
        if tokens >= 3_000_000 {
            return "做完一个主题就开新对话，别把不相干的需求塞进同一个会话。"
        }
        if task.sessionFile == nil {
            return "记录还不够完整，先继续积累几天，再看趋势。"
        }
        return "保持任务边界清楚，少让它全项目扫描，通常就能省不少。"
    }

    private func tokenDisplayHTML(for task: CodexReportTask) -> String {
        let main = task.tokenDelta.map { compactTokenCount($0) } ?? "-"
        let note = cumulativeTokenText(for: task)
        guard !note.isEmpty else { return main }
        return "\(main)<div style=\"font-size:11px; color:#aaa; margin-top:3px\">\(escapeHTML(note.trimmingCharacters(in: .whitespaces)))</div>"
    }

    private func cumulativeTokenText(for task: CodexReportTask) -> String {
        guard let total = task.tokenTotal,
              let delta = task.tokenDelta,
              total > max(delta * 2, delta + 1_000_000)
        else { return "" }
        return " · 会话累计 \(compactTokenCount(total))"
    }

    private func deepAnalysisPrompt(for task: CodexReportTask) -> String {
        let deltaText = task.quotaDelta.map { String(format: "约 %.1f%%", $0) } ?? "暂无明确额度下降"
        let tokenText = task.tokenDelta.map { compactTokenCount($0) } ?? "新增token未知"
        let fileText = task.sessionFile?.path ?? "没有找到本地 session 文件，只能根据摘要分析"
        return """
        请帮我做一次 Codex 高消耗任务复盘，全程用大白话，不要讲技术黑话。

        任务标题：\(task.title)
        模型：\(task.model)
        额度窗口：\(task.quotaWindowTitle)
        估算额度消耗：\(deltaText)
        本次新增 token 估算：\(tokenText)
        会话累计 token：\(task.tokenTotal.map { compactTokenCount($0) } ?? "累计token未知")
        记录时间：\(task.firstSeen) 到 \(task.lastSeen)
        本地 session 文件：\(fileText)

        请你优先读取这个 session 文件，只做只读分析，不要修改任何文件。

        我想知道：
        1. 这次到底贵在哪里？请按“读文件、写代码、跑命令、截图/浏览器验证、反复修错、上下文太长”等类别拆开。
        2. 哪些操作最可能烧额度？请给我排个顺序。
        3. 如果我要达成同样目标，下次怎么问、怎么拆任务，能明显省额度？
        4. 请给我一版“更省钱的提问模板”，让我以后可以直接复制使用。
        5. 最后用一句话总结：这个任务是“值得花”还是“有明显浪费”。
        """
    }

    private func usageColor(_ delta: Double?) -> String {
        guard let delta else { return "#999" }
        if delta > 5 { return "#e74c3c" }
        if delta >= 1 { return "#2980b9" }
        return "#27ae60"
    }

    private func htmlAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\n", with: "&#10;")
    }

    private func deltaForSession(_ sessionId: String) -> Double? {
        var total = 0.0
        var found = false
        guard claudeLedger.count > 1 else { return nil }
        for i in 1..<claudeLedger.count {
            let prev = claudeLedger[i - 1]
            let curr = claudeLedger[i]
            guard prev.sessionId == sessionId,
                  curr.sessionId == sessionId,
                  curr.timestamp >= prev.timestamp,
                  curr.timestamp.timeIntervalSince(prev.timestamp) <= 3 * 60
            else { continue }
            let drop = Double(prev.primaryRemaining - curr.primaryRemaining)
            if drop > 0 { total += drop; found = true }
        }
        return found ? total : nil
    }

    private func deltaForCodexSession(_ sessionId: String, windowID: String? = nil) -> Double? {
        var total = 0.0
        var found = false
        guard codexLedger.count > 1 else { return nil }
        let targetWindowID = windowID ?? codexLedger.reversed().first {
            $0.sessionId == sessionId && $0.trackedWindowID != nil
        }?.trackedWindowID
        guard let targetWindowID else { return nil }
        for i in 1..<codexLedger.count {
            let prev = codexLedger[i - 1]
            let curr = codexLedger[i]
            guard prev.trackedWindowID == targetWindowID,
                  curr.trackedWindowID == targetWindowID
            else { continue }
            let previous = QuotaReading(
                timestamp: prev.timestamp,
                remainingPercent: prev.primaryRemaining,
                sessionID: prev.sessionId)
            let current = QuotaReading(
                timestamp: curr.timestamp,
                remainingPercent: curr.primaryRemaining,
                sessionID: curr.sessionId)
            if let drop = UsageAttribution.quotaDrop(
                for: sessionId,
                from: previous,
                to: current)
            {
                total += drop
                found = true
            }
        }
        return found ? total : nil
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    @objc private func openCodexBarApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/CodexBar.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return !isRunning
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
