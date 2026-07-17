#!/bin/bash
################################################################################
##  File:  build-distrobuilder-image.sh
##  Desc:  Build Ubuntu images using distrobuilder for Incus
##  Usage: ./build-distrobuilder-image.sh <version> [arch]
##         version: 22.04 or 24.04
##         arch: ppc64le, s390x, or x86_64 (default: auto-detect)
################################################################################

# Note: Do NOT use 'set -e' in sourced scripts as it affects the parent shell
# Instead, use explicit error checking with || return 1

# Script/repository location
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(realpath "$SCRIPT_DIR/../..")"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Function to get release codename
get_release_codename() {
    local version="$1"
    
    case "$version" in
        22.04) echo "jammy" ;;
        24.04) echo "noble" ;;
        *)
            log_error "Unsupported Ubuntu version: $version"
            return 1
            ;;
    esac
}

# Function to check if image already exists
check_image_exists() {
    local alias="$1"
    
    if incus image info "$alias" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to detect OS type
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$ID"
    else
        log_error "Cannot detect OS type"
        return 1
    fi
}

# Function to install dependencies based on OS
install_dependencies() {
    local os_type
    os_type=$(detect_os)
    
    log_info "Installing distrobuilder dependencies for ${os_type}..."
    
    case "$os_type" in
        ubuntu|debian)
            log_info "Installing dependencies via apt..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                golang \
                debootstrap \
                rsync \
                squashfs-tools \
                make \
                qemu-utils \
                gdisk \
                dosfstools \
                btrfs-progs \
                git \
                wget \
                xz-utils >/dev/null 2>&1
            ;;
        centos|rhel|almalinux|rocky)
            log_info "Installing dependencies via dnf..."
            # Enable CRB/PowerTools repository for debootstrap
            dnf config-manager --set-enabled crb 2>/dev/null || \
            dnf config-manager --set-enabled powertools 2>/dev/null || true
            dnf clean all -q
            dnf install -y -q \
                golang \
                debootstrap \
                rsync \
                squashfs-tools \
                make \
                qemu-img \
                gdisk \
                dosfstools \
                btrfs-progs \
                git \
                wget \
                xz \
                patch >/dev/null 2>&1
            ;;
        fedora)
            log_info "Installing dependencies via dnf (Fedora)..."
            dnf clean all -q
            dnf install -y -q \
                golang \
                debootstrap \
                rsync \
                squashfs-tools \
                make \
                qemu-img \
                gdisk \
                dosfstools \
                btrfs-progs \
                git \
                wget \
                xz \
                patch >/dev/null 2>&1
            ;;
        *)
            log_error "Unsupported OS: ${os_type}"
            return 1
            ;;
    esac
    
    log_success "Dependencies installed"
}

# Function to build and install distrobuilder with IBM platform VM patches
install_distrobuilder() {
    log_info "Checking distrobuilder installation..."
    
    # Check if distrobuilder is already installed
    if command -v distrobuilder &>/dev/null; then
        local version
        version=$(distrobuilder --version 2>&1 | head -n1 || echo "unknown")
        log_info "distrobuilder already installed: ${version}"
        return 0
    fi
    
    log_info "Building distrobuilder from source with IBM platform VM patches..."
    
    echo "Repo root: ${REPO_ROOT}"
    echo "Patch file: ${REPO_ROOT}/patches/distrobuilder.patch"
    
    # Create temporary build directory
    local build_dir
    build_dir=$(mktemp -d)
    cd "$build_dir" || return 1
    
    # Clone distrobuilder
    log_info "Cloning distrobuilder repository..."
    if ! git clone -q https://github.com/lxc/distrobuilder; then
        log_error "Failed to clone distrobuilder repository"
        rm -rf "$build_dir"
        return 1
    fi
    
    cd distrobuilder || return 1
    
    # Apply IBM platform VM patches (covers ppc64le + s390x + fstab fixes)
    local patch_file="${REPO_ROOT}/patches/distrobuilder.patch"
    
    if [[ -f "$patch_file" ]]; then
        log_info "Applying IBM platform VM support patches..."
        if patch -p1 < "$patch_file"; then
            log_success "Patches applied successfully"
        else
            log_warn "Failed to apply patches (may already be applied or incompatible)"
            log_warn "Continuing with build..."
        fi
    else
        log_warn "Patch file not found: $patch_file"
        log_warn "Building without IBM platform VM patches"
    fi
    
    # Build distrobuilder
    log_info "Building distrobuilder (this may take a few minutes)..."
    if ! make >/dev/null 2>&1; then
        log_error "Failed to build distrobuilder"
        rm -rf "$build_dir"
        return 1
    fi
    
    # Install binary
    local gobin
    gobin="$(go env GOPATH)/bin"
    
    if [[ -f "${gobin}/distrobuilder" ]]; then
        log_info "Installing distrobuilder to /usr/local/bin..."
        install -m 755 "${gobin}/distrobuilder" /usr/local/bin/
        log_success "distrobuilder installed successfully"
    else
        log_error "distrobuilder binary not found after build"
        rm -rf "$build_dir"
        return 1
    fi
    
    # Cleanup build directory
    cd /
    rm -rf "$build_dir"
    
    # Verify installation
    if command -v distrobuilder &>/dev/null; then
        local version
        version=$(distrobuilder --version 2>&1 | head -n1)
        log_success "distrobuilder version: ${version}"
    else
        log_error "distrobuilder installation verification failed"
        return 1
    fi
}

# Main function to build Ubuntu image with distrobuilder
build_distrobuilder_ubuntu_image() {
    local VERSION="$1"
    local ARCH="${2:-$(uname -m)}"
    local WORKDIR="${3:-$HOME/incus-images/official-ubuntu}"
    local BUILD_VM="${4:-false}"  # New parameter for VM builds
    
    # Validate version
    if [[ ! "$VERSION" =~ ^(22.04|24.04)$ ]]; then
        log_error "Invalid Ubuntu version: $VERSION. Must be 22.04 or 24.04"
        return 1
    fi
    
    # Get release codename
    local CODENAME
    CODENAME=$(get_release_codename "$VERSION")
    
    # Define image alias (add -vm suffix for VM images)
    local IMAGE_ALIAS="ubuntu-${VERSION}"
    local IMAGE_TYPE="container"
    if [[ "$BUILD_VM" == "true" ]]; then
        IMAGE_ALIAS="${IMAGE_ALIAS}-vm"
        IMAGE_TYPE="virtual-machine"
    fi
    
    log_info "=========================================="
    log_info "Building Ubuntu ${VERSION} (${CODENAME})"
    log_info "Architecture: ${ARCH}"
    log_info "Image Type: ${IMAGE_TYPE}"
    log_info "Image Alias: ${IMAGE_ALIAS}"
    log_info "Build Method: distrobuilder"
    log_info "=========================================="
    
    # Check if image already exists
    if check_image_exists "$IMAGE_ALIAS"; then
        log_warn "Image '${IMAGE_ALIAS}' already exists in Incus"
        read -p "Do you want to rebuild? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping build for ${IMAGE_ALIAS}"
            return 0
        fi
        log_info "Removing existing image..."
        incus image delete "$IMAGE_ALIAS" || true
    fi
    
    # Install dependencies
    log_info "Ensuring dependencies are installed..."
    if ! install_dependencies; then
        log_error "Failed to install dependencies"
        return 1
    fi
    
    # Install distrobuilder
    if ! install_distrobuilder; then
        log_error "Failed to install distrobuilder"
        return 1
    fi
    
    # Use global REPO_ROOT
    local repo_root="$REPO_ROOT"
    
    # Log repo root detection result
    if [[ -d "$repo_root/patches" ]]; then
        log_info "Found repo root: $repo_root"
    else
        log_warn "Could not locate patches directory"
    fi
    
    # Create working directory
    log_info "Creating workspace: ${WORKDIR}"
    mkdir -p "$WORKDIR"
    # Save original directory to restore later
    local ORIGINAL_DIR
    ORIGINAL_DIR="$(pwd)"
    
    cd "$WORKDIR" || return 1
    
    # Cleanup function
    cleanup_files() {
        log_info "Cleaning up build artifacts..."
        if [[ -d "$WORKDIR" ]]; then
            rm -rf "${WORKDIR:?}"/*
        fi
        # Restore original directory to avoid affecting parent shell
        cd "$ORIGINAL_DIR" 2>/dev/null || cd / 2>/dev/null || true
        log_success "Cleanup completed"
    }
    
    # Download image definition
    local YAML_URL="https://raw.githubusercontent.com/lxc/lxc-ci/main/images/ubuntu.yaml"
    log_info "Downloading Ubuntu image definition..."
    if ! wget -q -O ubuntu.yaml "$YAML_URL"; then
        log_error "Failed to download ubuntu.yaml"
        cleanup_files
        return 1
    fi
    log_success "Image definition downloaded"
    
    # Apply IBM platform patches to ubuntu.yaml if repo root was found
    if [[ -n "$repo_root" && -d "$repo_root/patches" ]]; then
        local yaml_patch="${REPO_ROOT}/patches/lxc-ci.patch"
        log_info "Patch file path: $yaml_patch"
        
        if [[ -f "$yaml_patch" ]]; then
            log_info "Applying IBM platform patches to ubuntu.yaml..."
            # Create images directory structure for patch to work
            mkdir -p images
            mv ubuntu.yaml images/ubuntu.yaml
            if patch -p1 < "$yaml_patch"; then
                log_success "ubuntu.yaml patches applied successfully"
            else
                log_warn "Failed to apply ubuntu.yaml patches (may already be applied)"
                log_warn "Continuing with build..."
            fi
            # Move ubuntu.yaml back to current directory
            mv images/ubuntu.yaml ubuntu.yaml
            rmdir images 2>/dev/null || true
        else
            log_warn "Patch file not found: $yaml_patch"
            log_warn "Building without IBM platform patches"
        fi
    else
        log_warn "Building without IBM platform patches (patches directory not found)"
    fi
    
    # Build image with distrobuilder
    log_info "Building Ubuntu ${VERSION} ${IMAGE_TYPE} image (this will take several minutes)..."
    log_info "Architecture: ${ARCH}, Release: ${CODENAME}"
    
    # Add --vm flag for VM builds
    local VM_FLAG=""
    if [[ "$BUILD_VM" == "true" ]]; then
        VM_FLAG="--vm"
        log_info "Building as virtual machine image"
    fi
    
    # Mirror selection: try the FAU mirror first (faster, reliable),
    # fall back to the official Ubuntu ports mirror if it fails.
    local PRIMARY_MIRROR="https://ftp.fau.de/ubuntu-ports"
    local FALLBACK_MIRROR="https://ports.ubuntu.com/ubuntu-ports"
    local SOURCE_URL="$PRIMARY_MIRROR"

    log_info "Checking primary mirror: ${PRIMARY_MIRROR}..."
    if wget -q --spider --timeout=10 "${PRIMARY_MIRROR}/dists/${CODENAME}/Release" 2>/dev/null; then
        log_info "Primary mirror reachable — using ${PRIMARY_MIRROR}"
    else
        log_warn "Primary mirror unreachable — falling back to ${FALLBACK_MIRROR}"
        SOURCE_URL="$FALLBACK_MIRROR"
    fi
    log_info "Selected mirror: ${SOURCE_URL}"

    # Run distrobuilder. Use PIPESTATUS[0] because the pipeline
    # (| tee build.log) would otherwise mask a non-zero exit code.
    local distro_rc=0
    distrobuilder build-incus ubuntu.yaml ${VM_FLAG} \
        -o image.architecture="${ARCH}" \
        -o image.release="${CODENAME}" \
        -o image.variant=default \
        -o source.url="${SOURCE_URL}" 2>&1 | tee build.log
    distro_rc=${PIPESTATUS[0]}

    if [[ "$distro_rc" -ne 0 ]]; then
        log_error "distrobuilder exited with status ${distro_rc}"
        log_error "Mirror used: ${SOURCE_URL}"
        log_error "Check build.log for details"
        cleanup_files
        return 1
    fi

    log_success "Image build completed"
    
    # Check for generated artifacts (different for VMs vs containers)
    if [[ "$BUILD_VM" == "true" ]]; then
        # VM builds produce disk image
        if [[ ! -f "incus.tar.xz" ]] || [[ ! -f "disk.qcow2" ]]; then
            log_error "VM build artifacts not found (incus.tar.xz or disk.qcow2)"
            cleanup_files
            return 1
        fi
        log_info "VM Build artifacts:"
        ls -lh incus.tar.xz disk.qcow2
        
        # Import VM into Incus
        log_info "Importing VM image into Incus with alias '${IMAGE_ALIAS}'..."
        if ! incus image import incus.tar.xz disk.qcow2 --alias "$IMAGE_ALIAS"; then
            log_error "Failed to import VM image into Incus"
            cleanup_files
            return 1
        fi
    else
        # Container builds produce rootfs
        if [[ ! -f "incus.tar.xz" ]] || [[ ! -f "rootfs.squashfs" ]]; then
            log_error "Container build artifacts not found (incus.tar.xz or rootfs.squashfs)"
            cleanup_files
            return 1
        fi
        log_info "Container Build artifacts:"
        ls -lh incus.tar.xz rootfs.squashfs
        
        # Import container into Incus
        log_info "Importing container image into Incus with alias '${IMAGE_ALIAS}'..."
        if ! incus image import incus.tar.xz rootfs.squashfs --alias "$IMAGE_ALIAS"; then
            log_error "Failed to import container image into Incus"
            cleanup_files
            return 1
        fi
    fi
    log_success "Image imported successfully"
    
    # Verify import
    log_info "Verifying image import..."
    if check_image_exists "$IMAGE_ALIAS"; then
        log_success "Image '${IMAGE_ALIAS}' verified in Incus"
        
        # Show image info
        log_info "Image details:"
        incus image info "$IMAGE_ALIAS" | head -n 10
    else
        log_error "Image verification failed"
        cleanup_files
        return 1
    fi
    
    # Cleanup build directory
    log_info "Cleaning up build directory..."
    cleanup_files
    
    log_success "=========================================="
    log_success "Build completed successfully!"
    log_success "Image alias: ${IMAGE_ALIAS}"
    log_success "=========================================="
    
    return 0
}

# Main execution if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check if running as root (required for some operations)
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
    
    # Ensure /usr/local/bin is in PATH (where Incus is installed)
    export PATH="/usr/local/bin:$PATH"
    
    # Check if incus is available
    if ! command -v incus &>/dev/null; then
        log_error "Incus is not installed or not in PATH"
        log_error "Checked PATH: $PATH"
        return 1
    fi
    
    # Check if incus daemon is running
    if ! incus admin waitready --timeout=5 >/dev/null 2>&1; then
        log_error "Incus daemon is not running or not ready"
        return 1
    fi
    
    # Parse arguments
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <version> [arch] [workdir] [--vm]"
        echo "  version: 22.04 or 24.04"
        echo "  arch: ppc64le, s390x, or x86_64 (default: auto-detect)"
        echo "  workdir: Build directory (default: ~/incus-images/official-ubuntu)"
        echo "  --vm: Build VM image instead of container (optional)"
        return 1
    fi
    
    # Check for --vm flag
    BUILD_VM="false"
    for arg in "$@"; do
        if [[ "$arg" == "--vm" ]]; then
            BUILD_VM="true"
            break
        fi
    done
    
    # Remove --vm from arguments if present
    ARGS=()
    for arg in "$@"; do
        if [[ "$arg" != "--vm" ]]; then
            ARGS+=("$arg")
        fi
    done
    
    build_distrobuilder_ubuntu_image "${ARGS[@]}" "$BUILD_VM"
fi

