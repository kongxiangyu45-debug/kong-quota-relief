import Foundation

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAILED: \(message)\n", stderr)
        exit(1)
    }
}

let samePrevious = QuotaReading(timestamp: start, remainingPercent: 80, sessionID: "task-a")
let sameCurrent = QuotaReading(
    timestamp: start.addingTimeInterval(60),
    remainingPercent: 76,
    sessionID: "task-a")
expect(
    UsageAttribution.quotaDrop(for: "task-a", from: samePrevious, to: sameCurrent) == 4,
    "same-task drop should be attributed")

let switched = QuotaReading(
    timestamp: start.addingTimeInterval(60),
    remainingPercent: 70,
    sessionID: "task-b")
expect(
    UsageAttribution.quotaDrop(for: "task-a", from: samePrevious, to: switched) == nil,
    "task switch must not charge the previous task")
expect(
    UsageAttribution.quotaDrop(for: "task-b", from: samePrevious, to: switched) == nil,
    "task switch must not charge the new task")

let reset = QuotaReading(
    timestamp: start.addingTimeInterval(60),
    remainingPercent: 100,
    sessionID: "task-a")
expect(
    UsageAttribution.quotaDrop(for: "task-a", from: samePrevious, to: reset) == nil,
    "quota reset must not be counted as usage")

let stale = QuotaReading(
    timestamp: start.addingTimeInterval(10 * 60),
    remainingPercent: 70,
    sessionID: "task-a")
expect(
    UsageAttribution.quotaDrop(for: "task-a", from: samePrevious, to: stale) == nil,
    "long observation gaps must remain unattributed")

print("Core self-test passed")

let dynamicUsageJSON = #"""
[
  {
    "provider": "codex",
    "usage": {
      "dataConfidence": "exact",
      "primary": null,
      "secondary": {
        "usedPercent": 1,
        "windowMinutes": 10080,
        "resetsAt": "2026-07-19T22:52:17Z"
      },
      "extraRateWindows": [
        {
          "id": "codex-spark-weekly",
          "title": "Codex Spark Weekly",
          "window": {
            "usedPercent": 0,
            "windowMinutes": 10080,
            "resetsAt": "2026-07-19T23:25:52Z"
          }
        }
      ],
      "codexResetCredits": {
        "availableCount": 3,
        "credits": [
          {"status": "available", "expires_at": "2026-07-18T00:19:25Z"}
        ]
      },
      "updatedAt": "2026-07-12T23:25:52Z"
    }
  }
]
"""#

let parsedDynamic = CodexUsageParser.parse(
    dynamicUsageJSON,
    now: Date(timeIntervalSince1970: 1_750_000_000))
expect(parsedDynamic?.primary == nil, "missing primary window must stay missing")
expect(parsedDynamic?.secondary?.remainingPercent == 99, "weekly remaining percent should be parsed")
expect(parsedDynamic?.sparkWindow?.remainingPercent == 100, "Spark should be a separate window")
expect(parsedDynamic?.availableResetCount == 3, "banked reset count should be parsed")

let classicUsageJSON = #"""
[{"provider":"codex","usage":{"primary":{"usedPercent":25,"windowMinutes":300},"secondary":{"usedPercent":10,"windowMinutes":10080}}}]
"""#
let parsedClassic = CodexUsageParser.parse(classicUsageJSON)
expect(parsedClassic?.primary?.remainingPercent == 75, "five-hour window should remain supported")
expect(parsedClassic?.secondary?.remainingPercent == 90, "classic weekly window should remain supported")

print("Dynamic usage parser self-test passed")
