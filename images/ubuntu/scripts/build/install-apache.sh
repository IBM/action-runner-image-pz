#!/bin/bash -e
################################################################################
##  File:  install-apache.sh
##  Desc:  Install Apache HTTP Server
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh

# Install Apache
if install_dpkgs apache2; then
    # Disable apache2.service only if installation succeeded
    systemctl is-active --quiet apache2.service && systemctl stop apache2.service
    systemctl disable apache2.service || true
else
    echo "Apache2 installation failed or not available for this architecture. Skipping."
    exit 0
fi
