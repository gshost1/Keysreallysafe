#!/bin/sh
# Revoke a Keysrs license (a key posted publicly, a manual refund): it activates
# nowhere new and stops on each Mac at its next check-in (at most 30 + 14 days).
#   scripts/license-revoke.sh <license id> [reason]     license id: cs_live_… or owner_…
#   scripts/license-revoke.sh --undo <license id>
# Refunds and disputes through Stripe revoke automatically; this is for the rest.
set -eu
undo=0
if [ "${1:-}" = "--undo" ]; then undo=1; shift; fi
id="${1:-}"; reason="${2:-manual}"
case "$id" in (*[!A-Za-z0-9_]*|"") echo "usage: $0 [--undo] <license id> [reason]" >&2; exit 2;; esac
case "$reason" in (*[!A-Za-z0-9_-]*) echo "reason: letters, digits, - and _ only" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
if [ "$undo" = 1 ]; then
  sql="DELETE FROM revoked WHERE license_id = '$id';"
else
  sql="INSERT OR REPLACE INTO revoked (license_id, reason, revoked_at) VALUES ('$id', '$reason', unixepoch());"
fi
npx --yes wrangler@4 d1 execute keysrs-licenses --remote --command "$sql"
