# Changelog

All notable changes to Keysreallysafe. Each entry is a GitHub release.

## 0.1.0 — 2026-09-04

First public release.

### Added
- Local spend meter: reads Claude Code, Grok and Codex usage logs incrementally, prices from a checked-in list-price table (`Fixtures/models.json`) with hand overrides.
- Site on `127.0.0.1` with three panes: Usage (plan windows as `plan · % used · resets in`), Chart (today by hour, week and month by day, tokens or USD, model and project breakdown), Keys.
- Key vault in the macOS Keychain: add, copy with clipboard wipe, reveal, env injection, edit, rotate, delete, per-key audit log. Touch ID on every read.
- Local gateway on `127.0.0.1:12767` that injects a vault key into SDK traffic, records usage, and never stores message text.
- Menu bar item with the weekly window of each tool; 5-hour windows, reset times and Grok dollars in the dropdown. Refreshes every minute and on open.
- `keys doctor`, `keys purge`, `keys autostart --remove`, OpenRouter credit poll, CSV and Markdown export.
- Grouped provider catalog (`Web/providers.json`, 53 providers).

### Security
- Origin token on every mutating request, `Host` and `Sec-Fetch-Site` checks on both servers, redirect refusal on all outbound calls, content-length and body-size validation, no auth files ever read.

### Fixed
- Claude turns are counted once per message id; the previous count was roughly three times too high.
