# Changelog

## 0.3.0 - 2026-07-17

- Rename the public app to “kong 的额度焦虑缓解器”.
- Add WorkBuddy balance, recent-task credits and direct task links.
- Add a native Windows 10/11 x64 tray version.
- Follow Windows system proxy and PAC settings when querying Codex usage.
- Add a privacy-preserving WorkBuddy diagnostic worksheet for Windows connection issues.
- Publish matching Mac and Windows downloads from one repository.

## 0.2.0 - 2026-07-13

- Follow Codex's server-provided quota windows instead of assuming that both five-hour and weekly windows always exist.
- Show the separate Codex Spark weekly window when available.
- Show banked full-reset count and the earliest reset-credit expiration.
- Keep five-hour display compatibility when that window is returned again.
- Start a v3 task ledger that records the exact quota-window identity, preventing weekly and five-hour percentages from being mixed.
- Group token-to-percent calibration by both model and quota window.
- Use the ChatGPT app icon and launch path when the standalone Codex app is absent.

## 0.1.0 - Unreleased

- Prepare the first public source release.
- Show Codex quota windows, local task states and task progress hints.
- Generate local usage reports and high-usage review prompts.
- Refuse to attribute quota drops across task switches or long observation gaps.
- Discover CodexBar CLI from the app bundle, Homebrew or an explicit environment override.
