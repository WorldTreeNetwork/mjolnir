#!/usr/bin/env bash
# Bootstrap a hosted-being guest: bun, git, grok CLI, hypersigil-store-frontend.
# Run inside the VM (or via mj exec). Does not write XAI_API_KEY to disk.
set -euo pipefail

REPO="${HOSTED_BEING_REPO:-forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git}"
WORKDIR="${HOSTED_BEING_WORKDIR:-/root/hypersigil-store-frontend}"
API="${VITE_MEDUSA_BACKEND_URL:-https://api.hypersigil.world}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl unzip tmux ca-certificates openssh-client

if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

if ! command -v grok >/dev/null 2>&1; then
  curl -fsSL https://x.ai/cli/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ ! -d "$WORKDIR/.git" ]]; then
  git clone "$REPO" "$WORKDIR"
fi

cd "$WORKDIR"
if [[ ! -f .env ]]; then
  cat > .env <<EOF
VITE_MEDUSA_BACKEND_URL=${API}
EOF
fi

bun install

# Git SSH signing against the injected tmpfs key (add-vm-git-subkey).
git config --global gpg.format ssh
git config --global user.signingkey /run/mjolnir/git_signing_key
git config --global commit.gpgsign true

# tmux session=main for wrug /term and mj connect --session main
tmux has-session -t main 2>/dev/null || tmux new-session -d -s main

echo "hosted-being bootstrap ok workdir=$WORKDIR grok=$(command -v grok || true)"
