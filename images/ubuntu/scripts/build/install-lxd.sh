#!/bin/bash -e
################################################################################
##  File:  install-lxd.sh
##  Desc:  Install lxd
################################################################################
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh

LATEST_LTS_CHANNEL=$(snap info lxd | grep -E '(^\s*[0-9]+\.0/stable)' | awk '{print $1}' | sed 's|/stable:||' | sort -rV | head -n 1)

if [ -n "$LATEST_LTS_CHANNEL" ]; then
    echo "The latest LTS channel is: ${LATEST_LTS_CHANNEL}/stable"
else
    echo "Could not determine the latest LTS channel."
fi

# Install 5.21 LTS LXD version using snap
echo "Installing LXD version ${LATEST_LTS_CHANNEL} using snap..."
sudo snap install lxd --channel="${LATEST_LTS_CHANNEL}/stable"

echo "Checking list of refreshable snaps..."
sudo snap refresh --list

echo "Checking the status of snap.lxd.daemon..."
ensure_service_is_active snap.lxd.daemon

# Hold the autorefresh for LXD as it can cause unwanted service-disruptions 
sudo snap refresh --hold lxd

# Detect Environment (Host vs Container)
# We default to 'host'
ENV_TYPE="host"

# Check using systemd-detect-virt (standard on most modern distros)
# If it returns 'lxc', we are inside a container.
if command -v systemd-detect-virt >/dev/null 2>&1; then
    if [[ "$(systemd-detect-virt)" == "lxc" ]]; then
        ENV_TYPE="container"
    fi
# Fallback check: Look at process 1 environment for container flag
elif grep -qa "container=lxc" /proc/1/environ; then
    ENV_TYPE="container"
fi

CONFIG_FILENAME="lxd_init_${ENV_TYPE}_${ARCH}.yml"
CONFIG_PATH="$INSTALLER_SCRIPT_FOLDER/$CONFIG_FILENAME"

echo "----------------------------------------"
echo "LXD Initialization Setup"
echo "Detected Architecture : $ARCH"
echo "Detected Environment  : $ENV_TYPE"
echo "Target Config File    : $CONFIG_FILENAME"
echo "----------------------------------------"

echo "Initializing LXD with preseed configuration..."

if [[ -f "$CONFIG_PATH" ]]; then
    # shellcheck disable=SC2002
    cat "$CONFIG_PATH" | sudo /snap/bin/lxd init --preseed
    
    # Check if the command succeeded
    # shellcheck disable=SC2181
    if [[ $? -eq 0 ]]; then
        echo "Success: LXD initialized using $CONFIG_FILENAME"
    else
        echo "Error: LXD initialization failed."
        exit 1
    fi
else
    echo "Warning: $CONFIG_FILENAME not found at $INSTALLER_SCRIPT_FOLDER."
    echo "Falling back to default auto initialization..."
    sudo /snap/bin/lxd init --auto
fi

echo "LXD installation and initialization are complete!"