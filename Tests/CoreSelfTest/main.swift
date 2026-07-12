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
