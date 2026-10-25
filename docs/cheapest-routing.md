# Cheapest upstream routing

`keys gateway cheapest on|off <key>` (and Cheapest upstream in the key's Edit
dialog) is a per-key setting, off by default. When it is on and the key's
provider supports it, the gateway adds the aggregator's own price-sort field to
a POSTed, uncompressed JSON object body on a listed endpoint, unless the body
already names a routing preference. The insert is a byte-level edit (the rest
of the body is sent exactly as the caller wrote it), it is re-parsed before
sending, and anything it cannot edit unambiguously (an escaped or repeated
member name, a non-object where the field would go) goes upstream unchanged.
Only the upstream copy changes. Usage is still parsed against the caller's
body, and no body reaches the catalog or a log. The code is
`Sources/KeysCore/CheapestRouting.swift`.

| Provider | Field added | Endpoints | Left alone when the body has |
|---|---|---|---|
| OpenRouter | `provider.sort: "price"` | `/api/v1/chat/completions`, `/completions`, `/responses`, `/messages` | `provider.sort`, `provider.order`, `provider.only`, a non-object `provider`, a `:nitro` or `:floor` model |
| Vercel AI Gateway | `providerOptions.gateway.sort: "cost"` | `/v4/ai/language-model`, `/v1/chat/completions`, `/v1/responses`, `/v1/messages` | `providerOptions.gateway.sort`, `.order` or `.only`, or a top-level `provider` (the chat shorthand; Vercel rejects a request whose two forms disagree) |

Sources:
- OpenRouter: https://openrouter.ai/docs/features/provider-routing
- Vercel: https://vercel.com/docs/ai-gateway/models-and-providers/provider-filtering-and-ordering
  and https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions/advanced

Routers in the catalog that the setting refuses, as of 2026-10-25:

| Provider | Why |
|---|---|
| Haimaker | `provider.sort: "price"` exists but is already its default (https://docs.haimaker.ai/docs/completion/input) |
| Helicone | already routes a bare model name to the cheapest provider (https://docs.helicone.ai/gateway/provider-routing) |
| Ramp Router (router.com) | no price sort; `models`, `workload_slug`, `allow_flex_tier` instead (https://docs.router.com/api/responses-and-messages) |
| Requesty | provider is chosen through the model string or a policy; no cost policy found (https://docs.requesty.ai) |
| Portkey | routing comes from the `x-portkey-config` strategy; no cost mode |
| Kilo Gateway | none documented (https://kilo.ai/docs/gateway/models-and-providers) |
| Cloudflare AI Gateway | dynamic routes are configured on the gateway, not per request |
| LiteLLM | `cost-based-routing` is a proxy setting, not a request field (https://docs.litellm.ai/docs/routing) |
| NanoGPT | shows `provider.sort: "price"` in an example, but the accepted values aren't documented, so it's left out |
| Kluster, AI/ML API, Braintrust, Experiential Labs | not checked |
