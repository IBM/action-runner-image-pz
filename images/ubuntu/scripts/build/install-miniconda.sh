#!/bin/bash -e
################################################################################
##  File:  install-miniconda.sh
##  Desc:  Install miniconda
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/etc-environment.sh

CONDA=/usr/share/miniconda

if [ ! -d "$CONDA" ]; then
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-"${ARCH}".sh -o miniconda.sh \
        && chmod +x miniconda.sh \
        && ./miniconda.sh -b -p "$CONDA" \
        && rm miniconda.sh
else
    echo "Miniconda directory already exists at $CONDA. Skipping installation."
fi

set_etc_environment_variable "CONDA" "${CONDA}"

ln -sf "$CONDA/bin/conda" /usr/bin/conda