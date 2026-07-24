#!/bin/bash
################################################################################
##  File:  incus-common.sh
##  Desc:  Shared utilities and image import functions for Incus scripts.
##  Usage: source "$(dirname "${BASH_SOURCE[0]}")/incus-common.sh"
################################################################################

# Guard against multiple sourcing
if [[ -n "${_INCUS_COMMON_LOADED:-}" ]]; then
    return 0
fi
_INCUS_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

check_image_exists() {
    incus image info "$1" &>/dev/null
}

get_image_source_tag() {
    incus image get-property "$1" user.image-source 2>/dev/null || echo ""
}

set_image_source_tag() {
    local alias="$1" source="$2"
    incus image set-property "$alias" user.image-source "${source}"
}

check_or_replace_image() {
    local alias="$1" expected_source="$2"

    if ! check_image_exists "$alias"; then
        return 0
    fi

    local current_source
    current_source=$(get_image_source_tag "$alias")

    if [[ -z "$current_source" ]]; then
        log_warn "Image '${alias}' exists but has no source tag (pre-existing image)"
        log_info "Deleting untagged image to re-import from '${expected_source}'..."
        incus image delete "$alias" || true
        return 0
    fi

    if [[ "$current_source" != "$expected_source" ]]; then
        log_warn "Image '${alias}' exists but source is '${current_source}', expected '${expected_source}'"
        log_info "Deleting old image to re-import from correct source..."
        incus image delete "$alias" || true
        return 0
    fi

    log_info "Image '${alias}' already exists (source: ${current_source}). Skipping import."
    return 1
}

get_ubuntu_codename() {
    case "$1" in
        22.04) echo "jammy" ;;
        24.04) echo "noble" ;;
        *)
            log_error "Unsupported Ubuntu version: $1"
            return 1
            ;;
    esac
}

# Map uname -m to the architecture name used by Incus image server / Ubuntu.
map_arch() {
    case "$1" in
        x86_64)  echo "amd64" ;;
        ppc64le) echo "ppc64el" ;;
        s390x)   echo "s390x" ;;
        *)
            log_error "Unsupported architecture: $1"
            return 1
            ;;
    esac
}

# Preflight checks for direct script execution.
incus_preflight() {
    export PATH="/usr/local/bin:$PATH"

    if ! command -v incus &>/dev/null; then
        log_error "Incus is not installed or not in PATH"
        log_error "Checked PATH: $PATH"
        exit 1
    fi

    if ! incus admin waitready --timeout=5 >/dev/null 2>&1; then
        log_error "Incus daemon is not running or not ready"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Import: Official Ubuntu Cloud Images (cloud-images.ubuntu.com)
# ---------------------------------------------------------------------------

CLOUDIMG_BASE_URL="https://cloud-images.ubuntu.com/releases"

import_cloudimg_ubuntu_image() {
    local VERSION="${1:-}"
    local SYSTEM_ARCH="${2:-$(uname -m)}"
    local IMAGE_TYPE="${3:-}"

    if [[ "$VERSION" != "22.04" ]] && [[ "$VERSION" != "24.04" ]]; then
        log_error "Invalid Ubuntu version: $VERSION. Must be 22.04 or 24.04"
        return 1
    fi

    if [[ "$IMAGE_TYPE" != "vm" ]] && [[ "$IMAGE_TYPE" != "container" ]]; then
        log_error "Invalid or missing image type: '$IMAGE_TYPE'. Must be 'vm' or 'container'"
        return 1
    fi

    # Canonical uses "ppc64el" (Debian convention) not "ppc64le"
    local CLOUD_ARCH
    CLOUD_ARCH=$(map_arch "$SYSTEM_ARCH") || return 1

    local IMAGE_ALIAS="ubuntu-${VERSION}"
    [[ "$IMAGE_TYPE" == "vm" ]] && IMAGE_ALIAS="${IMAGE_ALIAS}-vm"

    log_info "=========================================="
    log_info "Importing Ubuntu ${VERSION} Cloud Image"
    log_info "Architecture: ${SYSTEM_ARCH} -> ${CLOUD_ARCH}"
    log_info "Image Type: ${IMAGE_TYPE}"
    log_info "Image Alias: ${IMAGE_ALIAS}"
    log_info "Source: ${CLOUDIMG_BASE_URL}/${VERSION}/release/"
    log_info "=========================================="

    if ! check_or_replace_image "$IMAGE_ALIAS" "cloud-img"; then
        return 0
    fi

    local FILE_PREFIX="ubuntu-${VERSION}-server-cloudimg-${CLOUD_ARCH}"
    local METADATA_URL="${CLOUDIMG_BASE_URL}/${VERSION}/release/${FILE_PREFIX}-lxd.tar.xz"
    local IMAGE_URL
    if [[ "$IMAGE_TYPE" == "vm" ]]; then
        IMAGE_URL="${CLOUDIMG_BASE_URL}/${VERSION}/release/${FILE_PREFIX}.img"
    else
        IMAGE_URL="${CLOUDIMG_BASE_URL}/${VERSION}/release/${FILE_PREFIX}.squashfs"
    fi

    local WORKDIR
    WORKDIR=$(mktemp -d)
    local METADATA_FILE="${WORKDIR}/${FILE_PREFIX}-lxd.tar.xz"
    local IMAGE_FILE="${WORKDIR}/${FILE_PREFIX}"
    [[ "$IMAGE_TYPE" == "vm" ]] && IMAGE_FILE="${IMAGE_FILE}.img" || IMAGE_FILE="${IMAGE_FILE}.squashfs"

    cleanup_downloads() { [[ -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }

    log_info "Downloading metadata: ${METADATA_URL}"
    if ! wget -q --show-progress -O "$METADATA_FILE" "$METADATA_URL"; then
        log_error "Failed to download metadata from ${METADATA_URL}"
        cleanup_downloads
        return 1
    fi
    log_success "Metadata downloaded: $(du -h "$METADATA_FILE" | cut -f1)"

    log_info "Downloading ${IMAGE_TYPE} image: ${IMAGE_URL}"
    log_info "This may take several minutes depending on network speed..."
    if ! wget -q --show-progress -O "$IMAGE_FILE" "$IMAGE_URL"; then
        log_error "Failed to download image from ${IMAGE_URL}"
        cleanup_downloads
        return 1
    fi
    log_success "Image downloaded: $(du -h "$IMAGE_FILE" | cut -f1)"

    log_info "Importing into Incus with alias '${IMAGE_ALIAS}'..."
    if ! incus image import "$METADATA_FILE" "$IMAGE_FILE" --alias "$IMAGE_ALIAS"; then
        log_error "Failed to import image into Incus"
        cleanup_downloads
        return 1
    fi
    log_success "Image imported successfully"
    cleanup_downloads

    set_image_source_tag "$IMAGE_ALIAS" "cloud-img"

    log_info "Verifying image import..."
    if check_image_exists "$IMAGE_ALIAS"; then
        log_success "Image '${IMAGE_ALIAS}' verified in Incus"
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

# ---------------------------------------------------------------------------
# Import: Incus Image Server (x86_64 containers only)
# ---------------------------------------------------------------------------

import_incus_ubuntu_image() {
    local VERSION="${1:-}"
    local SYSTEM_ARCH="${2:-$(uname -m)}"

    if [[ "$VERSION" != "22.04" ]] && [[ "$VERSION" != "24.04" ]]; then
        log_error "Invalid Ubuntu version: $VERSION. Must be 22.04 or 24.04"
        return 1
    fi

    if [[ "$SYSTEM_ARCH" != "x86_64" ]]; then
        log_error "Incus image server only supports x86_64, got: $SYSTEM_ARCH"
        return 1
    fi

    local INCUS_ARCH
    INCUS_ARCH=$(map_arch "$SYSTEM_ARCH") || return 1

    local CODENAME
    CODENAME=$(get_ubuntu_codename "$VERSION")
    local IMAGE_ALIAS="ubuntu-${VERSION}"

    log_info "=========================================="
    log_info "Importing Ubuntu ${VERSION} (${CODENAME})"
    log_info "Architecture: ${SYSTEM_ARCH} -> ${INCUS_ARCH}"
    log_info "Image Alias: ${IMAGE_ALIAS}"
    log_info "Source: Incus image server"
    log_info "=========================================="

    if ! check_or_replace_image "$IMAGE_ALIAS" "incus-img"; then
        return 0
    fi

    log_info "Importing image from Incus image server..."
    log_info "Command: incus image copy images:ubuntu/${VERSION}/${INCUS_ARCH} local: --alias ${IMAGE_ALIAS}"
    log_info "This may take a few minutes..."

    if ! incus image copy "images:ubuntu/${VERSION}/${INCUS_ARCH}" local: --alias "$IMAGE_ALIAS" --auto-update; then
        log_error "Failed to import image from Incus image server"
        return 1
    fi

    log_success "Image imported successfully"

    set_image_source_tag "$IMAGE_ALIAS" "incus-img"

    log_info "Verifying image import..."
    if check_image_exists "$IMAGE_ALIAS"; then
        log_success "Image '${IMAGE_ALIAS}' verified in Incus"
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

# ---------------------------------------------------------------------------
# Router: pick the right import method based on flags and architecture
# ---------------------------------------------------------------------------

import_ubuntu_base_image() {
    local IMAGE_TYPE="${1:-}"
    local VERSION="${2:-}"
    local SYSTEM_ARCH="${ARCH:-$(uname -m)}"
    local HELPERS_DIR
    HELPERS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

    if [[ "$IMAGE_TYPE" != "container" ]] && [[ "$IMAGE_TYPE" != "vm" ]]; then
        log_error "Invalid or missing image type: '$IMAGE_TYPE'. Must be 'container' or 'vm'"
        return 1
    fi

    if [[ "$VERSION" != "22.04" ]] && [[ "$VERSION" != "24.04" ]]; then
        log_error "Invalid or missing Ubuntu version: '$VERSION'. Must be 22.04 or 24.04"
        return 1
    fi

    echo ""
    log_info "=========================================="
    log_info " Ubuntu Base Image Import"
    log_info "=========================================="
    echo ""
    log_info "Architecture: ${SYSTEM_ARCH}"
    log_info "Image type:   ${IMAGE_TYPE}"
    log_info "Version:      ${VERSION}"

    if [[ "${USE_INCUS_IMG:-false}" == "true" ]]; then
        case "$SYSTEM_ARCH" in
            x86_64)
                if [[ "$IMAGE_TYPE" == "vm" ]]; then
                    log_info "Import method: Distrobuilder"
                    echo ""
                    # shellcheck source=build-distrobuilder-image.sh disable=SC1091
                    source "${HELPERS_DIR}/build-distrobuilder-image.sh"
                    build_distrobuilder_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "true"
                else
                    log_info "Import method: Incus Image Server"
                    echo ""
                    import_incus_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}"
                fi
                ;;
            ppc64le|s390x)
                log_info "Import method: Distrobuilder"
                echo ""
                local BUILD_VM="false"
                [[ "$IMAGE_TYPE" == "vm" ]] && BUILD_VM="true"
                # shellcheck source=build-distrobuilder-image.sh disable=SC1091
                source "${HELPERS_DIR}/build-distrobuilder-image.sh"
                build_distrobuilder_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"
                ;;
            *)
                log_error "Unsupported architecture: ${SYSTEM_ARCH}"
                return 1
                ;;
        esac
    else
        log_info "Import method: Ubuntu Cloud Images"
        echo ""
        import_cloudimg_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}" "${IMAGE_TYPE}"
    fi
}
