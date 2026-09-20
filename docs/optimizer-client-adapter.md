# Optimizer client adapter

`OptimizerSessionAdapter` is an embeddable TypeScript adapter for a host that
already owns task state, permissions and tool execution. It starts in
`suggest` mode (or `observe` when supplied by the current policy). It returns
advisory plans, tool selections and model routing; it never silently applies a
plan or switches a model.

The host supplies a current policy, compact plan/tool/model catalogs, and its
normal tool executor. Tool catalog entries can include `load()` callbacks; the
adapter returns IDs and invokes those callbacks only through the explicit
`loadSelectedTool` method. Mandatory and coordination tools are preserved even
outside the bounded advisory shortlist. If tool evaluation cannot produce a
safe result, the adapter returns the full host catalog fallback.

For `readOnly: true` tools, `executeTool` uses the existing memory-only
`ReadOnlyToolResultCache`. It obtains fresh permission and dependency
fingerprints before every cache lookup. Changed policy, dependency, permission,
or optimizer availability bypasses the cache and retains normal host execution.
Cache lookup failures also fall back to the normal host executor, whose
authorization result remains final. Writes bypass cache fingerprinting entirely
and always
use the normal host callback and are never cached.

`applySuggestedPlan` and `applySuggestedModel` require explicit caller
confirmation, active current project/provider policy in suggest mode, a current
eligible ID from advice for that task, and the relevant host capability.
Explicit model selections block model application.
Advice is bound to the exact task requirements, constraints, dependency and
permission fingerprints, policy, selected metadata, and host catalog observed
when it was generated. The adapter reloads those inputs before application and
rejects any change, including expired policies or plans.
They are integration points, not evidence that an unvalidated automatic mode
is enabled.

`captureVerifiedTask` accepts only opt-in, successful, verified, curated
candidate content through the host's save-candidate callback. The callback
receives the local `candidate_capture` shape: `project_id`, `task_id`,
`kind`, `title`, `content`, `source`, `verification`, `required_tools`,
`constraints`, and `dependencies`. The adapter rejects incomplete or oversized
capture metadata rather than dropping prerequisites. The local transport enforces active storage and
write access, a finished successful task with verification evidence, and puts
the result in pending review rather than search or reuse. It has no transcript
input and does not ingest raw conversation content.

The adapter has no global interception mechanism and cannot rewrite Codex
context. A host must call it at its own supported task boundaries.
