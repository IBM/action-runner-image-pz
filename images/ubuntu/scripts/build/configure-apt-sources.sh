#!/bin/bash -e
################################################################################
##  File:  configure-apt-sources.sh
##  Desc:  Configure apt sources with failover from Azure to Ubuntu archives.
################################################################################

# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/os.sh

touch /etc/apt/apt-mirrors.txt

printf "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n" | tee -a /etc/apt/apt-mirrors.txt
printf "https://archive.ubuntu.com/ubuntu/\tpriority:2\n" | tee -a /etc/apt/apt-mirrors.txt
printf "https://security.ubuntu.com/ubuntu/\tpriority:3\n" | tee -a /etc/apt/apt-mirrors.txt

# Support both deb822 format (ubuntu.sources) and classic format (sources.list)
# Check which format is present and configure accordingly
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    # Ubuntu 24.04+ with deb822 format
    sed -i 's|http://azure\.archive\.ubuntu\.com/ubuntu/|mirror+file:/etc/apt/apt-mirrors.txt|' /etc/apt/sources.list.d/ubuntu.sources
    
    # Apt changes to survive Cloud Init
    if [ -d /etc/cloud/templates ]; then
        cp -f /etc/apt/sources.list.d/ubuntu.sources /etc/cloud/templates/sources.list.ubuntu.deb822.tmpl
    fi
elif [ -f /etc/apt/sources.list ]; then
    # Classic format (Ubuntu 22.04 or distrobuilder images)
    sed -i 's|http://azure\.archive\.ubuntu\.com/ubuntu/|mirror+file:/etc/apt/apt-mirrors.txt|' /etc/apt/sources.list
    
    # Also handle ports.ubuntu.com for non-x86 architectures (distrobuilder default)
    sed -i 's|http://ports\.ubuntu\.com/ubuntu-ports/|mirror+file:/etc/apt/apt-mirrors.txt|' /etc/apt/sources.list
    
    # Apt changes to survive Cloud Init
    if [ -d /etc/cloud/templates ]; then
        cp -f /etc/apt/sources.list /etc/cloud/templates/sources.list.ubuntu.tmpl
    fi
else
    echo "Warning: No APT sources file found to configure"
fi
