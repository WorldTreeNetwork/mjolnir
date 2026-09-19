#!/usr/bin/env bash
# Bootstrap a hosted-being guest: bun, git, grok CLI, hypersigil-store-frontend.
# Run inside the VM (or via mj exec). Does not write XAI_API_KEY to disk.
set -euo pipefail

# mj exec does not set HOME; bun/git/tmux all need it.
export HOME="${HOME:-/root}"
export USER="${USER:-root}"

REPO="${HOSTED_BEING_REPO:-forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git}"
WORKDIR="${HOSTED_BEING_WORKDIR:-/root/hypersigil-store-frontend}"
API="${VITE_MEDUSA_BACKEND_URL:-https://api.hypersigil.world}"
# Gateway default guest port is 80 (`mj url` → https://<ticket>.vm.worldtree.network).
VITE_PORT="${HOSTED_BEING_VITE_PORT:-80}"
# Vite 6+ blocks unknown Host headers (403). Ticket URL is <z32>.vm.worldtree.network.
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="${HOSTED_BEING_ALLOWED_HOSTS:-.vm.worldtree.network}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl unzip tmux ca-certificates openssh-client

# PATH first so a snapshotted ~/.bun/bin/bun is found (mj exec has a tiny PATH).
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"

if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
fi

if ! command -v grok >/dev/null 2>&1; then
  curl -fsSL https://x.ai/cli/install.sh | bash
  export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
fi

# Login shells (tmux main, mj connect --session main) need bun on PATH.
if [[ -f "$HOME/.bashrc" ]] && ! grep -q '\.bun/bin' "$HOME/.bashrc"; then
  printf '\nexport PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"\n' >>"$HOME/.bashrc"
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

# Never persist the grok key. It belongs in /run/mjolnir/ tmpfs only.
if grep -q '^XAI_API_KEY=' .env 2>/dev/null; then
  echo "hosted-being bootstrap: refusing .env that contains XAI_API_KEY" >&2
  exit 1
fi

bun install

# Git SSH signing against the injected tmpfs key (add-vm-git-subkey).
git config --global gpg.format ssh
git config --global user.signingkey /run/mjolnir/git_signing_key
git config --global commit.gpgsign true

# tmux session=main for wrug /term and mj connect --session main.
# Vite in a named window so the process survives mj exec and the shell pane stays usable.
if ! tmux has-session -t main 2>/dev/null; then
  tmux new-session -d -s main -n shell
fi

vite_running() {
  pgrep -f 'bun run dev --host' >/dev/null 2>&1
}

start_vite() {
  # env + PATH must be in the tmux pane; mj exec's environment does not persist.
  tmux send-keys -t main:vite C-c
  tmux send-keys -t main:vite \
    "export PATH=\"$HOME/.bun/bin:\$HOME/.local/bin:\$PATH\"; export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=\"${__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS}\"; cd \"$WORKDIR\" && bun run dev --host --port ${VITE_PORT}" C-m
}

if tmux list-windows -t main -F '#{window_name}' | grep -qx vite; then
  if ! vite_running; then
    start_vite
  fi
else
  tmux new-window -t main -n vite -c "$WORKDIR" \
    "export PATH=\"$HOME/.bun/bin:\$HOME/.local/bin:\$PATH\"; export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=\"${__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS}\"; exec bun run dev --host --port ${VITE_PORT}"
fi
tmux select-window -t main:shell

# Keep a copy on the rootfs so respawn from hosted-<xid> does not depend on /tmp.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  cp -f "${BASH_SOURCE[0]}" /root/hosted-being-bootstrap.sh
  chmod 0755 /root/hosted-being-bootstrap.sh
fi

echo "hosted-being bootstrap ok workdir=$WORKDIR grok=$(command -v grok || true) vite=tmux:main:vite port=${VITE_PORT}"
