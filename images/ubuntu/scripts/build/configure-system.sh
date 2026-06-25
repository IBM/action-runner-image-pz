#!/bin/bash -e
################################################################################
##  File: configure-system.sh
##  Desc: Post deployment system configuration actions
################################################################################
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/etc-environment.sh
source "$HELPER_SCRIPTS"/os.sh

if [ -d "/opt/post-generation" ]; then
    rm -rf "/opt/post-generation"
fi
mv -f "${IMAGE_FOLDER}/post-generation" /opt

echo "chmod -R 777 /opt"
chmod -R 777 /opt
echo "chmod -R 777 /usr/share"
chmod -R 777 /usr/share

chmod 755 "$IMAGE_FOLDER"

# Remove quotes around PATH
ENVPATH=$(grep 'PATH=' /etc/environment | head -n 1 | sed -z 's/^PATH=*//')
ENVPATH=${ENVPATH#"\""}
ENVPATH=${ENVPATH%"\""}
replace_etc_environment_variable "PATH" "${ENVPATH}"
echo "Updated /etc/environment: $(cat /etc/environment)"

# Clean yarn and npm cache (only if installed)
if command -v yarn > /dev/null 2>&1; then
    echo "Cleaning yarn cache..."
    yarn cache clean
else
    echo "Yarn not installed, skipping cache clean"
fi

if command -v npm > /dev/null 2>&1; then
    echo "Cleaning npm cache..."
    npm cache clean --force
else
    echo "npm not installed, skipping cache clean"
fi

if is_ubuntu24; then
    # Prevent needrestart from restarting the provisioner service.
    # Currently only happens on Ubuntu 24.04, so make it conditional for the time being
    # as configuration is too different between Ubuntu versions.
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sed -i '/^\s*};/i \    qr(^runner-provisioner) => 0,' /etc/needrestart/needrestart.conf
    else
        echo "needrestart not installed, skipping configuration"
    fi
fi
