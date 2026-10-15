#!/bin/bash -e
################################################################################
##  File:  install-oc-cli.sh
##  Desc:  Install the OC CLI
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/os.sh
source "$HELPER_SCRIPTS"/install.sh

if is_x64; then
  download_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz"
elif is_arm64; then
  download_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux-arm64.tar.gz"
elif is_ppc64le || is_s390x; then
  download_url="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/latest/openshift-client-linux.tar.gz"
else
  echo "Unsupported architecture"
  exit 1
fi
archive_path=$(download_with_retry "$download_url")

tar xzf "$archive_path" -C "/usr/local/bin" oc
