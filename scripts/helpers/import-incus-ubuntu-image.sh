#!/bin/bash
################################################################################
##  File:  import-incus-ubuntu-image.sh
##  Desc:  Import Ubuntu images from Incus image server (x86_64/aarch64 only)
##  Usage: Source this file and call import_incus_ubuntu_image <version> [arch]
##         version: 22.04 or 24.04
##         arch: x86_64 or aarch64 (default: auto-detect)
##  Note:  For ppc64le and s390x, use build-distrobuilder-image.sh instead
################################################################################

# Note: Do NOT use 'set -e' in sourced scripts as it affects the parent shell
# Instead, use explicit error checking with || return 1

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
    echo -e "${RED}[ERROR]${NC} $*"
}

# Get Ubuntu codename from version
get_codename() {
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

# Map system architecture to Incus image server architecture
map_incus_arch() {
    case "$1" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        ppc64le) echo "ppc64le" ;;
        s390x)   echo "s390x" ;;
        *)       echo "$1" ;;
    esac
}

# Check if image exists in Incus
check_image_exists() {
    local alias="$1"
    if incus image info "$alias" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Import Ubuntu image from Incus image server
import_incus_ubuntu_image() {
    local VERSION="${1:-}"
    local SYSTEM_ARCH="${2:-$(uname -m)}"
    
    # Validate version
    if [[ "$VERSION" != "22.04" ]] && [[ "$VERSION" != "24.04" ]]; then
        log_error "Invalid Ubuntu version: $VERSION. Must be 22.04 or 24.04"
        return 1
    fi
    
    # Validate architecture - only x86_64 and aarch64 supported via Incus image server
    if [[ "$SYSTEM_ARCH" != "x86_64" ]] && [[ "$SYSTEM_ARCH" != "aarch64" ]]; then
        log_error "Unsupported architecture for Incus image server: $SYSTEM_ARCH"
        log_error "Incus image server only supports x86_64 and aarch64"
        log_error "Use distrobuilder for ppc64le and s390x"
        return 1
    fi
    
    # Map to Incus image server architecture naming
    local INCUS_ARCH
    INCUS_ARCH=$(map_incus_arch "$SYSTEM_ARCH")
    
    local CODENAME
    CODENAME=$(get_codename "$VERSION")
    local IMAGE_ALIAS="ubuntu-${VERSION}"
    
    log_info "=========================================="
    log_info "Importing Ubuntu ${VERSION} (${CODENAME})"
    log_info "System Architecture: ${SYSTEM_ARCH}"
    log_info "Incus Architecture: ${INCUS_ARCH}"
    log_info "Image Alias: ${IMAGE_ALIAS}"
    log_info "Source: Incus image server"
    log_info "=========================================="
    
    # Check if image already exists
    if check_image_exists "$IMAGE_ALIAS"; then
        log_warn "Image '${IMAGE_ALIAS}' already exists in Incus"
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping import for ${IMAGE_ALIAS}"
            return 0
        fi
        log_info "Removing existing image..."
        incus image delete "$IMAGE_ALIAS" || true
    fi
    
    # Import from Incus image server
    log_info "Importing image from Incus image server..."
    log_info "Command: incus image copy images:ubuntu/${VERSION}/${INCUS_ARCH} local: --alias ${IMAGE_ALIAS}"
    log_info "This may take a few minutes..."
    
    if ! incus image copy "images:ubuntu/${VERSION}/${INCUS_ARCH}" local: --alias "$IMAGE_ALIAS" --auto-update; then
        log_error "Failed to import image from Incus image server"
        return 1
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
        return 1
    fi
    
    log_success "=========================================="
    log_success "Import completed successfully!"
    log_success "Image alias: ${IMAGE_ALIAS}"
    log_success "=========================================="
    
    return 0
}

# Main execution if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
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
        echo "Usage: $0 <version> [arch]"
        echo "  version: 22.04 or 24.04"
        echo "  arch: x86_64 or aarch64 (default: auto-detect)"
        echo ""
        echo "Note: This script only supports x86_64 and aarch64 architectures."
        echo "      For ppc64le and s390x, use build-distrobuilder-image.sh instead."
        return 1
    fi
    
    import_incus_ubuntu_image "$@"
fi

# Made with Bob