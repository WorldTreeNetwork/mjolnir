#!/usr/bin/env bash
# Pull github.com/identikey/mjolnir into Forgejo on this host so Actions
# see the same main as GitHub. Native Forgejo pull-mirror cannot convert
# an existing repo (docs v15), so this is a fetch + git-push over
# localhost HTTP — receive-pack fires, CI runs.
#
# Secrets (not in git):
#   /etc/mjolnir/github-forgejo-mirror.env   FORGEJO_TOKEN=...
#   /etc/mjolnir/github-mjolnir-mirror       SSH key (GitHub deploy key, read)
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-git@github.com:identikey/mjolnir.git}"
FORGEJO_REPO="${FORGEJO_REPO:-http://127.0.0.1:3000/identikey/mjolnir.git}"
WORKDIR="${WORKDIR:-/var/lib/mjolnir/mirrors/mjolnir.git}"
SSH_KEY="${SSH_KEY:-/etc/mjolnir/github-mjolnir-mirror}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/etc/mjolnir/github-mjolnir-mirror.known_hosts}"

log() { printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*"; }

if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
  log "FORGEJO_TOKEN is empty (EnvironmentFile missing?)"
  exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
  log "GitHub deploy key missing at $SSH_KEY"
  exit 1
fi

export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS} -o StrictHostKeyChecking=yes"
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

install -d -m 700 "$(dirname "$WORKDIR")"

if [[ ! -d "$WORKDIR" ]]; then
  log "clone --mirror $GITHUB_REPO"
  git clone --mirror "$GITHUB_REPO" "$WORKDIR"
else
  log "fetch --prune"
  git --git-dir="$WORKDIR" fetch --prune origin
fi

# Push via token so Forgejo's receive-pack runs (disk fetch would skip Actions).
# Token stays in env; git reads it from the URL we build here.
remote="http://oauth2:${FORGEJO_TOKEN}@127.0.0.1:3000/identikey/mjolnir.git"
# Allow override of host/path without leaking a caller-supplied token URL.
if [[ "$FORGEJO_REPO" != "http://127.0.0.1:3000/identikey/mjolnir.git" ]]; then
  remote="$FORGEJO_REPO"
fi

before=$(git ls-remote --heads "$remote" refs/heads/main | awk '{print $1}')
after=$(git --git-dir="$WORKDIR" rev-parse refs/heads/main)
if [[ -n "$before" && "$before" == "$after" ]]; then
  log "already in sync main=$after"
  exit 0
fi

# Heads + tags only. `git push --mirror` also sends GitHub `refs/pull/*`,
# which Forgejo rejects as hidden refs and fails the whole push.
log "push heads+tags ${before:-none} -> $after"
git --git-dir="$WORKDIR" push --prune "$remote" \
  '+refs/heads/*:refs/heads/*' \
  '+refs/tags/*:refs/tags/*'
log "done"
