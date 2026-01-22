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
#   BTRFS_DEVICE    - Block device for BTRFS (will prompt if not set)
#   MJOLNIR_REPO    - Git repo URL (default: current directory or GitHub)
#   MJOLNIR_BRANCH  - Git branch (default: main)
#   SKIP_BTRFS      - Set to 1 to skip BTRFS setup (use existing)
#   SKIP_ROOTFS     - Set to 1 to skip rootfs build

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
        libssl-dev

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

    # Use asdf for reliable version management
    log_info "Installing asdf for Erlang/Elixir version management..."

    # Install asdf dependencies
    apt-get update
    apt-get install -y autoconf libncurses5-dev libssl-dev libwxgtk3.2-dev libwxgtk-webview3.2-dev \
        libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop \
        libxml2-utils libncurses-dev openjdk-17-jdk 2>/dev/null || true

    # Install asdf if not present
    if [[ ! -d "$HOME/.asdf" ]]; then
        git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.14.0
    fi

    # Source asdf
    # shellcheck source=/dev/null
    . "$HOME/.asdf/asdf.sh"

    # Add to bashrc for future sessions (shellcheck: we want literal $HOME in the file)
    if ! grep -q "asdf.sh" "$HOME/.bashrc" 2>/dev/null; then
        # shellcheck disable=SC2016
        echo '. "$HOME/.asdf/asdf.sh"' >> "$HOME/.bashrc"
    fi

    # Install Erlang plugin and version
    if ! asdf plugin list 2>/dev/null | grep -q erlang; then
        asdf plugin add erlang
    fi

    local erlang_version="26.2.5"
    log_info "Installing Erlang $erlang_version (this takes a while)..."
    if ! asdf list erlang 2>/dev/null | grep -q "$erlang_version"; then
        asdf install erlang "$erlang_version"
    fi
    asdf global erlang "$erlang_version"

    # Install Elixir plugin and version
    if ! asdf plugin list 2>/dev/null | grep -q elixir; then
        asdf plugin add elixir
    fi

    local elixir_version="1.16.2-otp-26"
    log_info "Installing Elixir $elixir_version..."
    if ! asdf list elixir 2>/dev/null | grep -q "$elixir_version"; then
        asdf install elixir "$elixir_version"
    fi
    asdf global elixir "$elixir_version"

    # Reshim to ensure binaries are available
    asdf reshim erlang
    asdf reshim elixir

    # Verify installation
    log_info "Erlang version: $(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null || echo 'unknown')"
    log_info "Elixir version: $(elixir --version | head -1)"

    # Install hex and rebar
    log_info "Installing Hex and Rebar..."
    mix local.hex --force
    mix local.rebar --force

    log_success "Erlang/Elixir installed via asdf"
}

install_rust() {
    log_section "Installing Rust"

    # Check if already installed
    if command -v rustc &>/dev/null; then
        log_success "Rust already installed: $(rustc --version)"

        # Ensure musl target is available
        if ! rustup target list --installed 2>/dev/null | grep -q "x86_64-unknown-linux-musl"; then
            log_info "Adding musl target..."
            rustup target add x86_64-unknown-linux-musl
        fi
        return 0
    fi

    log_info "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

    # Source cargo env
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"

    # Add musl target for static binaries
    log_info "Adding musl target for static linking..."
    rustup target add x86_64-unknown-linux-musl

    log_success "Rust installed: $(rustc --version)"
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

deploy_mjolnir_code() {
    log_section "Deploying Mjolnir Code"

    local repo="${MJOLNIR_REPO:-}"
    local branch="${MJOLNIR_BRANCH:-main}"

    # If we're running from within the repo, use that
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(dirname "$script_dir")"

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

    # Check if BTRFS is already set up
    if mountpoint -q "$MJOLNIR_ROOT/btrfs" 2>/dev/null; then
        log_info "BTRFS already mounted at $MJOLNIR_ROOT/btrfs"
        return 0
    fi

    # Prompt for device if not set
    if [[ -z "$device" ]]; then
        echo ""
        log_info "Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk|part"
        echo ""
        read -rp "Enter device for BTRFS (e.g., /dev/sdb): " device
    fi

    if [[ ! -b "$device" ]]; then
        log_error "$device is not a block device"
        exit 1
    fi

    # Confirm destructive operation (auto-confirm if BTRFS_DEVICE was explicitly set in env)
    if [[ -n "${BTRFS_DEVICE:-}" ]]; then
        log_warn "BTRFS_DEVICE was explicitly set - auto-confirming format of $device"
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
    mount -o compress=zstd:3,noatime,ssd,discard=async "$device" "$MJOLNIR_ROOT/btrfs"

    # Add to fstab
    local uuid
    uuid=$(blkid -s UUID -o value "$device")
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $MJOLNIR_ROOT/btrfs btrfs compress=zstd:3,noatime,ssd,discard=async 0 0" >> /etc/fstab
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

    log_success "BTRFS setup complete"
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
    log_section "Building Debian 12 Rootfs"

    if [[ "${SKIP_ROOTFS:-0}" == "1" ]]; then
        log_info "Skipping rootfs build (SKIP_ROOTFS=1)"
        return 0
    fi

    # Firecracker uses ext4 file images, not directories
    local rootfs_ext4="$MJOLNIR_ROOT/btrfs/@base/debian-12.ext4"
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

    # Socket directories
    mkdir -p /tmp/mjolnir
    mkdir -p /tmp/mjolnir-test
    chmod 755 /tmp/mjolnir /tmp/mjolnir-test

    # Ensure /var/lib/mjolnir exists
    mkdir -p "$MJOLNIR_ROOT"

    # Set up test directories within BTRFS for reflink to work
    # Tests use /var/lib/mjolnir/btrfs-test which we symlink to actual BTRFS dirs
    if [[ -d "$MJOLNIR_ROOT/btrfs" ]]; then
        mkdir -p "$MJOLNIR_ROOT/btrfs/@base-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs/@vms-test"

        # Copy base image to test directory for test isolation
        if [[ -f "$MJOLNIR_ROOT/btrfs/@base/debian-12.ext4" ]]; then
            cp --reflink=auto "$MJOLNIR_ROOT/btrfs/@base/debian-12.ext4" \
                "$MJOLNIR_ROOT/btrfs/@base-test/debian-12.ext4"
        fi

        # Create symlinks for test config paths
        rm -rf "$MJOLNIR_ROOT/btrfs-test"
        mkdir -p "$MJOLNIR_ROOT/btrfs-test"
        ln -sf "$MJOLNIR_ROOT/btrfs/@base-test" "$MJOLNIR_ROOT/btrfs-test/@base"
        ln -sf "$MJOLNIR_ROOT/btrfs/@vms-test" "$MJOLNIR_ROOT/btrfs-test/@vms"
    fi

    log_success "Directories created"
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
    echo "   Mjolnir Host Bootstrap Script"
    echo "========================================"
    echo ""

    check_system_suitability
    install_base_packages
    install_erlang_elixir
    install_rust
    install_firecracker
    deploy_mjolnir_code
    build_guest_agent
    setup_btrfs
    download_kernel
    build_rootfs
    setup_directories
    run_verification
    print_summary
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
