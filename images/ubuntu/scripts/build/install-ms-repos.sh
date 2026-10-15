#!/bin/bash -e
################################################################################
##  File:  install-ms-repos.sh
##  Desc:  Install official Microsoft package repos for the distribution
################################################################################

os_label=$(lsb_release -rs)
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

# packages.microsoft.com publishes no ppc64el/s390x packages, and every consumer of this repo
# (install-powershell.sh, install-mssql-tools.sh) is skipped on those architectures
if is_ppc64le || is_s390x; then
    echo "No actions defined for $ARCH architecture."
    exit 0
fi

# Install Microsoft repository
wget https://packages.microsoft.com/config/ubuntu/"$os_label"/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb

# update
install_dpkgs apt-transport-https ca-certificates curl software-properties-common
update_dpkgs
apt-get dist-upgrade
