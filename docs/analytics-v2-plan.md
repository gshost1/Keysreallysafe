# Product analytics v2: aggregate usage, and "compare" as the reason to opt in

Status: implemented in 0.8.0 (2026-09-23); [product-analytics.md](product-analytics.md)
describes what shipped. Differences from this design: model names are limited
to public model families (anything else is `unknown`) and unknown providers
become `other`; window `readings` counts UTC hours with a live reading (1–24);
benchmark percentiles are rounded to two significant figures; Compare compares
days, not people, because reports carry no persistent ID; the collector runs
behind a Cloudflare Tunnel instead of Caddy.

## Why

The v1 counters answer "does the feature work". They cannot answer the
questions that would make the dataset worth having: how much do people run
through Claude Code, Codex and Grok; which models; how often they hit a plan
window; what an API-key day looks like by provider. Nobody else sees that
across tools. Users only hand it over if they get something back, so v2 pairs
a wider aggregate report with a **compare** feature that is available only to
contributors: "how this Mac's week compares to everyone who shares."

The privacy boundaries do not move. v2 still contains no prompts, no key,
project or session names, no paths, no hostnames, no account IDs, no
persistent device or install ID, no exact timestamps, and no dollar amounts.
It adds provider and model names and daily token totals, which v1 excluded;
that is the entire change in what leaves the Mac, and the Privacy dialog says
so in those words.

## Report v2

One report per completed UTC day, as today. Top level:

| field | as v1 | notes |
|---|---|---|
| `schema_version` | `2` | |
| `consent_version` | `2` | new opt-in required |
| `report_id`, `day`, `app_version`, `os_major`, `architecture` | same | |
| `counts` | same event enum | unchanged |
| `usage` | **new** | array, see below |
| `windows` | **new** | array, see below |
| `gateway` | **new** | array, see below |

`usage`: one row per (source, provider, model) with activity that day, from
`usage_events` grouped by `occurred_at` UTC day.

```
{ "source": "claude_code" | "codex" | "grok",
  "provider": <allowlisted provider id>,
  "model": <model id as the tool wrote it, ≤ 64 chars, allowlisted charset>,
  "prompts": n, "model_calls": n,
  "input_tokens": n, "output_tokens": n,
  "cached_read_tokens": n, "cache_creation_tokens": n, "reasoning_tokens": n }
```

`windows`: one row per plan window the tool reports locally, from the
snapshots the Usage pane already reads.

```
{ "source": "claude_code", "window": "5h" | "fable" | "weekly",
  "peak_percent": 0–100,        // highest reading seen that day, rounded to 5
  "hit_cap": true|false,        // any reading ≥ 100
  "readings": n }               // how many readings the day had
```

`gateway`: one row per provider with routed calls that day, from
`gateway_usage`. Key names are never included; rows are per provider.

```
{ "provider": <allowlisted provider id>, "model": <as above or "unknown">,
  "requests": n, "ok": n, "failed": n,
  "input_tokens": n, "output_tokens": n,
  "cache_read_tokens": n, "cache_write_tokens": n }
```

Bounds, enforced by both the app and the collector, exactly as v1 enforces
its own: at most 40 `usage` rows, 8 `windows` rows and 40 `gateway` rows per
report; every integer 0…10^12; the report body ≤ 32 KiB (v1: 16 KiB); model
strings match `^[A-Za-z0-9._:-]{1,64}$`; provider ids come from the shipped
catalog. Unknown fields anywhere are rejected. A report that fails any bound is
dropped locally and never sent.

What is deliberately still absent: `cost_usd_ticks` (dollar figures are a
list-price estimate and add nothing the token counts do not); `session_id`,
`cwd`, `session_title`, `agent_name` (identifying); `key`/`key_name` (the vault
is the product); exact `occurred_at`/`ts` (the day is enough); IP addresses
(the collector already refuses to store them).

## Where it plugs in

- `ProductAnalytics.swift`: `Report` gains the three arrays; `record` is
  unchanged; a new `summarizeDay(day)` fills the arrays from the catalog when
  a day closes, i.e. in `flushCompletedReports` just before encoding, so the
  active day stays local and the arrays reflect the whole day. This is the one
  place the analytics code reads usage tables; the comment on the class that
  says it never does must change to say exactly what it reads. `consentVersion`
  becomes 2, `schema_version` 2, and the validity check in `update` grows the
  same bounds the collector applies.
- `Analytics/collector.py`: accept `schema_version` 2 only, validate the new
  arrays with the bounds above, store rows in three new tables keyed by
  `report_id`, keep the 30-day retention. The `summary` CLI gains per-provider
  and per-model totals.
- `Fixtures/analytics/report-golden.json`: replaced by a v2 golden that both
  test suites parse, with every array populated.
- `Web/analytics.js` Privacy dialog: the disclosure names the change in one
  sentence ("v2 adds provider and model names and daily token totals; it still
  never includes…"), and the preview shows the actual arrays, as it shows
  counts today.
- `docs/product-analytics.md`: "Collected fields" rewritten for v2; the
  sentence "no provider/model names, exact token totals" is removed because it
  stops being true.

## Compare

A contributor's dashboard gets a **Compare** line under the Usage summary:
"Your week: 1.9B tokens · top 12% of sharing users · most people at your
volume hit the Claude weekly cap by Thursday." Data path:

1. Collector publishes `GET /v1/benchmarks` once a day: percentiles of weekly
   tokens per source, cap-hit rates per window by volume decile, model share.
   Aggregates only, minimum 50 contributing reports per cell, otherwise the
   cell is omitted. No parameters, no auth, cacheable, ≤ 32 KiB.
2. The app fetches it at most once a day, only while analytics is enabled,
   through the same ephemeral transport with the same limits, and caches it in
   `meta`. The request carries nothing about the user; the comparison is
   computed locally against the cached table.
3. Not enabled, or no benchmark cached, or the user's cell is below the
   minimum: the line is absent, not filled with a guess.

This is the second outbound connection the app ever makes (the first is the
report upload). Both exist only after opt-in and both go to the one endpoint
shown in the Privacy dialog. The README's privacy boundaries gain one bullet
saying exactly that.

## Order of work

1. Collector: v2 validation, tables, summary, `/v1/benchmarks`, tests, on the
   Ubuntu host behind Caddy as `Analytics/README.md` describes.
2. App: `Report` v2, `summarizeDay`, bounds, consent 2, golden fixture, Swift
   tests with a synthetic catalog.
3. Privacy dialog disclosure and preview; `docs/product-analytics.md`.
4. Compare line, behind "analytics enabled and benchmark cached".
5. Ship with trial/license gating so first run asks for both once.

Bounded end-to-end trial with synthetic events on the deployed collector
before the endpoint goes into a release, as v1 already requires.
