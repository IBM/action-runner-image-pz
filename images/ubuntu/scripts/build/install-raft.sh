#!/bin/bash
################################################################################
##  File:  install-raft.sh
##  Desc:  Build and install raft from source (dependency for cowsql/Incus)
##  Note:  Sourced by install-incus.sh. Expects RAFT_VERSION,
##         PKG_CONFIG_PATH and LD_LIBRARY_PATH to be set by the caller.
################################################################################

echo "[INFO] Building raft..."

if pkg-config --exists raft 2>/dev/null; then
    INSTALLED_VERSION=$(pkg-config --modversion raft 2>/dev/null || echo "unknown")
    echo "[INFO] raft already installed (version: $INSTALLED_VERSION), skipping build"
else
    echo "[INFO] raft not found, building from source..."
    cd /tmp || exit 1

    if [ ! -d raft ]; then
        git clone --branch "${RAFT_VERSION}" https://github.com/cowsql/raft.git
    fi

    cd raft || exit 1
    autoreconf -i
    ./configure
    make -j"$(nproc)"
    make install
    echo "[INFO] raft installed successfully"
fi

# Export paths so subsequent steps can find raft headers and libs
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"

ldconfig

echo "Verifying raft installation..."
pkg-config --modversion raft
