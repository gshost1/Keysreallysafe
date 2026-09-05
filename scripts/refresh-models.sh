#!/usr/bin/env bash
set -euo pipefail

readonly source_url="https://openrouter.ai/api/v1/models"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_dir="$(cd "${script_dir}/.." && pwd)"
readonly output_file="${repo_dir}/Fixtures/models.json"
temporary_file="$(mktemp "${TMPDIR:-/tmp}/keysreallysafe-models.XXXXXX")"
trap 'rm -f "${temporary_file}"' EXIT

fetched_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

curl -sSf "${source_url}" | jq -e \
  --arg fetched_at "${fetched_at}" \
  --arg source "${source_url}" '
    def per_mtok($value):
      if $value == null or $value == "" then null
      else ($value | tonumber) * 1000000
      end;

    .data
    | map(select(.id | contains(":") | not))
    | sort_by(.created // 0)
    | reverse
    | reduce .[] as $model (
        {seen: {}, models: []};
        ($model.canonical_slug // $model.id) as $canonical_id
        | if .seen[$canonical_id] then .
          else
            .seen[$canonical_id] = true
            | .models += [$model]
          end
      )
    | {
        fetched_at: $fetched_at,
        source: $source,
        models: [
          .models[:100][]
          | {
              id: .id,
              name: .name,
              provider: (.id | split("/")[0]),
              input_per_mtok: per_mtok(.pricing.prompt),
              output_per_mtok: per_mtok(.pricing.completion),
              cache_read_per_mtok: per_mtok(.pricing.input_cache_read),
              context: .context_length
            }
        ]
      }
  ' > "${temporary_file}"

mv "${temporary_file}" "${output_file}"
trap - EXIT
