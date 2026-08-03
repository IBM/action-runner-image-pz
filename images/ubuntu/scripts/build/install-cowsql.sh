#!/bin/bash
################################################################################
##  File:  install-cowsql.sh
##  Desc:  Build and install cowsql from source (dependency for Incus)
##  Note:  Sourced by install-incus.sh. Expects PKG_CONFIG_PATH and
##         LD_LIBRARY_PATH to be set by the caller (via install-raft.sh).
################################################################################

echo "[INFO] Building cowsql..."

if pkg-config --exists cowsql 2>/dev/null; then
    INSTALLED_VERSION=$(pkg-config --modversion cowsql 2>/dev/null || echo "unknown")
    echo "[INFO] cowsql already installed (version: $INSTALLED_VERSION), skipping build"
else
    echo "[INFO] cowsql not found, building from source..."
    cd /tmp || exit 1

    if [ ! -d cowsql ]; then
        git clone https://github.com/cowsql/cowsql.git
    fi

    cd cowsql || exit 1
    autoreconf -i
    ./configure
    make -j"$(nproc)"
    make install
    echo "[INFO] cowsql installed successfully"
fi

echo "[INFO] Configuring shared libraries..."
echo "/usr/local/lib" > /etc/ld.so.conf.d/incus.conf
ldconfig
ldconfig -p | grep cowsql
