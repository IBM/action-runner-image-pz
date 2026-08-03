#!/bin/bash
set -euo pipefail
################################################################################
##  File:  install-incus.sh
##  Desc:  Install Incus from source for Ubuntu (orchestrator)
##  Note:  Sources per-step scripts for each installation phase.
##         Supports: ppc64le, s390x, x86_64
################################################################################

exec > >(tee -i /tmp/install-incus.log)
exec 2>&1

# --------------------------------------------------
# Environment Setup
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
SCRIPT_HELPER_SCRIPTS="${SCRIPT_DIR}/../helpers"

# shellcheck disable=SC1091
source "$SCRIPT_HELPER_SCRIPTS"/install.sh

ARCH="${ARCH:-$(uname -m)}"
CONFIG_FILE="${REPO_ROOT}/scripts/assets/incus_init_host_${ARCH}.yml"

# Version configuration (can be overridden via environment variables)
RAFT_VERSION="${RAFT_VERSION:-v0.22.1}"
INCUS_VERSION="${INCUS_VERSION:-v7.0.1}"

# LVM configuration (can be overridden via environment variables)
USE_LVM="${USE_LVM:-true}"
LVM_LOOP_SIZE="${LVM_LOOP_SIZE:-200G}"
LVM_VG_NAME="${LVM_VG_NAME:-vg_incus}"
LVM_LOOP_FILE="/var/lib/incus/disks/incus-lvm.img"

# Export so sourced step scripts can access them
export ARCH RAFT_VERSION INCUS_VERSION USE_LVM LVM_LOOP_SIZE LVM_VG_NAME LVM_LOOP_FILE CONFIG_FILE

# --------------------------------------------------
# Skip build/install if Incus is already installed and daemon is healthy
# --------------------------------------------------
SKIP_INCUS_BUILD=false
if command -v incus >/dev/null 2>&1 && \
   incus admin waitready --timeout=5 >/dev/null 2>&1 && \
   ip link show incusbr0 >/dev/null 2>&1; then
    INSTALLED_VERSION=$(/usr/local/bin/incus --version 2>/dev/null | head -n1 || echo "unknown")
    echo "[INFO] Incus already installed (version: ${INSTALLED_VERSION}), daemon healthy, bridge up — skipping build."
    SKIP_INCUS_BUILD=true
fi

if [ "$SKIP_INCUS_BUILD" = "false" ]; then

echo "=================================================="
echo " Installing Incus Environment"
echo " Architecture : ${ARCH}"
echo " Storage      : $([ "$USE_LVM" = "true" ] && echo "LVM ($LVM_VG_NAME)" || echo "DIR")"
echo " Config File  : ${CONFIG_FILE}"
echo "=================================================="

# --------------------------------------------------
# Install Dependencies
# --------------------------------------------------

echo "[INFO] Installing dependencies..."
update_dpkgs

install_dpkgs \
    git \
    gcc \
    g++ \
    make \
    golang \
    wget \
    lvm2 \
    thin-provisioning-tools \
    curl \
    tar \
    xz-utils \
    rsync \
    libsqlite3-dev \
    uuid-dev \
    lxc \
    lxc-dev \
    dnsmasq \
    squashfs-tools \
    autoconf \
    automake \
    libtool \
    pkg-config \
    acl \
    attr \
    libcap-dev \
    libacl1-dev \
    libattr1-dev \
    liblz4-dev \
    libuv1-dev \
    gettext \
    libsystemd-dev

# --------------------------------------------------
# Step 1: Build and install raft
# --------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-raft.sh"

# --------------------------------------------------
# Step 2: Build and install cowsql
# --------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-cowsql.sh"

# --------------------------------------------------
# Step 3: Build and install Incus binary
# --------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-incus-bin.sh"

# --------------------------------------------------
# Step 4: Setup LVM storage
# --------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/setup-lvm.sh"

# --------------------------------------------------
# Step 5: Start Incus daemon
# --------------------------------------------------

# If incusd is already running and responding, skip the restart entirely.
if /usr/local/bin/incus admin waitready --timeout=5 >/dev/null 2>&1; then
    echo "[INFO] incusd is already running and healthy — skipping restart."
else
    echo "[INFO] Starting incusd..."

    if pgrep -x incusd >/dev/null 2>&1; then
        echo "[INFO] Stopping unresponsive incusd..."
        pkill -9 incusd 2>/dev/null || true
        sleep 1
    fi
    rm -f /run/incus/unix.socket
    rm -f /var/run/incus/unix.socket
    rm -f /var/lib/incus/unix.socket

    INCUSD_LOG=$(mktemp /tmp/incusd.XXXX.log)
    export INCUSD_LOG
    echo "[INFO] incusd log: $INCUSD_LOG"

    nohup /usr/local/bin/incusd --group incus-admin >"$INCUSD_LOG" 2>&1 &

    echo "[INFO] Waiting for incusd to become ready..."
    for _ in {1..30}; do
        if /usr/local/bin/incus admin waitready --timeout=1 >/dev/null 2>&1; then
            break
        fi
        if ! pgrep -x incusd >/dev/null 2>&1; then
            echo "[ERROR] incusd exited unexpectedly"
            cat "$INCUSD_LOG"
            exit 1
        fi
        sleep 1
    done

    echo "[INFO] Verifying daemon..."
    if ! /usr/local/bin/incus admin waitready --timeout=5 >/dev/null 2>&1; then
        echo "[ERROR] incusd is not responding"
        cat "$INCUSD_LOG"
        exit 1
    fi
fi

fi # end SKIP_INCUS_BUILD

# --------------------------------------------------
# Step 6: Initialize network, storage, and profile
# --------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/setup-incus-network.sh"

# --------------------------------------------------
# Validation
# --------------------------------------------------

echo "[INFO] Running validation..."
/usr/local/bin/incus version
/usr/local/bin/incus network list
/usr/local/bin/incus storage list
/usr/local/bin/incus profile show default

echo "=================================================="
echo " Incus installation completed successfully"
echo "=================================================="

echo ""
echo "[INFO] Incus installation and configuration completed"
echo "[INFO] Base image import will be handled by the calling script"
echo ""
