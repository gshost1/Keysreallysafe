# Keys unattended implementation plan

Prepared September 19, 2026. Authorized scope: complete local development and verification that needs no user presence. Keep MIT, existing vault authorization, and the installed application intact. No actual provider calls, collector deployment, real credential reads, signing or native authorization are needed for this work.

## Parallel work

1. **Provider and key integration.** Verify the direct TypeSafe API against official documentation, implement a reviewed route if supported, preserve scoped vault access, expose compatible stored-key metadata, and test requests/usage/failure behavior with synthetic providers.
2. **Client adapters.** Implement a bounded task preparation pipeline, selective tool/skill loading for capable hosts, permission-aware read-result reuse, explicit application gates, and opt-in capture of verified outcomes. Add a compound MCP preparation tool so existing supported clients can use context and recommendations with fewer round trips. Do not claim global interception or unsupported Codex context editing.
3. **Deployment preparation.** Prepare a self-hosted analytics deployment with persistent storage and TLS templates, offline validation, and a release preflight that never invokes native authorization. Leave destination and live collection unconfigured.
4. **Integration owner.** Add compatible key selection and key-to-optimizer navigation, encrypted pending candidates and review, onboarding, client templates, integration tests, independent review, and refreshed release artifacts.

## Acceptance checks

- Stored keys remain inside the vault; only reviewed provider/host/path combinations may receive a temporary grant.
- Unsupported keys are clearly unavailable and never silently substituted. Missing usage and cost remain unknown.
- Read-result reuse rechecks permissions and current dependencies. Writes and credential-bearing results cannot enter the cache.
- Captured content requires storage/capture opt-in and a successfully verified task, stays encrypted and pending, and cannot enter retrieval until explicitly approved. Lock, project deletion and retention cover candidates.
- Task preparation returns bounded reference material and suggestions. Client abilities and policy gates determine what may be applied. No fabricated quality gate enables automatic behavior.
- Product analytics remains default-off with a nil destination. Templates contain placeholders, not real domains or credentials.
- Focused regression checks, full offline suites, release build, independent review and package verification pass before delivery.

## Work that still needs later input or external validation

- Choose and configure actual hosting/domain, deploy collector, and verify live delivery.
- Complete the final signing identity, Keychain upgrade and Touch ID checks, then install the application.
- Select a permitted real project and authorize bounded Jev requests; validate receipts, expiry, revocation and fallback.
- Compare representative real tasks with baselines before enabling automatic plan/model decisions or claiming net savings.
- Configure live client integrations after the signed application is available.
- Publishing/merging remains a separately reviewable step after verification of the final change.

Shared cloud caches, historical conversation imports, arbitrary response caching, automatic cross-project sharing, background social scraping and model training remain deferred. They are not prerequisites for this release.

## Status

The local implementation and offline verification are complete for the work described above. See [results and remaining gates](unattended-work-results.md). Supported-host adapters require client integration and cannot be presented as global automatic operation. Hosting, native authorization and real quality/savings validation remain separate gates.
