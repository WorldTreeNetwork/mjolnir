#!/bin/bash
set -euo pipefail

# Mjolnir Host Bootstrap Script
# Complete setup for a fresh bare-metal Debian/Ubuntu server
#
# This script:
# 1. Checks system suitability (KVM, architecture, etc.)
# 2. Installs all dependencies (Erlang, Elixir, Rust, Cloud Hypervisor)
# 3. Clones and compiles Mjolnir
# 4. Sets up BTRFS storage
# 5. Builds guest agent and rootfs
# 6. Runs verification tests
#
# Usage:
#   curl -sSL <url>/bootstrap-host-ubuntu.sh | sudo bash
#   # or
#   sudo ./bootstrap-host-ubuntu.sh
#
# Environment variables:
#   DEV_MODE             - Set to 1 for development setup (skip /opt deploy, setup dev dirs)
#   BTRFS_DEVICE         - Block device for BTRFS (will prompt if not set). Recommended for prod.
#   USE_LOOPBACK         - Set to 1 to opt-in to a loopback file instead of a dedicated device.
#                          NOTE: The script no longer silently falls back to an existing btrfs.img;
#                          loopback must be explicitly requested. A pre-existing image is treated
#                          as a stale artifact and warned about.
#   BTRFS_LOOPBACK_SIZE_GB - Size of loopback file in GB (default: 50)
#   MJOLNIR_REPO         - Git repo URL (default: current directory or GitHub)
#   MJOLNIR_BRANCH       - Git branch (default: main)
#   SKIP_BTRFS           - Set to 1 to skip BTRFS setup (use existing)
#   SKIP_ROOTFS          - Set to 1 to skip rootfs build

# =============================================================================
# Configuration
# =============================================================================

MJOLNIR_ROOT="/var/lib/mjolnir"
MJOLNIR_CODE="/opt/mjolnir"
CH_VERSION="50.0"
# Minimum versions (used for validation)
MIN_ELIXIR_VERSION="1.15"
# Populated by install_postgres() with the discovered server bin dir
# (e.g. /usr/lib/postgresql/16/bin); written into /etc/mjolnir/env by
# setup_systemd_service().
PG_BIN_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${GREEN}=== $1 ===${NC}"
    echo ""
}

# =============================================================================
# System Suitability Checks
# =============================================================================

check_system_suitability() {
    log_section "System Suitability Check"

    local errors=0

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_success "Running as root"

    # Check architecture
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "Unsupported architecture: $arch"
        log_error "Firecracker requires x86_64 (or aarch64 with different setup)"
        errors=$((errors + 1))
    else
        log_success "Architecture: $arch"
    fi

    # Check if running in a VM (we need bare metal or nested virt)
    local is_vm=0
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        local product
        product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        if echo "$product" | grep -qiE "(virtual|vmware|kvm|qemu|xen|hyperv|parallels)"; then
            is_vm=1
            log_warn "Running inside a VM: $product"
        fi
    fi
    if grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        is_vm=1
        log_warn "Hypervisor flag detected in CPU - this is a VM"
    fi

    # Check CPU virtualization extensions
    local virt_ext=""
    if grep -q "vmx" /proc/cpuinfo 2>/dev/null; then
        virt_ext="Intel VT-x (vmx)"
    elif grep -q "svm" /proc/cpuinfo 2>/dev/null; then
        virt_ext="AMD-V (svm)"
    fi

    if [[ -n "$virt_ext" ]]; then
        log_success "CPU virtualization: $virt_ext"
    else
        log_error "No CPU virtualization extensions found (vmx/svm)"
        log_error "Enable Intel VT-x or AMD-V in BIOS"
        errors=$((errors + 1))
    fi

    # Check for /dev/kvm
    if [[ -e /dev/kvm ]]; then
        log_success "/dev/kvm exists"

        # Check if accessible
        if [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            log_success "/dev/kvm is readable/writable"
        else
            log_warn "/dev/kvm exists but may not be accessible"
        fi
    else
        log_error "/dev/kvm not found"

        # Try to load KVM module
        log_info "Attempting to load KVM module..."
        if modprobe kvm 2>/dev/null; then
            if modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null; then
                if [[ -e /dev/kvm ]]; then
                    log_success "KVM module loaded successfully"
                else
                    log_error "KVM module loaded but /dev/kvm still missing"
                    errors=$((errors + 1))
                fi
            else
                log_error "Failed to load kvm_intel or kvm_amd module"
                if [[ $is_vm -eq 1 ]]; then
                    log_error "This VM does not have nested virtualization enabled"
                    log_error "You need bare metal or a VM with nested virt support"
                fi
                errors=$((errors + 1))
            fi
        else
            log_error "Failed to load KVM module"
            errors=$((errors + 1))
        fi
    fi

    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    if [[ "$kernel_major" -ge 5 ]]; then
        log_success "Kernel version: $(uname -r)"
    else
        log_warn "Kernel version $(uname -r) may be too old (recommend 5.10+)"
    fi

    # Check available memory
    local mem_gb
    mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    if [[ "$mem_gb" -ge 4 ]]; then
        log_success "Memory: ${mem_gb}GB"
    else
        log_warn "Memory: ${mem_gb}GB (recommend at least 4GB)"
    fi

    # Check OS
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        log_success "OS: $PRETTY_NAME"

        if [[ "$ID" != "debian" ]] && [[ "$ID" != "ubuntu" ]]; then
            log_warn "This script is tested on Debian/Ubuntu. Your mileage may vary."
        fi
    fi

    # Summary
    echo ""
    if [[ $errors -gt 0 ]]; then
        log_error "System suitability check FAILED with $errors error(s)"
        log_error "Please fix the issues above before continuing"
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

    apt-get update
    apt-get install -y \
        curl \
        wget \
        git \
        build-essential \
        btrfs-progs \
        jq \
        arch-install-scripts \
        debootstrap \
        musl-tools \
        pkg-config \
        libssl-dev \
        socat \
        screen \
        iptables \
        iptables-persistent \
        ncurses-bin

    log_success "Base packages installed"
}

install_erlang_elixir() {
    log_section "Installing Erlang/Elixir"

    # Check if already installed with correct version
    if command -v elixir &>/dev/null; then
        local current_elixir
        current_elixir=$(elixir --version 2>/dev/null | grep -oP 'Elixir \K[0-9]+\.[0-9]+' || echo "0")
        if [[ "$current_elixir" == "$MIN_ELIXIR_VERSION"* ]] || [[ "$current_elixir" > "$MIN_ELIXIR_VERSION" ]]; then
            log_success "Elixir $current_elixir already installed"
            # Ensure hex and rebar are installed
            mix local.hex --force --if-missing
            mix local.rebar --force --if-missing
            return 0
        else
            log_warn "Elixir $current_elixir is too old (need >= $MIN_ELIXIR_VERSION)"
        fi
    fi

    # Use mise for reliable version management (faster than asdf, compatible syntax)
    log_info "Installing mise for Erlang/Elixir version management..."

    # Install Erlang build dependencies
    apt-get update
    apt-get install -y autoconf libncurses5-dev libssl-dev \
        libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop \
        libxml2-utils libncurses-dev openjdk-17-jdk 2>/dev/null || true
    # wxWidgets libs vary by distro version; try both naming conventions
    apt-get install -y libwxgtk3.2-dev libwxgtk-webview3.2-dev 2>/dev/null || \
        apt-get install -y libwxgtk3.0-gtk3-dev 2>/dev/null || true

    # Install mise if not present
    if ! command -v mise &>/dev/null; then
        log_info "Downloading mise..."
        curl https://mise.run | sh

        # Add mise to PATH for this session
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Activate mise for this session (use shims for non-interactive scripts)
    eval "$(mise activate bash --shims)"

    # Add to bashrc for future interactive sessions (use full path since ~/.local/bin may not be in PATH)
    if ! grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        echo "eval \"\$($HOME/.local/bin/mise activate bash)\"" >> "$HOME/.bashrc"
    fi

    local erlang_version="26.2.5"
    local elixir_version="1.16.2-otp-26"

    log_info "Installing Erlang $erlang_version (this takes a while)..."
    mise use -g erlang@"$erlang_version"

    log_info "Installing Elixir $elixir_version..."
    mise use -g elixir@"$elixir_version"

    # Verify installation
    log_info "Erlang version: $(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null || echo 'unknown')"
    log_info "Elixir version: $(elixir --version | head -1)"

    # Install hex and rebar
    log_info "Installing Hex and Rebar..."
    mix local.hex --force
    mix local.rebar --force

    log_success "Erlang/Elixir installed via mise"
}

install_rust() {
    log_section "Installing Rust"

    # Use mise for Rust (consistent with Erlang/Elixir, and matches .mise.toml)
    # Mise uses rustup under the hood, so rustup commands still work after

    # Ensure mise is available (should be from install_erlang_elixir)
    if ! command -v mise &>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    eval "$(mise activate bash --shims 2>/dev/null)" || true

    log_info "Installing Rust stable via mise..."
    mise use -g rust@stable

    # Source cargo env for rustup commands
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    # Ensure musl target is available (required for static guest agent binary)
    if ! rustup target list --installed 2>/dev/null | grep -q "x86_64-unknown-linux-musl"; then
        log_info "Adding musl target for static linking..."
        rustup target add x86_64-unknown-linux-musl
    else
        log_success "musl target already installed"
    fi

    log_success "Rust ready: $(rustc --version)"
}

install_cloud_hypervisor() {
    log_section "Installing Cloud Hypervisor"

    # Check if already installed with correct version
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

    # Cloud Hypervisor provides a static binary (x86_64 and aarch64)
    local binary_suffix="cloud-hypervisor-static"
    if [[ "$arch" == "aarch64" ]]; then
        binary_suffix="cloud-hypervisor-static-aarch64"
    fi
   
    local url="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v${CH_VERSION}/${binary_suffix}"

    log_info "Downloading Cloud Hypervisor v${CH_VERSION}..."
    curl -fsSL "$url" -o /usr/local/bin/cloud-hypervisor
    chmod +x /usr/local/bin/cloud-hypervisor

    # Verify download integrity (warn if checksum unavailable)
    log_info "Verifying checksum..."
    if curl -fsSL "${url}.sha256" -o /tmp/ch-sha256 2>/dev/null; then
        echo "$(cat /tmp/ch-sha256)  /usr/local/bin/cloud-hypervisor" | sha256sum -c - || \
            log_error "Checksum verification FAILED for cloud-hypervisor binary"
        rm -f /tmp/ch-sha256
    else
        log_warn "SHA256 checksum file not available — skipping verification"
    fi

    # Also install virtiofsd if available (needed for virtio-fs shared directories)
    if ! command -v virtiofsd &>/dev/null; then
        log_info "Installing virtiofsd..."
        apt-get install -y virtiofsd 2>/dev/null || \
            log_warn "virtiofsd not available in package manager — virtio-fs will not work until installed manually"
    else
        log_success "virtiofsd already installed"
    fi

    # File capabilities let virtiofsd override DAC checks, chown, etc. without
    # running as root — required for guest writes to rootfs files owned by root.
    local vfsd_path
    vfsd_path=$(command -v virtiofsd 2>/dev/null || find /usr -name virtiofsd -type f 2>/dev/null | head -1)
    if [[ -n "$vfsd_path" ]]; then
        vfsd_path=$(readlink -f "$vfsd_path")
        setcap 'cap_dac_override,cap_chown,cap_fowner,cap_fsetid,cap_setfcap,cap_setgid,cap_setuid,cap_mknod,cap_sys_admin+eip' "$vfsd_path"
        log_info "Applied file capabilities to $vfsd_path"
    fi

    log_success "Cloud Hypervisor installed: $(cloud-hypervisor --version 2>/dev/null || echo "v${CH_VERSION}")"
}

install_postgres() {
    log_section "Installing PostgreSQL (server + client)"

    # `postgresql`/`postgresql-client` are metapackages that always pull the
    # distro's current default major version (16 on Ubuntu 24.04) — deliberately
    # not pinned to a version number so this keeps working on future LTS releases.
    apt-get install -y postgresql postgresql-client

    # Ubuntu does NOT symlink `postgres`/`initdb` into /usr/bin (only client tools
    # like psql/pg_dump are) — server binaries live at /usr/lib/postgresql/<ver>/bin.
    # Discover the installed version rather than hardcoding it, and pick the
    # highest one present in case multiple versions are ever installed side by side.
    local pg_ver pg_bin_dir
    pg_ver=$(find /usr/lib/postgresql -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -rn | head -1)
    if [[ -z "$pg_ver" ]]; then
        log_error "No /usr/lib/postgresql/<version> directory found after installing postgresql package"
        exit 1
    fi
    pg_bin_dir="/usr/lib/postgresql/${pg_ver}/bin"
    if [[ ! -x "$pg_bin_dir/postgres" ]]; then
        log_error "postgres binary not found at $pg_bin_dir/postgres"
        exit 1
    fi
    PG_BIN_DIR="$pg_bin_dir"
    log_success "PostgreSQL $pg_ver installed — server binaries at $PG_BIN_DIR"

    # The Debian/Ubuntu postgresql package's postinst auto-creates a cluster and
    # starts+enables it (postgresql@<ver>-main.service, plus the generic
    # postgresql.service target). Mjolnir does NOT use that cluster — it manages
    # its own postgres instance as an Erlang Port against a separate data dir
    # (/var/lib/mjolnir/pg, see lib/mjolnir/postgres/server.ex). A second,
    # distro-managed instance left running would be pure waste at best and an
    # actively harmful conflicting process at worst, so stop/disable/mask both
    # units. This is idempotent — safe to re-run against an already-masked unit.
    log_info "Disabling distro-managed postgresql cluster (Mjolnir manages its own)..."
    for unit in "postgresql@${pg_ver}-main.service" "postgresql.service"; do
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
        systemctl mask "$unit" 2>/dev/null || true
    done
    log_success "Distro postgresql unit(s) stopped, disabled, and masked"
}

# =============================================================================
# Code Deployment
# =============================================================================

# Get the repo root (works whether running from repo or not)
get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

deploy_mjolnir_code() {
    log_section "Deploying Mjolnir Code"

    local repo="${MJOLNIR_REPO:-}"
    local branch="${MJOLNIR_BRANCH:-main}"
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
        log_error "Either run this script from within the Mjolnir repo or set MJOLNIR_REPO"
        exit 1
    fi

    cd "$MJOLNIR_CODE"

    # Compile Elixir project and build release
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
        log_error "Current directory: $repo_root"
        exit 1
    fi

    # Set MJOLNIR_CODE to the workspace for other functions
    MJOLNIR_CODE="$repo_root"
    log_info "Using workspace at $MJOLNIR_CODE"

    cd "$MJOLNIR_CODE"

    # Fetch deps for dev environment
    log_info "Fetching dependencies..."
    mix deps.get

    log_success "Dev workspace ready at $MJOLNIR_CODE"
}

build_guest_agent() {
    log_section "Building Guest Agent"

    cd "$MJOLNIR_CODE"

    # Ensure cargo is available
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    bash scripts/build-guest-agent.sh

    local binary="native/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    if [[ -f "$binary" ]]; then
        log_success "Guest agent built: $(du -h "$binary" | cut -f1)"
    else
        log_error "Guest agent build failed"
        exit 1
    fi
}

# =============================================================================
# Storage Setup
# =============================================================================

setup_btrfs() {
    log_section "Setting Up BTRFS Storage"

    if [[ "${SKIP_BTRFS:-0}" == "1" ]]; then
        log_info "Skipping BTRFS setup (SKIP_BTRFS=1)"
        return 0
    fi

    local device="${BTRFS_DEVICE:-}"
    local use_loopback=0
    local loopback_file="$MJOLNIR_ROOT/btrfs.img"
    local loopback_size="${BTRFS_LOOPBACK_SIZE_GB:-50}"

    # Check if BTRFS is already set up
    if mountpoint -q "$MJOLNIR_ROOT/btrfs" 2>/dev/null; then
        log_info "BTRFS already mounted at $MJOLNIR_ROOT/btrfs"
        return 0
    fi

    # Stale-artifact guard: a leftover btrfs.img used to auto-trigger loopback mode.
    # That regression trap is removed — loopback is now strictly opt-in via USE_LOOPBACK=1.
    if [[ -f "$loopback_file" && -z "$device" && "${USE_LOOPBACK:-0}" != "1" ]]; then
        log_warn "Found existing loopback file at $loopback_file (ignored)."
        log_warn "To reuse it, set USE_LOOPBACK=1. To suppress this warning, move or delete the file."
    fi

    # Determine device
    if [[ -z "$device" ]]; then
        if [[ "${USE_LOOPBACK:-0}" == "1" ]]; then
            log_info "USE_LOOPBACK=1 — using loopback file at $loopback_file"
            use_loopback=1
        else
            # Detect empty candidate disks (type=disk, no partitions, no FS signature)
            local candidates=()
            local disk size
            while read -r disk; do
                if [[ -z "$(wipefs -n "/dev/$disk" 2>/dev/null)" ]] \
                   && [[ "$(lsblk -n "/dev/$disk" | wc -l)" -eq 1 ]]; then
                    size=$(lsblk -ndo SIZE "/dev/$disk")
                    candidates+=("/dev/$disk:$size")
                fi
            done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk" {print $1}')

            echo ""
            log_info "BTRFS storage selection:"
            echo ""
            echo "  Recommended: dedicated block device (production — true CoW, TRIM, no double FS)"
            echo "  Dev/testing: loopback file (type 'loop' below, or rerun with USE_LOOPBACK=1)"
            echo ""

            local default_dev=""
            if [[ ${#candidates[@]} -gt 0 ]]; then
                log_info "Detected empty candidate disks:"
                local max_bytes=0 bytes d
                for c in "${candidates[@]}"; do
                    echo "  - ${c%:*} (${c##*:})"
                    d="${c%:*}"
                    bytes=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
                    if (( bytes > max_bytes )); then
                        max_bytes=$bytes
                        default_dev=$d
                    fi
                done
                echo ""
                read -rp "Enter device (default: $default_dev) or 'loop' for loopback: " device
                device="${device:-$default_dev}"
            else
                log_warn "No empty block devices detected."
                log_info "Available block devices:"
                lsblk -do NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk|part" || true
                echo ""
                read -rp "Enter device (e.g., /dev/sdb) or 'loop' for loopback: " device
            fi

            if [[ "$device" == "loop" ]]; then
                use_loopback=1
                device=""
            fi
        fi
    fi

    # Create loopback device if needed
    if [[ $use_loopback -eq 1 ]]; then
        mkdir -p "$MJOLNIR_ROOT"

        if [[ ! -f "$loopback_file" ]]; then
            log_info "Creating ${loopback_size}GB sparse loopback file at $loopback_file..."
            dd if=/dev/zero of="$loopback_file" bs=1M count=0 seek=$((loopback_size * 1024)) 2>/dev/null
            log_success "Loopback file created (sparse, actual size will grow as needed)"
        fi

        # Find a free loop device and attach
        device=$(losetup -f)
        log_info "Attaching loopback file to $device..."
        losetup "$device" "$loopback_file"

        # Create systemd service to re-attach loopback on boot
        log_info "Creating systemd service for loopback persistence..."
        cat > /etc/systemd/system/mjolnir-loopback.service << EOF
[Unit]
Description=Mount Mjolnir BTRFS loopback device
DefaultDependencies=no
Before=local-fs.target
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/sbin/losetup -f $loopback_file
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF
        systemctl daemon-reload
        systemctl enable mjolnir-loopback.service
    fi

    if [[ ! -b "$device" ]]; then
        log_error "$device is not a block device"
        exit 1
    fi

    # Confirm destructive operation (auto-confirm if BTRFS_DEVICE was explicitly set in env)
    if [[ -n "${BTRFS_DEVICE:-}" ]] || [[ $use_loopback -eq 1 ]]; then
        log_warn "Auto-confirming format of $device"
    else
        log_warn "This will DESTROY all data on $device"
        read -rp "Type 'yes' to continue: " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_error "Aborted"
            exit 1
        fi
    fi

    # Create BTRFS filesystem
    log_info "Creating BTRFS filesystem on $device..."
    mkfs.btrfs -f -L mjolnir "$device"

    # Create mount point and mount
    mkdir -p "$MJOLNIR_ROOT/btrfs"
    # Use different mount options for loopback (no ssd/discard)
    if [[ $use_loopback -eq 1 ]]; then
        mount -o compress=zstd:3,noatime "$device" "$MJOLNIR_ROOT/btrfs"
    else
        mount -o compress=zstd:3,noatime,ssd,discard=async "$device" "$MJOLNIR_ROOT/btrfs"
    fi

    # Add to fstab (use loopback file path for loopback devices)
    if [[ $use_loopback -eq 1 ]]; then
        if ! grep -q "mjolnir.*btrfs.img" /etc/fstab; then
            echo "$loopback_file $MJOLNIR_ROOT/btrfs btrfs loop,compress=zstd:3,noatime 0 0" >> /etc/fstab
        fi
    else
        local uuid
        uuid=$(blkid -s UUID -o value "$device")
        if ! grep -q "$uuid" /etc/fstab; then
            echo "UUID=$uuid $MJOLNIR_ROOT/btrfs btrfs compress=zstd:3,noatime,ssd,discard=async 0 0" >> /etc/fstab
        fi
    fi

    # Create top-level directory structure.
    # These four are plain directories; the per-distro template under @base/<name>
    # and per-VM rootfs under @vms/<uuid> are btrfs SUBVOLUMES, created by
    # scripts/build-rootfs.sh and Mjolnir.BTRFS.clone_subvolume/2 at spawn time.
    # Subvolumes are required (not just directories) so Cloud Hypervisor can share
    # each rootfs over virtio-fs and so reflink clones give us instant VM creation.
    log_info "Creating BTRFS directory structure..."
    mkdir -p "$MJOLNIR_ROOT/btrfs/@base"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@vms"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@snapshots"
    mkdir -p "$MJOLNIR_ROOT/btrfs/@workspaces"

    # Enable quotas
    btrfs quota enable "$MJOLNIR_ROOT/btrfs"

    if [[ $use_loopback -eq 1 ]]; then
        log_success "BTRFS setup complete (loopback: $loopback_file)"
    else
        log_success "BTRFS setup complete"
    fi
}

download_kernel() {
    log_section "Downloading VM Kernels"

    mkdir -p "$MJOLNIR_ROOT"

    # --- Firecracker kernel (Fireactions, vsock built-in, MMIO) ---
    if [[ -f "$MJOLNIR_ROOT/vmlinux" ]]; then
        log_info "Firecracker kernel already exists at $MJOLNIR_ROOT/vmlinux"
    else
        local arch
        arch=$(uname -m)

        # Fireactions kernel has vsock support built-in and is well-tested with Firecracker
        # https://hostinger.github.io/fireactions/user-guide/kernels/
        local kernel_url
        if [[ "$arch" == "x86_64" ]]; then
            kernel_url="https://storage.googleapis.com/fireactions/kernels/amd64/5.10/vmlinux"
        else
            kernel_url="https://storage.googleapis.com/fireactions/kernels/arm64/5.10/vmlinux"
        fi

        log_info "Downloading Firecracker kernel 5.10 from Fireactions..."
        if curl -fsSL "$kernel_url" -o "$MJOLNIR_ROOT/vmlinux"; then
            chmod 644 "$MJOLNIR_ROOT/vmlinux"
            log_success "Firecracker kernel downloaded to $MJOLNIR_ROOT/vmlinux"
        else
            log_error "Failed to download Firecracker kernel"
            log_error "URL: $kernel_url"
            exit 1
        fi
    fi

    # --- Cloud Hypervisor kernel (PVH boot, vsock built-in, PCI virtio) ---
    if [[ -f "$MJOLNIR_ROOT/vmlinux-ch" ]]; then
        log_info "Cloud Hypervisor kernel already exists at $MJOLNIR_ROOT/vmlinux-ch"
    else
        build_ch_kernel
    fi
}

build_ch_kernel() {
    log_info "Building Cloud Hypervisor kernel (requires PVH + vsock built-in)..."

    # Install kernel build deps
    apt-get install -y --no-install-recommends flex bison libelf-dev bc 2>/dev/null || true

    local ch_linux_dir="/tmp/linux-cloud-hypervisor"
    local ch_kernel_branch="ch-6.12.8"

    if [[ -d "$ch_linux_dir" ]]; then
        log_info "Cloud Hypervisor linux source already cloned"
    else
        log_info "Cloning Cloud Hypervisor linux branch ($ch_kernel_branch)..."
        git clone --depth 1 "https://github.com/cloud-hypervisor/linux.git" \
            -b "$ch_kernel_branch" "$ch_linux_dir"
    fi

    cd "$ch_linux_dir"

    log_info "Configuring with ch_defconfig (vsock=y, PVH=y)..."
    make ch_defconfig

    # Enable virtio-fs and related configs (must be =y built-in, not =m module)
    ./scripts/config --enable CONFIG_VIRTIO_FS
    ./scripts/config --enable CONFIG_FUSE_FS

    # Verify critical configs are built-in
    for opt in CONFIG_VIRTIO_FS CONFIG_FUSE_FS CONFIG_PVH; do
        val=$(grep "^${opt}=" .config | cut -d= -f2)
        if [ "$val" != "y" ]; then
            log_error "FATAL: $opt is '$val', must be 'y' (built-in, not module)"
            exit 1
        fi
    done
    log_info "Kernel config verified: VIRTIO_FS=y, FUSE_FS=y, PVH=y"

    log_info "Building kernel (this takes a few minutes)..."
    KCFLAGS="-Wa,-mx86-used-note=no" make -j"$(nproc)" bzImage

    local vmlinux_bin="arch/x86/boot/compressed/vmlinux.bin"
    if [[ -f "$vmlinux_bin" ]]; then
        cp "$vmlinux_bin" "$MJOLNIR_ROOT/vmlinux-ch"
        chmod 644 "$MJOLNIR_ROOT/vmlinux-ch"
        log_success "Cloud Hypervisor kernel built: $MJOLNIR_ROOT/vmlinux-ch ($(du -h "$MJOLNIR_ROOT/vmlinux-ch" | cut -f1))"
    else
        log_error "Cloud Hypervisor kernel build failed"
        exit 1
    fi

    # Clean up source to save disk (keep it if DEV_MODE)
    if [[ "${DEV_MODE:-0}" != "1" ]]; then
        rm -rf "$ch_linux_dir"
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

    log_info "Building rootfs BTRFS subvolume (this takes a few minutes)..."
    export AGENT_BIN="$agent_bin"
    cd "$MJOLNIR_CODE"
    bash "$build_script" "$rootfs_path"

    log_success "Rootfs built: $rootfs_path ($(du -sh "$rootfs_path" | cut -f1))"
}

# Ghostty TERM=xterm-ghostty. Distro ncurses does not ship it yet, so tmux/less
# on the host (and in guests, via the rootfs builders) need the entry compiled
# into /etc/terminfo. Same helper the image builders use.
install_host_ghostty_terminfo() {
    log_section "Installing Ghostty terminfo"
    # shellcheck source=lib/terminfo.sh
    source "$MJOLNIR_CODE/scripts/lib/terminfo.sh"
    install_ghostty_terminfo /
}

# =============================================================================
# Final Setup
# =============================================================================

setup_directories() {
    log_section "Setting Up Directories"

    # Socket directories (prod, test, dev)
    mkdir -p /tmp/mjolnir /tmp/mjolnir-test /tmp/mjolnir-dev
    chmod 755 /tmp/mjolnir /tmp/mjolnir-test /tmp/mjolnir-dev

    # Ensure /var/lib/mjolnir exists
    mkdir -p "$MJOLNIR_ROOT"
    mkdir -p "$MJOLNIR_ROOT/boot"

    # Set up test and dev directories within BTRFS for reflink to work
    if [[ -d "$MJOLNIR_ROOT/btrfs" ]]; then
        mkdir -p "$MJOLNIR_ROOT/btrfs/@base-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-dev"

        # Snapshot base subvolume to test directory for test isolation
        local distro="${ROOTFS_DISTRO:-arch}"
        if [[ -d "$MJOLNIR_ROOT/btrfs/@base/${distro}" ]]; then
            btrfs subvolume snapshot "$MJOLNIR_ROOT/btrfs/@base/${distro}" \
                "$MJOLNIR_ROOT/btrfs/@base-test/${distro}"
        fi

        # Create symlinks for test config paths
        rm -rf "$MJOLNIR_ROOT/btrfs-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs-test"
        ln -sf "$MJOLNIR_ROOT/btrfs/@base-test" "$MJOLNIR_ROOT/btrfs-test/@base"
        ln -sf "$MJOLNIR_ROOT/btrfs/@vms-test" "$MJOLNIR_ROOT/btrfs-test/@vms"

        # Make dev directories writable by the user who ran sudo
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

setup_networking() {
    log_section "Setting Up VM Networking"

    # VM subnet - 10.200.0.0/10 gives us ~4 million VMs (10.192.0.0 – 10.255.255.255).
    # Must match @default_subnet in lib/mjolnir/network.ex.
    local vm_subnet="10.200.0.0/10"

    # External interface (NIC holding the default route). Auto-detect; allow override.
    local ext_iface="${MJOLNIR_EXT_IFACE:-$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')}"
    if [[ -z "$ext_iface" ]]; then
        log_error "Could not determine external interface (no default route found)."
        log_error "Set MJOLNIR_EXT_IFACE=<name> and re-run."
        exit 1
    fi
    log_info "External interface: $ext_iface"

    # Reserved host-from-guest address (same as :host_api_ip). Tenant Postgres
    # binds here. Dummy, not lo, so TAP guests can ARP it. Must exist before
    # the sidecar starts; allocate_ip refuses this address.
    local host_api_ip="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
    log_info "Assigning reserved host-from-guest address ${host_api_ip}/32 on dummy-mjolnir"
    ip link add dummy-mjolnir type dummy 2>/dev/null || true
    ip link set dummy-mjolnir up
    ip addr replace "${host_api_ip}/32" dev dummy-mjolnir

    # Enable IP forwarding, persist via /etc/sysctl.d (preferred over /etc/sysctl.conf on modern Ubuntu).
    log_info "Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    local sysctl_snippet=/etc/sysctl.d/99-mjolnir.conf
    if [[ ! -f "$sysctl_snippet" ]] || ! grep -q '^net.ipv4.ip_forward' "$sysctl_snippet"; then
        echo "net.ipv4.ip_forward = 1" > "$sysctl_snippet"
        log_info "Wrote $sysctl_snippet"
    fi

    if ufw_is_active; then
        setup_networking_ufw "$vm_subnet" "$ext_iface"
    else
        setup_networking_iptables "$vm_subnet" "$ext_iface"
    fi

    ensure_host_api_addr
    allow_tenant_postgres_input "$vm_subnet"
    allow_blob_door_input "$vm_subnet"

    log_success "VM networking configured (subnet: $vm_subnet, egress: $ext_iface)"
}

# Reserved host-from-guest address for tenant Postgres and the in-guest API.
# Dummy (not lo): TAP /32 guests ARP this via proxy-ARP; lo + rp_filter drops it.
ensure_host_api_addr() {
    local ip="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
    if ip addr show dummy-mjolnir >/dev/null 2>&1; then
        :
    else
        ip link add dummy-mjolnir type dummy || true
    fi
    ip link set dummy-mjolnir up
    if ! ip addr show dummy-mjolnir | grep -q "inet ${ip}/32"; then
        ip addr add "${ip}/32" dev dummy-mjolnir || true
    fi
    log_info "Host API / tenant Postgres bind: ${ip}/32 on dummy-mjolnir"
}

# Guest TCP to 10.200.0.1:5432 is INPUT (TAP), not FORWARD. Default deny incoming
# would black-hole the hotel even with a valid secret.
allow_tenant_postgres_input() {
    local vm_subnet="$1"
    local ip="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
    if ufw_is_active; then
        if ! ufw status | grep -q "${ip} 5432"; then
            ufw allow proto tcp from "$vm_subnet" to "$ip" port 5432 comment 'VMs to sidecar tenant Postgres'
        fi
    else
        if ! iptables -C INPUT -p tcp -s "$vm_subnet" -d "$ip" --dport 5432 -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp -s "$vm_subnet" -d "$ip" --dport 5432 -j ACCEPT
        fi
    fi
}

# Guest TCP to 10.200.0.1:7222 is INPUT (TAP), not FORWARD. Same trap as 5432.
allow_blob_door_input() {
    local vm_subnet="$1"
    local ip="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
    if ufw_is_active; then
        if ! ufw status | grep -q "${ip} 7222"; then
            ufw allow proto tcp from "$vm_subnet" to "$ip" port 7222 comment 'VMs to blob door'
        fi
    else
        if ! iptables -C INPUT -p tcp -s "$vm_subnet" -d "$ip" --dport 7222 -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp -s "$vm_subnet" -d "$ip" --dport 7222 -j ACCEPT
        fi
    fi
}

ufw_is_active() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'
}

# When ufw manages the firewall, raw `iptables` rules get silently wiped on every
# `ufw reload` or reboot. Embed our NAT + FORWARD rules in /etc/ufw/before.rules so
# ufw itself reapplies them on each reload.
setup_networking_ufw() {
    local vm_subnet="$1"
    local ext_iface="$2"
    local before=/etc/ufw/before.rules

    log_info "ufw is active — integrating NAT rules into $before"
    cp -a "$before" "${before}.bak-$(date +%Y%m%d-%H%M%S)"

    # 1. Prepend *nat table block (idempotent via marker).
    if ! grep -q '^# BEGIN MJOLNIR NAT' "$before"; then
        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<NAT
# BEGIN MJOLNIR NAT
# NAT masquerade so VM subnet ${vm_subnet} can reach the internet.
# Embedded in ufw before.rules so it survives \`ufw reload\` and reboots.
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${vm_subnet} -o ${ext_iface} -j MASQUERADE
COMMIT
# END MJOLNIR NAT

NAT
        cat "$before" >> "$tmp"
        mv "$tmp" "$before"
        chmod 640 "$before"
        chown root:root "$before"
    fi

    # 2. Inject FORWARD ACCEPTs into ufw-before-forward (idempotent via marker).
    if ! grep -q 'MJOLNIR VM FORWARD' "$before"; then
        local anchor='-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
        if ! grep -qF "$anchor" "$before"; then
            log_error "Could not find anchor in $before; FORWARD rules not added."
            return 1
        fi
        python3 - "$before" "$vm_subnet" <<'PY'
import pathlib, sys
path, subnet = pathlib.Path(sys.argv[1]), sys.argv[2]
anchor = '-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
inject = (
    '\n# MJOLNIR VM FORWARD — accept traffic to/from VM subnet\n'
    f'-A ufw-before-forward -s {subnet} -j ACCEPT\n'
    f'-A ufw-before-forward -d {subnet} -j ACCEPT\n'
)
txt = path.read_text()
path.write_text(txt.replace(anchor, anchor + inject, 1))
PY
    fi

    log_info "Reloading ufw to apply NAT rules..."
    ufw reload
}

# Non-ufw path (e.g. minimal server, CI): write rules directly and persist via
# iptables-persistent.
setup_networking_iptables() {
    local vm_subnet="$1"
    local ext_iface="$2"

    if ! iptables -t nat -C POSTROUTING -s "$vm_subnet" -o "$ext_iface" -j MASQUERADE 2>/dev/null; then
        log_info "Adding NAT masquerade rule for $vm_subnet out $ext_iface..."
        iptables -t nat -A POSTROUTING -s "$vm_subnet" -o "$ext_iface" -j MASQUERADE
    fi

    if ! iptables -C FORWARD -s "$vm_subnet" -j ACCEPT 2>/dev/null; then
        log_info "Adding FORWARD rules for $vm_subnet..."
        iptables -A FORWARD -s "$vm_subnet" -j ACCEPT
        iptables -A FORWARD -d "$vm_subnet" -j ACCEPT
    fi

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
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

    # Install service file (always update — may have changed)
    cp "$MJOLNIR_CODE/systemd/mjolnir.service" /etc/systemd/system/mjolnir.service

    install -m 440 "$MJOLNIR_CODE/systemd/mjolnir.sudoers" /etc/sudoers.d/mjolnir
    visudo -c -f /etc/sudoers.d/mjolnir || { log_error "sudoers syntax check failed"; exit 1; }
    log_info "Sudoers rules installed at /etc/sudoers.d/mjolnir"

    # Install environment file (only if not already present — preserve operator customizations)
    mkdir -p /etc/mjolnir
    if [[ ! -f /etc/mjolnir/env ]]; then
        cp "$MJOLNIR_CODE/systemd/mjolnir.env" /etc/mjolnir/env

        # Generate a random release cookie
        local cookie
        cookie=$(openssl rand -hex 32)
        sed -i "s/mjolnir_prod_changeme/$cookie/" /etc/mjolnir/env
        chmod 600 /etc/mjolnir/env

        log_info "Generated random RELEASE_COOKIE in /etc/mjolnir/env"
    else
        log_info "/etc/mjolnir/env already exists — preserving existing config"
    fi

    # Persist the postgres bin dir discovered by install_postgres(). Unlike Arch,
    # Ubuntu doesn't symlink postgres/initdb into /usr/bin, so the release's
    # compiled-in default (see config/config.exs's pg_bin_dir: "/usr/bin") is wrong
    # here — MJOLNIR_PG_BIN_DIR must be set explicitly. Unlike RELEASE_COOKIE above,
    # this is safe (and correct) to re-derive and overwrite on every run: it's a
    # host fact, not a secret, and a postgres major-version upgrade would move it.
    if [[ -n "$PG_BIN_DIR" ]]; then
        if grep -q '^MJOLNIR_PG_BIN_DIR=' /etc/mjolnir/env; then
            sed -i "s#^MJOLNIR_PG_BIN_DIR=.*#MJOLNIR_PG_BIN_DIR=${PG_BIN_DIR}#" /etc/mjolnir/env
        else
            echo "MJOLNIR_PG_BIN_DIR=${PG_BIN_DIR}" >> /etc/mjolnir/env
        fi
        log_info "Set MJOLNIR_PG_BIN_DIR=${PG_BIN_DIR} in /etc/mjolnir/env"
    fi

    if grep -q '^MJOLNIR_PG_TENANT_LISTEN_IP=' /etc/mjolnir/env; then
        :
    else
        echo "MJOLNIR_PG_TENANT_LISTEN_IP=10.200.0.1" >> /etc/mjolnir/env
        log_info "Set MJOLNIR_PG_TENANT_LISTEN_IP=10.200.0.1 in /etc/mjolnir/env"
    fi

    # Reload and enable
    systemctl daemon-reload
    systemctl enable mjolnir.service

    log_success "Systemd service installed and enabled"
    log_info "Start with: systemctl start mjolnir"
    log_info "Remote shell: /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote"
    log_info "Logs: journalctl -u mjolnir -f"
}

run_verification() {
    log_section "Running Verification"

    cd "$MJOLNIR_CODE"

    # Unit tests (no KVM required)
    log_info "Running unit tests..."
    if mix test 2>&1; then
        log_success "Unit tests passed"
    else
        log_warn "Some unit tests failed (may be expected without full setup)"
    fi

    # Integration tests (require KVM)
    log_info "Running integration tests..."
    if mix test --include integration 2>&1; then
        log_success "Integration tests passed!"
    else
        log_warn "Integration tests failed - check output above"
    fi
}

print_summary() {
    log_section "Setup Complete!"

    echo ""
    if [[ "${DEV_MODE:-0}" == "1" ]]; then
        echo "Mjolnir DEV environment configured:"
        echo ""
        echo "  Workspace:      $MJOLNIR_CODE"
        echo "  Data:           $MJOLNIR_ROOT"
        echo "  BTRFS:          $MJOLNIR_ROOT/btrfs"
        echo "  Kernel:         $MJOLNIR_ROOT/vmlinux"
        echo "  Base images:    $MJOLNIR_ROOT/btrfs/@base/"
        echo "  Dev VMs:        $MJOLNIR_ROOT/btrfs/@vms-dev/"
        echo "  Dev sockets:    /tmp/mjolnir-dev"
        echo ""
        echo "To start developing:"
        echo ""
        echo "  cd $MJOLNIR_CODE"
        echo "  iex -S mix"
        echo ""
        echo "Code changes are live. Use recompile() in IEx to pick them up."
    else
        echo "Mjolnir has been installed and configured:"
        echo ""
        echo "  Code:           $MJOLNIR_CODE"
        echo "  Release:        $MJOLNIR_CODE/_build/prod/rel/mjolnir/"
        echo "  Data:           $MJOLNIR_ROOT"
        echo "  BTRFS:          $MJOLNIR_ROOT/btrfs"
        echo "  Kernel (CH):    $MJOLNIR_ROOT/vmlinux-ch"
        echo "  Base images:    $MJOLNIR_ROOT/btrfs/@base/"
        echo "  Socket dir:     /tmp/mjolnir"
        echo "  Service:        mjolnir.service"
        echo "  Config:         /etc/mjolnir/env"
        echo ""
        echo "Service management:"
        echo ""
        echo "  systemctl start mjolnir     # Start the service"
        echo "  systemctl stop mjolnir      # Stop the service"
        echo "  systemctl status mjolnir    # Check status"
        echo "  journalctl -u mjolnir -f    # Follow logs"
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
        echo "   Mjolnir Dev Bootstrap Script"
    else
        echo "   Mjolnir Host Bootstrap Script"
    fi
    echo "========================================"
    echo ""

    check_system_suitability
    install_base_packages
    install_postgres
    install_erlang_elixir
    install_rust

    install_cloud_hypervisor

    # Dev mode: use workspace directly; Prod mode: deploy to /opt/mjolnir
    if [[ "${DEV_MODE:-0}" == "1" ]]; then
        setup_dev_workspace
    else
        deploy_mjolnir_code
    fi

    build_guest_agent
    setup_btrfs
    download_kernel
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

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
