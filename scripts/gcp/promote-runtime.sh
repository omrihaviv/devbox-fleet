#!/usr/bin/env bash
# Promote a candidate manifest to the fleet pointer. This is the ONLY writer of
# runtime/manifest.json — terraform apply uploads content-addressed candidates
# and never touches the pointer, so a timer firing mid-canary keeps consuming
# the previously promoted config.
#
# Flow: terraform apply → sync-converge.sh <canary> --manifest-sha <sha>
#       → verify → promote-runtime.sh <sha> → timers converge fleet ≤8h.
set -euo pipefail

BUCKET="${DEVBOX_RUNTIME_BUCKET:-}"
if [ -z "$BUCKET" ]; then
  echo "FATAL: set DEVBOX_RUNTIME_BUCKET (terraform -chdir=gcp output -raw runtime_bucket)" >&2
  exit 2
fi

if [ "$#" -ne 1 ] || ! [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "usage: $0 <manifest-sha256>" >&2
  echo "  (from: terraform -chdir=gcp output -raw runtime_manifest_sha256)" >&2
  exit 2
fi
sha="$1"

candidate="gs://${BUCKET}/runtime/manifest/${sha}.json"
pointer="gs://${BUCKET}/runtime/manifest.json"

if ! gcloud storage objects describe "$candidate" >/dev/null 2>&1; then
  echo "FATAL: no candidate at $candidate — run terraform apply first (it uploads the candidate), and check the sha against 'terraform output runtime_manifest_sha256'" >&2
  exit 1
fi

gcloud storage cp "$candidate" "$pointer"
echo "promoted $sha → $pointer"
echo "fleet timers converge within ≤8h; force a box now with: scripts/gcp/sync-converge.sh <machine>"
