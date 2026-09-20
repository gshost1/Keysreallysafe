# Optimizer task workflow

A task ID is optional. Every optimizer session already owns a session task, and
`keys_task_prepare` and the advisory tools attribute their usage to it when no
`task_id` is supplied. Supply a `task_id` only to attribute work to a task you
started yourself; it must be a canonical UUID, and other values are rejected
before any request is sent.

1. Optional, writable sessions only: start a separately attributable task with
   `keys_task_start`. `client` is required and identifies the host, for example
   `{"client": "claude-code"}` (1-128 characters from `A-Z a-z 0-9 . _ : / -`).
   `parent_id`, when given, must be a task UUID. Read-only sessions do not list
   this tool and simply use the session task.
2. Call `keys_task_prepare` with a bounded query and local context constraints.
   It prepares local context only by default. Set `include_evaluations: true`
   only in a Jev-enabled session to request advisory plan, tool, and model
   suggestions. The MCP adapter never applies a suggestion, changes client
   context, or runs a tool.
   - Plans come from the project's approved library. Keys shortlists them
     locally; there is no caller-supplied `plan_candidates` argument, and
     pending or unapproved candidates are never evaluated.
   - Tools are ranked from the `tool_catalog` you supply, models from
     `model_catalog`.
   - Model routing also receives `explicit_model_id`, `current_model_id`,
     `optimizer_cost_usd`, `cache_rebuild_cost_usd` and `fallback_cost_usd` when
     you supply them. Omit values you do not know: costs are never guessed, and
     an explicitly selected model is not overridden.
3. Perform normal host work and verify the outcome independently.
4. Finish with `keys_task_finish`, including concise verification evidence.
   Evidence is recorded as a keyed digest in the numeric ledger, not raw text.
5. If project storage and candidate capture are explicitly enabled, stage
   curated content with `keys_candidate_capture`. It requires a finished
   successful task with nonempty verification evidence. It does not establish
   independent task success.
6. An administrator manually reviews the pending candidate. Pending candidates
   are excluded from search, context preparation, and reuse until approved.

`keys_task_prepare` keeps local `context_constraints` as strings and passes
`engine_constraints` as a separate record to advisory operations. It does not
coerce either shape. Unknown provider usage remains unknown.

## Stage results and failures

Each of `stages.context`, `stages.plans`, `stages.tools` and `stages.models` is
either the complete stage result or a status object; a stage is never truncated.

- A recoverable advisory failure does not discard the prepared context. A
  policy or capability denial in a still-valid session (`operation_denied`), an
  optimizer budget or rate limit (`optimizer_limit`), or another refused
  operation (`operation_refused`) yields
  `{"status": "unavailable", "reason": ...}` for that stage, and the result
  reports `"evaluations": "partial"`. Remaining stages still run.
- Before a partial result is returned, the adapter makes a fresh authorization
  check against Keys. If that check fails for any reason, the whole call fails
  and no context is returned, because the earlier failure may have raced with a
  lock or revocation.
- A locked, expired or revoked session (`session_locked_or_expired`), an
  unreachable Keys (`keys_unavailable`), an unrecognized 403 body, and any other
  unknown error fail closed immediately: no partial decrypted context pack is
  returned.
- Limits count UTF-8 bytes, not escaped characters: 24,000 bytes per stage and
  128,000 bytes per request. Non-ASCII text is sent and returned as UTF-8 rather
  than `\u` escapes, so it does not expand against these bounds. A stage over
  the bound is replaced by `{"status": "stage_too_large"}`; text that is not
  valid Unicode is refused (`invalid_stage`, `invalid_request`).
