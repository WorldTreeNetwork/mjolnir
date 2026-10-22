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

# Guest git authenticates as the injected ssh_git key. Never a Forgejo token.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [[ ! -f "$KNOWN_HOSTS" ]] || ! grep -q 'mimir.worldtree.network' "$KNOWN_HOSTS"; then
  cat >>"$KNOWN_HOSTS" <<'EOF'
mimir.worldtree.network ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcBP5GKyif0Q1ML3cOjqWFhD5G21ldBKdlAtF8l7I3r
mimir.worldtree.network ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLXq+Qg5Xk/s07onLGqaJ5QmShpa8U8uMicbOfT4QE1aBmRiyWtjzohJFThFcqX/+pFffjld+VYJ7C24jkWquLM=
mimir.worldtree.network ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCv2WrXL/9UDpzjyiC81S+T/0UHcCBMHICXnNIu6bzMlgsf4FGURdg8nCg9NANExQCLbzE9vG8U/LIsWcomPUJXJw4m7w/ccNnPi6RcRf6+KnA9qDFLZQPkAWeTJ79YM/DjROcbXqb/8jBJ4nyeWhJ/GB8Qo/fjhif581h2Tw30+qkc60ICWrPC73phoyCC4MTiLUX7NaWOFGm4H/JTA0Iu4N3dOrnV9k2G0aJTOxeVzCy/Finm655Dc+ZD/5RcFLp9smhW/6rAsrEvxmJH3wFp2RkI6wNoLmK0Gnee/qZ3xfjthVYwjqK9NXhGvTLoYHvlMu6NK5Jo1JHICAXSHWaH1HJRWgdNQnZVnsPY5tMdh/rX6mEvWxKLKiSikqbL8vLbOlLyDxqgt4Ks82ze6e4sfHXaJY6+MF5Z9WOk73pxDqifCi+BEPBg18yF1772l/pzUZ1hpBBj6BSh7/oMOr8MU6/XzhM5cu7zX5RE1HqwApv2fHWtvJEt1i2t0+ul238=
EOF
fi
chmod 644 "$KNOWN_HOSTS"

SSH_CONFIG="$HOME/.ssh/config"
if [[ ! -f "$SSH_CONFIG" ]] || ! grep -q 'Host mimir.worldtree.network' "$SSH_CONFIG"; then
  cat >>"$SSH_CONFIG" <<'EOF'
Host mimir.worldtree.network
  User git
  IdentityFile /run/mjolnir/git_signing_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
EOF
fi
chmod 600 "$SSH_CONFIG"

# Forgejo advertises ssh://git@mimir... (passwd user `git`). The spec URL uses
# forgejogit@ — rewrite so clone/push still work.
git config --global url."git@mimir.worldtree.network:".insteadOf "forgejogit@mimir.worldtree.network:"
git config --global url."ssh://git@mimir.worldtree.network/".insteadOf "ssh://forgejogit@mimir.worldtree.network/"

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
  if [[ ! -r /run/mjolnir/git_signing_key ]]; then
    echo "hosted-being bootstrap: git clone needs /run/mjolnir/git_signing_key" >&2
    exit 1
  fi
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

# Git SSH signing + push against the injected tmpfs key (same key).
git config --global gpg.format ssh
git config --global user.signingkey /run/mjolnir/git_signing_key
git config --global commit.gpgsign true
git config --global core.sshCommand "ssh -i /run/mjolnir/git_signing_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts"

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
