#!/bin/bash
set -euo pipefail

# Build the "@base/buzz-agent" Ubuntu 24.04 BTRFS subvolume rootfs — the body
# image for Buzz remote agents deployed by buzz-backend-mjolnir (mjolnir-cxz,
# epic mjolnir-e70).
#
# Structure deliberately mirrors scripts/build-ci-image.sh and
# scripts/build-deploy-base.sh: debootstrap --variant=minbase, a BTRFS subvolume
# used directly as the rootfs (no loop-mount), the same virtiofs root fstab
# entry, the same mount-extra-fs.sh / mount-workspace.service plumbing, and the
# same mjolnir-network-setup hook for the guest agent. Do not reinvent that
# plumbing here — copy/adjust it the way this script does if it changes.
#
# Usage: sudo ./scripts/build-buzz-agent-image.sh [output-path]
# Example: sudo ./scripts/build-buzz-agent-image.sh /var/lib/mjolnir/btrfs/@base/buzz-agent
#
# The script is idempotent: if the subvolume already exists it is deleted and
# recreated from scratch.
#
# Prerequisites (on the server):
#   apt-get install -y debootstrap btrfs-progs skopeo jq
#
# ── What is baked in, and why ────────────────────────────────────────────────
#
# The bead's open question was "which agents baked in vs fetched at boot (image
# size vs cold start)". The answer is settled by Block's own reference body
# image, block/buzz@main:Dockerfile.sprig:
#
#   `sprig` is a single multi-call binary that IS buzz-acp, buzz-agent,
#   buzz-dev-mcp, the buzz CLI, rg, tree, git-credential-nostr and
#   git-sign-nostr — eight symlinks onto one file.
#
# So the harness (buzz-acp) and the default ACP agent (buzz-agent) cost zero
# marginal bytes over each other, and both are baked unconditionally. The
# reference image ships nothing else — no goose, no node, no npm ACP agents.
#
# We diverge from the reference on the *other* three runtimes, because unlike
# the SSH/GCE providers we own this image and the (unmerged, tracked upstream as
# block/buzz#3449) `discover_harnesses` op will answer authoritatively out of
# whatever is here. Fetch-at-boot would put a network round trip and a registry
# outage inside every cold start, in a body whose whole selling point is that
# BTRFS makes starts instant. So they are baked too, each behind a flag so the
# size/cadence tradeoff stays tunable per host:
#
#   WITH_NPM_AGENTS=1  (default)  @agentclientprotocol/claude-agent-acp
#                                 @agentclientprotocol/codex-acp  + node@20
#   WITH_GOOSE=1       (default)  block/goose stable CLI
#
# Set either to 0 for a minimal buzz-agent-only body. The resulting harness set
# is recorded in /etc/buzz-agent-image.json for the provider to read back.
#
# ── The I5 contract this image implements ────────────────────────────────────
#
# docs/L3-mjolnir-binding.md (§I5, in the buzz-backend-mjolnir repo):
#
#   "The harness is the guest's signal-receiving process, so harness exit
#    terminates the VM."
#
# The reference image gets this from `exec buzz-acp "$@"` as the container
# ENTRYPOINT. A Mjolnir guest boots systemd, so the equivalent here is:
#
#   buzz-harness.path     watches /run/mjolnir/buzz.env (tmpfs)
#     └─> buzz-harness.service
#           Type=exec                → buzz-acp IS the unit's main process
#           ExecStart=…entrypoint    → which `exec`s buzz-acp, so SIGTERM from
#                                      systemd reaches the harness directly
#           TimeoutStopSec=60        → matches the K8s binding's declared
#                                      terminationGracePeriodSeconds (60), the
#                                      drain budget I3 sizes (mjolnir-a5t)
#           SuccessAction=poweroff   → clean harness exit powers off the VM
#           FailureAction=poweroff   → so does an abnormal one; nothing in the
#                                      guest restarts the harness (the binding
#                                      ships no revive-on-abnormal-death policy
#                                      until the upstream exit-code contract is
#                                      pinned — Known Defect 6)
#
# The exit code is recorded to /var/lib/buzz/harness-exit BEFORE poweroff. That
# file is on the rootfs, not tmpfs, on purpose: the host can read it straight
# out of the stopped VM's BTRFS subvolume and make I5's intentional-vs-accidental
# classification from evidence rather than inference. It holds an exit code and
# a systemd result word — never any part of the agent env.
#
# ── The I2 contract: where the nsec is allowed to be ─────────────────────────
#
# /run/mjolnir/buzz.env is on tmpfs. Mjolnir's guest agent already renders
# injected secrets to /run/mjolnir/secrets.env for exactly this reason (see
# native/mjolnir_guest_agent/src/secrets.rs — "plaintext secrets are never
# persisted and never captured by a BTRFS rootfs snapshot"). BUZZ_PRIVATE_KEY
# therefore never touches the rootfs and never enters a resume snapshot.
#
# Writing /run/mjolnir/buzz.env is the deploy/injection lane's job (mjolnir-1pe),
# NOT this script's. This image only defines the contract and reacts to it:
#
#   /run/mjolnir/buzz.env   0600 root:agent, KEY=value lines, must contain at
#                           minimum BUZZ_PRIVATE_KEY and BUZZ_RELAY_URL.
#                           Its creation is the start trigger.
#   /run/mjolnir/secrets.env  optional, sourced first if present (the generic
#                           Mjolnir secrets volume).
#
# The entrypoint fails closed (exit 78 / EX_CONFIG) if the identity vars are
# absent, which powers the VM off rather than idling a bodiless agent.

OUTPUT="${1:-/var/lib/mjolnir/btrfs/@base/buzz-agent}"

# The directory this script lives in — used to locate the ci-image/ assets.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ASSETS="$SCRIPT_DIR/ci-image"

# shellcheck source=lib/guest-agent.sh
source "$SCRIPT_DIR/lib/guest-agent.sh"
# shellcheck source=lib/mise.sh
source "$SCRIPT_DIR/lib/mise.sh"
# shellcheck source=lib/terminfo.sh
source "$SCRIPT_DIR/lib/terminfo.sh"

# Pinned sprig image. Tag+digest form: the tag stays human-traceable to its git
# SHA while the digest does the pinning. Keep in sync with DEFAULT_IMAGE in
# block/buzz@main:crates/buzz-backend-kubernetes/src/config.rs — that constant
# is the reference binding's own pin, so tracking it keeps our body and the
# Kubernetes body on the same harness bytes.
SPRIG_IMAGE="${SPRIG_IMAGE:-ghcr.io/block/buzz-sprig:sha-6530b58@sha256:17facfc7608d8ddb33bc056c9aaba1098f4ef6abe5655702fbfd7584d1f74d76}"

# Escape hatch: point at a locally-built sprig binary instead of pulling the
# published image (e.g. `cargo build --profile sprig -p sprig` in a buzz
# checkout). Skips the skopeo dependency entirely.
SPRIG_BIN="${SPRIG_BIN:-}"

# Optional harnesses (see header).
WITH_NPM_AGENTS="${WITH_NPM_AGENTS:-1}"
WITH_GOOSE="${WITH_GOOSE:-1}"

# node is only needed for the npm-distributed ACP agents. Pinned to an exact
# v20 patch (the 20 line matches scripts/build-deploy-base.sh and
# lib/mjolnir/deploy/detector.ex's @runtime); the tarball is checksum-verified
# against nodejs.org's SHASUMS256.txt at build time.
NODE_VERSION="20.20.2"

# The names sprig answers to, from Dockerfile.sprig. Order is irrelevant; the
# list is not — a missing symlink is a harness that silently does not exist.
SPRIG_ALIASES=(buzz-acp buzz-agent buzz-dev-mcp rg tree buzz git-credential-nostr git-sign-nostr)

# uid/gid of the in-guest agent user. Matches RUN_AS_UID/RUN_AS_GID in the
# Kubernetes binding so the two bodies agree on file ownership — which matters
# the moment a workspace is moved between substrates.
AGENT_UID=10001
AGENT_GID=10001
AGENT_HOME=/home/agent

# Harness drain budget. TERMINATION_GRACE_SECONDS in the Kubernetes binding.
# Conformance-relevant (I3): a kill that races the drain burns the relay's full
# 180s presence TTL. Not a tuning knob.
TERMINATION_GRACE_SECONDS=60

echo "=== Building Buzz Agent Rootfs (BTRFS subvolume) ==="
echo "Output:      $OUTPUT"
echo "Assets dir:  $CI_ASSETS"
if [[ -n "$SPRIG_BIN" ]]; then
    echo "sprig:       $SPRIG_BIN (local binary)"
else
    echo "sprig:       $SPRIG_IMAGE"
fi
echo "npm agents:  $WITH_NPM_AGENTS   goose: $WITH_GOOSE"
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (need debootstrap, btrfs, chroot)"
    exit 1
fi

if ! command -v debootstrap &>/dev/null; then
    echo "Error: debootstrap not found."
    echo "  apt-get install -y debootstrap"
    exit 1
fi

if ! command -v btrfs &>/dev/null; then
    echo "Error: btrfs-progs not found."
    echo "  apt-get install -y btrfs-progs"
    exit 1
fi

if [[ -n "$SPRIG_BIN" ]]; then
    if [[ ! -x "$SPRIG_BIN" ]]; then
        echo "Error: SPRIG_BIN=$SPRIG_BIN is not an executable file"
        exit 1
    fi
else
    for tool in skopeo jq tar; do
        if ! command -v "$tool" &>/dev/null; then
            echo "Error: $tool not found (needed to extract sprig from $SPRIG_IMAGE)."
            echo "  apt-get install -y skopeo jq"
            echo "Or build sprig yourself and re-run with SPRIG_BIN=/path/to/sprig"
            exit 1
        fi
    done
fi

# ── Extract sprig BEFORE touching the subvolume ──────────────────────────────
#
# Done first so a registry failure costs nothing: no half-built subvolume is
# left behind for the operator to clean up. sprig is built in the published
# image against musl (rust:alpine + openssl-libs-static), so the binary is
# static and runs unmodified on this glibc Ubuntu rootfs.

STAGE="$(mktemp -d)"
stage_cleanup() { rm -rf "$STAGE"; }
trap stage_cleanup EXIT

if [[ -n "$SPRIG_BIN" ]]; then
    cp "$SPRIG_BIN" "$STAGE/sprig"
else
    # skopeo rejects a reference carrying BOTH a tag and a digest, so normalize
    # to repo@digest before pulling. This is the same normalization upstream's
    # own `image::parse` performs ("drops the tag on normalization") — the tag
    # exists to keep the pin human-traceable to its git SHA, the digest is what
    # actually resolves. The sed strips a trailing `:tag` only when it is not a
    # registry port (a port is followed by a `/`).
    sprig_pull_ref="$SPRIG_IMAGE"
    if [[ "$sprig_pull_ref" == *"@"* ]]; then
        sprig_digest="${sprig_pull_ref#*@}"
        sprig_repo="$(printf '%s' "${sprig_pull_ref%%@*}" | sed 's|:[^:/]*$||')"
        sprig_pull_ref="${sprig_repo}@${sprig_digest}"
    fi

    echo "--- Pulling sprig image ($sprig_pull_ref) ---"
    skopeo copy --quiet "docker://$sprig_pull_ref" "dir:$STAGE/img"

    echo "--- Extracting /usr/local/bin/sprig from image layers ---"
    # Layers are ordered base-first in the manifest; unpack in that order so a
    # later layer's copy of a path wins, exactly as the container runtime would.
    mkdir -p "$STAGE/rootfs"
    while read -r digest; do
        blob="$STAGE/img/${digest#sha256:}"
        [[ -f "$blob" ]] || blob="$STAGE/img/${digest/:/-}"
        if [[ ! -f "$blob" ]]; then
            echo "Error: layer blob for $digest not found under $STAGE/img"
            exit 1
        fi
        # Layers may be gzip'd or plain tar; tar -a sniffs the compression.
        tar -xaf "$blob" -C "$STAGE/rootfs" 2>/dev/null || true
    done < <(jq -r '.layers[].digest' "$STAGE/img/manifest.json")

    if [[ ! -f "$STAGE/rootfs/usr/local/bin/sprig" ]]; then
        echo "Error: sprig binary not found in $SPRIG_IMAGE layers."
        echo "  The published image layout may have changed — check Dockerfile.sprig."
        exit 1
    fi
    cp "$STAGE/rootfs/usr/local/bin/sprig" "$STAGE/sprig"
fi

chmod 0755 "$STAGE/sprig"
echo "sprig staged: $(du -h "$STAGE/sprig" | cut -f1)"

# ── Subvolume setup ──────────────────────────────────────────────────────────

mkdir -p "$(dirname "$OUTPUT")"

if [[ -d "$OUTPUT" ]]; then
    echo "Removing existing subvolume: $OUTPUT"
    btrfs subvolume delete "$OUTPUT" 2>/dev/null || rm -rf "$OUTPUT"
fi

echo "Creating BTRFS subvolume: $OUTPUT"
btrfs subvolume create "$OUTPUT"

# The subvolume IS the rootfs directory — no loop-mount needed.
R="$OUTPUT"

cleanup() {
    # Unmount any proc/sys/dev that chroot may have left behind.
    for mnt in proc sys dev/pts dev; do
        mountpoint -q "$R/$mnt" 2>/dev/null && umount -lf "$R/$mnt" || true
    done
    stage_cleanup
}
trap cleanup EXIT

# ── Bootstrap ────────────────────────────────────────────────────────────────

echo ""
echo "--- Bootstrapping Ubuntu 24.04 Noble (minbase) ---"
debootstrap --variant=minbase \
    --include=systemd,systemd-sysv,dbus,procps,iproute2,ca-certificates,gpg \
    noble "$R" http://archive.ubuntu.com/ubuntu

# ── Hostname / hosts / fstab ─────────────────────────────────────────────────

echo "buzz-agent" > "$R/etc/hostname"

cat > "$R/etc/hosts" << 'EOF'
127.0.0.1 localhost buzz-agent
::1       localhost
EOF

# Root fs is a virtio-fs share — tag "myfs" matches Cloud Hypervisor fs_config.
cat > "$R/etc/fstab" << 'EOF'
myfs / virtiofs rw 0 0
EOF

# ── APT repositories ──────────────────────────────────────────────────────────

echo ""
echo "--- Configuring apt sources (universe + updates + security) ---"
cat > "$R/etc/apt/sources.list.d/ubuntu.sources" << 'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq"

# ── Packages ─────────────────────────────────────────────────────────────────
#
# The reference sprig image is alpine + bash/ca-certificates/curl/git and
# nothing else. We add a little more because this body is a *coding* agent's
# desk and its working tree persists across resumes (snapshot-resume, §I5) —
# an agent that has to apt-get a compiler on every turn defeats the point.
#
#   Shell/net   — bash, curl, ca-certificates (relay TLS, tool downloads)
#   VCS         — git (+ the nostr credential/signing helpers sprig provides)
#   Build       — build-essential, pkg-config (native module builds)
#   Runtimes    — python3 + venv (the runtime agents reach for most often;
#                 node arrives via mise below, only when WITH_NPM_AGENTS=1)
#   Utilities   — jq, unzip, xz-utils, file, less, sudo, openssh-client
#
# Deliberately NOT installed: ripgrep and tree — sprig already provides `rg`
# and `tree` as symlinks onto itself, and an apt copy would shadow or be
# shadowed by them depending on PATH order.

echo ""
echo "--- Installing base packages ---"
chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    bash \
    build-essential \
    pkg-config \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    jq \
    unzip \
    xz-utils \
    file \
    less \
    sudo \
    openssh-client \
    iproute2"

# ── agent user ───────────────────────────────────────────────────────────────
#
# The harness runs as an unprivileged user with a fixed uid/gid, and $HOME is
# the workspace — same shape as the Kubernetes binding's WORKSPACE_PATH
# (/home/agent, also HOME and the harness cwd). No sudo: unlike the CI image,
# this body is driven by a model, and passwordless root would put the
# hypervisor boundary in charge of nothing that the guest could not undo.

echo ""
echo "--- Creating agent user (uid=$AGENT_UID) ---"
chroot "$R" groupadd -g "$AGENT_GID" agent
chroot "$R" useradd -m -d "$AGENT_HOME" -s /bin/bash -u "$AGENT_UID" -g "$AGENT_GID" agent

# ── sprig ────────────────────────────────────────────────────────────────────

echo ""
echo "--- Installing sprig (+ ${#SPRIG_ALIASES[@]} multi-call aliases) ---"
install -m 0755 "$STAGE/sprig" "$R/usr/local/bin/sprig"
for name in "${SPRIG_ALIASES[@]}"; do
    ln -sf sprig "$R/usr/local/bin/$name"
done

# Nostr-backed git signing, copied from Dockerfile.sprig. System-wide so it
# applies to every checkout the agent makes; the *credential* helper is
# deliberately NOT system-wide — see the entrypoint, which scopes it to the
# relay URL so it never answers for unrelated remotes.
chroot "$R" git config --system gpg.format x509
chroot "$R" git config --system gpg.x509.program /usr/local/bin/git-sign-nostr
chroot "$R" git config --system commit.gpgSign true
chroot "$R" git config --system tag.gpgSign true

SPRIG_VERSION="$(chroot "$R" /usr/local/bin/sprig --version 2>/dev/null | head -1 || echo unknown)"
echo "sprig version: $SPRIG_VERSION"

# ── node + npm-distributed ACP agents ────────────────────────────────────────
#
# mise-managed, installed for root, with shims symlinked into /usr/local/bin —
# same reasoning as scripts/build-deploy-base.sh: the harness spawns its ACP
# agent as a bare command with no guarantee that shell activation has run, so
# /usr/local/bin (unconditionally on PATH for every shell flavor) is the only
# reliable place. HOME is passed explicitly on every invocation for the same
# reason it is there — the bun/mise installers hard-require it under `set -u`.

NPM_AGENTS_INSTALLED="[]"
if [[ "$WITH_NPM_AGENTS" == "1" ]]; then
    echo ""
    echo "--- Installing node v${NODE_VERSION} into /usr/local ---"
    # The official tarball is unpacked directly over /usr/local, rather than
    # managed by mise the way scripts/build-deploy-base.sh does it. Two reasons,
    # both learned the hard way in a debootstrap chroot:
    #
    #   1. `mise reshim` writes shims that point at `/mise`. mise finds its own
    #      executable through /proc/self/exe, /proc is not mounted in the chroot,
    #      and every shim it emits is therefore a dangling symlink. Silent at
    #      build time; surfaces as "node: command not found" the first time a
    #      live body spawns an ACP agent.
    #   2. node's `bin/npm` is a shell script that resolves npm-cli.js from
    #      `$(dirname "$0")/../lib`, so symlinking it into /usr/local/bin sends
    #      it looking in /usr/local/lib and it dies with MODULE_NOT_FOUND.
    #
    # Unpacking with --strip-components=1 puts bin/ and lib/ in their correct
    # relative positions under one prefix, which makes both problems structurally
    # impossible. It also pins the exact version rather than resolving "20" at
    # build time — same reproducibility argument as the sprig digest pin.
    #
    # An agent body has no use for mise's version switching anyway: it runs one
    # node, and the harness spawns its ACP agent as a bare command with no
    # guarantee shell activation ever ran, so /usr/local/bin is the only PATH
    # entry that can be relied on.
    node_tarball="node-v${NODE_VERSION}-linux-x64.tar.xz"
    chroot "$R" /bin/bash -c "set -e
        cd /tmp
        curl -fsSLO 'https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}'
        curl -fsSL 'https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt' \
            | grep ' ${node_tarball}\$' | sha256sum -c -
        tar -xJf '${node_tarball}' -C /usr/local --strip-components=1 \
            --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md
        rm -f '${node_tarball}'"

    chroot "$R" /bin/bash -c "PATH=/usr/local/bin:\$PATH node --version && npm --version"

    echo ""
    echo "--- Installing ACP agents from npm ---"
    # --prefix /usr/local lands the bins in /usr/local/bin, already on PATH for
    # the unprivileged agent user, next to the node that runs them.
    chroot "$R" /bin/bash -c "HOME=/root PATH=/usr/local/bin:\$PATH npm install -g --prefix /usr/local \
        @agentclientprotocol/claude-agent-acp \
        @agentclientprotocol/codex-acp"
    NPM_AGENTS_INSTALLED='["claude-agent-acp","codex-acp"]'
fi

# ── goose ────────────────────────────────────────────────────────────────────
#
# Block's own ACP agent, and the one buzz-acp's README leads with. CONFIGURE=false
# because the installer's interactive provider setup has nothing to configure at
# image-build time — the provider/model arrive in the deploy payload's launch.env
# (GOOSE_PROVIDER / GOOSE_MODEL), per-body, at start.

GOOSE_INSTALLED=false
if [[ "$WITH_GOOSE" == "1" ]]; then
    echo ""
    echo "--- Installing goose ---"
    if chroot "$R" /bin/bash -c "HOME=/root CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin \
            curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | \
            HOME=/root CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash"; then
        GOOSE_INSTALLED=true
    else
        echo "Warning: goose install failed — continuing without it."
        echo "         The image is still usable; goose just won't appear in"
        echo "         /etc/buzz-agent-image.json and discover_harnesses."
    fi
fi

# ── Workspace ────────────────────────────────────────────────────────────────
#
# $HOME is the workspace, matching the Kubernetes binding. This is the directory
# snapshot-resume preserves: the checkout, the working tree, the half-finished
# refactor. /workspace/{repo,cache} exist for virtio-fs shares the way they do
# in the CI and deploy images.

echo ""
echo "--- Creating workspace directories ---"
mkdir -p "$R/workspace/repo" "$R/workspace/cache"
mkdir -p "$R$AGENT_HOME"
mkdir -p "$R/var/lib/buzz"
chown -R "$AGENT_UID:$AGENT_GID" "$R$AGENT_HOME" "$R/var/lib/buzz" "$R/workspace"

# ── Mjolnir guest agent ───────────────────────────────────────────────────────
#
# BOTH the binary and its unit have to be baked into the base image. Neither is
# supplied at clone time in practice:
#
#   - VM.spawn's inject_guest_agent/1 copies the binary into each clone only if
#     :guest_agent_bin is configured AND the file exists. On this server the
#     prod path (native/target/x86_64-unknown-linux-musl/release/mjolnir-agent)
#     is absent, so the rescue-free `if` falls through and injection is a silent
#     no-op — the clone gets no agent at all.
#   - Nothing ever injects the systemd unit; only build-rootfs-ubuntu-24.04.sh
#     writes it.
#
# Either omission produces the same symptom: the VM boots normally and then
# spawn dies on :boot_timeout waiting for a vsock ping that nobody is listening
# to, surfaced through the API as a bare {"error":"spawn_failed"}.
#
# ⚠️ build-ci-image.sh and build-deploy-base.sh do neither. @base/ci-ubuntu-24.04
# boots today only because the binary and unit were added to it by hand months
# after it was built. Tracked as mjolnir-0e8.
#
# WantedBy=basic.target, not multi-user.target: the agent must be answering
# before the VM counts as started, well below where ordinary services come up.

install_guest_agent "$R"
install_ghostty_terminfo "$R"

# mise goes in every base image: it is how an image grows any toolchain it was
# not built with, without a rebuild. Note this does NOT replace the node install
# above — that one deliberately unpacks the official tarball into /usr/local for
# the reasons documented there, and mise is here for whatever a body needs later.
install_mise "$R"

# ── Harness entrypoint ───────────────────────────────────────────────────────

cat > "$R/usr/local/bin/buzz-harness-entrypoint" << 'ENTRYEOF'
#!/bin/bash
# Buzz ACP harness entrypoint.
#
# Invariant: this script must END in `exec buzz-acp`, so that buzz-acp becomes
# the service's main process and receives systemd's SIGTERM directly. Anything
# that leaves a shell in the middle converts a clean drain into a kill, which
# under I3 burns the relay's full 180s presence TTL. Do not add cleanup after
# the exec — there is no "after".
set -euo pipefail

# I1 fail-closed: no identity, no body. Exiting non-zero here trips the unit's
# FailureAction=poweroff, so a bodiless agent stops rather than idling.
: "${BUZZ_PRIVATE_KEY:?buzz-harness: BUZZ_PRIVATE_KEY not injected — refusing to start}"
: "${BUZZ_RELAY_URL:?buzz-harness: BUZZ_RELAY_URL not injected — refusing to start}"

: "${OPENAI_COMPAT_BASE_URL:=http://10.200.0.1:8020/v1}"
: "${OPENAI_COMPAT_API:=chat}"
: "${OPENAI_COMPAT_MODEL:=qwen3.8-27b}"
: "${BUZZ_AGENT_PROVIDER:=openai}"
if [[ -z "${OPENAI_COMPAT_API_KEY:-}" && -r /etc/buzz-host-llm.key ]]; then
  OPENAI_COMPAT_API_KEY="$(cat /etc/buzz-host-llm.key)"
fi
export OPENAI_COMPAT_BASE_URL OPENAI_COMPAT_API OPENAI_COMPAT_MODEL OPENAI_COMPAT_API_KEY BUZZ_AGENT_PROVIDER

# Scope the nostr git credential helper to the relay's own HTTP origin, rather
# than installing it globally where it would answer for unrelated remotes.
# Mirrors block/buzz@main:scripts/sprig-entrypoint.sh.
relay_http_url="${BUZZ_RELAY_URL/#ws:/http:}"
relay_http_url="${relay_http_url/#wss:/https:}"
relay_http_url="${relay_http_url%/}"
git config --global "credential.${relay_http_url}/git.helper" \
    /usr/local/bin/git-credential-nostr
git config --global "credential.${relay_http_url}/git.useHttpPath" true

exec buzz-acp "$@"
ENTRYEOF
chmod +x "$R/usr/local/bin/buzz-harness-entrypoint"

# ── Harness exit recorder ────────────────────────────────────────────────────

cat > "$R/usr/local/bin/buzz-harness-exit-record" << 'EXITEOF'
#!/bin/bash
# Record how the harness died, for the host's I5 classification.
#
# Runs as ExecStopPost, so systemd has set $EXIT_CODE / $EXIT_STATUS /
# $SERVICE_RESULT. Written to the ROOTFS, not tmpfs, on purpose: the host reads
# it straight out of the stopped VM's BTRFS subvolume, after poweroff, and
# classifies intentional (exit 0) vs accidental from evidence rather than
# inference. Contains no part of the agent environment.
#
# Field naming follows systemd's actual semantics, which are the reverse of what
# the variable names suggest: $EXIT_CODE is the REASON word ("exited", "killed",
# "dumped"), and $EXIT_STATUS is the numeric exit code — or the signal number
# when the reason is "killed". Read exit_status only after checking exit_reason.
#
# I5 classification for the host:
#   exit_reason=exited, exit_status=0   → intentional (!shutdown or inactivity
#                                         reap). Terminal — do not revive.
#   anything else                       → abnormal.
set -u

out=/var/lib/buzz/harness-exit
umask 022

printf 'exit_reason=%s\nexit_status=%s\nservice_result=%s\n' \
    "${EXIT_CODE:-unknown}" \
    "${EXIT_STATUS:-unknown}" \
    "${SERVICE_RESULT:-unknown}" > "$out".tmp 2>/dev/null || exit 0

sync "$out".tmp 2>/dev/null || true
mv -f "$out".tmp "$out" 2>/dev/null || true
exit 0
EXITEOF
chmod +x "$R/usr/local/bin/buzz-harness-exit-record"

# ── Harness systemd units ────────────────────────────────────────────────────

echo ""
echo "--- Installing buzz-harness units ---"

# /run/mjolnir must exist before anything can write the identity env into it.
# The guest agent creates it lazily when it renders secrets.env, but the Buzz
# injection path does not necessarily go through secrets — so without this the
# injector races the agent and gets "Directory nonexistent". Creating it at boot
# makes the directory a property of the image rather than a precondition the
# injection lane has to remember.
#
# 0750 root:agent — the injector (root, over vsock) writes; the harness (running
# as agent) reads a group-readable file; nothing else on the box can list it.
cat > "$R/usr/lib/tmpfiles.d/mjolnir-buzz.conf" << 'EOF'
d /run/mjolnir 0750 root agent -
EOF

# The path unit is the start trigger: the harness starts when — and only when —
# the injection lane has written the identity env to tmpfs. There is no
# WantedBy on the service itself, so a VM booted without an injection (a manual
# `mj spawn` for debugging, say) comes up as an ordinary box with the harness
# idle rather than crash-looping.
cat > "$R/etc/systemd/system/buzz-harness.path" << 'EOF'
[Unit]
Description=Await Buzz agent identity injection (/run/mjolnir/buzz.env)

[Path]
PathExists=/run/mjolnir/buzz.env
Unit=buzz-harness.service

[Install]
WantedBy=multi-user.target
EOF

# Quoted heredoc: an unquoted one ran `systemctl show` from a comment's backticks
# against the *host* systemd and dumped 150 lines of unit keys into the guest file.
cat > "$R/etc/systemd/system/buzz-harness.service" << EOF
[Unit]
Description=Buzz ACP harness (buzz-acp)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/run/mjolnir/buzz.env
SuccessAction=poweroff
FailureAction=poweroff

[Service]
Type=exec
User=agent
Group=agent
WorkingDirectory=$AGENT_HOME
Environment=HOME=$AGENT_HOME
EnvironmentFile=-/run/mjolnir/secrets.env
EnvironmentFile=/run/mjolnir/buzz.env
ExecStart=/usr/local/bin/buzz-harness-entrypoint
ExecStopPost=+/usr/local/bin/buzz-harness-exit-record
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=$TERMINATION_GRACE_SECONDS
Restart=no
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=false
PrivateTmp=false
EOF

# Do not `systemctl enable` inside the chroot — it talks to the host daemon via
# /run. Link the path unit the way systemd would.
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/buzz-harness.path \
    "$R/etc/systemd/system/multi-user.target.wants/buzz-harness.path"

# ── Serial console autologin ─────────────────────────────────────────────────

mkdir -p "$R/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
chroot "$R" systemctl enable serial-getty@ttyS0.service

# ── Disable IPv6 ─────────────────────────────────────────────────────────────

cat > "$R/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# ── mount-extra-fs.sh ─────────────────────────────────────────────────────────
#
# Tries to mount known virtio-fs tags into /workspace at boot.
# Failures are non-fatal — the VM boots even if the host didn't attach shares.

cat > "$R/usr/local/bin/mount-extra-fs.sh" << 'MOUNTEOF'
#!/bin/bash
# Mount virtio-fs workspace shares from the host, if present.
# Called by mount-workspace.service on boot.

set -euo pipefail

mkdir -p /workspace/repo /workspace/cache

# Mount the repo share read-only (source tree injected by the host).
if mount -t virtiofs repo /workspace/repo -o ro 2>/dev/null; then
    echo "mount-extra-fs: mounted virtiofs 'repo' at /workspace/repo (ro)"
fi

# Mount the cache share read-write (persistent cache).
if mount -t virtiofs cache /workspace/cache 2>/dev/null; then
    echo "mount-extra-fs: mounted virtiofs 'cache' at /workspace/cache (rw)"
fi

exit 0
MOUNTEOF
chmod +x "$R/usr/local/bin/mount-extra-fs.sh"

echo ""
echo "--- Installing mount-workspace.service ---"
cp "$CI_ASSETS/mount-workspace.service" "$R/etc/systemd/system/mount-workspace.service"
chroot "$R" systemctl enable mount-workspace.service

# ── Network setup script ──────────────────────────────────────────────────────
#
# Called by the Mjolnir guest agent after the TAP interface is attached.

cat > "$R/usr/local/bin/mjolnir-network-setup" << 'NETEOF'
#!/bin/bash
# Configure the VM network interface. Called by the Mjolnir guest agent.
# Usage: mjolnir-network-setup <ip>
set -e

IP="${1:?Usage: mjolnir-network-setup <ip>}"

/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
/sbin/ip route add default dev eth0 2>/dev/null || true

echo "nameserver 8.8.8.8"   > /etc/resolv.conf
echo "nameserver 1.1.1.1"  >> /etc/resolv.conf

echo "Network configured: $IP"
NETEOF
chmod +x "$R/usr/local/bin/mjolnir-network-setup"

# ── Image manifest ────────────────────────────────────────────────────────────
#
# What this body can run, recorded at build time. buzz-backend-mjolnir answers
# `discover_harnesses` (block/buzz#3449) out of this file — because we own the
# image, it can answer authoritatively instead of probing the way an SSH
# provider must.

echo ""
echo "--- Writing /etc/buzz-agent-image.json ---"
harnesses='["buzz-agent"]'
if [[ "$WITH_NPM_AGENTS" == "1" ]]; then
    harnesses="$(printf '%s' "$harnesses" | sed 's/\]$/,"claude-agent-acp","codex-acp"]/')"
fi
if [[ "$GOOSE_INSTALLED" == "true" ]]; then
    harnesses="$(printf '%s' "$harnesses" | sed 's/\]$/,"goose"]/')"
fi

cat > "$R/etc/buzz-agent-image.json" << EOF
{
  "image": "buzz-agent",
  "schema_version": 1,
  "distro": "ubuntu-24.04",
  "sprig_image": "$SPRIG_IMAGE",
  "sprig_version": "$SPRIG_VERSION",
  "harness": "buzz-acp",
  "harnesses": $harnesses,
  "npm_agents": $NPM_AGENTS_INSTALLED,
  "goose": $GOOSE_INSTALLED,
  "workspace": "$AGENT_HOME",
  "agent_uid": $AGENT_UID,
  "termination_grace_seconds": $TERMINATION_GRACE_SECONDS,
  "identity_env_path": "/run/mjolnir/buzz.env",
  "harness_exit_path": "/var/lib/buzz/harness-exit"
}
EOF

# ── APT cache cleanup ─────────────────────────────────────────────────────────

echo ""
echo "--- Cleaning apt caches ---"
chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get clean"
rm -rf "$R/var/lib/apt/lists/"*
rm -rf "$R/var/cache/apt/"*

# npm's download cache is ~230MB of tarballs for packages already unpacked into
# /usr/local/lib. It is pure build residue: every clone of this base image would
# carry it, and nothing in a live body reads it.
rm -rf "$R/root/.npm"

# ── Done ──────────────────────────────────────────────────────────────────────

trap - EXIT
stage_cleanup

echo ""
echo "=== Buzz Agent Rootfs Built ==="
echo "Subvolume: $OUTPUT"
echo "Size:      $(du -sh "$OUTPUT" | cut -f1)"
echo "Harnesses: $harnesses"
echo ""
echo "To start an agent, the injection lane (mjolnir-1pe) writes the identity"
echo "env to tmpfs inside the guest — that write is the start trigger:"
echo ""
echo "  /run/mjolnir/buzz.env   (0600, KEY=value)"
echo "    BUZZ_PRIVATE_KEY=nsec1..."
echo "    BUZZ_RELAY_URL=wss://relay.example"
echo "    BUZZ_AUTH_TAG=..."
echo "    BUZZ_ACP_AGENT_COMMAND=goose"
echo "    BUZZ_ACP_EXIT_AFTER_INACTIVITY=7200"
echo ""
echo "Verify:"
echo "  btrfs subvolume show $OUTPUT"
echo "  jq . $OUTPUT/etc/buzz-agent-image.json"
