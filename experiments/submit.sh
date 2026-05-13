#!/bin/sh
# Submit a new experiment to Synthex Hub.
#
# Usage:
#   SYNTHEX_HUB_TOKEN=<master token> \
#     experiments/submit.sh experiments/configs/ant.json
#
# Optional:
#   SYNTHEX_HUB_URL=...      override hub URL (default https://synthex.fit)
#   SYNTHEX_SUBMITTER=alice  attribution name on the resulting run
#
# What this does:
#   POST <hub>/api/master/experiments  with body @<config-file>
#
# The hub spawns an Oban-supervised master loop. The experiment
# runs ENTIRELY on the hub server — you don't need to keep this
# terminal open, your laptop online, or anything else after the
# submission returns. Crash recovery, checkpointing, and progress
# tracking are all server-side.
#
# Monitor at https://synthex.fit. Cancel with:
#
#   curl -X POST -H "Authorization: Bearer $SYNTHEX_HUB_TOKEN" \
#        https://synthex.fit/api/master/experiments/<id>/cancel
set -eu

if [ "$#" -lt 1 ]; then
  printf >&2 'usage: %s <config-file.json>\n' "$0"
  printf >&2 '\n'
  printf >&2 '  Examples:\n'
  printf >&2 '    %s experiments/configs/ant.json\n' "$0"
  printf >&2 '    %s experiments/configs/humanoid.json\n' "$0"
  exit 2
fi

CONFIG="$1"

if [ ! -f "$CONFIG" ]; then
  printf >&2 'config file not found: %s\n' "$CONFIG"
  exit 2
fi

if [ -z "${SYNTHEX_HUB_TOKEN:-}" ]; then
  printf >&2 'SYNTHEX_HUB_TOKEN is not set. Get it from the hub operator.\n'
  exit 2
fi

URL="${SYNTHEX_HUB_URL:-https://synthex.fit}"
SUBMITTER="${SYNTHEX_SUBMITTER:-}"

CURL_HEADERS="-H Authorization:Bearer\ $SYNTHEX_HUB_TOKEN -H Content-Type:application/json"

if [ -n "$SUBMITTER" ]; then
  curl --fail-with-body -sS -X POST \
       -H "Authorization: Bearer $SYNTHEX_HUB_TOKEN" \
       -H "Content-Type: application/json" \
       -H "X-Submitter: $SUBMITTER" \
       --data "@$CONFIG" \
       "$URL/api/master/experiments"
else
  curl --fail-with-body -sS -X POST \
       -H "Authorization: Bearer $SYNTHEX_HUB_TOKEN" \
       -H "Content-Type: application/json" \
       --data "@$CONFIG" \
       "$URL/api/master/experiments"
fi

printf '\n'
printf 'Submitted. Track progress at %s\n' "$URL"
