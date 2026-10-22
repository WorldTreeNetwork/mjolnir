#!/usr/bin/env bash
# Deploy a repo's checkout as a named app, stamped with that repo's IdentiKey.
#
# Forced command (the workflow cannot choose the owner or the repo):
#
#   command="/usr/local/bin/forgejo-deploy-host.sh VirtueInnova/ml-control-plane ml-control-plane 512",no-pty,no-port-forwarding
#
# The client sends only `deploy <git-sha>` (or the bare sha). This script
# confirms Forgejo has an Actions run for that sha, resolves the XID, then
# runs `mjolnir deploy` in the current directory. Check the tree out before
# invoking it. The workflow must not pass --owner or a login.
#
# The IdentiKey comes from the forgejo-owners map, resolved by the API
# when this script sends X-Forgejo-Repo over the operator socket. The
# script does not read a pin file and does not pass --owner.
#
# No map row: the API returns owner_not_linked and nothing is deployed.
# The checkout at MJOLNIR_DEPLOY_DIR (default: .) must already be that sha.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "forgejo-deploy: jq is required" >&2
  exit 1
fi

REPO="${1:?usage: forgejo-deploy-host.sh <owner>/<repo> <app-name> [memory-mb]}"
APP="${2:?usage: forgejo-deploy-host.sh <owner>/<repo> <app-name> [memory-mb]}"
MEMORY="${3:-512}"

FORGEJO="${MJOLNIR_FORGEJO_URL:-http://127.0.0.1:3000}"
SRC="${MJOLNIR_DEPLOY_DIR:-.}"
SOCK="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"

if [[ ! "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}/[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]]; then
  echo "forgejo-deploy: repo must be owner/name, got: $REPO" >&2
  exit 1
fi

raw="${SSH_ORIGINAL_COMMAND:-}"
# `deploy <sha>` or a bare sha. Anything else is a client trying to pass flags.
sha="$(printf '%s' "$raw" | awk '{print $NF}' | tr 'A-F' 'a-f')"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ && ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "forgejo-deploy: expected a git sha, got: ${raw:-<empty>}" >&2
  exit 1
fi

if [[ -z "${MJOLNIR_FORGEJO_TOKEN:-}" ]]; then
  echo "forgejo-deploy: MJOLNIR_FORGEJO_TOKEN is not set" >&2
  exit 1
fi

runs="$(curl -fsS \
  -H "Authorization: token ${MJOLNIR_FORGEJO_TOKEN}" \
  "${FORGEJO}/api/v1/repos/${REPO}/actions/runs?head_sha=${sha}")"

count="$(printf '%s' "$runs" | jq -r '.total_count // 0')"
actor="$(printf '%s' "$runs" | jq -r '.workflow_runs[0].trigger_user.login // .workflow_runs[0].triggering_actor.login // empty')"
ok="$(printf '%s' "$runs" | jq '[.workflow_runs[] | select(.status == "success")] | length')"

if [[ "$count" == "0" || "$count" == "null" || "$ok" == "0" ]]; then
  echo "forgejo-deploy: no successful Actions run for ${REPO} @ ${sha}" >&2
  exit 1
fi

echo "forgejo-deploy: ${REPO} @ ${sha} triggered by ${actor:-unknown}" >&2

head_now="$(git -C "$SRC" rev-parse HEAD 2>/dev/null | tr 'A-F' 'a-f' || true)"
if [[ "$head_now" != "$sha" ]]; then
  echo "forgejo-deploy: ${SRC} is ${head_now:-not a git checkout}, not ${sha}" >&2
  exit 1
fi

if [[ ! -S "$SOCK" ]]; then
  echo "forgejo-deploy: operator socket ${SOCK} is missing" >&2
  exit 1
fi

export MJOLNIR_OPERATOR_SOCKET="$SOCK"
exec mjolnir deploy "$SRC" \
  --name "$APP" \
  --memory "$MEMORY" \
  --forgejo-repo "$REPO"
