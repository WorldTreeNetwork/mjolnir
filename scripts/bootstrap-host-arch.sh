#!/bin/bash
set -euo pipefail

# Mjolnir Host Bootstrap Script — Arch Linux
# Complete setup for a fresh Arch Linux machine (bare metal or dev workstation).
#
# Key differences from the Ubuntu script:
#   - pacman for packages (not apt)
#   - nftables for NAT (not iptables)
#   - No BTRFS device/loopback setup — assumes the host filesystem IS BTRFS
#   - musl from the `musl` package (loader at /usr/lib/musl/lib/libc.so)
#   - virtiofsd from packages (not compiled)
#   - No Firecracker installation (deprecated)
#
# Usage:
#   sudo ./scripts/bootstrap-host-arch.sh
#
# Environment variables:
#   DEV_MODE             - Set to 1 for development setup (skip /opt deploy, use workspace)
#   MJOLNIR_REPO         - Git repo URL (default: current directory)
#   MJOLNIR_BRANCH       - Git branch (default: main)
#   SKIP_BTRFS           - Set to 1 to skip subvolume setup (use existing)
#   SKIP_ROOTFS          - Set to 1 to skip rootfs build
#   SKIP_KERNEL          - Set to 1 to skip kernel build (use existing vmlinux-ch)

# =============================================================================
# Configuration
# =============================================================================

MJOLNIR_ROOT="/var/lib/mjolnir"
MJOLNIR_CODE="/opt/mjolnir"
CH_VERSION="50.0"
MIN_ELIXIR_VERSION="1.15"
# On Arch, `pacman -S postgresql` symlinks postgres/initdb straight into /usr/bin,
# which already matches the release's compiled-in pg_bin_dir default (see
# config/config.exs) — so unlike Ubuntu there's nothing to discover/override here.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Utility Functions
# =============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo ""; echo -e "${GREEN}=== $1 ===${NC}"; echo ""; }

# =============================================================================
# System Suitability Checks
# =============================================================================

check_system_suitability() {
    log_section "System Suitability Check"

    local errors=0

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_success "Running as root"

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "Unsupported architecture: $arch (requires x86_64)"
        errors=$((errors + 1))
    else
        log_success "Architecture: $arch"
    fi

    # Verify Arch Linux
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        log_success "OS: $PRETTY_NAME"
        if [[ "$ID" != "arch" ]]; then
            log_warn "This script is for Arch Linux. Your OS is $ID — use bootstrap-host-ubuntu.sh for Debian/Ubuntu."
        fi
    fi

    # CPU virtualization
    local virt_ext=""
    if grep -q "vmx" /proc/cpuinfo 2>/dev/null; then
        virt_ext="Intel VT-x (vmx)"
    elif grep -q "svm" /proc/cpuinfo 2>/dev/null; then
        virt_ext="AMD-V (svm)"
    fi

    if [[ -n "$virt_ext" ]]; then
        log_success "CPU virtualization: $virt_ext"
    else
        log_error "No CPU virtualization extensions found (vmx/svm) — enable in BIOS"
        errors=$((errors + 1))
    fi

    # /dev/kvm
    if [[ -e /dev/kvm ]]; then
        log_success "/dev/kvm exists"
    else
        log_info "Attempting to load KVM module..."
        if modprobe kvm 2>/dev/null && (modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null); then
            if [[ -e /dev/kvm ]]; then
                log_success "KVM module loaded"
            else
                log_error "KVM module loaded but /dev/kvm missing"
                errors=$((errors + 1))
            fi
        else
            log_error "Failed to load KVM — check BIOS virtualization settings"
            errors=$((errors + 1))
        fi
    fi

    # BTRFS host filesystem check (`btrfs filesystem show PATH` is not reliable)
    if findmnt -n -o FSTYPE / | grep -qx btrfs || findmnt -t btrfs &>/dev/null; then
        log_success "BTRFS filesystem present"
    else
        log_warn "No BTRFS filesystem detected. This script assumes the host is on BTRFS."
        log_warn "If /var/lib/mjolnir is not on BTRFS, subvolume operations will fail."
    fi

    local mem_gb
    mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    if [[ "$mem_gb" -ge 4 ]]; then
        log_success "Memory: ${mem_gb}GB"
    else
        log_warn "Memory: ${mem_gb}GB (recommend 4GB+)"
    fi

    echo ""
    if [[ $errors -gt 0 ]]; then
        log_error "System suitability check FAILED with $errors error(s)"
        exit 1
    else
        log_success "System suitability check PASSED"
    fi
}

# =============================================================================
# Package Installation
# =============================================================================

install_base_packages() {
    log_section "Installing Base Packages"

    # Sync package databases
    pacman -Sy --noconfirm

    # Core tools
    pacman -S --noconfirm --needed \
        base-devel \
        curl \
        wget \
        git \
        btrfs-progs \
        jq \
        debootstrap \
        musl \
        socat \
        screen \
        nftables \
        iproute2 \
        openssh \
        openssl

    # virtiofsd (needed for virtio-fs VM rootfs sharing)
    if pacman -S --noconfirm --needed virtiofsd 2>/dev/null; then
        log_success "virtiofsd installed"
    else
        log_warn "virtiofsd not found in repos — check AUR or install manually"
    fi

    # virtiofsd ships at /usr/lib/virtiofsd on Arch; the mjolnir code expects
    # /usr/libexec/virtiofsd (FHS-compliant location). Symlink bridges that.
    if [[ -f /usr/lib/virtiofsd && ! -e /usr/libexec/virtiofsd ]]; then
        mkdir -p /usr/libexec
        ln -s /usr/lib/virtiofsd /usr/libexec/virtiofsd
        log_info "Linked /usr/lib/virtiofsd → /usr/libexec/virtiofsd"
    fi

    # File capabilities let virtiofsd override DAC checks, chown, etc. without
    # running as root — required for guest writes to rootfs files owned by root.
    if command -v virtiofsd &>/dev/null || [[ -f /usr/lib/virtiofsd ]]; then
        local vfsd_path
        vfsd_path=$(readlink -f "$(command -v virtiofsd 2>/dev/null || echo /usr/lib/virtiofsd)")
        setcap 'cap_dac_override,cap_chown,cap_fowner,cap_fsetid,cap_setfcap,cap_setgid,cap_setuid,cap_mknod,cap_sys_admin+eip' "$vfsd_path"
        log_info "Applied file capabilities to $vfsd_path"
    fi

    log_success "Base packages installed"
}

install_erlang_elixir() {
    log_section "Installing Erlang/Elixir"

    if command -v elixir &>/dev/null; then
        local current_elixir
        current_elixir=$(elixir --version 2>/dev/null | grep -oP 'Elixir \K[0-9]+\.[0-9]+' || echo "0")
        if [[ "$current_elixir" == "$MIN_ELIXIR_VERSION"* ]] || [[ "$current_elixir" > "$MIN_ELIXIR_VERSION" ]]; then
            log_success "Elixir $current_elixir already installed"
            mix local.hex --force --if-missing
            mix local.rebar --force --if-missing
            return 0
        fi
    fi

    log_info "Installing mise for Erlang/Elixir version management..."

    # Erlang build deps on Arch
    pacman -S --noconfirm --needed \
        autoconf \
        ncurses \
        openssl \
        libpng \
        libssh \
        unixodbc \
        xsltproc \
        fop \
        libxml2 2>/dev/null || true

    if ! command -v mise &>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if ! command -v mise &>/dev/null; then
        log_info "Downloading mise..."
        curl -fsSL https://mise.run | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi

    eval "$(mise activate bash --shims)"

    if ! grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        echo "eval \"\$($HOME/.local/bin/mise activate bash)\"" >> "$HOME/.bashrc"
    fi

    local erlang_version="26.2.5"
    local elixir_version="1.16.2-otp-26"

    log_info "Installing Erlang $erlang_version..."
    mise use -g erlang@"$erlang_version"

    log_info "Installing Elixir $elixir_version..."
    mise use -g elixir@"$elixir_version"

    log_info "Elixir version: $(elixir --version | head -1)"

    log_info "Installing Hex and Rebar..."
    mix local.hex --force
    mix local.rebar --force

    log_success "Erlang/Elixir installed via mise"
}

install_rust() {
    log_section "Installing Rust"

    if ! command -v mise &>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    eval "$(mise activate bash --shims 2>/dev/null)" || true

    log_info "Installing Rust stable via mise..."
    mise use -g rust@stable

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    # musl target for static PIE guest agent binary
    if ! rustup target list --installed 2>/dev/null | grep -q "x86_64-unknown-linux-musl"; then
        log_info "Adding musl target..."
        rustup target add x86_64-unknown-linux-musl
    else
        log_success "musl target already installed"
    fi

    log_success "Rust ready: $(rustc --version)"
}

install_cloud_hypervisor() {
    log_section "Installing Cloud Hypervisor"

    if command -v cloud-hypervisor &>/dev/null; then
        local current_ch
        current_ch=$(cloud-hypervisor --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' || echo "0")
        if [[ "$current_ch" == "$CH_VERSION" ]]; then
            log_success "Cloud Hypervisor v$current_ch already installed"
            return 0
        else
            log_info "Cloud Hypervisor v$current_ch found, upgrading to v$CH_VERSION"
        fi
    fi

    local arch
    arch=$(uname -m)
    local binary_suffix="cloud-hypervisor-static"
    if [[ "$arch" == "aarch64" ]]; then
        binary_suffix="cloud-hypervisor-static-aarch64"
    fi

    local url="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v${CH_VERSION}/${binary_suffix}"

    log_info "Downloading Cloud Hypervisor v${CH_VERSION}..."
    curl -fsSL "$url" -o /usr/local/bin/cloud-hypervisor
    chmod +x /usr/local/bin/cloud-hypervisor

    log_info "Verifying checksum..."
    if curl -fsSL "${url}.sha256" -o /tmp/ch-sha256 2>/dev/null; then
        echo "$(cat /tmp/ch-sha256)  /usr/local/bin/cloud-hypervisor" | sha256sum -c - || \
            log_error "Checksum verification FAILED for cloud-hypervisor binary"
        rm -f /tmp/ch-sha256
    else
        log_warn "SHA256 checksum not available — skipping verification"
    fi

    log_success "Cloud Hypervisor installed: $(cloud-hypervisor --version 2>/dev/null || echo "v${CH_VERSION}")"
}

install_postgres() {
    log_section "Installing PostgreSQL"

    # Single `postgresql` package on Arch provides both server and client
    # binaries, all symlinked into /usr/bin — already matches the release's
    # compiled-in pg_bin_dir default, no discovery/override needed (see
    # config/config.exs).
    pacman -S --noconfirm --needed postgresql

    if [[ ! -x /usr/bin/postgres ]]; then
        log_error "postgres binary not found at /usr/bin/postgres after install"
        exit 1
    fi
    log_success "PostgreSQL installed: $(/usr/bin/postgres --version 2>/dev/null || echo unknown)"

    # Arch's postgresql package does not auto-start or auto-enable postgresql.service
    # (unlike Debian/Ubuntu's postinst), but stop/disable/mask it anyway: Mjolnir
    # manages its own postgres instance as an Erlang Port against a separate data
    # dir (/var/lib/mjolnir/pg, see lib/mjolnir/postgres/server.ex), and a
    # distro-managed instance started by hand later would be actively harmful.
    # Idempotent — safe to re-run against an already-masked/never-enabled unit.
    log_info "Ensuring distro postgresql.service is disabled (Mjolnir manages its own)..."
    systemctl stop postgresql.service 2>/dev/null || true
    systemctl disable postgresql.service 2>/dev/null || true
    systemctl mask postgresql.service 2>/dev/null || true
}

# =============================================================================
# Code Deployment
# =============================================================================

get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

deploy_mjolnir_code() {
    log_section "Deploying Mjolnir Code"

    local branch="${MJOLNIR_BRANCH:-main}"
    local repo="${MJOLNIR_REPO:-}"
    local repo_root
    repo_root="$(get_repo_root)"

    if [[ -f "$repo_root/mix.exs" ]] && grep -q "mjolnir" "$repo_root/mix.exs" 2>/dev/null; then
        log_info "Running from within Mjolnir repo at $repo_root"
        if [[ "$repo_root" != "$MJOLNIR_CODE" ]]; then
            log_info "Copying to $MJOLNIR_CODE..."
            mkdir -p "$MJOLNIR_CODE"
            rsync -av --exclude='_build' --exclude='deps' --exclude='.git' "$repo_root/" "$MJOLNIR_CODE/"
        fi
    elif [[ -n "$repo" ]]; then
        log_info "Cloning from $repo..."
        git clone --branch "$branch" "$repo" "$MJOLNIR_CODE"
    else
        log_error "No Mjolnir code found and MJOLNIR_REPO not set"
        exit 1
    fi

    cd "$MJOLNIR_CODE"

    if command -v mise &>/dev/null; then
        mise trust "$MJOLNIR_CODE/.mise.toml" >/dev/null 2>&1 || true
        mise trust "$MJOLNIR_CODE" >/dev/null 2>&1 || true
    fi

    log_info "Fetching dependencies..."
    MIX_ENV=prod mix deps.get

    log_info "Compiling Mjolnir..."
    MIX_ENV=prod mix compile

    log_info "Building release..."
    MIX_ENV=prod mix release mjolnir --overwrite

    log_success "Mjolnir release built at $MJOLNIR_CODE/_build/prod/rel/mjolnir/"
}

setup_dev_workspace() {
    log_section "Setting Up Dev Workspace"

    local repo_root
    repo_root="$(get_repo_root)"

    if [[ ! -f "$repo_root/mix.exs" ]] || ! grep -q "mjolnir" "$repo_root/mix.exs" 2>/dev/null; then
        log_error "DEV_MODE requires running from within the Mjolnir repo"
        exit 1
    fi

    MJOLNIR_CODE="$repo_root"
    log_info "Using workspace at $MJOLNIR_CODE"

    cd "$MJOLNIR_CODE"
    mix deps.get

    log_success "Dev workspace ready at $MJOLNIR_CODE"
}

build_guest_agent() {
    log_section "Building Guest Agent"

    cd "$MJOLNIR_CODE"

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    bash scripts/build-guest-agent.sh

    local binary="native/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    if [[ -f "$binary" ]]; then
        log_success "Guest agent built: $(du -h "$binary" | cut -f1)"
        # Verify the binary — on Arch it will be static PIE (needs musl loader in guest rootfs)
        local interp
        interp=$(readelf -l "$binary" 2>/dev/null | grep INTERP | awk '{print $NF}' || echo "")
        if [[ -n "$interp" ]]; then
            log_info "Binary PT_INTERP: $interp (static PIE — musl loader will be copied to rootfs)"
        else
            log_info "Binary has no PT_INTERP (truly static)"
        fi
    else
        log_error "Guest agent build failed"
        exit 1
    fi
}

# =============================================================================
# BTRFS Storage Setup
# =============================================================================

setup_btrfs() {
    log_section "Setting Up BTRFS Storage"

    if [[ "${SKIP_BTRFS:-0}" == "1" ]]; then
        log_info "Skipping BTRFS setup (SKIP_BTRFS=1)"
        return 0
    fi

    # On Arch, the host IS on BTRFS. We just need the directory structure.
    # The build-rootfs.sh script creates @base/ubuntu-24.04 as a btrfs subvolume.
    # @vms/<uuid> subvolumes are created per-VM by Mjolnir at runtime.
    mkdir -p "$MJOLNIR_ROOT/btrfs"

    # Confirm we're actually on BTRFS (creates subvolumes, not just directories)
    local btrfs_fstype
    btrfs_fstype=$(findmnt -n -o FSTYPE "$MJOLNIR_ROOT/btrfs" 2>/dev/null || findmnt -n -o FSTYPE / | head -1)
    if [[ "$btrfs_fstype" != "btrfs" ]]; then
        log_warn "$MJOLNIR_ROOT/btrfs fstype=${btrfs_fstype:-unknown} (want btrfs)"
        log_warn "Subvolume operations will use regular directories (CoW cloning won't work)"
    else
        log_success "Confirmed BTRFS at $MJOLNIR_ROOT/btrfs"
    fi

    # Create parent directories for subvolumes (subvolumes themselves created by build scripts)
    mkdir -p "$MJOLNIR_ROOT/btrfs/@base"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@vms"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@snapshots"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@workspaces"

    # Enable BTRFS quotas (needed for disk usage tracking per VM)
    btrfs quota enable "$MJOLNIR_ROOT/btrfs" 2>/dev/null || \
        log_warn "Failed to enable BTRFS quotas (non-fatal)"

    log_success "BTRFS storage layout ready at $MJOLNIR_ROOT/btrfs"
}

# =============================================================================
# Kernel Build
# =============================================================================

build_ch_kernel() {
    log_section "Building Cloud Hypervisor Kernel"

    if [[ "${SKIP_KERNEL:-0}" == "1" ]]; then
        log_info "Skipping kernel build (SKIP_KERNEL=1)"
        return 0
    fi

    if [[ -f "$MJOLNIR_ROOT/vmlinux-ch" ]]; then
        log_info "Cloud Hypervisor kernel already exists at $MJOLNIR_ROOT/vmlinux-ch"
        return 0
    fi

    # Install kernel build dependencies
    pacman -S --noconfirm --needed \
        flex \
        bison \
        bc \
        libelf \
        perl \
        python \
        cpio \
        pahole 2>/dev/null || true

    cd "$MJOLNIR_CODE"
    bash scripts/build-kernel.sh

    if [[ -f "$MJOLNIR_ROOT/vmlinux-ch" ]]; then
        log_success "Kernel built: $MJOLNIR_ROOT/vmlinux-ch ($(du -h "$MJOLNIR_ROOT/vmlinux-ch" | cut -f1))"
    else
        log_error "Kernel build failed — check scripts/build-kernel.sh output"
        exit 1
    fi
}

build_rootfs() {
    local distro="${ROOTFS_DISTRO:-arch}"
    log_section "Building ${distro} Rootfs"

    if [[ "${SKIP_ROOTFS:-0}" == "1" ]]; then
        log_info "Skipping rootfs build (SKIP_ROOTFS=1)"
        return 0
    fi

    local rootfs_path="$MJOLNIR_ROOT/btrfs/@base/${distro}"
    local agent_bin="$MJOLNIR_CODE/native/target/x86_64-unknown-linux-musl/release/mjolnir-agent"

    if [[ -d "$rootfs_path" ]]; then
        log_info "Rootfs already exists at $rootfs_path"
        return 0
    fi

    local build_script="scripts/build-rootfs-${distro}.sh"
    if [[ ! -f "$MJOLNIR_CODE/$build_script" ]]; then
        log_error "No build script for distro '${distro}': $build_script"
        log_error "Available: $(ls "$MJOLNIR_CODE/scripts/build-rootfs-"*.sh 2>/dev/null | xargs -n1 basename | sed 's/build-rootfs-//;s/\.sh//' | tr '\n' ' ')"
        exit 1
    fi

    export AGENT_BIN="$agent_bin"
    cd "$MJOLNIR_CODE"
    bash "$build_script" "$rootfs_path"

    log_success "Rootfs built: $rootfs_path ($(du -sh "$rootfs_path" | cut -f1))"
}

install_host_ghostty_terminfo() {
    log_section "Installing Ghostty terminfo"
    # shellcheck source=lib/terminfo.sh
    source "$MJOLNIR_CODE/scripts/lib/terminfo.sh"
    install_ghostty_terminfo /
}

# =============================================================================
# Networking
# =============================================================================

setup_networking() {
    log_section "Setting Up VM Networking (nftables)"

    local vm_subnet="10.200.0.0/10"

    # Enable IP forwarding
    log_info "Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.d/99-mjolnir.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-mjolnir.conf
        sysctl -p /etc/sysctl.d/99-mjolnir.conf
    fi

    # Write nftables rules for VM NAT
    # We create a separate table so we don't collide with existing nftables config.
    local nft_file="/etc/nftables.d/mjolnir.nft"
    mkdir -p /etc/nftables.d

    log_info "Writing nftables NAT rules to $nft_file..."
    cat > "$nft_file" << 'EOF'
table ip mjolnir {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.200.0.0/10 masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr 10.200.0.0/10 accept
        ip daddr 10.200.0.0/10 accept
    }
}
EOF

    # Include our rules from the main nftables config
    local main_conf="/etc/nftables.conf"
    local include_line='include "/etc/nftables.d/*.nft"'

    if [[ -f "$main_conf" ]]; then
        if ! grep -q 'nftables.d' "$main_conf"; then
            log_info "Adding include to $main_conf..."
            echo "" >> "$main_conf"
            echo "$include_line" >> "$main_conf"
        else
            log_info "Include already present in $main_conf"
        fi
    else
        # Create minimal nftables.conf if it doesn't exist
        cat > "$main_conf" << NFTEOF
#!/usr/bin/nft -f
$include_line
NFTEOF
    fi

    # Load the mjolnir table only. Do not restart nftables.service — that
    # flushes Tailscale's xtables/nft hybrid rules on Arch.
    if nft -f "$nft_file" 2>/dev/null; then
        log_success "nftables rules loaded"
    else
        log_warn "Failed to load nftables NAT immediately (missing nf_nat/dummy.ko is common if the running kernel != /lib/modules)."
        log_warn "Hotel IP fallback: 10.200.0.1/32 on lo. Reboot onto a matching kernel for dummy.ko + masquerade."
    fi

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/mjolnir-hotel-ip.service << 'UNIT'
[Unit]
Description=Mjolnir hotel IP 10.200.0.1
After=network-pre.target
Before=mjolnir.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if modprobe dummy 2>/dev/null; then ip link add dummy-mjolnir type dummy 2>/dev/null || true; ip link set dummy-mjolnir up; ip addr replace 10.200.0.1/32 dev dummy-mjolnir; else ip addr replace 10.200.0.1/32 dev lo; fi'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now mjolnir-hotel-ip.service

    log_success "VM networking configured (subnet: $vm_subnet, nftables)"
}

# =============================================================================
# Directories & Systemd Service
# =============================================================================

setup_directories() {
    log_section "Setting Up Directories"

    mkdir -p /tmp/mjolnir /tmp/mjolnir-test /tmp/mjolnir-dev
    chmod 755 /tmp/mjolnir /tmp/mjolnir-test /tmp/mjolnir-dev
    mkdir -p "$MJOLNIR_ROOT" "$MJOLNIR_ROOT/boot"

    if [[ -d "$MJOLNIR_ROOT/btrfs" ]]; then
        mkdir -p "$MJOLNIR_ROOT/btrfs/@base-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-dev"

        local distro="${ROOTFS_DISTRO:-arch}"
        if [[ -d "$MJOLNIR_ROOT/btrfs/@base/${distro}" ]]; then
            btrfs subvolume snapshot "$MJOLNIR_ROOT/btrfs/@base/${distro}" \
                "$MJOLNIR_ROOT/btrfs/@base-test/${distro}" 2>/dev/null || \
                cp -a --reflink=auto "$MJOLNIR_ROOT/btrfs/@base/${distro}" \
                    "$MJOLNIR_ROOT/btrfs/@base-test/${distro}"
        fi

        rm -rf "$MJOLNIR_ROOT/btrfs-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs-test"
        ln -sf "$MJOLNIR_ROOT/btrfs/@base-test" "$MJOLNIR_ROOT/btrfs-test/@base"
        ln -sf "$MJOLNIR_ROOT/btrfs/@vms-test" "$MJOLNIR_ROOT/btrfs-test/@vms"

        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER:$SUDO_USER" "$MJOLNIR_ROOT/btrfs/@vms-dev" /tmp/mjolnir-dev
        fi
    fi

    log_success "Directories created"
}

setup_postgres_user_and_dirs() {
    log_section "Setting Up PostgreSQL Sidecar User & Directories"

    # `postgres`/`initdb` refuse to run as root, but mjolnir.service runs as root
    # (needed for VM/networking ops), so the OTP-managed postgres sidecar drops
    # privileges via setpriv to this dedicated user (see
    # lib/mjolnir/postgres/server.ex and config/prod.exs's pg_run_as).
    if ! id -u mjolnir_pg &>/dev/null; then
        useradd --system --no-create-home --shell /sbin/nologin \
            --comment "Mjolnir postgres sidecar" mjolnir_pg
        log_info "Created mjolnir_pg system user"
    else
        log_info "mjolnir_pg user already exists"
    fi

    mkdir -p /var/lib/mjolnir/pg
    chown mjolnir_pg:mjolnir_pg /var/lib/mjolnir/pg
    chmod 0700 /var/lib/mjolnir/pg

    mkdir -p /var/run/mjolnir
    chown mjolnir_pg:mjolnir_pg /var/run/mjolnir
    chmod 0750 /var/run/mjolnir

    mkdir -p /var/log/mjolnir/pg
    chown mjolnir_pg:mjolnir_pg /var/log/mjolnir/pg

    log_success "mjolnir_pg user and data/socket/log directories ready"

    # NOTE: /var/run is tmpfs, so /var/run/mjolnir does not survive a reboot. That
    # is fine and needs no tmpfiles.d drop-in: Mjolnir.Postgres.Server.ensure_dirs/1
    # mkdir_p's the data, socket and log dirs on every start and chowns them to
    # pg_run_as, so the socket dir is rebuilt with the right ownership before
    # postgres is spawned. Creating it here just means a correct host before the
    # service has ever run.
}

setup_systemd_service() {
    log_section "Setting Up Systemd Service"

    # Create dedicated service user — runs with CAP_NET_ADMIN+CAP_SYS_ADMIN, not root
    if ! id -u mjolnir &>/dev/null; then
        useradd --system --no-create-home --shell /sbin/nologin \
            --comment "Mjolnir VM daemon" mjolnir
        log_info "Created mjolnir system user"
    else
        log_info "mjolnir user already exists"
    fi

    # Code dir: full ownership (release binary, logs, runtime artifacts)
    chown -R mjolnir:mjolnir "$MJOLNIR_CODE"

    # Data dir: top-level ownership only — do NOT recurse into BTRFS subvolumes
    # (guest rootfs files retain their original uid/gid; CAP_SYS_ADMIN covers
    # privileged ioctls regardless of parent directory ownership)
    chown mjolnir:mjolnir "$MJOLNIR_ROOT"
    for d in btrfs sockets boot; do
        [[ -d "$MJOLNIR_ROOT/$d" ]] && chown mjolnir:mjolnir "$MJOLNIR_ROOT/$d"
    done

    # ProtectSystem=strict requires every ReadWritePaths entry to exist.
    # Ubuntu units list /etc/ufw; Arch does not ship it.
    mkdir -p /etc/ufw

    cp "$MJOLNIR_CODE/systemd/mjolnir.service" /etc/systemd/system/mjolnir.service

    install -m 440 "$MJOLNIR_CODE/systemd/mjolnir.sudoers" /etc/sudoers.d/mjolnir
    visudo -c -f /etc/sudoers.d/mjolnir || { log_error "sudoers syntax check failed"; exit 1; }
    log_info "Sudoers rules installed at /etc/sudoers.d/mjolnir"

    mkdir -p /etc/mjolnir
    if [[ ! -f /etc/mjolnir/env ]]; then
        cp "$MJOLNIR_CODE/systemd/mjolnir.env" /etc/mjolnir/env

        local cookie
        cookie=$(openssl rand -hex 32)
        sed -i "s/mjolnir_prod_changeme/$cookie/" /etc/mjolnir/env
        chmod 600 /etc/mjolnir/env

        log_info "Generated random RELEASE_COOKIE in /etc/mjolnir/env"
    else
        log_info "/etc/mjolnir/env already exists — preserving existing config"
    fi

    systemctl daemon-reload
    systemctl enable mjolnir.service

    log_success "Systemd service installed and enabled"
}

run_verification() {
    log_section "Running Verification"

    cd "$MJOLNIR_CODE"

    log_info "Running unit tests..."
    if mix test 2>&1; then
        log_success "Unit tests passed"
    else
        log_warn "Some unit tests failed (may be expected without full setup)"
    fi
}

print_summary() {
    log_section "Setup Complete!"

    echo ""
    if [[ "${DEV_MODE:-0}" == "1" ]]; then
        echo "Mjolnir DEV environment configured (Arch Linux):"
        echo ""
        echo "  Workspace:      $MJOLNIR_CODE"
        echo "  Data:           $MJOLNIR_ROOT"
        echo "  BTRFS:          $MJOLNIR_ROOT/btrfs (host filesystem)"
        echo "  Kernel (CH):    $MJOLNIR_ROOT/vmlinux-ch"
        echo "  Base image:     $MJOLNIR_ROOT/btrfs/@base/${ROOTFS_DISTRO:-arch}"
        echo "  musl loader:    /usr/lib/musl/lib/libc.so (auto-copied to rootfs)"
        echo ""
        echo "To start developing:"
        echo ""
        echo "  cd $MJOLNIR_CODE"
        echo "  iex -S mix"
    else
        echo "Mjolnir has been installed and configured (Arch Linux):"
        echo ""
        echo "  Code:           $MJOLNIR_CODE"
        echo "  Release:        $MJOLNIR_CODE/_build/prod/rel/mjolnir/"
        echo "  Data:           $MJOLNIR_ROOT"
        echo "  BTRFS:          $MJOLNIR_ROOT/btrfs (host filesystem)"
        echo "  Kernel (CH):    $MJOLNIR_ROOT/vmlinux-ch"
        echo "  Base image:     $MJOLNIR_ROOT/btrfs/@base/${ROOTFS_DISTRO:-arch}"
        echo "  NAT:            nftables (table 'mjolnir', subnet 10.200.0.0/10)"
        echo "  Service:        mjolnir.service"
        echo "  Config:         /etc/mjolnir/env"
        echo ""
        echo "Service management:"
        echo ""
        echo "  systemctl start mjolnir"
        echo "  systemctl status mjolnir"
        echo "  journalctl -u mjolnir -f"
        echo ""
        echo "Remote IEx shell:"
        echo ""
        echo "  $MJOLNIR_CODE/_build/prod/rel/mjolnir/bin/mjolnir remote"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "========================================"
    if [[ "${DEV_MODE:-0}" == "1" ]]; then
        echo "   Mjolnir Dev Bootstrap — Arch Linux"
    else
        echo "  Mjolnir Host Bootstrap — Arch Linux"
    fi
    echo "========================================"
    echo ""

    check_system_suitability
    install_base_packages
    install_postgres
    install_erlang_elixir
    install_rust
    install_cloud_hypervisor

    if [[ "${DEV_MODE:-0}" == "1" ]]; then
        setup_dev_workspace
    else
        deploy_mjolnir_code
    fi

    build_guest_agent
    setup_btrfs
    build_ch_kernel
    build_rootfs
    install_host_ghostty_terminfo
    setup_directories
    setup_networking

    if [[ "${DEV_MODE:-0}" != "1" ]]; then
        setup_postgres_user_and_dirs
        run_verification
        setup_systemd_service
    fi

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
