#!/bin/bash -e
################################################################################
##  File:  install-nvm.sh
##  Desc:  Install Nvm
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/etc-environment.sh

export NVM_DIR="/etc/skel/.nvm"
mkdir -p "$NVM_DIR"

if [ ! -f "$NVM_DIR/nvm.sh" ]; then
    nvm_version=$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r '.tag_name')
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/"$nvm_version"/install.sh | bash
else
    echo "NVM already installed at $NVM_DIR. Skipping installation."
fi

# shellcheck disable=SC2016
set_etc_environment_variable "NVM_DIR" '$HOME/.nvm'

# shellcheck disable=SC2016
grep -qF "nvm.sh" /etc/skel/.bash_profile || echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' | tee -a /etc/skel/.bash_profile
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# set system node.js as default one
nvm alias default system
