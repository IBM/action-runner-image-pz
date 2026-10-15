#!/bin/bash -e
################################################################################
##  File:  install-packer.sh
##  Desc:  Install packer
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_x64; then
  packer_arch="amd64"
elif is_arm64; then
  packer_arch="arm64"
elif is_ppc64le; then
  packer_arch="ppc64le"
elif is_s390x; then
  echo "Packer is not officially available for the s390x architecture."
  exit 0
else
  echo "Unsupported architecture"
  exit 1
fi

# Install Packer
download_url=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/packer/latest | jq -r ".builds[] | select((.arch==\"$packer_arch\") and (.os==\"linux\")).url")
archive_path=$(download_with_retry "$download_url")
unzip -o -qq "$archive_path" -d /usr/local/bin
