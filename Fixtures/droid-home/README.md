# Synthetic Droid home (`KEYS_DROID_HOME`)

Everything here is invented. No line was copied from a real `~/.factory/logs` file, and the
session, request and model ids are fake. CI and tests point `KEYS_DROID_HOME` at this folder
so the Droid ingest never reads a real log.

`logs/droid-log-single.log` is the active log and `logs/droid-log-single.log.2026-09-30` is a
date-rotated one. Each holds `[Agent] Streaming result` records mixed with non-usage records
(`[Agent] Streaming text`, `[Agent] Tool result`, `[Gateway] Request`) that carry sentinel
strings (`SENTINEL-*-CONTENT`) and extra tag ids (`HOSTID-SENTINEL`, `COMPUTERID-SENTINEL`,
`INSTALLATIONID-SENTINEL`, `TRACEID-SENTINEL`, `SPANID-SENTINEL`, `MISSIONID-SENTINEL`).
The parser must keep only the token fields, model id, session id and timestamp: none of the
sentinels may appear in the catalog. Two records have all-zero token fields and must be
skipped. `totalInputTokens` always equals `inputTokens + cacheReadInputTokens +
cachedTokensWritten` here; it is never added on top of its parts.

## Expected per-model totals (nonzero records only)

Stored raw buckets, per model, over both files:

| model | provider | records | input | cache read | cache write | output | reasoning | total |
|---|---|---|---|---|---|---|---|---|
| claude-sonnet-5 | anthropic | 2 | 2,000 | 71,000 | 500 | 852 | 0 | 74,352 |
| gpt-6-pro | openai | 1 | 640 | 0 | 0 | 220 | 96 | 956 |
| gemini-3-pro | google | 1 | 2,100 | 0 | 0 | 430 | 0 | 2,530 |
| glm-5.3 | zhipu | 1 | 900 | 1,200 | 60 | 150 | 0 | 2,310 |
| kimi-k3 | moonshot | 1 | 450 | 0 | 0 | 90 | 0 | 540 |
| grok-4-fast | xai | 1 | 700 | 0 | 0 | 130 | 64 | 894 |

Total is input + cache write + cache read + output + reasoning, the dashboard's rule for
`droid-local`. 7 rows land in `usage_events` (source `droid-local`); the 2 zero-token records
and the 3 non-usage records produce none.

`claude-sonnet-5` is also the model of `Fixtures/claude-home`, so a cross-tool merge on the
model id can be tested. The records on 2026-10-10 sit in the active log at 09:05, 20:18 and
21:04 UTC and the rotated file holds 2026-09-30 (a previous calendar week and month), so
5-hour, weekly and month windows can be separated with a fixed clock.
