#!/bin/bash
################################################################################
##  File:  install-pipx-packages.sh
##  Desc:  Install tools via pipx
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh

export PATH="$PATH:/opt/pipx_bin"

pipx_packages=$(get_toolset_value ".pipx[] .package")

for package in $pipx_packages; do
    echo "Install $package into default python"
    if pipx install "$package"; then
        echo "Successfully installed $package"
        
        # https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html
        # Install ansible into an existing ansible-core Virtual Environment
        if [[ $package == "ansible-core" ]]; then
            if pipx inject "$package" ansible; then
                echo "Successfully injected ansible into ansible-core"
            else
                echo "Warning: Failed to inject ansible into ansible-core. Continuing..."
            fi
        fi
    else
        echo "Warning: Failed to install $package. This may be due to architecture limitations. Continuing..."
    fi
done

exit 0
