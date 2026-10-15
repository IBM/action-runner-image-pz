#!/bin/bash -e
################################################################################
##  File:  install-azure-devops-cli.sh
##  Desc:  Install Azure DevOps CLI (az devops)
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/etc-environment.sh
source "$HELPER_SCRIPTS"/os.sh

if is_ppc64le || is_s390x; then
    echo "No actions defined for $ARCH architecture."
    exit 0
fi

# AZURE_EXTENSION_DIR shell variable defines where modules are installed
# https://docs.microsoft.com/en-us/cli/azure/azure-cli-extensions-overview
export AZURE_EXTENSION_DIR=/opt/az/azcliextensions
set_etc_environment_variable "AZURE_EXTENSION_DIR" "${AZURE_EXTENSION_DIR}"

# install azure devops Cli extension
az extension add -n azure-devops
