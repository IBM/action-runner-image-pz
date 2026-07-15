#!/bin/bash
set -euo pipefail
################################################################################
##  File:  install-incus.sh
##  Desc:  Install Incus from source for Ubuntu
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
# Always use the script's own helpers directory for install.sh
SCRIPT_HELPER_SCRIPTS="${SCRIPT_DIR}/../helpers"

# shellcheck disable=SC1091
source "$SCRIPT_HELPER_SCRIPTS"/install.sh

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
# Configure Groups
# --------------------------------------------------

echo "[INFO] Configuring Incus groups..."
getent group incus       >/dev/null || groupadd --system incus
getent group incus-admin >/dev/null || groupadd --system incus-admin
usermod -aG incus,incus-admin root

# --------------------------------------------------
# Configure User Namespace Mapping
# --------------------------------------------------

echo "[INFO] Configuring idmap..."

# Remove any existing root: entries (may have wrong range from a
# previous partial run) then write the single correct mapping.
# This keeps the operation idempotent across re-runs.
sed -i '/^root:/d' /etc/subuid
echo "root:100000:65536" >> /etc/subuid

sed -i '/^root:/d' /etc/subgid
echo "root:100000:65536" >> /etc/subgid

echo "[INFO] subuid: $(grep ^root /etc/subuid)"
echo "[INFO] subgid: $(grep ^root /etc/subgid)"

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

    # If the VG already exists we have nothing to do.
    if vgs "$LVM_VG_NAME" &>/dev/null; then
        echo "[INFO] Volume group $LVM_VG_NAME already exists, skipping creation"
        return 0
    fi

    # VG is absent — clean up any stale loop devices or PVs from a
    # previous partial run before creating fresh ones.
    echo "[INFO] Cleaning up any stale loop devices backed by $LVM_LOOP_FILE..."
    for dev in $(losetup -j "$LVM_LOOP_FILE" 2>/dev/null | cut -d: -f1); do
        echo "[INFO] Detaching stale loop device: $dev"
        pvremove -ff -y "$dev" 2>/dev/null || true
        losetup -d "$dev" 2>/dev/null || true
    done

    # Create directory and loop device file
    mkdir -p "$(dirname "$LVM_LOOP_FILE")"
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
    # Wipe any stale filesystem or LVM signatures so pvcreate
    # does not fail on a device that was partially initialised.
    wipefs -af "$LOOP_DEV" 2>/dev/null || true
    pvremove -ff -y "$LOOP_DEV" 2>/dev/null || true
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

echo "[INFO] Stopping any existing Incus daemon..."

# Force-kill any running incusd and remove stale socket files so
# the new daemon always starts from a completely clean state.
if pgrep -x incusd >/dev/null 2>&1; then
    echo "[INFO] Stopping incusd..."
    pkill -9 incusd 2>/dev/null || true
    sleep 1
fi
rm -f /run/incus/unix.socket
rm -f /var/run/incus/unix.socket
rm -f /var/lib/incus/unix.socket

# Use a fresh log file each run to avoid permission errors if the
# file was previously created by a different user/process.
INCUSD_LOG=$(mktemp /tmp/incusd.XXXX.log)
echo "[INFO] incusd log: $INCUSD_LOG"

echo "[INFO] Starting incusd..."
nohup /usr/local/bin/incusd --group incus-admin >"$INCUSD_LOG" 2>&1 &

echo "[INFO] Waiting for incusd to become ready..."
for i in {1..30}; do
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

# --------------------------------------------------
# Initialize Incus
# --------------------------------------------------

echo "[INFO] Initializing Incus..."

# Check if storage pool exists
STORAGE_EXISTS=$(/usr/local/bin/incus storage list --format csv 2>/dev/null | grep -q "^default," && echo "true" || echo "false")

# Check if network exists AND is properly configured (managed=YES)
NETWORK_EXISTS=$(/usr/local/bin/incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES," && echo "true" || echo "false")

if [ "$STORAGE_EXISTS" = "true" ] && [ "$NETWORK_EXISTS" = "true" ]; then
    echo "[INFO] Incus already initialized (storage and network exist)"
    echo "[INFO] Existing storage pools:"
    /usr/local/bin/incus storage list
    echo "[INFO] Existing networks:"
    /usr/local/bin/incus network list
else
    # Hybrid approach: Try preseed first if nothing exists, fallback to manual if partial state
    if [ "$STORAGE_EXISTS" = "false" ] && [ "$NETWORK_EXISTS" = "false" ]; then
        echo "[INFO] Fresh installation detected. Attempting preseed initialization..."
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "[ERROR] Config file not found: $CONFIG_FILE"
            exit 1
        fi

        echo "[INFO] Verifying daemon..."

        if ! /usr/local/bin/incus admin waitready --timeout=5; then
            echo "[ERROR] incusd not ready"
            cat "$INCUSD_LOG"
            exit 1
        fi

        # Try preseed initialization
        if timeout 60 /usr/local/bin/incus admin init --preseed < "$CONFIG_FILE"; then
            echo "[INFO] Preseed initialization successful"
        else
            RC=$?
            if [ "$RC" = "124" ]; then
                echo "[ERROR] Preseed initialization timed out"
            fi
            echo "[ERROR] Preseed initialization failed"
            cat "$INCUSD_LOG" || true
            echo "[WARN] Falling back to manual configuration..."
            PRESEED_FAILED=true

            # Re-query state after preseed failure — preseed may have
            # partially succeeded (e.g. created the pool but not the
            # network). Using stale pre-preseed values would cause
            # 'already exists' errors in the manual path below.
            STORAGE_EXISTS=$(/usr/local/bin/incus storage list --format csv 2>/dev/null | grep -q "^default," && echo "true" || echo "false")
            NETWORK_EXISTS=$(/usr/local/bin/incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES," && echo "true" || echo "false")
            echo "[INFO] Post-preseed state — storage: $STORAGE_EXISTS, network: $NETWORK_EXISTS"
        fi
    else
        echo "[INFO] Partial configuration detected (storage: $STORAGE_EXISTS, network: $NETWORK_EXISTS)"
        echo "[INFO] Using manual configuration for idempotent setup..."
        PRESEED_FAILED=true
    fi

    # Manual configuration (runs if preseed failed or partial state exists)
    if [ "${PRESEED_FAILED:-false}" = "true" ]; then
        # Create network if it doesn't exist
        if [ "$NETWORK_EXISTS" = "false" ]; then
            echo "[INFO] Creating network incusbr0..."
            # Remove stale kernel bridge if a previous partial run left one behind
            if ip link show incusbr0 >/dev/null 2>&1; then
                echo "[INFO] Removing stale bridge incusbr0..."
                ip link set incusbr0 down || true
                ip link delete incusbr0 || true
            fi
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
                size=100GiB \
                volume.size=60GiB \
                --description="Incus LVM storage pool for $ARCH"
        fi
    fi
    
    # Always configure profile (works for both preseed and manual)
    echo "[INFO] Configuring default profile..."
    /usr/local/bin/incus profile device set default root pool=default 2>/dev/null || \
        /usr/local/bin/incus profile device add default root disk path=/ pool=default
    
    /usr/local/bin/incus profile device set default eth0 network=incusbr0 2>/dev/null || \
        /usr/local/bin/incus profile device add default eth0 nic name=eth0 network=incusbr0
    
    /usr/local/bin/incus profile set default security.nesting=true
    /usr/local/bin/incus profile set default security.syscalls.deny_default=false
    if [ "$ARCH" = "ppc64le" ]; then
        /usr/local/bin/incus profile set default limits.memory=16GiB
        /usr/local/bin/incus profile set default raw.qemu="-m 16384M,slots=0,maxmem=16384M"
    fi
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

echo ""
echo "[INFO] Incus installation and configuration completed"
echo "[INFO] Base image import will be handled by the calling script"
echo ""


