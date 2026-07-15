#!/bin/bash
################################################################################
##  File:  import_ubuntu_base_images.sh
##  Desc:  Architecture-aware Ubuntu base image import for Incus
##  Usage: Source this file and call import_ubuntu_base_images [container|vm]
##         Automatically selects import method based on system architecture:
##         - x86_64/aarch64: Uses Incus image server (fast, pre-configured)
##         - ppc64le/s390x: Uses Distrobuilder (custom build required)
##  Args:  $1 - Image type: "container" (default) or "vm"
################################################################################

# Note: Do NOT use 'set -e' in sourced scripts as it affects the parent shell

import_ubuntu_base_images() {
    local IMAGE_TYPE="${1:-container}"  # Default to container if not specified
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
    
    echo ""
    echo "=========================================="
    echo " Ubuntu Base Image Import"
    echo "=========================================="
    echo ""
    echo "Detected system architecture: ${SYSTEM_ARCH}"
    echo "Image type: ${IMAGE_TYPE}"
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
    echo "Choose Ubuntu version to import:"
    echo "1) Ubuntu 22.04 LTS (Jammy)"
    echo "2) Ubuntu 24.04 LTS (Noble)"
    echo "3) Both versions"
    echo "4) Skip (use existing images)"
    echo ""
    
    read -r -p "Enter choice [1-4]: " version_choice
    
    case "$version_choice" in
        1)
            echo ""
            if [ "$IMPORT_METHOD" = "incus-server" ]; then
                echo "Importing Ubuntu 22.04 from Incus image server..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/import-incus-ubuntu-image.sh"
                if ! import_incus_ubuntu_image "22.04" "${SYSTEM_ARCH}"; then
                    echo "Error: Failed to import Ubuntu 22.04"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            else
                echo "Building Ubuntu 22.04 ${IMAGE_TYPE} with Distrobuilder..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/build-distrobuilder-image.sh"
                local BUILD_VM="false"
                [[ "$IMAGE_TYPE" == "vm" ]] && BUILD_VM="true"
                if ! build_distrobuilder_ubuntu_image "22.04" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"; then
                    echo "Error: Failed to build Ubuntu 22.04 ${IMAGE_TYPE}"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            fi
            ;;
        2)
            echo ""
            if [ "$IMPORT_METHOD" = "incus-server" ]; then
                echo "Importing Ubuntu 24.04 from Incus image server..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/import-incus-ubuntu-image.sh"
                if ! import_incus_ubuntu_image "24.04" "${SYSTEM_ARCH}"; then
                    echo "Error: Failed to import Ubuntu 24.04"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            else
                echo "Building Ubuntu 24.04 ${IMAGE_TYPE} with Distrobuilder..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/build-distrobuilder-image.sh"
                local BUILD_VM="false"
                [[ "$IMAGE_TYPE" == "vm" ]] && BUILD_VM="true"
                if ! build_distrobuilder_ubuntu_image "24.04" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"; then
                    echo "Error: Failed to build Ubuntu 24.04 ${IMAGE_TYPE}"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            fi
            ;;
        3)
            echo ""
            if [ "$IMPORT_METHOD" = "incus-server" ]; then
                echo "Importing Ubuntu 22.04 from Incus image server..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/import-incus-ubuntu-image.sh"
                if ! import_incus_ubuntu_image "22.04" "${SYSTEM_ARCH}"; then
                    echo "Error: Failed to import Ubuntu 22.04"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
                echo ""
                echo "Importing Ubuntu 24.04 from Incus image server..."
                if ! import_incus_ubuntu_image "24.04" "${SYSTEM_ARCH}"; then
                    echo "Error: Failed to import Ubuntu 24.04"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            else
                echo "Building Ubuntu 22.04 ${IMAGE_TYPE} with Distrobuilder..."
                # shellcheck disable=SC1090,SC1091
                source "${HELPERS_DIR}/build-distrobuilder-image.sh"
                local BUILD_VM="false"
                [[ "$IMAGE_TYPE" == "vm" ]] && BUILD_VM="true"
                if ! build_distrobuilder_ubuntu_image "22.04" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"; then
                    echo "Error: Failed to build Ubuntu 22.04 ${IMAGE_TYPE}"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
                echo ""
                echo "Building Ubuntu 24.04 ${IMAGE_TYPE} with Distrobuilder..."
                if ! build_distrobuilder_ubuntu_image "24.04" "${SYSTEM_ARCH}" "$HOME/incus-images/official-ubuntu" "$BUILD_VM"; then
                    echo "Error: Failed to build Ubuntu 24.04 ${IMAGE_TYPE}"
                    cd "$ORIGINAL_DIR" || return 1
                    return 1
                fi
            fi
            ;;
        4)
            echo ""
            echo "Skipping image import. Using existing images."
            ;;
        *)
            echo ""
            echo "Invalid choice. Skipping image import."
            cd "$ORIGINAL_DIR" || return 1
            return 1
            ;;
    esac
    
    cd "$ORIGINAL_DIR" || return 1
    
    echo ""
    echo "=========================================="
    echo "Image import step completed successfully"
    echo "=========================================="
    echo ""
    
    return 0
}
