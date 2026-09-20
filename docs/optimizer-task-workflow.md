# Optimizer task workflow

Use the same task ID for all accounting and advisory work in one task:

1. Start it with `keys_task_start`.
2. Call `keys_task_prepare` with a bounded query and local context constraints.
   It prepares local context only by default. Set `include_evaluations: true`
   only in a Jev-enabled session to request advisory plan, tool, and model
   suggestions. The MCP adapter never applies a suggestion, changes client
   context, or runs a tool.
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
coerce either shape. A revoked or expired session fails closed; no partial
decrypted context pack is returned. Unknown provider usage remains unknown.
