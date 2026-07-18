#!/bin/bash
################################################################################
##  File:  import_ubuntu_base_images.sh
##  Desc:  Architecture-aware Ubuntu base image import for Incus
##  Usage: Source this file and call import_ubuntu_base_images [container|vm] [version]
##         Automatically selects import method based on system architecture:
##         - x86_64/aarch64: Uses Incus image server (fast, pre-configured)
##         - ppc64le/s390x: Uses Distrobuilder (custom build required)
##  Args:  $1 - Image type: "container" (default) or "vm"
##         $2 - Ubuntu version: "22.04" or "24.04" (required)
################################################################################

# Note: Do NOT use 'set -e' in sourced scripts as it affects the parent shell

import_ubuntu_base_images() {
    local IMAGE_TYPE="${1:-container}"  # Default to container if not specified
    local VERSION="${2:-}"
    local ORIGINAL_DIR
    ORIGINAL_DIR=$(pwd)
    local SYSTEM_ARCH="${ARCH:-$(uname -m)}"
    local HELPERS_DIR="${HELPERS_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"

    # Validate image type
    if [[ "$IMAGE_TYPE" != "container" ]] && [[ "$IMAGE_TYPE" != "vm" ]]; then
        echo "Error: Invalid image type: $IMAGE_TYPE"
        echo "Must be 'container' or 'vm'"
        return 1
    fi

    # Validate version
    if [[ "$VERSION" != "22.04" ]] && [[ "$VERSION" != "24.04" ]]; then
        echo "Error: Invalid or missing Ubuntu version: '${VERSION}'"
        echo "Must be 22.04 or 24.04"
        return 1
    fi

    echo ""
    echo "=========================================="
    echo " Ubuntu Base Image Import"
    echo "=========================================="
    echo ""
    echo "Detected system architecture: ${SYSTEM_ARCH}"
    echo "Image type: ${IMAGE_TYPE}"
    echo "Ubuntu version: ${VERSION}"
    echo ""

    # Determine import method based on architecture
    local IMPORT_METHOD
    local METHOD_DESC

    case "$SYSTEM_ARCH" in
        x86_64|aarch64)
            if [[ "$IMAGE_TYPE" == "vm" ]]; then
                IMPORT_METHOD="distrobuilder"
                METHOD_DESC="Distrobuilder (VM images not available on Incus server)"
            else
                IMPORT_METHOD="incus-server"
                METHOD_DESC="Incus Image Server (fast, pre-configured images)"
            fi
            ;;
        ppc64le|s390x)
            IMPORT_METHOD="distrobuilder"
            METHOD_DESC="Distrobuilder (custom build from source)"
            ;;
        *)
            echo "Error: Unsupported architecture: ${SYSTEM_ARCH}"
            echo "Supported architectures: x86_64, aarch64, ppc64le, s390x"
            cd "$ORIGINAL_DIR" || return 1
            return 1
            ;;
    esac

    echo "Import method: ${METHOD_DESC}"
    echo ""

    local BUILD_VM="false"
    [[ "$IMAGE_TYPE" == "vm" ]] && BUILD_VM="true"

    if [ "$IMPORT_METHOD" = "incus-server" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${HELPERS_DIR}/import-incus-ubuntu-image.sh"
        echo "Importing Ubuntu ${VERSION} from Incus image server..."
        if ! import_incus_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}"; then
            echo "Error: Failed to import Ubuntu ${VERSION}"
            cd "$ORIGINAL_DIR" || return 1
            return 1
        fi
    else
        # shellcheck disable=SC1090,SC1091
        source "${HELPERS_DIR}/build-distrobuilder-image.sh"
        echo "Building Ubuntu ${VERSION} ${IMAGE_TYPE} with Distrobuilder..."
        if ! build_distrobuilder_ubuntu_image "${VERSION}" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"; then
            echo "Error: Failed to build Ubuntu ${VERSION} ${IMAGE_TYPE}"
            cd "$ORIGINAL_DIR" || return 1
            return 1
        fi
    fi

    cd "$ORIGINAL_DIR" || return 1

    echo ""
    echo "=========================================="
    echo "Image import step completed successfully"
    echo "=========================================="
    echo ""

    return 0
}
