# Verified-task candidate capture

Candidate capture is an optional project setting, disabled by default. It is separate from product analytics and sends no content to the analytics collector. A writable client can capture curated content only when the project has storage and candidate capture enabled and is not Off.

The client first starts a task, performs its normal work and verification, then calls `task_finish` with `outcome: "success"` and nonempty `verification` evidence. The numeric task ledger stores only a project-keyed digest of that evidence, not the evidence text. A finished task is immutable; retries must match the original outcome and evidence. Client-reported success is not independent proof that a task was correct.

`candidate_capture` accepts the task ID and a curated plan or memory with title, content, source, verification steps, optional constraints, tools, and dependency fingerprints. It does not ingest a transcript. Capture requires a successful completed task with evidence recorded and allows one candidate of each kind per task. Identical retries reuse the same candidate; conflicting content is refused.

Captured entries live in the existing encrypted content archive and start **pending**. They are excluded from library search, context packs and Jev plan selection. Editing, pinning or unarchiving an entry cannot approve it. Retention, project deletion, locking and export follow the same boundaries as other library content.

An administrative dashboard session can inspect a candidate's complete content, provenance and verification steps, then approve or reject its current version. Review carries an `expected_version`; an edit made since inspection requires a fresh review. Editing an approved captured entry returns it to pending, including edits by a writable client. Approval makes the entry eligible for ordinary retrieval checks—it never executes the plan or proves that its dependencies remain valid. Rejection keeps the entry excluded even if subsequently edited or unarchived.

Project-scoped MCP clients can capture and inspect candidates but cannot approve them. The supported-host adapter can invoke capture after an opted-in verified task; the bundled MCP workflow documents the same sequence. Neither building Keys nor opening a project imports previous conversations or enables capture automatically.
