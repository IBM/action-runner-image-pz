#!/bin/bash -e
################################################################################
##  File:  install-runner-package.sh
##  Desc:  Download and Install runner package
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

SRC=$(readlink -f "${BASH_SOURCE[0]}")
DIR=$(dirname "${SRC}")

if is_x64; then
    package_arch="x64"
elif is_arm64; then
    package_arch="arm64"
elif is_ppc64le || is_s390x; then
    source "${DIR}/configure-runner.sh"
    exit 0
else
    echo "Unsupported architecture"
    exit 1
fi

download_url=$(resolve_github_release_asset_url "actions/runner" "test(\"actions-runner-linux-${package_arch}-[0-9]+\\\\.[0-9]{3}\\\\.[0-9]+\\\\.tar\\\\.gz$\")" "latest")
archive_name="${download_url##*/}"
archive_path=$(download_with_retry "$download_url")

rm -rf /opt/runner-cache
mkdir -p /opt/runner-cache
mv "$archive_path" "/opt/runner-cache/$archive_name"
sudo tar -xf /opt/runner-cache/*.tar.gz -C /opt/runner-cache