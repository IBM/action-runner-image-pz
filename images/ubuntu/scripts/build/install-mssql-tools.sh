#!/bin/bash -e
################################################################################
##  File:  install-mssql-tools.sh
##  Desc:  Install MS SQL Server client tools (https://docs.microsoft.com/en-us/sql/linux/sql-server-linux-setup-tools?view=sql-server-2017)
################################################################################
# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_ppc64le || is_s390x; then
    echo "No actions defined for $ARCH architecture."
    exit 0
fi

export ACCEPT_EULA=Y

update_dpkgs
install_dpkgs mssql-tools unixodbc-dev
apt-get -f install
ln -sf /opt/mssql-tools/bin/* /usr/local/bin/



