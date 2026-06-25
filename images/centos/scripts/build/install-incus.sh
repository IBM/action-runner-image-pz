#!/bin/bash
set -euo pipefail
################################################################################
##  File:  install-incus.sh
##  Desc:  Install Incus from source for CentOS/AlmaLinux
##  Note:  Builds Incus from source for consistency across architectures
##         Supports: ppc64le, s390x, x86_64
################################################################################

exec > >(tee -i /tmp/install-incus.log)
exec 2>&1

# --------------------------------------------------
# Environment Setup
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${SCRIPT_DIR}/../helpers}"

# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh

ARCH="${ARCH:-$(uname -m)}"
CONFIG_FILE="${REPO_ROOT}/scripts/assets/incus_init_host_${ARCH}.yml"

# Version configuration (can be overridden via environment variables)
RAFT_VERSION="${RAFT_VERSION:-v0.22.1}"
INCUS_VERSION="${INCUS_VERSION:-v7.1.0}"

# LVM configuration (can be overridden via environment variables)
USE_LVM="${USE_LVM:-true}"
LVM_LOOP_SIZE="${LVM_LOOP_SIZE:-200G}"
LVM_VG_NAME="${LVM_VG_NAME:-vg_incus}"
LVM_LOOP_FILE="/var/lib/incus/disks/incus-lvm.img"

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
dnf install -y \
    git \
    gcc \
    gcc-c++ \
    make \
    golang \
    wget \
    curl \
    tar \
    lvm2 \
    device-mapper-persistent-data \
    xz \
    rsync \
    sqlite-devel \
    libuuid-devel \
    lxc \
    lxc-devel \
    dnsmasq \
    firewalld \
    shadow-utils \
    podman \
    buildah \
    fuse-overlayfs \
    slirp4netns \
    squashfs-tools \
    autoconf \
    automake \
    libtool \
    pkg-config \
    acl \
    libacl-devel \
    attr \
    libattr-devel \
    libcap-devel \
    lz4-devel \
    libuv-devel \
    gettext \
    systemd-devel

# --------------------------------------------------
# Build raft
# --------------------------------------------------

echo "[INFO] Building raft..."

# Check if raft is already installed
if pkg-config --exists raft 2>/dev/null; then
    INSTALLED_VERSION=$(pkg-config --modversion raft 2>/dev/null || echo "unknown")
    echo "[INFO] raft already installed (version: $INSTALLED_VERSION), skipping build"
else
    echo "[INFO] raft not found, building from source..."
    cd /tmp

    if [ ! -d raft ]; then
        git clone --branch "${RAFT_VERSION}" https://github.com/cowsql/raft.git
    fi

    cd raft
    autoreconf -i
    ./configure
    make -j"$(nproc)"
    make install
    echo "[INFO] raft installed successfully"
fi

# Export PKG_CONFIG_PATH for subsequent builds
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"

ldconfig

# Verify raft installation
echo "Verifying raft installation..."
pkg-config --modversion raft

# --------------------------------------------------
# Build cowsql
# --------------------------------------------------

echo "[INFO] Building cowsql..."

# Check if cowsql is already installed
if pkg-config --exists cowsql 2>/dev/null; then
    INSTALLED_VERSION=$(pkg-config --modversion cowsql 2>/dev/null || echo "unknown")
    echo "[INFO] cowsql already installed (version: $INSTALLED_VERSION), skipping build"
else
    echo "[INFO] cowsql not found, building from source..."
    cd /tmp

    if [ ! -d cowsql ]; then
        git clone https://github.com/cowsql/cowsql.git
    fi

    cd cowsql
    autoreconf -i
    ./configure
    make -j"$(nproc)"
    make install
    echo "[INFO] cowsql installed successfully"
fi

# --------------------------------------------------
# Configure Shared Libraries
# --------------------------------------------------

echo "[INFO] Configuring shared libraries..."
echo "/usr/local/lib" > /etc/ld.so.conf.d/incus.conf
ldconfig
ldconfig -p | grep cowsql

# --------------------------------------------------
# Build Incus
# --------------------------------------------------

echo "[INFO] Building Incus..."

# Check if Incus is already installed
if command -v incusd >/dev/null 2>&1; then
    INSTALLED_VERSION=$(incusd --version 2>/dev/null | head -n1 || echo "unknown")
    echo "[INFO] Incus already installed (version: $INSTALLED_VERSION)"
    
    # Check if version matches
    if echo "$INSTALLED_VERSION" | grep -q "${INCUS_VERSION#v}"; then
        echo "[INFO] Incus version matches ${INCUS_VERSION}, skipping build"
    else
        echo "[INFO] Incus version mismatch, rebuilding..."
        BUILD_INCUS=true
    fi
else
    echo "[INFO] Incus not found, building from source..."
    BUILD_INCUS=true
fi

if [ "${BUILD_INCUS:-false}" = "true" ]; then
    cd /tmp

    if [ ! -d incus ]; then
        git clone --branch "${INCUS_VERSION}" https://github.com/lxc/incus.git
    fi

    cd incus
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

# --------------------------------------------------
# Configure User Namespace Mapping
# --------------------------------------------------

echo "[INFO] Configuring idmap..."
grep -q "^root:100000:65536" /etc/subuid || \
    echo "root:100000:65536" >> /etc/subuid

grep -q "^root:100000:65536" /etc/subgid || \
    echo "root:100000:65536" >> /etc/subgid

chmod u+s /usr/bin/newuidmap
chmod u+s /usr/bin/newgidmap

# --------------------------------------------------
# Setup LVM Storage (if enabled)
# --------------------------------------------------

setup_lvm_storage() {
    if [ "$USE_LVM" != "true" ]; then
        echo "[INFO] LVM storage disabled, using DIR storage"
        return 0
    fi
    
    echo "[INFO] Setting up LVM storage for Incus..."
    
    # Check if vg_incus already exists
    if vgs "$LVM_VG_NAME" &>/dev/null; then
        echo "[INFO] Volume group $LVM_VG_NAME already exists, skipping creation"
        return 0
    fi
    
    # Create directory for loop device
    mkdir -p "$(dirname "$LVM_LOOP_FILE")"
    
    # Create loop device file if it doesn't exist
    if [ ! -f "$LVM_LOOP_FILE" ]; then
        echo "[INFO] Creating loop device file: $LVM_LOOP_FILE ($LVM_LOOP_SIZE)"
        truncate -s "$LVM_LOOP_SIZE" "$LVM_LOOP_FILE"
    else
        echo "[INFO] Loop device file already exists: $LVM_LOOP_FILE"
    fi
    
    # Setup loop device
    echo "[INFO] Setting up loop device..."
    LOOP_DEV=$(losetup -f --show "$LVM_LOOP_FILE")
    echo "[INFO] Loop device created: $LOOP_DEV"
    
    # Create physical volume
    echo "[INFO] Creating physical volume on $LOOP_DEV..."
    pvcreate "$LOOP_DEV"
    
    # Create volume group
    echo "[INFO] Creating volume group: $LVM_VG_NAME..."
    vgcreate "$LVM_VG_NAME" "$LOOP_DEV"
    
    # Verify creation
    echo "[INFO] Verifying LVM setup..."
    pvs | grep "$LOOP_DEV"
    vgs | grep "$LVM_VG_NAME"
    
    # Make loop device persistent across reboots
    echo "[INFO] Making loop device persistent..."
    cat > /etc/systemd/system/incus-lvm-loop.service << EOF
[Unit]
Description=Setup Incus LVM loop device
DefaultDependencies=no
Before=lvm2-activation-early.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/losetup -f $LVM_LOOP_FILE
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF
    
    systemctl daemon-reload
    systemctl enable incus-lvm-loop.service
    
    echo "[INFO] LVM storage setup complete"
    echo "[INFO] Volume Group: $LVM_VG_NAME"
    echo "[INFO] Loop Device: $LOOP_DEV"
    echo "[INFO] Loop File: $LVM_LOOP_FILE"
}

# Setup LVM storage before starting Incus
setup_lvm_storage

# --------------------------------------------------
# Start Incus
# --------------------------------------------------

echo "[INFO] Starting incusd..."
pkill incusd 2>/dev/null || true

nohup /usr/local/bin/incusd >/tmp/incusd.log 2>&1 &

sleep 10

pgrep incusd
/usr/local/bin/incus admin waitready

# --------------------------------------------------
# Initialize Incus
# --------------------------------------------------

echo "[INFO] Initializing Incus..."

# Check if storage pool exists
STORAGE_EXISTS=$(/usr/local/bin/incus storage list --format csv 2>/dev/null | grep -q "^default," && echo "true" || echo "false")

# Check if network exists
NETWORK_EXISTS=$(/usr/local/bin/incus network list --format csv 2>/dev/null | grep -q "^incusbr0," && echo "true" || echo "false")

if [ "$STORAGE_EXISTS" = "true" ] && [ "$NETWORK_EXISTS" = "true" ]; then
    echo "[INFO] Incus already initialized (storage and network exist)"
    echo "[INFO] Existing storage pools:"
    /usr/local/bin/incus storage list
    echo "[INFO] Existing networks:"
    /usr/local/bin/incus network list
else
    echo "[INFO] Running preseed configuration..."
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[ERROR] Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Create network if it doesn't exist
    if [ "$NETWORK_EXISTS" = "false" ]; then
        echo "[INFO] Creating network incusbr0..."
        /usr/local/bin/incus network create incusbr0 \
            ipv4.address=auto \
            ipv4.nat=true \
            ipv6.address=auto \
            ipv6.nat=true \
            --description="Default Incus bridge for $ARCH"
    fi
    
    # Create storage pool if it doesn't exist
    if [ "$STORAGE_EXISTS" = "false" ]; then
        echo "[INFO] Creating storage pool default..."
        /usr/local/bin/incus storage create default lvm \
            source=vg_incus \
            lvm.thinpool_name=IncusThinPool \
            size=180GiB \
            volume.size=60GiB \
            --description="Incus LVM storage pool for $ARCH"
    fi
    
    # Update/create profile
    echo "[INFO] Configuring default profile..."
    /usr/local/bin/incus profile device set default root pool=default 2>/dev/null || \
        /usr/local/bin/incus profile device add default root disk path=/ pool=default
    
    /usr/local/bin/incus profile device set default eth0 network=incusbr0 2>/dev/null || \
        /usr/local/bin/incus profile device add default eth0 nic name=eth0 network=incusbr0
    
    /usr/local/bin/incus profile set default security.nesting=true
    /usr/local/bin/incus profile set default security.syscalls.deny_default=false
fi

# --------------------------------------------------
# Configure Firewalld
# --------------------------------------------------

echo "[INFO] Configuring firewall..."
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd \
        --zone=trusted \
        --add-interface=incusbr0 \
        --permanent || true
    
    firewall-cmd --reload || true
fi

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

# Made with Bob
