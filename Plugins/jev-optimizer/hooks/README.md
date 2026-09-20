# Claude Code function hook

`vercel-compaction.ts` retains the upstream module path and adapts the bounded
optimizer library to Claude Code's `session.compact` and `turn.complete` events.
Untouched session messages retain their original handles; edited tool pairs are
rebuilt without handles so the host installs their edited contents.

- Early automatic attempts start at 60% context and require 8,000 new context
  tokens after a previous attempt. A smaller window after compaction establishes
  a fresh baseline. Subagent, aborted and failed turns do not trigger the main
  session's early compaction.
- The library applies a removable-text preflight, largest-output selection,
  request/input budgets and bounded concurrency. Failure or insufficient pruning
  delegates to the host's built-in summary. Tiny early attempts skip both models.
- `observe` mode reports proposals while leaving early automatic attempts
  unchanged. Manual/host-required compaction still reaches the built-in summary.
  Explicit compaction instructions always reach that summarizer directly.
- Validated exact requests can reuse decisions in the current session's bounded
  in-memory cache. Credential, model or endpoint changes replace the transport
  and its cache. Reuse is reported separately and is not charged usage again.

Keys scoped mode (`KEYS_JEV_SCOPED_GRANT=1`) requires both gateway environment
values from the launcher and rejects malformed grants or non-Keys URLs. These
values override saved plugin options as a pair. Outside scoped mode, the key
comes from plugin configuration, environment, then settings; the endpoint comes
from plugin configuration, environment, then the public gateway. Only trusted
HTTPS or loopback destinations are accepted outside scoped mode.

UI summaries distinguish character reduction, estimated request input and actual
reported evaluator tokens. Missing/invalid reported usage is unknown. The hook
does not claim realized dollar savings. Conversation contents and upstream error
bodies are not included in diagnostic logs.

Function hooks and the evaluation HTTP protocol are experimental. Typechecking
uses the local, ignored `types/claude-code.d.ts` generated with `/plugin-types
types`; regenerate after a Claude upgrade. See the [plugin README](../README.md)
for options, data disclosure, limits and testing instructions.
