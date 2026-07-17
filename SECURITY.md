# Security and privacy

The app reads local Codex and WorkBuddy metadata, process information and task databases. Task titles, token totals, progress information and generated reports stay on the local computer.

Balance refreshes use the login state already stored by the official apps and contact only the corresponding Codex or WorkBuddy usage endpoint. Credentials are not written to generated reports or bundled with releases. There is no project-owned telemetry service.

Please do not attach raw `~/.codex` session files, `auth.json`, WorkBuddy authentication files or local databases to public issues. They can contain credentials, prompts, file paths and private project information. When reporting a bug, use redacted screenshots and remove task titles, home-directory paths and account identifiers.

Security reports should be sent privately to the repository owner instead of being opened as public issues.
