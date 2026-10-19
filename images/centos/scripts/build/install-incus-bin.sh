#!/bin/bash
################################################################################
##  File:  install-incus-bin.sh
##  Desc:  Build and install the Incus binary from source (CentOS/AlmaLinux)
##  Note:  Sourced by install-incus.sh. Expects INCUS_VERSION to be set
##         by the caller. Skips build if the installed version matches.
################################################################################

echo "[INFO] Building Incus..."

# Check if Incus is already installed
if command -v incus >/dev/null 2>&1; then
    # Use the client binary version (not incusd --version which returns the
    # running server version and can differ from the installed binary version)
    INSTALLED_VERSION=$(/usr/local/bin/incus --version 2>/dev/null | head -n1 || echo "unknown")
    echo "[INFO] Incus already installed (version: $INSTALLED_VERSION)"

    # Compare full version string against target
    if echo "$INSTALLED_VERSION" | grep -q "${INCUS_VERSION#v}"; then
        echo "[INFO] Incus version matches ${INCUS_VERSION}, skipping build"
    else
        echo "[INFO] Incus version mismatch (installed: $INSTALLED_VERSION, expected: ${INCUS_VERSION#v}), rebuilding..."
        BUILD_INCUS=true
    fi
else
    echo "[INFO] Incus not found, building from source..."
    BUILD_INCUS=true
fi

if [ "${BUILD_INCUS:-false}" = "true" ]; then
    cd /tmp || exit 1

    # Remove stale/incomplete clone from a previous partial run
    if [ -d incus ] && [ ! -f incus/Makefile ]; then
        echo "[INFO] Removing incomplete incus directory from previous run..."
        rm -rf incus
    fi

    if [ ! -d incus ]; then
        git clone --branch "${INCUS_VERSION}" https://github.com/lxc/incus.git || {
            echo "[ERROR] Failed to clone incus repository (branch: ${INCUS_VERSION})"
            exit 1
        }
    fi

    cd incus || exit 1
    make

    GOBIN="$(go env GOPATH)/bin"

    test -f "${GOBIN}/incusd"

    install -m 755 "${GOBIN}/incus" /usr/local/bin/
    install -m 755 "${GOBIN}/incusd" /usr/local/bin/
    install -m 755 "${GOBIN}/incus-agent" /usr/local/bin/
    install -m 755 "${GOBIN}/incus-migrate" /usr/local/bin/

    echo "[INFO] Incus installed successfully"
fi

/usr/local/bin/incusd --version

echo "[INFO] Configuring Incus groups..."
getent group incus       >/dev/null || groupadd --system incus
getent group incus-admin >/dev/null || groupadd --system incus-admin
usermod -aG incus,incus-admin root

echo "[INFO] Configuring idmap..."
# Every container gets root's whole range. 65536 IDs leaves none for rootless
# podman (runner:100000:65536) inside a job, so match the production hosts
# (actions-deploy tasks/incus_idmap.yml). incusd reads these only at start-up.
INCUS_IDMAP="${INCUS_IDMAP:-1000000:1000000000}"
sed -i '/^root:/d' /etc/subuid
echo "root:${INCUS_IDMAP}" >> /etc/subuid
sed -i '/^root:/d' /etc/subgid
echo "root:${INCUS_IDMAP}" >> /etc/subgid
echo "[INFO] subuid: $(grep ^root /etc/subuid)"
echo "[INFO] subgid: $(grep ^root /etc/subgid)"

chmod u+s /usr/bin/newuidmap
chmod u+s /usr/bin/newgidmap
