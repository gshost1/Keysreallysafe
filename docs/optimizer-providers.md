# Optimizer provider routes

Keys supports two explicitly reviewed Jev transports. A stored provider key is
eligible only when its provider and configured host match the table. Adding an
arbitrary provider to the vault does not make it compatible with Jev.

| Vault provider | Required host | Scoped POST path | Model | Usage and cost |
| --- | --- | --- | --- | --- |
| `vercel-ai-gateway` | `ai-gateway.vercel.sh` | `/v4/ai/evaluation-model` | `typesafe-ai/jev` | Vercel token counts; reported gateway cost when present |
| `typesafe` | `api.typesafe.ai` | `/v1/systemone` | `jev-latest` | Direct input/output token counts; billed cost unknown |

Both routes support the library's plan retrieval, tool selection, model
recommendations and memory assessment, plus the optional Claude compaction
launcher. Recommendations remain advisory. Neither adapter switches the
client's model, approves execution, or grants access to other providers.

## Select an existing vault key

`GET /api/optimizer/keys` returns compatible stored key names and reviewed
provider capabilities. It reads catalog metadata only: no secret retrieval,
presence prompt, grant or provider request. Names are local UI metadata, not
product analytics. Discovery does not test whether a key is valid, has credit,
or has access to Jev. Custom-host keys and incompatible provider configurations
are omitted.

Select that key when unlocking Optimizer. Keys rechecks eligibility, asks for
native presence and issues a temporary grant for the provider's evaluation
route. Its existing request and time bounds still apply. The real provider
secret stays in the vault/gateway; only a temporary Keys token is passed to the
decision engine. The issued provider, host and scope are checked again after
presence. Local library access remains available without choosing a Jev key.

Optimizer and launcher grants carry an explicit `jev_provider` marker and
`exact_paths: true`. The server checks the reviewed authentication, API and
path-prefix configuration before approval, again before an uncached secret
read, and when the grant is used. Only the exact evaluation route is accepted;
descendant routes are refused. Ordinary grants keep their existing prefix
semantics. TypeSafe has an empty catalog path prefix, since clients send its
complete `/v1/systemone` path.

The Claude launcher keeps Vercel as its default. For a direct TypeSafe key:

```sh
python3 scripts/claude-with-jev.py my-typesafe-key --provider typesafe
```

It requests the direct route, verifies the returned grant and passes the
protocol with the temporary token to the child. Existing Vercel invocation is
unchanged. Grant revocation on exit and built-in compaction fallback continue
to apply. This command requires the signed, running app and presence; it is not
part of offline validation.

Internally the launcher requests `--jev-provider typesafe` (or
`--jev-provider vercel-ai-gateway`) along with the exact POST path. It refuses
an older app response lacking the reviewed marker or exact-path flag, or one
whose provider, host, base URL, authorization header or route differs.

## Protocol evidence

The direct implementation follows TypeSafe's [API reference](https://docs.typesafe.ai/api)
and [quick start](https://docs.typesafe.ai/introduction/quickstart), checked on
2026-09-19. They document bearer authentication, a body containing `model`,
`state` and `questions`, native `noul` answers, and snake_case
`usage.input_tokens` / `usage.output_tokens`. Published choice/score confidence
is preserved, rather than recomputed from probabilities. No billed-cost field
is documented, so Keys does not infer a price or use Vercel metadata for direct
responses. Model aliases can resolve to a provider version; see TypeSafe's
[model reference](https://docs.typesafe.ai/models).

Vercel retains its existing native evaluation adapter: model/protocol headers,
`boolean` wire questions, camelCase usage, and optional gateway cost metadata.
Vercel's [Jev model page](https://vercel.com/ai-gateway/models/jev) describes
availability through that gateway. The two protocols are selected explicitly;
the client never guesses compatibility from a URL or falls back to another
provider with the selected key.

## Validation and unavailable gates

Automated coverage uses synthetic response fixtures, injected transports and
loopback test servers. It checks both wire formats, exact local endpoint and
provider pairing, metadata discovery without secret reads, scoped grants,
usage parsing, absent cost, revocation and fallback. No real TypeSafe account,
key, provider request, Claude runtime or billed savings has been validated by
those tests.

Before using either route, install and test the final signed build through the
normal Keychain/presence workflow and obtain a compatible provider account.
Account eligibility, live response behavior, provider price and current client
hook support remain live release checks. No automatic provider fallback,
OpenAI/Anthropic/Gemini-as-Jev compatibility, or automatic client model switch
is enabled. Further providers need their own verified protocol, allowlisted
host/auth/path, parser and offline tests before appearing in discovery.
