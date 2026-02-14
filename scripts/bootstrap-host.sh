#!/bin/bash
set -euo pipefail

# Mjolnir Host Bootstrap Script
# Complete setup for a fresh bare-metal Debian/Ubuntu server
#
# This script:
# 1. Checks system suitability (KVM, architecture, etc.)
# 2. Installs all dependencies (Erlang, Elixir, Rust, Firecracker)
# 3. Clones and compiles Mjolnir
# 4. Sets up BTRFS storage
# 5. Builds guest agent and rootfs
# 6. Runs verification tests
#
# Usage:
#   curl -sSL <url>/bootstrap-host.sh | sudo bash
#   # or
#   sudo ./bootstrap-host.sh
#
# Environment variables:
#   DEV_MODE             - Set to 1 for development setup (skip /opt deploy, setup dev dirs)
#   BTRFS_DEVICE         - Block device for BTRFS (will prompt if not set)
#   USE_LOOPBACK         - Set to 1 to auto-create a loopback file instead of using a device
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
FC_VERSION="1.5.0"
# Minimum versions (used for validation)
MIN_ELIXIR_VERSION="1.15"

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
        debootstrap \
        musl-tools \
        pkg-config \
        libssl-dev \
        socat \
        screen \
        iptables \
        iptables-persistent

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

install_firecracker() {
    log_section "Installing Firecracker"

    # Check if already installed with correct version
    if command -v firecracker &>/dev/null; then
        local current_fc
        current_fc=$(firecracker --version 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0")
        if [[ "$current_fc" == "$FC_VERSION" ]]; then
            log_success "Firecracker v$current_fc already installed"
            return 0
        fi
    fi

    local arch
    arch=$(uname -m)

    local url="https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-${arch}.tgz"

    log_info "Downloading Firecracker v${FC_VERSION}..."
    curl -L "$url" | tar xz -C /tmp

    mv "/tmp/release-v${FC_VERSION}-${arch}/firecracker-v${FC_VERSION}-${arch}" /usr/local/bin/firecracker
    mv "/tmp/release-v${FC_VERSION}-${arch}/jailer-v${FC_VERSION}-${arch}" /usr/local/bin/jailer

    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer
    rm -rf "/tmp/release-v${FC_VERSION}-${arch}"

    log_success "Firecracker installed: $(firecracker --version)"
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

    # Compile Elixir project
    log_info "Fetching dependencies..."
    mix deps.get

    log_info "Compiling Mjolnir..."
    MIX_ENV=prod mix compile

    log_success "Mjolnir code deployed to $MJOLNIR_CODE"
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

    cd "$MJOLNIR_CODE/native/mjolnir_guest_agent"

    # Ensure cargo is available
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    log_info "Building static musl binary..."
    cargo build --release --target x86_64-unknown-linux-musl

    local binary="target/x86_64-unknown-linux-musl/release/mjolnir-agent"
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

    # Determine device: explicit device, existing loopback, or create new loopback
    if [[ -z "$device" ]]; then
        # Check if loopback file already exists
        if [[ -f "$loopback_file" ]]; then
            log_info "Found existing loopback file at $loopback_file"
            use_loopback=1
        elif [[ "${USE_LOOPBACK:-0}" == "1" ]]; then
            log_info "USE_LOOPBACK=1, will create loopback device"
            use_loopback=1
        else
            echo ""
            log_info "No BTRFS_DEVICE specified. Options:"
            echo ""
            echo "  1. Use a loopback file (recommended for dev/testing)"
            echo "  2. Use a dedicated block device (recommended for production)"
            echo ""
            log_info "Available block devices:"
            lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk|part" || true
            echo ""
            read -rp "Enter device (e.g., /dev/sdb) or 'loop' for loopback: " device

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

    # Create directory structure
    # Note: We use regular directories for @base and @vms, not subvolumes,
    # because Firecracker uses ext4 file images. BTRFS CoW cloning (cp --reflink)
    # works on files within the same filesystem, giving us instant VM creation.
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
    log_section "Downloading Firecracker Kernel"

    mkdir -p "$MJOLNIR_ROOT"

    if [[ -f "$MJOLNIR_ROOT/vmlinux" ]]; then
        log_info "Kernel already exists at $MJOLNIR_ROOT/vmlinux"
        return 0
    fi

    local arch
    arch=$(uname -m)

    # Use Fireactions kernel which has vsock support and is well-tested
    # https://hostinger.github.io/fireactions/user-guide/kernels/
    local kernel_url
    if [[ "$arch" == "x86_64" ]]; then
        kernel_url="https://storage.googleapis.com/fireactions/kernels/amd64/5.10/vmlinux"
    else
        kernel_url="https://storage.googleapis.com/fireactions/kernels/arm64/5.10/vmlinux"
    fi

    log_info "Downloading kernel 5.10 from Fireactions..."
    if curl -fsSL "$kernel_url" -o "$MJOLNIR_ROOT/vmlinux"; then
        chmod 644 "$MJOLNIR_ROOT/vmlinux"
        log_success "Kernel downloaded to $MJOLNIR_ROOT/vmlinux"
    else
        log_error "Failed to download kernel"
        log_error "URL: $kernel_url"
        exit 1
    fi
}

build_rootfs() {
    log_section "Building Ubuntu 24.04 Rootfs"

    if [[ "${SKIP_ROOTFS:-0}" == "1" ]]; then
        log_info "Skipping rootfs build (SKIP_ROOTFS=1)"
        return 0
    fi

    # Firecracker uses ext4 file images, not directories
    local rootfs_ext4="$MJOLNIR_ROOT/btrfs/@base/ubuntu-24.04.ext4"
    local agent_bin="$MJOLNIR_CODE/native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent"

    if [[ -f "$rootfs_ext4" ]]; then
        log_info "Rootfs already exists at $rootfs_ext4"
        return 0
    fi

    # Build ext4 image using build-rootfs.sh
    log_info "Building rootfs ext4 image (this takes a few minutes)..."

    # Set agent binary path for build script
    export AGENT_BIN="$agent_bin"

    # Run the build script directly to the target location on BTRFS
    # This allows CoW cloning to work for instant VM creation
    cd "$MJOLNIR_CODE"
    bash scripts/build-rootfs.sh "$rootfs_ext4" 512

    log_success "Rootfs built: $rootfs_ext4 ($(du -h "$rootfs_ext4" | cut -f1))"
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

    # Set up test and dev directories within BTRFS for reflink to work
    if [[ -d "$MJOLNIR_ROOT/btrfs" ]]; then
        mkdir -p "$MJOLNIR_ROOT/btrfs/@base-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-dev"

        # Copy base image to test directory for test isolation
        if [[ -f "$MJOLNIR_ROOT/btrfs/@base/ubuntu-24.04.ext4" ]]; then
            cp --reflink=auto "$MJOLNIR_ROOT/btrfs/@base/ubuntu-24.04.ext4" \
                "$MJOLNIR_ROOT/btrfs/@base-test/ubuntu-24.04.ext4"
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

setup_networking() {
    log_section "Setting Up VM Networking"

    # VM subnet - 10.200.0.0/10 gives us ~4 million VMs
    # Using 10.200.x.x avoids conflicts with common LAN ranges (10.0.x, 10.1.x)
    local vm_subnet="10.200.0.0/10"

    # Enable IP forwarding
    log_info "Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Make persistent
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    # Add NAT rule for VM subnet (MASQUERADE rewrites source IP)
    if ! iptables -t nat -C POSTROUTING -s "$vm_subnet" -j MASQUERADE 2>/dev/null; then
        log_info "Adding NAT masquerade rule for $vm_subnet..."
        iptables -t nat -A POSTROUTING -s "$vm_subnet" -j MASQUERADE
    else
        log_info "NAT rule already exists"
    fi

    # Allow forwarding for VM traffic (both directions)
    if ! iptables -C FORWARD -s "$vm_subnet" -j ACCEPT 2>/dev/null; then
        log_info "Adding FORWARD rules for VM traffic..."
        iptables -A FORWARD -s "$vm_subnet" -j ACCEPT
        iptables -A FORWARD -d "$vm_subnet" -j ACCEPT
    else
        log_info "FORWARD rules already exist"
    fi

    # Make iptables rules persistent
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_success "VM networking configured (subnet: $vm_subnet)"
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
        echo "  Data:           $MJOLNIR_ROOT"
        echo "  BTRFS:          $MJOLNIR_ROOT/btrfs"
        echo "  Kernel:         $MJOLNIR_ROOT/vmlinux"
        echo "  Base images:    $MJOLNIR_ROOT/btrfs/@base/"
        echo "  Socket dir:     /tmp/mjolnir"
        echo ""
        echo "To start Mjolnir:"
        echo ""
        echo "  cd $MJOLNIR_CODE"
        echo "  iex -S mix"
    fi
    echo ""
    echo "Then in IEx:"
    echo ""
    echo "  {:ok, vm} = Mjolnir.VM.spawn()"
    echo "  {:ok, output} = Mjolnir.VM.exec(vm.id, \"uname -a\")"
    echo "  Mjolnir.VM.stop(vm.id)"
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
    install_erlang_elixir
    install_rust
    install_firecracker

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
    setup_directories
    setup_networking

    # Skip verification in dev mode (user will run tests manually)
    if [[ "${DEV_MODE:-0}" != "1" ]]; then
        run_verification
    fi

    print_summary
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
