#!/bin/bash -e
################################################################################
##  File:  install-bicep.sh
##  Desc:  Install bicep cli
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_x64; then
    package_arch="x64"
elif is_arm64; then
    package_arch="arm64"
elif is_ppc64le || is_s390x; then
    echo "No actions defined for $ARCH architecture."
    exit 0
else
    echo "Unsupported architecture"
    exit 1
fi

# Install Bicep CLI
download_url=$(resolve_github_release_asset_url "Azure/bicep" "endswith(\"bicep-linux-${package_arch}\")" "latest")
bicep_binary_path=$(download_with_retry "${download_url}")

# Mark it as executable
install "$bicep_binary_path" /usr/local/bin/bicep


