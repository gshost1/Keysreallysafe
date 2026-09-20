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
outside the bounded advisory shortlist. `SessionTask.requiredTools` names and
required tools of suggested plans are also preserved. `suggestedToolIds` contains
ranked advisory IDs. `toolIds` contains the host-facing selection plus required
tools, or the entire catalog when `fullCatalogFallback` is true. The engine's
`full_catalog_fallback` reports the same decision. Any optional tool omitted by
the catalog bound, lexical prefilter or evaluator candidate limit requires the
full fallback. Hosts must preserve access to that catalog and explicitly choose
whether to use a complete advisory selection; this does not enable auto-routing.

For `readOnly: true` tools, `executeTool` uses the existing memory-only
`ReadOnlyToolResultCache`. It obtains fresh permission and dependency
fingerprints before every cache lookup. Changed policy, dependency, permission,
or optimizer availability bypasses the cache and retains normal host execution.
Cache lookup failures also fall back to the normal host executor, whose
authorization result remains final. Writes bypass cache fingerprinting entirely
and always
use the normal host callback and are never cached.
Hosts can mark a tool `sensitive: true` to bypass caching. Credential-format
heuristics and explicit sensitive result metadata also reject cache admission;
these checks do not discover every possible secret. Hosts remain responsible for
classifying sensitive reads. The cache stays memory-only and permission-scoped.

`applySuggestedPlan` and `applySuggestedModel` require explicit caller
confirmation, active current project/provider policy in suggest mode, a current
eligible ID from advice for that task, and the relevant host capability.
Explicit model selections block model application.
Advice is bound to the exact task requirements, constraints, dependency and
permission fingerprints, policy, selected metadata, and host catalog observed
when it was generated. The adapter reloads those inputs before application and
rejects any change, including expired policies or plans.
Advice expires after five minutes and retains at most 64 tasks. Catalog bindings
are stored as hashes rather than serialized catalog copies. Model application
requires an actual cost/quality-gated proposal; a retained-current abstention is
not an applicable model recommendation.
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
