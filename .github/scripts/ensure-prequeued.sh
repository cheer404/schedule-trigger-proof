#!/usr/bin/env bash
set -euo pipefail

target_utc="${1:?target UTC is required}"
wait_environment="${2:-daily-queue}"
workflow_ref="${3:-main}"
wait_minutes="${4:-1425}"

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
token="${GH_TOKEN:?GH_TOKEN is required}"
export GH_TOKEN="$token"

if [[ ! "$target_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "::error::Invalid target_utc format: $target_utc"
  exit 1
fi
if [[ ! "$wait_minutes" =~ ^[0-9]+$ ]]; then
  echo "::error::wait_minutes must be an integer"
  exit 1
fi

target_epoch="$(date -u -d "$target_utc" +%s)"
now_epoch="$(date -u +%s)"
release_offset="$((target_epoch - now_epoch - wait_minutes * 60))"

# A daily-queue job should leave its environment no more than 20 minutes early
# and no more than one hour late. Refuse tasks that cannot meet that window.
if (( release_offset > 1200 || release_offset < -3000 )); then
  echo "::error::The selected wait environment cannot release near target=$target_utc (offset_seconds=$release_offset)."
  exit 1
fi

run_title="Daily target $target_utc"

find_existing_run() {
  gh run list \
    --repo "$repo" \
    --workflow daily-prequeued.yml \
    --event workflow_dispatch \
    --limit 100 \
    --json databaseId,displayTitle,status,conclusion \
    --jq "[.[] | select(.displayTitle == \"$run_title\") | select(.status != \"completed\" or .conclusion == \"success\")][0].databaseId // empty"
}

for attempt in 1 2 3; do
  existing_run="$(find_existing_run || true)"
  if [[ -n "$existing_run" ]]; then
    echo "PREQUEUE_CONFIRMED run_id=$existing_run target=$target_utc"
    exit 0
  fi

  echo "PREQUEUE_DISPATCH attempt=$attempt target=$target_utc"
  gh workflow run daily-prequeued.yml \
    --repo "$repo" \
    --ref "$workflow_ref" \
    -f mode=production \
    -f target_utc="$target_utc" \
    -f wait_environment="$wait_environment" || true

  for _ in 1 2 3; do
    sleep 5
    existing_run="$(find_existing_run || true)"
    if [[ -n "$existing_run" ]]; then
      echo "PREQUEUE_CONFIRMED run_id=$existing_run target=$target_utc"
      exit 0
    fi
  done
done

echo "::error::Unable to confirm a prequeued run for target=$target_utc after three attempts."
exit 1
